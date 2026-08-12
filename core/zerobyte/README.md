# Zerobyte backup project

This project runs Zerobyte as the operator UI and Restic orchestrator for VM
backups. It uses Zerobyte's simplified local-directory mode: no Docker socket,
host ports, FUSE device or `SYS_ADMIN` capability is provided.
The `v0.41` image is pinned to its verified Linux ARM64 manifest digest.

The public route is `https://backups.polinetwork.org` through the existing
Cloudflare Tunnel and Traefik. Protect it with a dedicated Cloudflare Access
application before deploying the container.

## Storage and trust boundaries

- `/srv/polinetwork/state/zerobyte/data` contains Zerobyte's local database and
  must remain on the VM's local disk. It is useful for normal operations but is
  not a prerequisite for break-glass recovery of the Restic repository.
- `/srv/polinetwork/state/backup-staging` is mounted read-only at `/data` and is
  the only application-data tree Zerobyte can read. Producers must write
  consistent exports or snapshots there. Never mount a live database or the
  OpenBao Raft directory into Zerobyte.
- `/srv/polinetwork/state/zerobyte/restore-tests` is the only writable restore
  target, mounted at `/restore-tests`. Recovery rehearsals must use a fresh
  child directory there and must never target `/data` or a live service path.
- `APP_SECRET` and the Azure Storage account key are stored in the existing
  `kv-polinetwork` Azure Key Vault. They are copied to root-owned mode `0600`
  files only for container startup and disaster recovery; they are not stored
  in Git, Compose environment variables, OpenBao or Terraform state.
- The organization recovery key downloaded during onboarding is the actual
  Restic repository password. It remains in the approved break-glass store and
  is staged as `restic-recovery-key` only during clean-host recovery. It is not
  needed for normal Zerobyte startup because the APP-secret-encrypted copy is
  in Zerobyte's database.
- The native Azure backend requires the shared account key and therefore has
  account-wide storage access. Zerobyte uses a dedicated `zerobyte` container;
  the existing `backups` container has 30-day immutable retention and is not a
  valid Restic repository because Restic must remove locks and obsolete packs.

## First deployment

Terraform must first have enabled shared-key access on `polinetworkbackups` and
created a private `zerobyte` container without an immutability policy or an
Azure lifecycle rule that deletes Restic objects independently of Restic.
Create the two runtime secrets in the existing Key Vault from an administrator
workstation. None of these commands prints a secret value:

```sh
ZEROBYTE_APP_SECRET="$(openssl rand -hex 32)"
ZEROBYTE_STORAGE_KEY="$(az storage account keys list \
  --resource-group rg-polinetwork \
  --account-name polinetworkbackups \
  --query '[0].value' --output tsv)"

az keyvault secret set --vault-name kv-polinetwork \
  --name zerobyte-app-secret --value "$ZEROBYTE_APP_SECRET" --output none
az keyvault secret set --vault-name kv-polinetwork \
  --name zerobyte-azure-storage-account-key --value "$ZEROBYTE_STORAGE_KEY" --output none
unset ZEROBYTE_APP_SECRET ZEROBYTE_STORAGE_KEY
```

Prepare the VM paths:

```sh
ssh pn-vm01 'sudo install -d -o root -g root -m 0700 \
  /srv/polinetwork/state/zerobyte/data \
  /srv/polinetwork/state/zerobyte/secrets \
  /srv/polinetwork/state/zerobyte/restore-tests \
  /srv/polinetwork/state/backup-staging/openbao'
```

Copy each secret directly from Key Vault to its mode `0600` VM file:

```sh
for mapping in \
  zerobyte-app-secret:app-secret \
  zerobyte-azure-storage-account-key:azure-storage-account-key
do
  keyvault_name="${mapping%%:*}"
  file_name="${mapping#*:}"
  az keyvault secret show --vault-name kv-polinetwork \
    --name "$keyvault_name" --query value --output tsv |
    tr -d '\r\n' |
    ssh pn-vm01 "sudo install -o root -g root -m 0600 /dev/stdin \
      /srv/polinetwork/state/zerobyte/secrets/$file_name"
done
unset keyvault_name file_name mapping
```

Deploy only after Cloudflare Access is active:

```sh
ssh pn-vm01 '
  cd /srv/polinetwork/compose/polinetwork-cd/core/zerobyte &&
  docker compose pull &&
  docker compose up -d --wait &&
  docker compose ps
'
```

Complete the initial owner and organization setup in the UI. Preserve the
recovery key outside the VM in the approved break-glass store.

## Azure repository provisioning

Provisioning requires the organization ID created during first-run setup.
Consequently, the committed `provisioning.json` intentionally starts empty.
After obtaining the organization ID, add these entries and commit the actual
ID; the credential values remain file references:

```json
{
  "version": 1,
  "repositories": [
    {
      "id": "azure-primary",
      "organizationId": "REPLACE_WITH_ORGANIZATION_ID",
      "name": "Azure primary",
      "backend": "azure",
      "compressionMode": "auto",
      "config": {
        "backend": "azure",
        "container": "zerobyte",
        "accountName": "polinetworkbackups",
        "accountKey": "file://azure_storage_account_key",
        "endpointSuffix": "core.windows.net",
        "isExistingRepository": false
      }
    }
  ],
  "volumes": [
    {
      "id": "openbao-snapshots",
      "organizationId": "REPLACE_WITH_ORGANIZATION_ID",
      "name": "OpenBao snapshots",
      "backend": "directory",
      "autoRemount": true,
      "config": {
        "backend": "directory",
        "path": "/data/openbao"
      }
    }
  ]
}
```

Restart Zerobyte after changing provisioning data. Repository and volume
provisioning is declarative, but backup jobs and schedules must currently be
created through the UI. Do not schedule OpenBao until its snapshot producer is
installed and a clean restore has been rehearsed.

After the first successful repository initialization,
`isExistingRepository` must remain `true` in the tracked provisioning file.
This prevents a rebuilt instance from attempting to initialize storage that
already contains the production Restic repository. Do not set a
`customPassword`: this repository was initialized with the organization's
recovery key.

## OpenBao snapshot producer

Zerobyte must back up native Raft snapshots, never live Raft files. Bootstrap
the dedicated short-lived, three-use AppRole by piping the existing `pnadmin`
password to `openbao-snapshot/bootstrap.sh`. Its policy can only read the Raft
snapshot endpoint; the bootstrap proves a snapshot succeeds and a different
Raft endpoint is denied.

Install `openbao-snapshot.service` and `.timer` into `/etc/systemd/system`.
The timer creates an atomic snapshot in the read-only Zerobyte staging mount at
minute 05 of every hour and retains staging files for seven days. Configure the
Zerobyte job after it, for example at minute 15. Restic retention remains a
separate job-level setting.

After restoring one snapshot from Zerobyte into the dedicated restore-test
mount, pipe the `pnadmin` password to `sudo restore-rehearsal.sh`. Root is
required to traverse the intentionally protected restore and OpenBao runtime
directories. If the restore directory contains multiple snapshots, pass the
absolute path of the one under test as the sole argument. The script creates an
isolated, temporary OpenBao container, bridge network and Docker volume with no
published ports or production-network membership. The script initializes only
that disposable cluster, force-restores the snapshot, verifies Azure Auto
Unseal, authenticates as `pnadmin`, reads the known canary secret, confirms the
production container stayed healthy, and removes all temporary resources.

## Clean-host recovery without Zerobyte

Loss of the VM also loses Zerobyte's local database and UI. Do not make that
database a dependency for opening its backups. The pinned Zerobyte image
contains Restic 0.19.1, and `openbao-snapshot/disaster-restore.sh` uses that
binary directly against `azure:zerobyte:/`.

On a freshly bootstrapped host, first stream the Azure account key from Key
Vault and the organization recovery key from the approved break-glass store
into these root-owned mode-`0600` paths:

```text
/srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key
/srv/polinetwork/state/zerobyte/secrets/restic-recovery-key
```

For example, from an authenticated administrator workstation, stream the
recovery key on stdin; never put its value in the SSH command:

```sh
op read 'REPLACE_WITH_APPROVED_1PASSWORD_REFERENCE' |
  tr -d '\r\n' |
  ssh pn-vm01 'sudo install -d -o root -g root -m 0700 \
    /srv/polinetwork/state/zerobyte/secrets && \
    sudo install -o root -g root -m 0600 /dev/stdin \
    /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key'
```

Then run:

```sh
sudo core/zerobyte/openbao-snapshot/disaster-restore.sh
```

The script:

- does not start Zerobyte or read `/srv/polinetwork/state/zerobyte/data`;
- checks ownership and mode of both secret files;
- lists the latest `pn-vm01` `/data/openbao` snapshot and runs a Restic
  repository metadata check;
- restores only that snapshot subtree into a new, root-only directory;
- refuses an existing target and never writes into live OpenBao state; and
- prints the restored file's SHA-256 and absolute path.

To validate the downloaded snapshot on a host where production OpenBao is not
yet running, pipe the restored `pnadmin` password from the approved break-glass
store and explicitly disable only the production-health assertion:

```sh
printf '%s\n' "$PN_OPENBAO_ADMIN_PASSWORD" |
  sudo REQUIRE_PRODUCTION_OPENBAO=false \
  core/zerobyte/openbao-snapshot/restore-rehearsal.sh \
  /srv/polinetwork/state/zerobyte/restore-tests/openbao-disaster-REPLACE/openbao-REPLACE.snap
unset PN_OPENBAO_ADMIN_PASSWORD
```

This environment variable does not weaken the isolated recovery container; it
only skips checking a production container that cannot exist yet on a clean
host. The rehearsal still uses a new Docker volume/network, Azure Auto Unseal,
`pnadmin` authentication and the known canary value.

The final production promotion remains a separate, deliberately guarded step:
start from an empty OpenBao Raft target, force-restore the validated snapshot,
and verify normal application Agent delivery before starting dependent apps.
Never restore over a non-empty live Raft directory.
