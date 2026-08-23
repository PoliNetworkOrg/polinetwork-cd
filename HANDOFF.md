# Migration handoff — 23 August 2026

This document is the restart point after the workstation is erased. It records facts verified from Git, Terraform state, Azure read-only queries, and the relevant T3 Code threads. Secret values are intentionally excluded.

## Executive state

- AKS is still production. No application or database cutover to K3s has been recorded.
- The Azure K3s foundation has already been applied. `k3s01` is running, private-only, on ARM64.
- The failed earlier VM/Compose target has already been removed through Terraform. Its Git branch remains only as historical evidence.
- Terraform state splitting and CI are merged to `terraform#stable`.
- Multi-architecture container publishing is present on the maintained application repositories listed below.
- Ansible, Flux, ESO, K3s host provisioning, workload conversion, data migration, DR rehearsal, and cutover are still to do.
- Two decisions must be reconciled before the next Terraform apply: the final two-vault design and the actual Key Vault firewall state.
- The daily SSH design also needs an explicit final confirmation: the canonical plan still uses Cloudflare Access; a later thread explored Headscale/Headplane but did not approve the switch.

## Do not resume the superseded attempt

`polinetwork-cd#vm` at `59522e5` is the old Docker Compose migration based on doco.cd, OpenBao, Zerobyte, and per-service Compose projects. It is clean and was pushed, but it is not the K3s implementation branch.

The old attempt proved useful facts—backup/restore behavior, data sizes, ARM64 builds, and bootstrap failure modes—but its architecture is superseded. Do not:

- branch new work from `vm`;
- deploy its Compose control plane to `k3s01`;
- treat old OpenBao success as proof that ESO/Key Vault on K3s works;
- infer current Azure or VM health from `legacy/VM_SETUP_RUNBOOK.md`.

New `polinetwork-cd` implementation must start from `origin/main` (`6ff993a` at this snapshot) on a new branch such as `k3s-flux`.

## Verified Azure and Terraform state

Read-only checks on 23 August 2026 showed:

| Item | Verified state |
|---|---|
| VM | `k3s01`, running, `Standard_E2ps_v6`, private IP `10.43.1.4`, no VM public IP |
| OS disk | `disk-k3s01-os`, Standard SSD, 64 GiB in Terraform |
| Fast disk | `disk-k3s-fast`, Premium SSD v2, 64 GiB, 3,000 IOPS / 125 MB/s in Terraform |
| Standard disk | `disk-k3s-standard`, Standard SSD, 128 GiB in Terraform |
| Network | `vnet-k3s`, `snet-k3s`, deny-inbound NSG, outbound-only NAT Gateway and public IP |
| Identities | separate ESO, backend Blob, and backup UAMIs in `k3s.tfstate` |
| Shared services | `rg-polinetwork`, `polinetworksa`, `polinetworkbackups`, backup containers, retention, and budgets retained |
| Old failed target | `vm01`, `disk-core`, `disk-services`, old VNet/PIP/NIC/NSG and old OpenBao identities absent |
| AKS | retained in the legacy state and still production-serving |
| Unowned temporary network | `disk-insp-2-vnet` still exists outside the K3s state; identify its owner before considering removal |

Terraform repository facts after a fresh fetch:

- `origin/stable`: `933d9ed`;
- state split merged by PR `#79` as `0937051`;
- protected apply workflow restored/fixed by PR `#80` (`565b104`) and follow-up `e2c5ef6`;
- `environments/legacy` uses `state.tfstate`;
- `environments/k3s` uses `k3s.tfstate`;
- current stable legacy plan: `No changes`;
- current stable K3s plan: `0 add, 3 change, 0 destroy`, all three changes enforcing Key Vault firewall `Allow → Deny` and adding `snet-k3s`.

No plan output or state file belongs in Git; both can contain sensitive metadata.

## Terraform work already completed

PR `#79` did all of the following and was applied:

- split legacy and K3s ownership without moving AKS into the new state;
- kept shared backup storage and budgets in the legacy state using declarative `moved` blocks;
- created the ARM64 VM, disks, VNet/subnet/NSG, outbound NAT, identities, RBAC, and Blob access;
- removed the old `module.foundation` implementation;
- removed the authorized failed-test resources while preserving AKS and shared storage;
- added per-environment validation/plan/apply CI.

The destructive cleanup was limited to the reviewed old test. Its two data disks were deleted without snapshots and are irrecoverable. This action must not be replayed.

## Terraform reconciliation still required

Terraform was applied before the final Key Vault naming decision. Azure currently contains:

- `kv-polinetwork-platform`;
- `kv-polinetwork-apps`;
- `kv-polinetwork-ci`.

The later accepted target is only:

- `kv-pn-infra` — Cloudflare, backup, controllers, and infrastructure runtime secrets;
- `kv-pn-apps` — application and database runtime secrets.

There is no new CI vault: GHCR uses temporary `GITHUB_TOKEN`, Azure uses GitHub OIDC, and legacy CI credentials should be verified and retired rather than copied.

Required next Terraform PR:

1. branch from the latest `origin/stable`;
2. inventory only secret metadata/consumer ownership in the three applied vaults; never print values;
3. change the Terraform map and RBAC references to `infra` and `apps` with the two final names;
4. retain firewall `default_action = "Deny"` and `snet-k3s` access;
5. inspect all creates/deletes carefully because Key Vault purge protection is enabled;
6. require no VM, disk, network, AKS, or shared-storage replacement;
7. apply through the protected workflow, then require both roots to report `No changes`.

Before that apply, refresh the cost estimate. The earlier USD 103–110/month estimate omitted the applied 64 GiB OS disk and the NAT Gateway/public IP. The annual USD 2,000 credit implies an average ceiling of USD 166.67/month.

## Application image work already completed

The following ARM64 publishing changes are durable on each repository's `main` branch:

| Repository | Main commit | Result |
|---|---|---|
| `admin` | `d5fb641` | native amd64/arm64 builds and a combined `latest` manifest |
| `backend` | `a641510` | amd64/arm64 Buildx publication to `latest` |
| `polinet.cc` | `8fb680c` | native multi-architecture publication |
| `web` | `73126fc` | native amd64/arm64 builds and a combined `latest` manifest |
| `telegram` | `bae4ed5` | amd64/arm64 publication to `latest` |
| `bot-maintenance` | `f0e6595` (after `dba6d33`) | only `latest`, verified amd64/arm64 manifest |

The original migration branches in some clones are now deleted or superseded remotely. Do not recreate them merely to preserve history: the relevant Docker workflows are already on `main`. Revalidate a fresh GHCR manifest immediately before each workload is enabled.

## Decisions that are final

The full rationale is in `migration-plan.md`. The condensed set is:

- target: single-node K3s on `Standard_E2ps_v6`, operated as production from bootstrap;
- operations: Terraform → Azure, Ansible → host/K3s, Flux → Kubernetes resources, ESO → Key Vault secrets;
- source of truth: `polinetwork-cd` for Ansible, Flux, apps, and operations; Terraform remains separate;
- storage: OS 64 GiB, fast Premium SSD v2 64 GiB at baseline performance, standard SSD 128 GiB; K3s/containerd and normal PVCs on standard;
- ingress: Cloudflare Tunnel → bundled K3s Traefik as `ClusterIP`; no ServiceLB, MetalLB, Azure Load Balancer, or VM public IP;
- K3s/Traefik: exact K3s pin and checksum in Ansible; bundled Traefik configured with `HelmChartConfig`, not a second Flux Helm release;
- secrets: two RBAC Key Vaults, namespaced ESO `SecretStore` resources, no values in Terraform or Git;
- images: PoliNetwork manifests keep `:latest`; Flux Operator resolves the digest inside K3s; Git receives no automated digest commits; GitHub package webhook is the fast path and 6-hour polling the fallback;
- monitoring at cutover: Grafana, Prometheus, and node-exporter; no initial Loki, Tempo, or Mimir;
- databases: PostgreSQL dump/restore with all writers fenced; MariaDB is legacy archive-only unless a real consumer is found;
- `file-blobs`: remains Azure Blob and is accessed with scoped Managed Identity;
- AKS and Argo remain unchanged until K3s workloads and rollback are accepted;
- no seven-day observation window: implementation and cutover are intended to fit into one or two days, with backups providing the longer rollback boundary.

## Decision still open: daily SSH

The executable plan uses Cloudflare Access for Infrastructure:

```text
WARP + identity/MFA → outbound Cloudflare tunnel → private VM:22
```

Azure Run Command or Serial Console remains break-glass. A later thread preferred a UI and support for admins without Entra accounts and explored Headscale + Headplane as systemd services, using upgraded Better Auth as OIDC IdP and Authentik only if needed. That was an architectural recommendation, not an approved change.

Before writing the final Ansible SSH role, explicitly choose one. If Headscale wins, update the plan, Terraform/networking assumptions, bootstrap, backup, monitoring, and IAM together. Do not silently mix both designs.

## Remaining work in resume order

1. Push and protect this documentation snapshot.
2. Reconcile Terraform Key Vault names/firewalls and refresh the full Azure cost estimate.
3. Confirm Cloudflare Access or Headscale for daily SSH; verify that path plus Azure break-glass.
4. Create `polinetwork-cd#k3s-flux` from `origin/main`, never from `vm`.
5. Implement and run Ansible twice: Debian hardening, UUID mounts, K3s pin/checksum, `/srv/standard/k3s`, image GC, bundled Traefik, backups, and verification.
6. Add Flux bootstrap and ordered infrastructure Kustomizations: storage → Traefik config → ESO → secret stores → cloudflared → backup/monitoring → apps.
7. Build the private secret ownership map and migrate only verified consumers into `kv-pn-infra` or `kv-pn-apps`.
8. Prove IMDS isolation. If an ordinary Pod can obtain an Azure token, stop and implement Workload Identity before secret cutover.
9. Configure the Gitless `latest` automation and GitHub package webhook; prove a real digest change and rollback.
10. Run `bot-maintenance` as the canary after stopping its AKS instance; validate for 1–2 hours.
11. Convert and migrate the remaining active workloads in the order documented in the plan.
12. Rehearse PostgreSQL restore, inventory/fence every writer, archive and restore-test MariaDB, and verify Blob operations.
13. Implement off-VM backups and perform a clean-VM DR rebuild using only Terraform, Git, Azure Key Vault, and approved backup custody.
14. Perform final data cutover, route switch, smoke tests, and a few hours of observation.
15. Decommission AKS only through a separately reviewed Terraform plan; retain final dumps/snapshots for 14 days.

## Cutover blockers

- final Terraform plans reconciled and both roots converged;
- actual monthly cost below the approved sponsorship ceiling;
- hostname → service/port → Access policy → Traefik route mapping complete;
- secret → consumer → target vault → `ExternalSecret` mapping complete;
- PostgreSQL rehearsal and complete writer-fencing list;
- 1–2 hour all-workload capacity test with no sustained CPU >80% and no OOM;
- daily SSH path and Azure break-glass both tested;
- Flux/ESO/image automation/backup/restore evidence complete.

## External durable artifacts

- Terraform source and history: `git@github.com:PoliNetworkOrg/terraform.git`, branch `stable`.
- Target GitOps source: `git@github.com:PoliNetworkOrg/polinetwork-cd.git`, branch `main`.
- Superseded attempt: same repository, branch `vm`—history only.
- Published plan version last confirmed after the table fix: <https://qlqx3u0ekt4n.postplan.dev>.
- Raw published HTML: <https://postplan.dev/d/qlqx3u0ekt4n/raw>.

## Unrelated local work

At this snapshot, `/home/lorenzo/dev/PoliNetwork/previewer` had staged modifications in `src/lib/env.ts` and `src/services/github.ts`. They were not inspected, changed, committed, or pushed because they are outside this migration. Preserve them separately before erasing the workstation if they are still needed.
