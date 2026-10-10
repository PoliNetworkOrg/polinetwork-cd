# polinetwork-cd

PoliNetwork deployment source of truth for the production K3s cluster. Flux on
`k3s01` tracks `main` from [`clusters/k3s`](clusters/k3s) and applies
[`infrastructure/`](infrastructure) and [`apps/<namespace>`](apps). The host
bootstrap (disks, firewall, K3s, backups, Flux) is done with Ansible and
documented in [ansible/README.md](ansible/README.md).

## Layout

```
ansible/          host provisioning and verification
clusters/k3s/     Flux entry point and reconciliation order
infrastructure/   storage, Traefik, External Secrets, cloudflared, image automation, Flux UI
apps/<ns>/        one folder per application namespace
tests/            manifest checks run in CI
bot-prod/ bot-rooms/ mariadb/   legacy AKS folders, disabled
```

## How it works

- **Traffic:** Cloudflare Tunnel → Traefik (`ClusterIP`) → Ingress. The NSG
  denies all inbound traffic, so a public IP on the VM is outbound-only.
  Auth uses `AUTH_CLIENT_IP_HEADER=cf-connecting-ip` for per-address rate limits.
  Cloudflare supplies that header; Traefik's default handling of `X-Forwarded-For`
  does not preserve the visitor address without trusted proxy configuration.
  Keep Auth behind the tunnel and ensure Cloudflare does not remove the header.
  Cluster-internal IdP calls carry no visitor address and share Auth's bounded
  token budget of 60 requests per minute.
- **Secrets:** `ExternalSecret`s sync from Azure Key Vault (`kv-pn-apps`,
  `kv-pn-infra`). No secrets live in Git.
- **Images:** PoliNetwork apps run `ghcr.io/polinetworkorg/<app>:latest`. The
  Flux Operator resolves the digest and rolls out on the GitHub `package`
  webhook, with 6h polling as fallback.
- **Storage:** PVCs use the `fast` or `standard` local-path class on the node's
  data disks, with `Retain` and Flux pruning disabled.
- **Backups:** `age`-encrypted uploads to Azure Blob: control plane daily,
  application data every 6 hours.

## Common tasks

- **New app version:** publish `:latest` to GHCR.
- **Config change:** edit `apps/<ns>/` and merge to `main`.
- **Secret change:** update it in Key Vault; it resyncs within 1h.
- **New app:** add `apps/<ns>/` and `clusters/k3s/apps/<ns>.yaml`, list it in
  `clusters/k3s/apps/kustomization.yaml`, and allow the namespace in
  `infrastructure/secret-stores/` if it needs secrets.
- **Status:** Flux UI at `flux.polinetwork.org`.

CI (`.github/workflows/ansible.yml`) syntax-checks the playbooks, builds the
Kustomizations and runs `tests/`.
