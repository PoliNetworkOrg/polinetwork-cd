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

collab_deployment = deployment("apps/backend/regulations-collab.yaml", "regulations-collab")
collab = container(collab_deployment, "regulations-collab")
collab_policy = network_policy("apps/backend/network-policy.yaml", "regulations-collab")
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
backend_docs = Dir.glob(File.join(ROOT, "apps/backend/*.yaml")).flat_map { |path| YAML.load_stream(File.read(path)).compact }
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
