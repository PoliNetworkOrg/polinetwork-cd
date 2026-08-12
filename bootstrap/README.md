# VM bootstrap and disaster-recovery contract

This directory is the Git-backed source for host configuration that is not
secret. The target is a repeatable recovery flow:

1. Terraform creates or replaces `vm01` and attaches the data disks.
2. An operator checks out this public repository.
3. `bootstrap-host.sh` installs and configures the pinned container runtime and
   creates the shared Docker networks.
4. Bootstrap secrets are streamed from their off-host stores into protected
   files. Secret values are never command arguments or Git content.
5. Retained data disks are reused, or off-host backups are restored to clean
   storage before workloads start.
6. `core/openbao/prepare.sh` prepares the managed-identity selector and
   internal TLS before the core services start.
7. `core/komodo/start.sh` starts Komodo first; its Git-backed Resource Sync then
   manages the `core` and `applications` Stacks.

Secret restoration and state recovery will be added to the top-level
orchestration only as each application gets an accepted clean-host restore
procedure. Until then, this is the reproducible host and control-plane layer,
not a claim that every application can already be recovered.

## Run the host layer

Prerequisites:

- Debian 13 ARM64 provisioned by the Terraform foundation module;
- `/srv/polinetwork/state` and `/srv/polinetwork/applications` mounted on their
  dedicated data disks by `prepare-data-disks.service`;
- a clean checkout of this repository; and
- root access through the `pnadmin` account.

From the repository root on the VM:

```sh
sudo bootstrap/bootstrap-host.sh
sudo PN_OPENBAO_CLIENT_ID=REPLACE_WITH_TERRAFORM_OUTPUT \
  core/openbao/prepare.sh
core/komodo/start.sh
```

The script refuses unsupported OS/architecture combinations. If containers
already exist, it enters validation-only mode: every package version, tracked
runtime file and shared network must match exactly, and no service is
restarted. Any drift fails closed for manual review.

Package versions can be changed in Git by editing the non-secret defaults near
the top of `bootstrap-host.sh`. The script deliberately fails if an exact
version is no longer available; it never silently substitutes `latest`.

## Configuration and custody inventory

| Input | Canonical source | Clean-host handling |
| --- | --- | --- |
| Docker/containerd config and systemd ordering | This directory | Installed by `bootstrap-host.sh` |
| Compose files, OpenBao policy/templates and backup scripts | This repository | Public Git checkout |
| Shared Docker network definitions | `bootstrap-host.sh` | Created idempotently and verified exactly |
| Terraform/cloud-init and disk preparation | `PoliNetworkOrg/terraform` | Applied before this script |
| OpenBao managed-identity client ID | Terraform output; non-secret | Rendered by `core/openbao/prepare.sh` |
| Internal OpenBao TLS | `core/openbao/prepare.sh` | New private key and CA per rebuilt host |
| Zerobyte APP secret and Azure account key | `kv-polinetwork` | Streamed to root-owned mode-`0600` files |
| Zerobyte organization recovery key | Approved break-glass store | Opens repositories independently of the UI account |
| OpenBao recovery key and `pnadmin` password | Approved break-glass store | Used only for privileged recovery/verification |
| Cloudflare Tunnel token | Off-host secret store | Streamed to the edge env file |
| Application runtime secrets | Restored OpenBao data | Rendered by per-application Agents after OpenBao recovery |

No secret required to recover OpenBao may exist only inside OpenBao. No
configuration required to locate a backup may exist only in Zerobyte's local
database.

## Accepted and pending recovery scopes

The current OpenBao backup has passed native Raft snapshot creation, encrypted
off-host storage, byte-integrity restore and isolated clean-volume recovery.
`../core/zerobyte/openbao-snapshot/disaster-restore.sh` additionally provides the
clean-host entry point that opens Azure Blob directly with Restic, without a
running Zerobyte instance or its local database.

The complete one-script gate remains open until all of the following pass:

- clean Terraform replacement of the VM with retained data disks;
- clean-host OpenBao restore starting only with Git, Azure/Key Vault and the
  approved break-glass store;
- backup and restore of Komodo/Mongo state or a fully declarative replacement;
- application-consistent backup and restore for every migrated database and
  mutable application data tree;
- off-host custody for every bootstrap secret, including the tunnel token;
- ordered full-stack startup, health checks and a timed recovery rehearsal.
