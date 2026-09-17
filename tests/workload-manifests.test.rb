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
  "admin/src/deployment.yaml" => ["admin", 3001],
  "backend/src/deployment.yaml" => ["backend", 3000],
  "polinetcc/src/deployment.yaml" => ["polinetcc", 6111],
  "web/src/deployment.yaml" => ["web", 3000],
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

prometheus_deployment = deployment("monitoring/src/deployment-prometheus.yaml", "prometheus-server")
grafana_deployment = deployment("monitoring/src/deployment-grafana.yaml", "grafana")
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

postgres_deployment = deployment("postgres/src/deployment.yaml", "postgres")
postgres = container(postgres_deployment, "postgres")
raise "PostgreSQL must keep a single writer during rollout" unless postgres_deployment.dig("spec", "strategy", "type") == "Recreate"
raise "PostgreSQL must report database readiness" unless postgres.dig("readinessProbe", "exec", "command").last.include?("pg_isready")
raise "Do not restart PostgreSQL automatically on probe failures" if postgres["livenessProbe"]

claims = Dir.glob(File.join(ROOT, "**/src/*.yaml")).flat_map do |path|
  YAML.load_stream(File.read(path)).compact.select { |doc| doc["kind"] == "PersistentVolumeClaim" }
end
claims.each do |claim|
  next unless claim.dig("spec", "storageClassName") == "longhorn"
  options = claim.dig("metadata", "annotations", "argocd.argoproj.io/sync-options").to_s.split(",")
  raise "Argo must retain #{claim.dig("metadata", "name")}" unless ["Prune=false", "Delete=false"].all? { |option| options.include?(option) }
end

puts "workload manifest checks passed"
