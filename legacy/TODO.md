# AKS to ARM64 VM migration TODO

Cross-session progress register for the migration from AKS to the ARM64 VM.
This file tracks tasks and macro-tasks only; commands, implementation details
and acceptance criteria belong in the migration plans and operational runbooks.

References:

- [`migration-plan-it.html`](./migration-plan-it.html)
- [`migration-plan.html`](./migration-plan.html)
- [`POST_MIGRATION_TODO.md`](./POST_MIGRATION_TODO.md)
- [`VM_SETUP_RUNBOOK.md`](./VM_SETUP_RUNBOOK.md)

Last reviewed: 2026-08-12

## Current checkpoint

The Azure foundation and `vm01` remain provisioned without changing AKS.
Host bootstrap, storage/reboot recovery, shared Docker networks, dedicated VM
Cloudflare Tunnel, Traefik routing and Wave 1 canaries have passed. doco.cd
`0.108.0` now polls `polinetwork-cd/vm`, discovers each immediate `core/*` and
`apps/*` Compose project without a catalog, and resolves folder-local OpenBao
references. OpenBao and doco.cd remain the only deliberately bootstrapped
`infra/` projects. Every reconciled service is running and each health-checked
service is healthy.

Repository history remains separated: `main` ends at the pre-migration commit
`6ff993a`; migration development remains on `vm`. Runtime application secrets
will live in OpenBao and are injected as environment-backed Compose secrets by
doco.cd, with no CLI env file.

OpenBao production recovery has passed from an empty state disk using Azure
Key Vault Auto Unseal and a direct Restic restore that does not depend on
Zerobyte. The restored cluster identity, `pnadmin` login and canary secret were
verified. Hourly native Raft snapshots and consistent Zerobyte SQLite snapshots
are staged before the six-hour off-host run. A fresh combined Azure backup
passed full repository check, byte-identical restore, SQLite integrity and
semantic validation of the Zerobyte organization, repository, volume, schedule
and retention policy. The active `restic.pass` remains off-host.

The guarded, idempotent `bootstrap/bootstrap-vm.sh` entry point has passed its
first convergence on the healthy host. Before application porting, its local
polish change is awaiting review and deployment: quiet colored phases,
up-front input collection, managed-identity retrieval of Azure-held recovery
values, and an HMAC-authenticated GitHub webhook replacing recurring doco.cd
polling. Terraform validation passed, but the local plan could not refresh the
Azure backend until the repository `access_key.sh` was sourced. The corrected
plan passed with `0 add, 2 change, 0 destroy`; a saved, inspected plan and its
explicitly approved apply remain the next infrastructure gate. After the polish is deployed and a real
`vm`-branch push is observed, the next macro-task is migrating production
application secrets and Compose projects using folder-local native references.

## Migration progress

- [x] Define migration scope, architecture, security constraints and rollback
      principles.
- [x] Validate sponsorship, target cost and temporary AKS/VM overlap budget.
- [x] Inventory workloads and add multi-architecture image publishing for the
      maintained services.
- [x] Provision the Terraform-managed Azure foundation and ARM64 VM while
      keeping AKS unchanged and production-serving.
- [x] Bootstrap the VM host and Docker runtime, including storage layout,
      recovery checks, capacity safeguards and an operational command record.
- [x] Build the Compose-based platform control plane, deployment workflow,
      private networks and workload isolation.
- [x] Deploy and harden edge routing and private administration with Traefik,
      Cloudflare Tunnel and protected management surfaces.
- [ ] Deploy OpenBao and migrate application secrets with tested backup,
      recovery and least-privilege access.
- [ ] Prove full VM-loss recovery starting only from Terraform, Git, Azure Key
      Vault and the approved break-glass store; recovery must not depend on the
      lost Zerobyte database or any file that existed only on `vm01`.
- [ ] Keep every non-secret host/application configuration in Git and converge
      the accepted recovery steps into one guarded, idempotent bootstrap entry
      point with an explicit external-secret manifest.
- [ ] Implement host, container, data and external observability with actionable
      alerts.
- [ ] Implement and prove application-consistent backups and clean-environment
      restores.
- [ ] Convert and qualify the selected applications on native ARM64, including
      capacity, health, deployment and rollback testing.
- [ ] Rehearse migration and rollback for PostgreSQL, InfluxDB, MariaDB and
      persistent application data.
- [ ] Migrate production workloads in incremental waves while retaining an
      immediate route back to AKS.
- [ ] Complete the production acceptance and rollback-observation window.
- [ ] Decommission AKS and obsolete Azure resources through a separate,
      explicitly approved Terraform change.

## Migration-wide gates

- AKS remains production-serving until each workload passes its VM acceptance
  criteria and rollback window.
- Destructive infrastructure changes require a separate reviewed plan and
  explicit approval of the exact targets.
- Every production image, Compose dependency and backup format must be pinned
  or otherwise reproducible before cutover.
- Stateful cutover requires a rehearsed restore, writer fencing, measured
  RTO/RPO and a tested rollback procedure.
- The target host must retain at least 20% CPU and memory headroom under
  representative peak load.

## Deferred until after migration

- [ ] Complete the deferred C# image pipelines and workloads.
- [ ] Decide the fate of dormant and test workloads.
- [ ] Audit and retire MariaDB after the agreed observation period.
- [ ] Complete the centralized identity/OIDC decision independently of the VM
      cutover.
- [ ] Review the first full post-AKS billing period and resize from measured
      evidence only.

Detailed post-migration acceptance criteria remain in
[`POST_MIGRATION_TODO.md`](./POST_MIGRATION_TODO.md).
