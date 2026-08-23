# Post-migration TODO

This is the single register for work deliberately deferred until after the
AKS-to-ARM64 migration. Items listed here are not cutover blockers unless they
are explicitly promoted back into the migration plan.

Last reviewed: 2026-08-11

## Accepted service deferrals

### C# bots and support image

The following images do not currently have source/build pipelines available in
this workspace and are not production-critical:

- `ghcr.io/polinetworkorg/botcsharp-config`
- `ghcr.io/polinetworkorg/botcsharp_dev`
- `ghcr.io/polinetworkorg/bot-maintenance`

Their dependent workloads (`bot-rooms` and the `bot-mat` maintenance workload)
are excluded from the initial ARM64 cutover. Downtime after AKS retirement is
accepted until this work is completed.

- [ ] Locate the owning repositories and assign an owner.
- [ ] Add `linux/amd64,linux/arm64` builds and publish a multi-arch manifest.
- [ ] Pin an immutable version or manifest-list digest for each image.
- [ ] Run startup, configuration, Telegram connectivity and graceful-shutdown
      tests on native ARM64.
- [ ] Add the workloads to the `applications` Compose project with memory/CPU/
      PID limits, health checks and isolated networks.
- [ ] Create their OpenBao paths/policies and confirm that no secret is embedded
      in an image or Compose file.
- [ ] Re-enable each workload only after owner acceptance and duplicate-consumer
      checks.

## MariaDB retirement

MariaDB 10.9.4 will be migrated as-is to the shared P4 state disk. Its removal
is intentionally deferred and must not be inferred from its small footprint.

- [ ] Identify remaining clients, schemas, grants and last-write activity.
- [ ] Obtain owner approval for retention or deletion.
- [ ] Produce an encrypted logical export and verify a clean restore.
- [ ] Remove clients and observe failed connection attempts during an agreed
      shutdown window.
- [ ] Remove MariaDB, its OpenBao credentials and Compose service only after
      sign-off; retain the export according to the backup policy.

## Central identity

The identity project remains independent from the infrastructure cutover.

- [ ] Remove caller-controlled identity from the backend and enforce server-side
      authorization on sensitive procedures.
- [ ] Run the pinned Better Auth 1.6 OAuth Provider conformance/security PoC.
- [ ] Validate discovery, JWKS, PKCE S256, issuer/audience, claims, rotation,
      revocation/logout, MFA and relying-party integrations.
- [ ] Adopt Better Auth as the central provider only if every gate passes;
      otherwise retain application-local Better Auth and deploy Authentik.

## Dormant and legacy workloads

- [ ] Decide whether `bot-prod` and disabled/test workloads should be revived,
      archived or removed; do not migrate them automatically.
- [ ] Remove stale Kubernetes-only manifests after their retention window and
      after the accepted Compose state is versioned.

## Later platform improvements

- [ ] Review the first full post-AKS billing period against the $1,600-$1,700
      recurring target and the $2,000 absolute annual ceiling.
- [ ] Re-evaluate E4/P4 disk sizing using measured growth, latency and backup
      restore times; resize only with evidence.
- [ ] Reconsider a dedicated OpenBao disk only if operational isolation provides
      measurable value on the single-host architecture.
- [ ] Consider centralized log search (for example Loki) only after sustained
      memory and disk headroom is demonstrated.
- [ ] Review mutable-tag policies for student projects and promote important
      workloads to immutable version tags or digests.

## Not deferrable to this register

The following remain migration gates: ARM64 qualification for every workload in
the initial cutover, cost/capacity limits, doco.cd folder-scoped update proof,
OpenBao recovery, off-host backup restore, state/ingress rollback, external
outage monitoring, Terraform sequencing and student-workload isolation.
