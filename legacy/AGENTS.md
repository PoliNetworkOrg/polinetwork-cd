# AKS to VM migration instructions

This directory tracks PoliNetwork's incremental migration from AKS to the
ARM64 Docker Compose host `vm01`. AKS remains the production rollback target
until each workload is accepted on the VM.

## Before starting work

1. Read `TODO.md` for the current checkpoint and next macro-task.
2. Read the relevant recent section of `VM_SETUP_RUNBOOK.md`; search it before
   repeating a command or decision.
3. Check the working tree and active branch of every repository in scope.
4. Confirm current infrastructure state before proposing mutations; never infer
   success from an earlier command.

## Working rules

- Record every proposed VM command in `VM_SETUP_RUNBOOK.md` before execution,
  then append only the result actually reported by the operator.
- The operator normally runs SSH commands; do not connect to `vm01` directly
  unless explicitly asked in the current session.
- Never print, commit or place secret values in command arguments. Use
  1Password, the existing Azure Key Vault `kv-polinetwork`, stdin and protected
  files as documented in the runbook.
- Keep changes scoped and reversible. Do not remove AKS resources or live data
  without an explicit, separately reviewed instruction.
- Use signed Conventional Commits. `polinetwork-cd` targets `main`; Terraform
  targets `stable` through a PR unless the user explicitly requests otherwise.
- Ignore Checkov findings only because the owner explicitly accepted that for
  this migration; still require Terraform validation and an inspected plan.

## Current checkpoint

OpenBao production deployment, Azure Auto Unseal, AppRole/Agent delivery,
hourly native Raft snapshots, Zerobyte/Restic Azure backup, byte-integrity
restore and isolated clean-volume recovery have passed. The next migration
work is adapting production applications to the accepted per-application
OpenBao Agent pattern. See `POST_MIGRATION_TODO.md` only for work intentionally
deferred beyond cutover.
