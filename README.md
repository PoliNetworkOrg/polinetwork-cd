# PoliNetwork deployments

This repository is the Git source of truth for the ARM64 `vm01` host. VM work
happens on the `vm` branch; AKS remains the rollback target during migration.

| Directory | Purpose |
| --- | --- |
| [`infra/`](infra/) | One-time OpenBao and doco.cd control-plane bootstrap |
| [`core/`](core/) | Core services reconciled by doco.cd |
| [`apps/`](apps/) | PoliNetwork applications reconciled by doco.cd |
| [`bootstrap/`](bootstrap/) | Host bootstrap and clean-host recovery contract |
| [`k8s-apps/`](k8s-apps/) | Legacy Kubernetes workloads awaiting migration |

doco.cd polls this public repository and natively discovers every immediate
`core/*/compose.yaml` and `apps/*/compose.yaml`. Add a service folder and push:
there is no aggregate Compose file or deployment catalog to update. A folder
can add `.doco-cd.yaml` only when it needs profiles, OpenBao secret references
or another per-project option.

On a new VM, place the two protected recovery files described in
[`bootstrap/SECRETS.md`](bootstrap/SECRETS.md), then run
`sudo bootstrap/bootstrap-vm.sh`. It restores and converges the platform and
asks once for the OpenBao administrator password without exposing it in a
command argument. Terraform remains in `PoliNetworkOrg/terraform`.
