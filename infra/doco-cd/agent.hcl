vault {
  address = "https://openbao:8200"
  ca_cert = "/openbao/tls/ca.crt"
}

auto_auth {
  method {
    type = "approle"
    config = {
      role_id_file_path                   = "/openbao/auth/role-id"
      secret_id_file_path                 = "/openbao/auth/secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink {
    type = "file"
    config = {
      path = "/run/openbao/token"
      mode = 0640
    }
  }
}
