# VM bootstrap

This directory contains the reproducible host layer and the single VM entry
point. The normal clean-host sequence is:

1. Terraform creates `vm01`, its managed identity and data disks.
2. Check out the `vm` branch of this repository.
3. Stream the Azure storage key and active organization `restic.pass` into the
   protected paths in [`SECRETS.md`](SECRETS.md).
4. Run `sudo bootstrap/bootstrap-vm.sh` and answer its single protected
   OpenBao administrator-password prompt.

From that point doco.cd polls Git and reconciles all projects under `core/` and
`apps/`. There is no generated Compose catalog, env-file flag or deployment
helper script.

`bootstrap-vm.sh` is guarded and idempotent. It calls `bootstrap-host.sh`,
restores OpenBao and Zerobyte only when their live state is absent, regenerates
the host-local AppRoles, starts doco.cd, waits for the restored Zerobyte state,
and installs both snapshot timers. It refuses an initialized/partially missing
state rather than overwriting it. Temporary restore output and VM credential
copies are removed only after every health gate passes.

`bootstrap-host.sh` remains the reusable host-only layer. It supports Debian
13 ARM64 and verifies an already-running host without restarting containers.
Pinned package versions are its non-secret defaults. Runtime configuration,
shared networks and the custom containerd-root skeleton are Git-backed and
validated exactly; drift fails for operator review.

## Recovery boundary

The combined platform backup has passed native OpenBao and consistent SQLite
snapshot creation, encrypted Azure Blob storage, full Restic checks,
byte-identical direct recovery and isolated semantic validation. The
break-glass retrieval entry point used by `bootstrap-vm.sh` is
[`../core/zerobyte/openbao-snapshot/disaster-restore.sh`](../core/zerobyte/openbao-snapshot/disaster-restore.sh);
it opens the Restic repository directly and does not depend on Zerobyte's local
database.

No value needed to recover OpenBao may exist only in OpenBao. The external
inputs and their custody are listed in [`SECRETS.md`](SECRETS.md). Stateful
applications added later still require their own consistent producers and
tested restores before cutover.
