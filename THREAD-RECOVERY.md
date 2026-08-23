# T3 Code thread recovery index

This is a sanitized index of migration decisions recovered from local T3 Code/Codex session history and Git checkpoint refs. It intentionally records outcomes rather than complete transcripts, because transcripts can contain operational metadata and must not become a secret backup.

## Current K3s attempt

| Date | T3 thread | Recovered outcome |
|---|---|---|
| 13–14 Aug 2026 | `df6e76c7-8d82-42cf-9896-a36f2c9f872a` | fresh assessment from the real Azure/AKS/Git environment; current workload scope, two-disk sizing, E2ps choice, Flux/ESO/K3s architecture, 1–2 day cutover, and canonical Markdown/HTML plan |
| 14 Aug 2026 | `ef91bc78-7df6-4b0e-8868-c56d25595c48` | use bundled Traefik, configure it with `HelmChartConfig`, pin K3s, and treat Traefik upgrades as K3s upgrades |
| 14 Aug 2026 | `15816ae7-70dd-416c-bf67-b9905c428149` | start with ARM64 `Standard_E2ps_v6`; measure before considering `D4ps_v6`; older estimate must now be refreshed for NAT/OS changes |
| 14 Aug 2026 | `dc23f3a7-6ac9-49f2-83f0-086ede0c59b1` | names are globally unique; final minimal vault design is `kv-pn-infra` + `kv-pn-apps`; do not create a CI vault without a real consumer |
| 14 Aug 2026 | `a803218e-a1f5-4d08-88da-eeabd11a4474` | Gitless Flux Operator image automation; `latest` remains in Git, digest is materialized only in K3s, package webhook is fast path, 6-hour polling is fallback |
| 14 Aug 2026 | `22081102-e3a2-4125-8e05-3580504099fd` | compared private SSH choices; later recommendation was Headscale + Headplane + Better Auth OIDC, but the user never approved replacing the canonical Cloudflare Access design |
| 14 Aug 2026 | `5fb95809-80a7-4963-b278-4576dbf8a8a3` | Terraform state split implemented in PR #79; authorized failed-test cleanup; K3s first, then legacy apply ordering |
| 14 Aug 2026 | `0c50c72e-2bdd-4b9e-87bb-80b7f751a60c` | fixed generated table layout and published Postplan version 9 |
| 23 Aug 2026 | `0e2c2779-9b4e-419b-b69a-96060260174b` | reconstructed this durable handoff, re-fetched repositories, and verified the applied Azure/Terraform state |

The T3 feature explanation thread `b4a76673-533d-4871-bbb0-19a2e9bc2dfe` was reviewed and excluded because it contains no migration decision.

## Superseded Compose attempt

The 11–12 August sessions implemented and exercised the older `polinetwork-cd#vm` design: Docker Compose, doco.cd, OpenBao, Zerobyte/Restic, Cloudflare/Traefik, and one-script bootstrap. The recovery rehearsals were useful evidence, but the target architecture was explicitly reset on 13 August.

Useful facts already carried into the current plan include:

- backups are not accepted until a clean, isolated restore succeeds;
- all non-secret configuration must live in Git;
- secrets need off-host custody and must never be printed or committed;
- an idempotent bootstrap must replace manual host folklore;
- the old VM and test disks were safe to remove only through a reviewed Terraform plan.

Do not carry forward its Compose folder structure, doco.cd reconciliation, OpenBao runtime secret delivery, public-SSH decisions, or VM command history.

## Other useful migration threads

The 11 August parent-workspace thread validated and published multi-architecture workflows. Those changes later reached the maintained repositories' `main` branches; the exact durable commits are listed in `HANDOFF.md`.

The local checkpoint refs are snapshots, not a substitute for a normal Git branch. They may disappear with T3 Code or the workstation; all decisions needed to resume are therefore written in this repository.
