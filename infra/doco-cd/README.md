# doco.cd infrastructure

doco.cd polls the public `vm` branch every 60 seconds. The repository root
`.doco-cd.yaml` uses native auto-discovery for immediate `core/` and `apps/`
children, so adding a folder with `compose.yaml` requires no central edit.
Deleted folders remove their project but retain volumes and images.

doco.cd reads deployment secrets from OpenBao. Because its OpenBao provider
accepts a token rather than AppRole credentials, the small Agent sidecar logs
in and renews a periodic token in shared tmpfs. This is the only Agent needed;
application folders use native `external_secrets` references.

## One-time provisioning

[`../../bootstrap/bootstrap-vm.sh`](../../bootstrap/bootstrap-vm.sh) verifies
the referenced OpenBao keys, writes the narrow `doco-cd` policy and regenerates
the unlimited-use AppRole credentials directly in protected host state. It
does not print or commit a token. Manual policy, role and credential commands
are deliberately not duplicated here.

To deliberately converge only this already-provisioned infrastructure project:

```sh
docker compose up -d --pull always --wait --wait-timeout 120
```

The service has no published HTTP port or webhook. It does mount the Docker
socket, which is the trust boundary required for direct Compose deployment.
Its root process retains only `DAC_OVERRIDE` after dropping capabilities so it
can read the Agent-owned token and the host Docker socket without hard-coding
host-specific group IDs or making the token world-readable.
