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
- `provisioning.json` declares the Azure repository and OpenBao snapshot
  volume. Zerobyte initializes the repository when its container is empty;
  backup schedules are configured in the UI.
- The exact `restic.pass` file downloaded for the active Zerobyte organization
  is the Restic password. Its exact bytes are stored as the Key Vault secret
  `zerobyte-restic-recovery-key`, while an approved off-host copy remains an
  independent break-glass artifact. Do not substitute the account password,
  APP secret, an older Key Vault value, or a key from another organization.

## OpenBao snapshots

[`openbao-snapshot/`](openbao-snapshot/) contains the accepted native Raft
snapshot producer, hourly systemd unit and isolated restore rehearsal. Run its
`bootstrap.sh` once after OpenBao restore to create the narrow snapshot
AppRole, then install the unit and timer as documented in that folder.

[`database-snapshot/`](database-snapshot/) creates a consistent, integrity-
checked copy of Zerobyte's SQLite database. Its hourly systemd timer stages the
copy before the off-host schedule, preserving the organization, administrator
and UI-managed backup schedule needed after total VM loss.

The single managed recovery volume backs up the resulting files below
`/srv/polinetwork/state/backup-staging`. It must never copy the live Raft or
live SQLite database.

## Clean-host recovery

Loss of the VM also loses Zerobyte's local database, so recovery deliberately
bypasses the UI. Normal `bootstrap/bootstrap-vm.sh` recovery retrieves the
Azure account key and exact active Restic password through the VM managed
identity and stages them temporarily at:

```text
/srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key
/srv/polinetwork/state/zerobyte/secrets/restic-recovery-key
```

Both files are `root:root`, mode `0600`, and are removed after convergence.
When invoking the disaster-restore helper directly, an operator must still
stage those two files explicitly before running:

```sh
sudo core/zerobyte/openbao-snapshot/disaster-restore.sh
```

The script uses the pinned Zerobyte image's Restic binary directly, verifies
the repository, restores the latest `pn-vm01` `/data` backup into a new
root-only directory, selects the newest native Raft and SQLite snapshots, and
prints both SHA-256 values. It never starts Zerobyte or writes live storage.

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
