# Bootstrap secret custody

Normal application secrets live in OpenBao and are resolved by doco.cd. Only
secrets needed before OpenBao is available remain outside that loop.

| Secret | Canonical custody | Clean-host use |
| --- | --- | --- |
| OpenBao Azure Auto Unseal key | Azure Key Vault `kv-polinetwork`; VM managed identity | OpenBao startup |
| OpenBao recovery key and admin password | Approved break-glass store | Restore and privileged verification |
| doco.cd AppRole credentials | Regenerated from restored OpenBao | Written once to `/srv/polinetwork/state/openbao/approle/doco-cd` |
| Zerobyte Azure account key | Azure Key Vault | Direct Restic recovery and `secret/core/zerobyte` |
| Zerobyte organization recovery key | Approved break-glass store | Direct Restic recovery only |

The Cloudflare token, Zerobyte runtime APP secret and migrated application
secrets are stored in OpenBao. doco.cd resolves them during reconciliation and
passes them to Compose without an env file. For direct disaster recovery, the
Azure account key and Restic recovery key are streamed into the root-owned
mode-`0600` files documented by `core/zerobyte`; they must never be committed.
