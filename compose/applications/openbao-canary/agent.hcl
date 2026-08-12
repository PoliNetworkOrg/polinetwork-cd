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
}

template_config {
  exit_on_retry_failure         = true
  static_secret_render_interval = "1m"
}

template {
  source               = "/openbao/templates/canary.env.ctmpl"
  destination          = "/run/secrets/canary.env"
  perms                = "0640"
  backup               = false
  error_on_missing_key = true
}
