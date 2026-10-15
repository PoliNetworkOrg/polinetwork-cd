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
