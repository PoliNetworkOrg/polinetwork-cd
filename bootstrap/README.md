# VM bootstrap

This directory contains the reproducible host layer and the single VM entry
point. The normal clean-host sequence is:

1. Terraform creates `vm01`, its managed identity and data disks.
2. Check out the `vm` branch of this repository.
3. Run `sudo bootstrap/bootstrap-vm.sh`. When privileged OpenBao access is
   needed, the script asks for the administrator password before emitting any
   phase logs. All Azure-held recovery values are fetched by the VM identity.

On an interactive terminal, each phase starts as one blue progress line and is
replaced in place by its green result, so start/result pairs do not duplicate
the log. Successful internal Compose checks stay hidden. Redirected output
contains one plain result line per phase. Command output is captured in a
root-only log under `/var/log/polinetwork`; a failed phase prints its last 80
lines. Use `--verbose` to mirror phase output or `NO_COLOR=1` to disable color.
If the Key Vault webhook secret changes, bootstrap detects the change without
printing either value and recreates doco.cd so the in-memory verifier cannot
continue using stale key material.

From that point doco.cd performs one initial reconciliation and GitHub push
webhooks reconcile all projects under `core/` and `apps/`. There is no
generated Compose catalog, env-file flag or deployment helper script.

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

## One-time webhook setup

From an authenticated operator workstation, run:

```sh
bootstrap/seed-restic-recovery-key.sh /protected/path/restic.pass
bootstrap/configure-doco-webhook.sh
```

The first helper copies and byte-verifies the exact active Zerobyte organization
password without printing it, and refuses to replace an existing value unless
`--replace` is explicit. Keep the source file in the approved off-host break-glass store. The
second helper creates the HMAC secret in Azure Key Vault when absent and creates
or updates the push-only GitHub webhook without printing the secret. Retain the
Argo CD webhook while AKS is the rollback target. A legacy Komodo webhook is
reported but deliberately left unchanged; disable it only after a signed
doco.cd delivery has been accepted on the VM.

The existing remotely managed `*.polinetwork.org` VM tunnel route already
carries `doco-cd.polinetwork.org` to `http://traefik:80`; no additional tunnel
mapping is needed. Do not protect this hostname with Cloudflare Access: GitHub
must reach it directly, while doco.cd authenticates each delivery with the
HMAC secret.
