# External secret manifest

Run `sudo bootstrap/prepare-secrets.sh runtime` before the first service start.
The script keeps existing files, safely splits legacy environment files and
silently prompts for missing values. Keep every value in the listed off-host
store; the VM copy is replaceable runtime state, not canonical custody.

| Protected host file | Canonical source | Granted to |
| --- | --- | --- |
| `komodo/secrets/database-username` | Approved break-glass store | MongoDB, Komodo Core |
| `komodo/secrets/database-password` | Approved break-glass store | MongoDB, Komodo Core |
| `komodo/secrets/init-admin-username` | Approved break-glass store | Komodo Core |
| `komodo/secrets/init-admin-password` | Approved break-glass store | Komodo Core |
| `komodo/secrets/webhook-secret` | Approved break-glass store | Komodo Core |
| `komodo/secrets/jwt-secret` | Approved break-glass store | Komodo Core |
| `cloudflare/secrets/tunnel-token` | Cloudflare/off-host secret store | Cloudflared |
| `zerobyte/secrets/app-secret` | Key Vault `zerobyte-app-secret` | Zerobyte |
| `zerobyte/secrets/azure-storage-account-key` | Key Vault `zerobyte-azure-storage-account-key` | Zerobyte and recovery tooling |
| `zerobyte/secrets/restic-recovery-key` | Approved break-glass store | Recovery tooling only |

Paths are relative to `/srv/polinetwork/state`. Compose never receives a
general-purpose secret environment file. Non-secret values stay in Git.

The VM identity intentionally has no broad Key Vault secret-read policy:
`kv-polinetwork` cannot scope its current access policies to only these two
secrets. Retrieve Key Vault values on an authenticated administrator machine,
then paste them into the silent prompt. `prepare-secrets.sh recovery` stages
the Restic recovery key only when a clean-host restore needs it.
