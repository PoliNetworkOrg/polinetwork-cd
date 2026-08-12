# Bootstrap secret custody

Normal application secrets live in OpenBao and are resolved by doco.cd. A
secret needed to recover OpenBao cannot live only in OpenBao, so the small
bootstrap set below remains in Azure Key Vault `kv-polinetwork`.

| Secret | Azure Key Vault name | Clean-host use |
| --- | --- | --- |
| Dedicated VM Cloudflare token | `cloudflared-vm-tunnel-token` | Re-seed `secret/core/cloudflared` after restore |
| doco.cd GitHub HMAC secret | `doco-cd-github-webhook-secret` | Authenticate `/v1/webhook` before OpenBao-dependent reconciliation |
| Zerobyte runtime APP secret | `zerobyte-app-secret` | Re-seed `secret/core/zerobyte` |
| Zerobyte Azure storage account key | `zerobyte-azure-storage-account-key` | Open the Azure Restic repository and re-seed OpenBao |
| Active Zerobyte organization Restic password | `zerobyte-restic-recovery-key` | Recover the OpenBao and Zerobyte snapshots |

The VM backup/bootstrap user-assigned managed identity receives only Key Vault
secret `Get`. The bootstrap fetch helper also enforces the exact name allowlist
above and writes values atomically as `root:root`, mode `0600`. It uses the
Azure Instance Metadata Service directly, so the VM does not need Azure CLI or
operator credentials.

The exact active `restic.pass` bytes must be seeded once as
`zerobyte-restic-recovery-key`; do not reuse an older Key Vault value or a key
from another Zerobyte organization. Keep the approved off-host copy as an
independent break-glass artifact even after it is copied to Key Vault. Use
`bootstrap/seed-restic-recovery-key.sh /protected/path/restic.pass` so the
value travels as a file and is never placed in a command argument or output.

The OpenBao Azure Auto Unseal key remains in Key Vault under its Terraform-
managed custody. The OpenBao recovery key and administrator password remain in
the approved human break-glass store. AppRole credentials are regenerated from
restored OpenBao and written only to protected host state.

`sudo bootstrap/bootstrap-vm.sh` fetches all Azure-held values itself. It asks
for the OpenBao administrator password at startup only when recovery,
credential regeneration, or `--with-admin` requires it; it never accepts that
password as an argument or writes it to the log. Temporary recovery copies are
removed after successful convergence and by the exit trap.
