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

doco.cd performs one initial reconciliation, then an authenticated GitHub
webhook follows pushes to the public `vm` branch. It natively discovers every
immediate `core/*/compose.yaml` and `apps/*/compose.yaml`. Add a service folder
and push: there is no aggregate Compose file or deployment catalog to update.
A folder can add `.doco-cd.yaml` only when it needs profiles, OpenBao secret
references or another per-project option.

On a new VM, run `sudo bootstrap/bootstrap-vm.sh`. The VM managed identity
retrieves its Azure-held bootstrap secrets; when privileged OpenBao access is
needed, the script asks once at the beginning without exposing the password in
a command argument. Default output is a concise colored phase summary, with
full root-only logs retained for diagnosis. Terraform remains in
`PoliNetworkOrg/terraform`.
