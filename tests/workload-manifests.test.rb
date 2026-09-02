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
  raise "#{name} must have a TCP readiness probe" unless app.dig("readinessProbe", "tcpSocket", "port") == port
  raise "#{name} must have a TCP liveness probe" unless app.dig("livenessProbe", "tcpSocket", "port") == port
  raise "#{name} must declare resource requests and limits" unless app.dig("resources", "requests") && app.dig("resources", "limits")
end

prometheus = container(deployment("monitoring/src/deployment-prometheus.yaml", "prometheus-server"), "prometheus")
grafana = container(deployment("monitoring/src/deployment-grafana.yaml", "grafana"), "grafana")

raise "Prometheus image must be pinned" unless prometheus["image"].include?("@sha256:")
raise "Prometheus must expose readiness and liveness probes" unless prometheus["readinessProbe"] && prometheus["livenessProbe"]
raise "Prometheus must declare resources" unless prometheus["resources"]
raise "Grafana image must be pinned" unless grafana["image"].include?("@sha256:")
raise "Grafana memory request must cover its observed working set" unless grafana.dig("resources", "requests", "memory") == "768Mi"

puts "workload manifest checks passed"
