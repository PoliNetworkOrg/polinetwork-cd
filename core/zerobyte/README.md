# Zerobyte backups

Zerobyte provides the backup UI and orchestrates Restic against the dedicated
`zerobyte` Azure Blob container. It receives no Docker socket, host port, FUSE
device or `SYS_ADMIN` capability. Traefik exposes it at
`https://backups.polinetwork.org`; keep that route behind Cloudflare Access.

The local `.doco-cd.yaml` resolves the APP secret and Azure account key from
`secret/core/zerobyte`. Compose mounts both as service-scoped files. Keep the
same Azure account key in Key Vault for clean-host recovery: a secret needed to
open the OpenBao backup cannot live only in OpenBao.

## Storage boundaries

- `/srv/polinetwork/state/zerobyte/data` is replaceable UI/database state, not
  a recovery prerequisite.
- `/srv/polinetwork/state/backup-staging` is read-only input. Producers place
  consistent snapshots there; never expose live database or Raft files.
- `/srv/polinetwork/state/zerobyte/restore-tests` is the only restore target.
- `provisioning.json` declares the existing Azure repository and OpenBao
  snapshot volume. Backup schedules are configured in the UI.
- The exact `restic.pass` file downloaded for the active Zerobyte organization
  is the Restic password and remains in the approved break-glass store outside
  the VM. Do not substitute the account password, APP secret, or a recovery
  key downloaded for another organization.

## OpenBao snapshots

[`openbao-snapshot/`](openbao-snapshot/) contains the accepted native Raft
snapshot producer, hourly systemd unit and isolated restore rehearsal. Run its
`bootstrap.sh` once after OpenBao restore to create the narrow snapshot
AppRole, then install the unit and timer as documented in that folder.

Zerobyte backs up only the resulting files below
`/srv/polinetwork/state/backup-staging/openbao`. It must never copy the live
Raft directory.

## Clean-host recovery

Loss of the VM also loses Zerobyte's local database, so recovery deliberately
bypasses the UI. Stream the Azure account key from Key Vault and the exact
downloaded `restic.pass` file for the active organization from the break-glass
store into:

```text
/srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key
/srv/polinetwork/state/zerobyte/secrets/restic-recovery-key
```

Both files must be `root:root`, mode `0600`. Then run:

```sh
sudo core/zerobyte/openbao-snapshot/disaster-restore.sh
```

The script uses the pinned Zerobyte image's Restic binary directly, verifies
the repository, restores only the latest `pn-vm01` OpenBao snapshot into a new
root-only directory, and prints its SHA-256. It never starts Zerobyte or writes
to live OpenBao storage.

Validate the restored snapshot in an isolated container before promotion:

```sh
printf '%s\n' "$PN_OPENBAO_ADMIN_PASSWORD" |
  sudo REQUIRE_PRODUCTION_OPENBAO=false \
  core/zerobyte/openbao-snapshot/restore-rehearsal.sh \
  /srv/polinetwork/state/zerobyte/restore-tests/REPLACE/openbao-REPLACE.snap
unset PN_OPENBAO_ADMIN_PASSWORD
```

Production restore is a separate guarded step: restore only into an empty
OpenBao Raft target, verify Auto Unseal and the canary, then start doco.cd.
Never restore over non-empty live Raft state.
