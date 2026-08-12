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
  must remain on the VM's local disk.
- `/srv/polinetwork/state/backup-staging` is mounted read-only at `/data` and is
  the only application-data tree Zerobyte can read. Producers must write
  consistent exports or snapshots there. Never mount a live database or the
  OpenBao Raft directory into Zerobyte.
- `/srv/polinetwork/state/zerobyte/restore-tests` is the only writable restore
  target, mounted at `/restore-tests`. Recovery rehearsals must use a fresh
  child directory there and must never target `/data` or a live service path.
- `APP_SECRET`, the Restic repository password and the Azure Storage account
  key are stored in the existing `kv-polinetwork` Azure Key Vault. They are
  copied to root-owned mode `0600` files only for container startup and
  disaster recovery; they are not stored in Git, Compose environment variables,
  OpenBao or Terraform state.
- The native Azure backend requires the shared account key and therefore has
  account-wide storage access. Zerobyte uses a dedicated `zerobyte` container;
  the existing `backups` container has 30-day immutable retention and is not a
  valid Restic repository because Restic must remove locks and obsolete packs.

## First deployment

Terraform must first have enabled shared-key access on `polinetworkbackups` and
created a private `zerobyte` container without an immutability policy or an
Azure lifecycle rule that deletes Restic objects independently of Restic.
Create the three secrets in the existing Key Vault from an administrator
workstation. None of these commands prints a secret value:

```sh
ZEROBYTE_APP_SECRET="$(openssl rand -hex 32)"
ZEROBYTE_RESTIC_PASSWORD="$(openssl rand -hex 32)"
ZEROBYTE_STORAGE_KEY="$(az storage account keys list \
  --resource-group rg-polinetwork \
  --account-name polinetworkbackups \
  --query '[0].value' --output tsv)"

az keyvault secret set --vault-name kv-polinetwork \
  --name zerobyte-app-secret --value "$ZEROBYTE_APP_SECRET" --output none
az keyvault secret set --vault-name kv-polinetwork \
  --name zerobyte-restic-password --value "$ZEROBYTE_RESTIC_PASSWORD" --output none
az keyvault secret set --vault-name kv-polinetwork \
  --name zerobyte-azure-storage-account-key --value "$ZEROBYTE_STORAGE_KEY" --output none
unset ZEROBYTE_APP_SECRET ZEROBYTE_RESTIC_PASSWORD ZEROBYTE_STORAGE_KEY
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
  zerobyte-restic-password:restic-repository-password \
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
  cd /srv/polinetwork/compose/polinetwork-cd/compose/backup &&
  docker compose pull &&
  docker compose up -d --wait &&
  docker compose ps
'
```

Complete the initial owner and organization setup in the UI. Preserve the
recovery key outside the VM, in the existing Azure Key Vault and in the
approved break-glass store.

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
        "isExistingRepository": false,
        "customPassword": "file://restic_repository_password"
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
