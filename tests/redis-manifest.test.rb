#!/usr/bin/env ruby

require "yaml"

root = File.expand_path("..", __dir__)
documents = YAML.load_stream(File.read(File.join(root, "bot-ts/src/deployment.yaml"))).compact

deployment = lambda do |name|
  documents.find { |doc| doc["kind"] == "Deployment" && doc.dig("metadata", "name") == name } ||
    raise("missing Deployment #{name}")
end
container = lambda do |resource, name|
  resource.dig("spec", "template", "spec", "containers").find { |item| item["name"] == name } ||
    raise("missing container #{name}")
end

redis = deployment.call("bot-ts-redis")
redis_container = container.call(redis, "bot-ts-redis")
bot_container = container.call(deployment.call("bot-ts"), "bot-ts")
pvc = documents.find { |doc| doc["kind"] == "PersistentVolumeClaim" && doc.dig("metadata", "name") == "redis-pvc" }

raise "Redis image must be pinned by digest" unless redis_container["image"].include?("@sha256:")
raise "Redis must use noeviction" unless redis_container.fetch("args", []).include?("noeviction")
raise "Redis must enable AOF" unless redis_container.fetch("args", []).each_cons(2).include?(["--appendonly", "yes"])
raise "Redis must have readiness and liveness probes" unless redis_container["readinessProbe"] && redis_container["livenessProbe"]
raise "Redis must mount redis-pvc at /data" unless redis_container.fetch("volumeMounts", []).any? { |mount| mount == { "name" => "redis-pvc", "mountPath" => "/data" } }
raise "The bot must not mount the Redis data volume" if bot_container.fetch("volumeMounts", []).any? { |mount| mount["name"] == "redis-pvc" }
raise "Redis PVC must leave room for AOF rewrites" unless pvc.dig("spec", "resources", "requests", "storage") == "1Gi"

puts "Redis manifest checks passed"
