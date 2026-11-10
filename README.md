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
infrastructure/   storage, Traefik, SSO gateway, External Secrets, cloudflared, image automation, Flux UI
apps/<ns>/        one folder per application namespace
tests/            manifest checks run in CI
bot-prod/ bot-rooms/ mariadb/   legacy AKS folders, disabled
```

## How it works

- **Traffic:** Cloudflare Tunnel → Traefik (`ClusterIP`) → Ingress. The NSG
  denies all inbound traffic except WireGuard on UDP 48726, which reaches the
  WireGuard Portal Pod through a hostPort; the tunnel cannot carry it.
  Auth uses `AUTH_CLIENT_IP_HEADER=cf-connecting-ip` for per-address rate limits.
  Cloudflare supplies that header. The `web` entrypoint trusts `X-Forwarded-*`
  from the pod network, where cloudflared runs, but Auth keeps reading
  `cf-connecting-ip`. Keep Auth behind the tunnel and ensure Cloudflare does
  not remove the header.
  Cluster-internal IdP calls carry no visitor address and share Auth's bounded
  token budget of 60 requests per minute.
- **SSO gateway:** apps without their own OIDC login sit behind oauth2-proxy
  ([`infrastructure/sso`](infrastructure/sso)), which Traefik calls through a
  `forwardAuth` Middleware. People sign in once at `auth.polinetwork.org`, and each
  app's Middleware requires one permission (`?allowed_groups=<permission>`).
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
- **Put an app behind SSO:** create an `<app>:access` permission in Auth and grant
  it to a role. Add this Middleware to `apps/<ns>/`, changing only the permission:

  ```yaml
  apiVersion: traefik.io/v1alpha1
  kind: Middleware
  metadata:
    name: sso
  spec:
    forwardAuth:
      address: http://oauth2-proxy.sso.svc.cluster.local:4180/?allowed_groups=<app>:access
      trustForwardHeader: true
      authResponseHeaders: [X-Auth-Request-User, X-Auth-Request-Email, X-Auth-Request-Preferred-Username]
      # Auth rotates refresh tokens: without this, sessions break after 4 minutes.
      addAuthCookiesToResponse: [__Secure-pn_sso, __Secure-pn_sso_0, __Secure-pn_sso_1, __Secure-pn_sso_2]
      maxResponseBodySize: 1048576
  ```

  Reference it from the Ingress with
  `traefik.ingress.kubernetes.io/router.middlewares: <ns>-sso@kubernetescrd`, add
  `infrastructure-sso` to the app's `dependsOn`, and admit only Traefik with a
  NetworkPolicy. Public paths go in a separate Ingress without the Middleware.
- **Status:** Flux UI at `flux.polinetwork.org`.

CI (`.github/workflows/ansible.yml`) syntax-checks the playbooks, builds the
Kustomizations and runs `tests/`.
