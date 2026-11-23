#!/usr/bin/env ruby

require "yaml"

ROOT = File.expand_path("..", __dir__)

def documents(path)
  YAML.load_stream(File.read(File.join(ROOT, path))).compact
end

def deployment(path, name)
  documents(path).find { |doc| doc["kind"] == "Deployment" && doc.dig("metadata", "name") == name } ||
    raise("missing Deployment #{name}")
end

def container(resource, name)
  resource.dig("spec", "template", "spec", "containers").find { |item| item["name"] == name } ||
    raise("missing container #{name}")
end

def init_container(resource, name)
  resource.dig("spec", "template", "spec", "initContainers").find { |item| item["name"] == name } ||
    raise("missing init container #{name}")
end

{
  "apps/admin/deployment.yaml" => ["admin", 3001],
  "apps/backend/deployment.yaml" => ["backend", 3000],
  "apps/polinetcc/deployment.yaml" => ["polinetcc", 6111],
  "apps/web/deployment.yaml" => ["web", 3000],
}.each do |path, (name, port)|
  resource = deployment(path, name)
  app = container(resource, name)
  strategy = resource.dig("spec", "strategy")

  raise "#{name} must use zero-downtime RollingUpdate" unless strategy == {
    "type" => "RollingUpdate",
    "rollingUpdate" => { "maxUnavailable" => 0, "maxSurge" => 1 },
  }
  raise "#{name} must have a TCP startup probe" unless app.dig("startupProbe", "tcpSocket", "port") == port
  raise "#{name} must have a TCP readiness probe" unless app.dig("readinessProbe", "tcpSocket", "port") == port
  raise "#{name} must have a TCP liveness probe" unless app.dig("livenessProbe", "tcpSocket", "port") == port
  raise "#{name} must declare resource requests and limits" unless app.dig("resources", "requests") && app.dig("resources", "limits")
end

prometheus_deployment = deployment("apps/monitoring/deployment-prometheus.yaml", "prometheus-server")
grafana_deployment = deployment("apps/monitoring/deployment-grafana.yaml", "grafana")
prometheus = container(prometheus_deployment, "prometheus")
prometheus_permissions = init_container(prometheus_deployment, "init-permissions")
grafana = container(grafana_deployment, "grafana")

raise "Prometheus image must be pinned" unless prometheus["image"].include?("@sha256:")
raise "Prometheus init image must be pinned" unless prometheus_permissions["image"].include?("@sha256:")
raise "Prometheus must expose startup, readiness, and liveness probes" unless prometheus["startupProbe"] && prometheus["readinessProbe"] && prometheus["livenessProbe"]
raise "Prometheus must declare resources" unless prometheus["resources"]
raise "Prometheus must use Recreate with its single-writer PVC" unless prometheus_deployment.dig("spec", "strategy", "type") == "Recreate"
raise "Grafana image must be pinned" unless grafana["image"].include?("@sha256:")
raise "Grafana memory request must cover its observed working set" unless grafana.dig("resources", "requests", "memory") == "768Mi"
raise "Grafana must use Recreate with its single-writer PVC" unless grafana_deployment.dig("spec", "strategy", "type") == "Recreate"

postgres_deployment = deployment("apps/postgres/deployment.yaml", "postgres")
postgres = container(postgres_deployment, "postgres")
raise "PostgreSQL must keep a single writer during rollout" unless postgres_deployment.dig("spec", "strategy", "type") == "Recreate"
raise "PostgreSQL must report database readiness" unless postgres.dig("readinessProbe", "exec", "command").last.include?("pg_isready")
raise "Do not restart PostgreSQL automatically on probe failures" if postgres["livenessProbe"]

vaultwarden_deployment = deployment("apps/vaultwarden/deployment.yaml", "vaultwarden")
vaultwarden = container(vaultwarden_deployment, "vaultwarden")
vaultwarden_env = vaultwarden["env"].to_h { |item| [item["name"], item] }
raise "Vaultwarden image must be pinned" unless vaultwarden["image"].include?("@sha256:")
raise "Vaultwarden must use Recreate with its single-writer PVC" unless vaultwarden_deployment.dig("spec", "strategy", "type") == "Recreate"
raise "Vaultwarden must expose startup, readiness, and liveness probes" unless vaultwarden["startupProbe"] && vaultwarden["readinessProbe"] && vaultwarden["livenessProbe"]
raise "Vaultwarden must declare resources" unless vaultwarden.dig("resources", "requests") && vaultwarden.dig("resources", "limits")
raise "Vaultwarden must not allow open signups" unless vaultwarden_env.dig("SIGNUPS_ALLOWED", "value") == "false"
raise "Vaultwarden must require SSO login" unless vaultwarden_env.dig("SSO_ENABLED", "value") == "true" && vaultwarden_env.dig("SSO_ONLY", "value") == "true"
raise "Vaultwarden SSO must not create accounts for any auth user" unless vaultwarden_env.dig("SSO_SIGNUPS_ALLOWED", "value") == "false"
raise "Vaultwarden must read its database URL from a secret" unless vaultwarden_env.dig("DATABASE_URL", "valueFrom", "secretKeyRef")

live_audience_deployment = deployment("apps/live-audience/deployment.yaml", "live-audience")
live_audience = container(live_audience_deployment, "live-audience")
live_audience_env = live_audience["env"].to_h { |item| [item["name"], item] }
raise "Live Audience must run exactly one replica" unless live_audience_deployment.dig("spec", "replicas") == 1
raise "Live Audience must use Recreate with its single-writer SQLite PVC" unless live_audience_deployment.dig("spec", "strategy", "type") == "Recreate"
raise "Live Audience must expose startup, readiness, and liveness probes" unless live_audience["startupProbe"] && live_audience["readinessProbe"] && live_audience["livenessProbe"]
raise "Live Audience must declare resources" unless live_audience.dig("resources", "requests") && live_audience.dig("resources", "limits")
raise "Live Audience must never enable the fake dev login" if live_audience_env.key?("DEV_LOGIN")
raise "Live Audience must read its OIDC client secret from a secret" unless live_audience_env.dig("OIDC_CLIENT_SECRET", "valueFrom", "secretKeyRef")

def network_policy(path, name)
  documents(path).find { |doc| doc["kind"] == "NetworkPolicy" && doc.dig("metadata", "name") == name } ||
    raise("missing NetworkPolicy #{name}")
end

def hardened!(name, resource, app)
  pod = resource.dig("spec", "template", "spec")
  raise "#{name} must run as a numeric non-root user" unless pod.dig("securityContext", "runAsNonRoot") && pod.dig("securityContext", "runAsUser").to_i.positive?
  raise "#{name} must use the RuntimeDefault seccomp profile" unless pod.dig("securityContext", "seccompProfile", "type") == "RuntimeDefault"
  raise "#{name} must not mount a service account token" unless pod["automountServiceAccountToken"] == false
  raise "#{name} must have a read-only root filesystem" unless app.dig("securityContext", "readOnlyRootFilesystem")
  raise "#{name} must not allow privilege escalation" unless app.dig("securityContext", "allowPrivilegeEscalation") == false
  raise "#{name} must drop all capabilities" unless app.dig("securityContext", "capabilities", "drop") == ["ALL"]
end

def from_pod?(peer, namespace, app)
  peer.dig("namespaceSelector", "matchLabels") == { "kubernetes.io/metadata.name" => namespace } &&
    peer.dig("podSelector", "matchLabels") == { "app" => app }
end

TRAEFIK = {
  "namespaceSelector" => { "matchLabels" => { "kubernetes.io/metadata.name" => "kube-system" } },
  "podSelector" => { "matchLabels" => { "app.kubernetes.io/name" => "traefik" } },
}.freeze

def peers(policy, port)
  policy.dig("spec", "ingress").select { |rule| rule["ports"].any? { |item| item["port"] == port } }.flat_map { |rule| rule["from"] }
end

collab_deployment = deployment("apps/regulations-collab/deployment.yaml", "regulations-collab")
collab = container(collab_deployment, "regulations-collab")
collab_policy = network_policy("apps/regulations-collab/network-policy.yaml", "regulations-collab")
raise "Collab must run the backend image, so it ships with the backend's digest" unless collab["image"] == container(deployment("apps/backend/deployment.yaml", "backend"), "backend")["image"]
raise "Collab must run exactly one replica" unless collab_deployment.dig("spec", "replicas") == 1
raise "Collab must use Recreate so one process owns each open document" unless collab_deployment.dig("spec", "strategy", "type") == "Recreate"
%w[startupProbe readinessProbe livenessProbe].each do |probe|
  raise "Collab must have a TCP #{probe}" unless collab.dig(probe, "tcpSocket", "port") == 4100
end
raise "Collab must declare resource requests and limits" unless collab.dig("resources", "requests") && collab.dig("resources", "limits")
hardened!("Collab", collab_deployment, collab)
raise "Collab must restrict both ingress and egress" unless collab_policy.dig("spec", "policyTypes").sort == %w[Egress Ingress]
raise "Only Traefik may reach the collab websocket" unless peers(collab_policy, 4100) == [TRAEFIK]
raise "Only the backend may reach the collab internal API" unless peers(collab_policy, 4101) == [{ "podSelector" => { "matchLabels" => { "app" => "backend" } } }]
raise "Collab exposes only ports 4100 and 4101" unless collab_policy.dig("spec", "ingress").flat_map { |rule| rule["ports"].map { |item| item["port"] } }.sort == [4100, 4101]

worker_deployment = deployment("apps/latex-worker/deployment.yaml", "latex-worker")
worker = container(worker_deployment, "latex-worker")
worker_env = worker["env"].to_h { |item| [item["name"], item["value"]] }
worker_policy = network_policy("apps/latex-worker/network-policy.yaml", "latex-worker")
worker_limits = documents("apps/latex-worker/limits.yaml")
hardened!("LaTeX worker", worker_deployment, worker)
raise "LaTeX worker must declare CPU and memory requests and limits" unless %w[requests limits].all? { |kind| worker.dig("resources", kind, "cpu") && worker.dig("resources", kind, "memory") }
work_mount = worker.fetch("volumeMounts", []).find { |mount| mount["mountPath"] == "/work" } || raise("LaTeX worker must mount a /work volume")
work_volume = worker_deployment.dig("spec", "template", "spec", "volumes").find { |volume| volume["name"] == work_mount["name"] }
raise "LaTeX worker /work must be a size-limited tmpfs" unless work_volume.dig("emptyDir", "medium") == "Memory" && work_volume.dig("emptyDir", "sizeLimit")
%w[WORKER_WORK_DIR WORKER_TMP_DIR].each do |name|
  mount = worker.fetch("volumeMounts", []).find { |item| item["mountPath"] == worker_env[name] } || raise("LaTeX worker #{name} must be a mounted volume, not the read-only root")
  volume = worker_deployment.dig("spec", "template", "spec", "volumes").find { |item| item["name"] == mount["name"] }
  raise "LaTeX worker #{name} must be a size-limited tmpfs" unless volume.dig("emptyDir", "medium") == "Memory" && volume.dig("emptyDir", "sizeLimit")
end
collab_env = collab["env"].to_h { |item| [item["name"], item["value"]] }
raise "Collab must not send more parallel compiles than the worker runs" unless collab_env["REGULATIONS_COMPILE_CONCURRENCY"].to_i.between?(1, worker_env["WORKER_CONCURRENCY"].to_i)
# RLIMIT_NPROC (the worker's prlimit --nproc per xelatex) counts every task of
# the uid on the node, so the worker's uid must be its own.
worker_uid = worker_deployment.dig("spec", "template", "spec", "securityContext", "runAsUser")
other_uids = Dir.glob(File.join(ROOT, "{apps,infrastructure}/**/*.yaml")).reject { |path| path.include?("apps/latex-worker/") }.flat_map do |path|
  File.read(path).scan(/runAsUser:\s*(\d+)/).flatten.map(&:to_i)
end
raise "LaTeX worker must run as a uid no other workload or common image user (1000) uses" if worker_uid.to_i == 1000 || other_uids.include?(worker_uid.to_i)
raise "LaTeX worker policy must cover every Pod in its namespace" unless worker_policy.dig("spec", "podSelector") == {}
raise "LaTeX worker must restrict both ingress and egress" unless worker_policy.dig("spec", "policyTypes").sort == %w[Egress Ingress]
raise "LaTeX worker must have no egress at all" unless worker_policy.dig("spec", "egress") == []
raise "LaTeX worker may only be reached by the backend and collab" unless worker_policy.dig("spec", "ingress").flat_map { |rule| rule["from"] }.all? { |peer| from_pod?(peer, "backend", "backend") || from_pod?(peer, "backend", "regulations-collab") }
raise "LaTeX worker namespace needs a LimitRange" unless worker_limits.any? { |doc| doc["kind"] == "LimitRange" }
quota = worker_limits.find { |doc| doc["kind"] == "ResourceQuota" } || raise("LaTeX worker namespace needs a ResourceQuota")
raise "LaTeX worker quota must cap CPU and memory limits" unless quota.dig("spec", "hard", "limits.cpu") && quota.dig("spec", "hard", "limits.memory")

# The backend stays in-cluster only (#28) except its declared /public prefix
# (regulations spec, "Public backend routes"). A NetworkPolicy cannot filter
# paths, so the guard is routing: in the backend namespace (Ingresses and
# IngressRoutes only reach Services in their own namespace) exactly one router
# targets backend-service, with exactly this rule and these middlewares.
PUBLIC_RULE = "Host(`api.polinetwork.org`) && PathPrefix(`/public/`) && PathRegexp(`^/public(/[A-Za-z0-9_-]+)+$`)".freeze
backend_dirs = Dir.glob(File.join(ROOT, "apps/*/kustomization.yaml")).select { |path| YAML.safe_load(File.read(path))["namespace"] == "backend" }.map { |path| File.dirname(path) }
raise "expected apps/backend and apps/regulations-collab in the backend namespace" unless backend_dirs.map { |dir| File.basename(dir) }.sort == %w[backend regulations-collab]
backend_docs = backend_dirs.flat_map { |dir| Dir.glob(File.join(dir, "*.yaml")) }.reject { |path| path.end_with?("kustomization.yaml") }.flat_map { |path| YAML.load_stream(File.read(path)).compact }
backend_docs += documents("apps/regulations-secrets/external-secrets.yaml").select { |doc| doc.dig("metadata", "namespace") == "backend" }
backend_docs.select { |doc| doc["kind"] == "Ingress" }.flat_map { |ingress| ingress.dig("spec", "rules") }.flat_map { |rule| rule.dig("http", "paths") }.each do |path|
  raise "Ingresses in the backend namespace may only publish the collab websocket" unless path.dig("backend", "service") == { "name" => "regulations-collab", "port" => { "number" => 4100 } }
end
raise "Only Traefik CRDs this test understands may route in the backend namespace" if backend_docs.any? { |doc| %w[IngressRouteTCP IngressRouteUDP TraefikService].include?(doc["kind"]) }
backend_routes = backend_docs.select { |doc| doc["kind"] == "IngressRoute" }.flat_map { |route| route.dig("spec", "routes") }
raise "Exactly one route may reach the backend, its /public prefix" unless backend_routes.size == 1
public_route = backend_routes.first
raise "The backend public route must match only #{PUBLIC_RULE}" unless public_route["match"] == PUBLIC_RULE
raise "The backend public route must target backend-service:3000" unless public_route["services"] == [{ "name" => "backend-service", "port" => 3000 }]
middlewares = backend_docs.select { |doc| doc["kind"] == "Middleware" }.to_h { |doc| [doc.dig("metadata", "name"), doc["spec"]] }
route_middlewares = public_route.fetch("middlewares", []).map { |item| middlewares.fetch(item["name"]) { raise "missing Middleware #{item["name"]}" } }
raise "The backend public route needs a body size limit" unless route_middlewares.any? { |spec| spec.dig("buffering", "maxRequestBodyBytes").to_i.between?(1, 10 * 1024 * 1024) }
raise "The backend public route needs a per-visitor rate limit" unless route_middlewares.any? { |spec| spec.dig("rateLimit", "sourceCriterion", "requestHeaderName") == "Cf-Connecting-Ip" }
raise "The backend public route needs a total rate limit" unless route_middlewares.any? { |spec| spec.dig("rateLimit", "sourceCriterion", "requestHost") }
raise "The backend public route must stamp X-PoliNetwork-Ingress: public" unless route_middlewares.any? { |spec| spec.dig("headers", "customRequestHeaders") == { "X-PoliNetwork-Ingress" => "public" } }

# The same whitelist Traefik evaluates (RE2 and Ruby agree on this pattern).
public_path = Regexp.new(PUBLIC_RULE[/PathRegexp\(`(.+)`\)/, 1])
%w[/public/webhooks/github /public/a /public/a-b_c/D9].each do |path|
  raise "#{path} must stay reachable" unless path.start_with?("/public/") && public_path.match?(path)
end
%w[
  / /api/trpc /api/trpc/regulations.list /internal/events /trpc /public /public/ /publicx /publicx/a /PUBLIC/a
  /public/../api/trpc /public/./a /public/a/.. /public/.. /public//a /public/a/ //public/a /x/public/a
  /public/%2e%2e/api/trpc /public/%2E%2E%2Fapi%2Ftrpc /public/..%2fapi/trpc /public%2f..%2fapi /public/a%00
  /public/a;x /public/a\\..\\api /public/webhooks/github.json /public/~a /public/a@b
].each do |path|
  raise "#{path} must not match the public route" if path.start_with?("/public/") && public_path.match?(path)
end

# Merging must be harmless before Lorenzo creates the regulations secrets and
# the worker image is pullable: nothing that needs them may run, fail or alert.
def flux_kustomizations(path)
  YAML.load_stream(File.read(File.join(ROOT, path))).compact.flat_map do |doc|
    doc["kind"] == "ResourceSet" ? doc.dig("spec", "resources") : [doc]
  end.select { |doc| doc["kind"] == "Kustomization" }.to_h { |doc| [doc.dig("metadata", "name"), doc["spec"]] }
end
flux = flux_kustomizations("clusters/k3s/apps/backend.yaml").merge(flux_kustomizations("clusters/k3s/apps/latex-worker.yaml")).merge(flux_kustomizations("clusters/k3s/apps/regulations-secrets.yaml"))
gate = flux.fetch("regulations-secrets")
raise "clusters/k3s/apps/kustomization.yaml must list regulations-secrets.yaml" unless YAML.safe_load(File.read(File.join(ROOT, "clusters/k3s/apps/kustomization.yaml")))["resources"].include?("regulations-secrets.yaml")
raise "regulations-secrets must check only the core secrets, not every ExternalSecret" unless gate["wait"] == false && gate["healthChecks"]
gated_secrets = gate["healthChecks"].select { |check| check["kind"] == "ExternalSecret" }.map { |check| [check["namespace"], check["name"]] }
external_secrets = documents("apps/regulations-secrets/external-secrets.yaml").to_h { |doc| [[doc.dig("metadata", "namespace"), doc.dig("metadata", "name")], doc.dig("spec", "target", "name")] }
%w[regulations-collab latex-worker].each do |name|
  raise "#{name} must wait for regulations-secrets" unless flux.fetch(name)["dependsOn"].map { |dep| dep["name"] }.include?("regulations-secrets")
end
raise "The backend Kustomization must not wait for regulations-secrets" if flux.fetch("backend")["dependsOn"].map { |dep| dep["name"] }.include?("regulations-secrets")
{ collab_deployment => "backend", worker_deployment => "latex-worker" }.each do |resource, namespace|
  resource.dig("spec", "template", "spec", "containers").flat_map { |item| item.fetch("env", []) }.map { |item| item.dig("valueFrom", "secretKeyRef") }.compact.reject { |ref| ref["optional"] }.each do |ref|
    next if ref["name"] == "azure-kv"
    raise "#{resource.dig("metadata", "name")} requires Secret #{ref["name"]}, which regulations-secrets does not gate" unless gated_secrets.any? { |ns, es| ns == namespace && external_secrets[[ns, es]] == ref["name"] }
  end
end
backend_app = container(deployment("apps/backend/deployment.yaml", "backend"), "backend")
backend_app.fetch("env", []).map { |item| item.dig("valueFrom", "secretKeyRef") }.compact.reject { |ref| ref["name"] == "azure-kv" }.each do |ref|
  raise "The backend must read regulations Secret #{ref["name"]} with optional: true" unless ref["optional"] == true && external_secrets.value?(ref["name"])
end
raise "apps/backend must not hold ExternalSecrets other than azure-kv" unless documents("apps/backend/external-secret.yaml").map { |doc| doc.dig("metadata", "name") } == ["azure-kv"]

%w[core edge gateway].each do |component|
  name = "defguard-#{component}"
  resource = deployment("infrastructure/defguard/deployment-#{component}.yaml", name)
  app = container(resource, name)
  raise "#{name} image must be pinned" unless app["image"].include?("@sha256:")
  raise "#{name} must use Recreate" unless resource.dig("spec", "strategy", "type") == "Recreate"
  raise "#{name} must expose readiness and liveness probes" unless app["readinessProbe"] && app["livenessProbe"]
  raise "#{name} must declare resources" unless app.dig("resources", "requests") && app.dig("resources", "limits")
  raise "#{name} must drop all capabilities" unless app.dig("securityContext", "capabilities", "drop") == ["ALL"]
end
defguard_gateway = container(deployment("infrastructure/defguard/deployment-gateway.yaml", "defguard-gateway"), "defguard-gateway")
raise "Defguard Gateway must not run privileged" if defguard_gateway.dig("securityContext", "privileged")
raise "Defguard Gateway may only add NET_ADMIN" unless defguard_gateway.dig("securityContext", "capabilities", "add") == ["NET_ADMIN"]

wg_portal_deployment = deployment("infrastructure/wg-portal/deployment.yaml", "wg-portal")
wg_portal = container(wg_portal_deployment, "wg-portal")
wg_portal_env = wg_portal["env"].to_h { |item| [item["name"], item] }
raise "WireGuard Portal image must be pinned" unless wg_portal["image"].include?("@sha256:")
raise "WireGuard Portal must use Recreate with its hostPort" unless wg_portal_deployment.dig("spec", "strategy", "type") == "Recreate"
raise "WireGuard Portal must not run privileged" if wg_portal.dig("securityContext", "privileged")
raise "WireGuard Portal may only add NET_ADMIN" unless wg_portal.dig("securityContext", "capabilities", "add") == ["NET_ADMIN"]
raise "WireGuard Portal must store its state in PostgreSQL" unless wg_portal_env.dig("WG_PORTAL_DATABASE_TYPE", "value") == "postgres"
%w[WG_PORTAL_DATABASE_DSN WG_PORTAL_DATABASE_ENCRYPTION_PASSPHRASE WG_PORTAL_CORE_ADMIN_PASSWORD WG_PORTAL_WEB_SESSION_SECRET WG_PORTAL_WEB_CSRF_SECRET].each do |name|
  raise "WireGuard Portal must read #{name} from a secret" unless wg_portal_env.dig(name, "valueFrom", "secretKeyRef")
end

# Gatus: status.polinetwork.org is anonymous, so the public instance must load
# nothing but the public endpoints, and every path of uptime.polinetwork.org
# except the gate's own /oauth2 must cross the it-member gate.
gatus_kustomization = YAML.safe_load(File.read(File.join(ROOT, "apps/gatus/kustomization.yaml")))
gatus_maps = gatus_kustomization["configMapGenerator"].to_h { |map| [map["name"], map["files"]] }
raise "The public Gatus instance must load only the public endpoints and its settings" unless gatus_maps["gatus-status-config"].sort == %w[config/endpoints-public.yaml config/status.yaml]
status_settings = YAML.safe_load(File.read(File.join(ROOT, "apps/gatus/config/status.yaml")))
raise "The public Gatus settings must not define endpoints, metrics, security or alerting" if (status_settings.keys & %w[endpoints external-endpoints suites metrics security alerting]).any?
public_config = YAML.safe_load(File.read(File.join(ROOT, "apps/gatus/config/endpoints-public.yaml")))
raise "endpoints-public.yaml must hold only endpoints: the anonymous instance loads it" unless public_config.keys == ["endpoints"]
public_endpoints = public_config["endpoints"]
raise "Public Gatus endpoints must hide check errors on the anonymous page" unless public_endpoints.all? { |item| item.dig("ui", "hide-errors") == true }
raise "Public Gatus endpoints must be https URLs, never in-cluster addresses" unless public_endpoints.all? { |item| item["url"].start_with?("https://") && !item["url"].include?(".svc") }
gatus_names = (public_endpoints + YAML.safe_load(File.read(File.join(ROOT, "apps/gatus/config/endpoints-internal.yaml")))["endpoints"]).map { |item| item["name"] }
raise "Gatus endpoint names must be unique" unless gatus_names.uniq.size == gatus_names.size
# The internal instance may reach in-cluster services: a monitored origin must
# not be able to redirect it there.
gatus_http = (public_endpoints + YAML.safe_load(File.read(File.join(ROOT, "apps/gatus/config/endpoints-internal.yaml")))["endpoints"]).select { |item| item["url"].start_with?("http") }
raise "Gatus HTTP endpoints must not follow redirects" unless gatus_http.all? { |item| item.dig("client", "ignore-redirect") == true }
# A failing connectivity check makes Gatus skip every endpoint while its gauges
# keep the last results, so no EndpointDown could ever fire.
gatus_maps.values.flatten.uniq.each do |file|
  raise "Gatus #{file} must not use the connectivity checker" if YAML.safe_load(File.read(File.join(ROOT, "apps/gatus", file))).key?("connectivity")
end
raise "endpoints-internal.yaml must hold only endpoints" unless YAML.safe_load(File.read(File.join(ROOT, "apps/gatus/config/endpoints-internal.yaml"))).keys == ["endpoints"]
gatus_rules = YAML.safe_load(File.read(File.join(ROOT, "apps/monitoring/prometheus/alert-rules.yml")))["groups"].flat_map { |group| group["rules"] }.map { |rule| rule["alert"] }
%w[EndpointDown UptimeChecksStalled].each { |name| raise "Prometheus must alert #{name}" unless gatus_rules.include?(name) }
# Every Gatus endpoint shares one scrape instance: a critical EndpointDown must
# only mute the warning of the same endpoint.
inhibit = YAML.safe_load(File.read(File.join(ROOT, "apps/monitoring/alertmanager/alertmanager.yml")))["inhibit_rules"]
raise "Alertmanager inhibition must compare the Gatus endpoint key" unless inhibit.all? { |rule| rule["equal"].include?("key") }

{ "gatus" => "gatus-config", "gatus-status" => "gatus-status-config" }.each do |name, config_map|
  resource = deployment("apps/gatus/deployment-#{name == "gatus" ? "gatus" : "status"}.yaml", name)
  app = container(resource, "gatus")
  pod = resource.dig("spec", "template", "spec")
  hardened!(name, resource, app)
  raise "#{name} image must be pinned" unless app["image"].include?("@sha256:")
  raise "#{name} must use Recreate with its single-writer SQLite PVC" unless resource.dig("spec", "strategy", "type") == "Recreate"
  raise "#{name} must expose startup, readiness, and liveness probes" unless app["startupProbe"] && app["readinessProbe"] && app["livenessProbe"]
  raise "#{name} must declare resources" unless app.dig("resources", "requests") && app.dig("resources", "limits")
  config_volume = pod["volumes"].find { |volume| volume.dig("configMap", "name") == config_map } || raise("#{name} must mount #{config_map}")
  # Gatus walks its whole config directory, including the ..<timestamp>
  # directory of a plain ConfigMap mount, and would load every file twice.
  file_mounts = app["volumeMounts"].select { |mount| mount["name"] == config_volume["name"] }
  raise "#{name} must mount each config file with subPath" unless file_mounts.all? { |mount| mount["subPath"] && mount["mountPath"] == "/etc/gatus/#{mount["subPath"]}" }
  raise "#{name} must mount exactly the files of #{config_map}" unless file_mounts.map { |mount| mount["subPath"] }.sort == gatus_maps[config_map].map { |file| File.basename(file) }.sort
end

gatus_gate = container(deployment("apps/gatus/deployment-gate.yaml", "gatus-gate"), "oauth2-proxy")
hardened!("Gatus gate", deployment("apps/gatus/deployment-gate.yaml", "gatus-gate"), gatus_gate)
raise "The Gatus gate must admit only it-member" unless gatus_gate["args"].select { |arg| arg.start_with?("--allowed-group") } == ["--allowed-group=it-member"]
raise "The Gatus gate must use PKCE" unless gatus_gate["args"].include?("--code-challenge-method=S256")
raise "The Gatus gate cookie must be a __Host- cookie" unless gatus_gate["args"].any? { |arg| arg.start_with?("--cookie-name=__Host-") }

gatus_ingresses = documents("apps/gatus/ingress.yaml")
gatus_ingresses.each do |ingress|
  middlewares = ingress.dig("metadata", "annotations", "traefik.ingress.kubernetes.io/router.middlewares").to_s.split(",")
  ingress.dig("spec", "rules").each do |rule|
    rule.dig("http", "paths").each do |path|
      service = path.dig("backend", "service", "name")
      case rule["host"]
      when "uptime.polinetwork.org"
        next if service == "gatus-gate" && path["path"] == "/oauth2"
        raise "uptime.polinetwork.org may only route to the internal instance" unless service == "gatus"
        raise "uptime.polinetwork.org must cross the it-member gate" unless middlewares.include?("gatus-it-member-gate@kubernetescrd")
      when "status.polinetwork.org"
        raise "status.polinetwork.org may only route to the public instance" unless service == "gatus-status"
      else
        raise "unexpected Gatus host #{rule["host"]}"
      end
    end
  end
end
gatus_policy = network_policy("apps/gatus/network-policy.yaml", "allow-traefik")
raise "Only Traefik may reach the Gatus web ports" unless peers(gatus_policy, 4180) == [TRAEFIK] && peers(gatus_policy, 8080) == [TRAEFIK]
raise "Only Prometheus may reach the internal Gatus besides Traefik" unless peers(network_policy("apps/gatus/network-policy.yaml", "allow-prometheus"), 8080).all? { |peer| from_pod?(peer, "monitoring", "prometheus-server") }

# Traefik is the only auth layer in front of the internal Gatus: its image
# must be digest-pinned and carry the 3.7.18 security fixes.
traefik_values = YAML.safe_load(documents("infrastructure/traefik/traefik-service.yaml").find { |doc| doc["kind"] == "HelmChartConfig" }.dig("spec", "valuesContent"))
raise "Traefik must be pinned by digest" unless traefik_values.dig("image", "digest").to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
raise "Traefik must be at least 3.7.18" unless Gem::Version.new(traefik_values.dig("image", "tag").to_s) >= Gem::Version.new("3.7.18")

claims = Dir.glob(File.join(ROOT, "apps/*/*.yaml")).flat_map do |path|
  YAML.load_stream(File.read(path)).compact.select { |doc| doc["kind"] == "PersistentVolumeClaim" }
end
raise "expected application PVCs under apps/" if claims.empty?
claims.each do |claim|
  name = claim.dig("metadata", "name")
  raise "#{name} must use the fast or standard local-path class" unless %w[fast standard].include?(claim.dig("spec", "storageClassName"))
  raise "Flux must never prune #{name}" unless claim.dig("metadata", "annotations", "kustomize.toolkit.fluxcd.io/prune") == "disabled"
end

puts "workload manifest checks passed"
