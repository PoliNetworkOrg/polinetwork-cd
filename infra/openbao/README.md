# OpenBao infrastructure

OpenBao is bootstrapped outside doco.cd because doco.cd reads deployment
secrets from it. The Compose project generates or validates the internal TLS
certificate, then starts OpenBao with Raft storage and Azure Key Vault Auto
Unseal. The Terraform-managed identity client ID is non-secret and tracked in
Compose.

Audit events go to container stdout and are bounded by Docker's tracked
`local` logging policy (`20m`, five files). Do not restore the former unbounded
audit file below the state disk. The health check requires this single-node
cluster to be active; a responsive standby with no leader is unhealthy.

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
