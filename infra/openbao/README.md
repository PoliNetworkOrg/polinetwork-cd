# OpenBao infrastructure

OpenBao is bootstrapped outside doco.cd because doco.cd reads deployment
secrets from it. The Compose project generates or validates the internal TLS
certificate, then starts OpenBao with Raft storage and Azure Key Vault Auto
Unseal. The Terraform-managed identity client ID is non-secret and tracked in
Compose.

Start or converge it from this directory after the shared networks exist:

```sh
docker compose up -d --pull always --wait --wait-timeout 120
```

The TLS initialization container is idempotent: it generates all three files
only when none exists, validates a complete set, and refuses partial state.
OpenBao initialization, snapshot restoration and recovery-key custody remain
operator-controlled steps. Native Raft backup and clean-host recovery tooling
live in [`../../core/zerobyte/openbao-snapshot/`](../../core/zerobyte/openbao-snapshot/).

OpenBao is the sole runtime-secret store for doco.cd projects. It is not
self-managed: updates to this Compose project are applied deliberately before
restarting doco.cd.
