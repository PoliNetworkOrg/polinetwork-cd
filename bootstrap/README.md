# VM bootstrap

This directory contains the reproducible host layer and recovery contract.
The normal clean-host sequence is:

1. Terraform creates `vm01`, its managed identity and data disks.
2. Check out the `vm` branch of this repository.
3. Run `sudo bootstrap/bootstrap-host.sh` to install the pinned Docker runtime
   and create the shared networks.
4. Start [`../infra/openbao/`](../infra/openbao/), then initialize it or restore
   the accepted Raft snapshot from Azure Blob.
5. Provision the single doco.cd AppRole and start
   [`../infra/doco-cd/`](../infra/doco-cd/).

From that point doco.cd polls Git and reconciles all projects under `core/` and
`apps/`. There is no generated Compose catalog, env-file flag or deployment
helper script.

`bootstrap-host.sh` supports Debian 13 ARM64 and verifies an already-running
host without restarting containers. Pinned package versions are the non-secret
defaults at the top of the file. Shared Docker networks and runtime config are
validated exactly; drift fails for operator review.

## Recovery boundary

The OpenBao backup has passed native Raft snapshot creation, encrypted Azure
Blob storage, byte-integrity restore and isolated clean-volume recovery. The
break-glass entry point is
[`../core/zerobyte/openbao-snapshot/disaster-restore.sh`](../core/zerobyte/openbao-snapshot/disaster-restore.sh);
it opens the Restic repository directly and does not depend on Zerobyte's local
database.

No value needed to recover OpenBao may exist only in OpenBao. The few external
inputs and their custody are listed in [`SECRETS.md`](SECRETS.md). Full-stack
one-command recovery remains incomplete until every migrated stateful
application has its own tested backup and restore procedure.
