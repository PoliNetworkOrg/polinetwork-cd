ui = true
disable_mlock = false
log_level = "info"

api_addr = "https://openbao.polinetwork.org"
cluster_addr = "http://openbao:8201"

storage "raft" {
  path    = "/openbao/data"
  node_id = "vm01"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable     = true
}

telemetry {
  disable_hostname = true
}
