# doco.cd infrastructure

doco.cd reconciles the public `vm` branch once at startup, then receives signed
GitHub push events at `https://doco-cd.polinetwork.org/v1/webhook`. The root
`.doco-cd.yaml` filters webhook refs to `refs/heads/vm` and uses native
auto-discovery for immediate `core/` and `apps/` children. Adding a folder with
`compose.yaml` therefore requires no central edit; deleted folders remove their
project but retain volumes and images.

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

The same bootstrap retrieves the webhook HMAC secret from Azure Key Vault into
`/srv/polinetwork/state/doco-cd/secrets/github-webhook-secret`. Azure Key Vault
is intentional: doco.cd and its authenticated recovery trigger must be
recoverable before OpenBao is available. Compose mounts that exact root-only
file through `WEBHOOK_SECRET_FILE`; no GitHub credential is stored on the VM.
Run [`../../bootstrap/configure-doco-webhook.sh`](../../bootstrap/configure-doco-webhook.sh)
once from an authenticated workstation to create or update the GitHub side.
The existing remotely managed wildcard Cloudflare Tunnel route carries this
hostname to `http://traefik:80`. Keep `doco-cd.polinetwork.org` outside
Cloudflare Access so GitHub can reach it; the HMAC signature authenticates the
request.

To deliberately converge only this already-provisioned infrastructure project:

```sh
docker compose up -d --pull always --wait --wait-timeout 120
```

The service publishes no host port. Only the exact `/v1/webhook` path is routed
through Traefik on `pn-edge`; requests are accepted only when their GitHub
HMAC-SHA256 signature matches. The service mounts the Docker socket, which is
the trust boundary required for direct Compose deployment. Its root process
retains only `DAC_OVERRIDE` after dropping capabilities so it can read the
Agent-owned token and the host Docker socket without hard-coding host-specific
group IDs or making the token world-readable.
