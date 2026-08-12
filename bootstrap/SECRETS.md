# Bootstrap secret custody

Normal application secrets live in OpenBao and are resolved by doco.cd. Only
secrets needed before OpenBao is available remain outside that loop.

| Secret | Canonical custody | Clean-host use |
| --- | --- | --- |
| OpenBao Azure Auto Unseal key | Azure Key Vault `kv-polinetwork`; VM managed identity | OpenBao startup |
| OpenBao recovery key and admin password | Approved break-glass store | Restore and privileged verification |
| Dedicated VM Cloudflare tunnel token | Azure Key Vault secret `cloudflared-vm-tunnel-token` | Seed `secret/core/cloudflared` after OpenBao restore |
| doco.cd AppRole credentials | Regenerated from restored OpenBao | Written once to `/srv/polinetwork/state/openbao/approle/doco-cd` |
| Zerobyte Azure account key | Azure Key Vault | Direct Restic recovery and `secret/core/zerobyte` |
| Zerobyte active-organization `restic.pass` file | Approved break-glass store | Direct Restic recovery only |

The Cloudflare token, Zerobyte runtime APP secret and migrated application
secrets are stored in OpenBao. The Cloudflare token also remains in Azure Key
Vault because the OpenBao snapshot may predate a token rotation or secret-path
migration. doco.cd resolves runtime values during reconciliation and passes
them to Compose without an env file. For direct disaster recovery, the Azure
account key and Restic recovery key are streamed into the root-owned mode-`0600`
files documented by `core/zerobyte`; they must never be committed.
