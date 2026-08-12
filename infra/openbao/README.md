# OpenBao infrastructure

OpenBao is bootstrapped outside doco.cd because doco.cd reads deployment
secrets from it. The Compose project prepares the Raft directory, generates or
validates the internal TLS certificate, then starts OpenBao with Raft storage
and Azure Key Vault Auto Unseal. The Terraform-managed identity client ID is
non-secret and tracked in Compose.

Audit events go to container stdout and are bounded by Docker's tracked
`local` logging policy (`20m`, five files). Do not restore the former unbounded
audit file below the state disk. The health check requires this single-node
cluster to be active; a responsive standby with no leader is unhealthy.

Converge an already initialized or restored instance after the shared networks
exist:

```sh
docker compose up -d --pull always --wait --wait-timeout 120
```

On an empty state disk, start without `--wait`: the active-only health check
must remain unhealthy until OpenBao has been initialized or a snapshot has been
restored. After that operation and the required restart, use the command above
to enforce the normal health gate.

The state initialization container is idempotent: it enforces the Raft
directory ownership and mode, generates all three TLS files only when none
exists, validates a complete set, and refuses partial TLS state.
Initialization and restoration ordering is owned by
[`../../bootstrap/bootstrap-vm.sh`](../../bootstrap/bootstrap-vm.sh); the
external recovery inputs remain operator-controlled. Native Raft backup and
break-glass tooling live in
[`../../core/zerobyte/openbao-snapshot/`](../../core/zerobyte/openbao-snapshot/).

OpenBao is the sole runtime-secret store for doco.cd projects. It is not
self-managed: updates to this Compose project are applied deliberately before
restarting doco.cd.
