# PoliNetwork deployment configuration

This repository contains both the current Kubernetes definitions and the
Docker Compose platform that is replacing AKS on the ARM64 `vm01` host.
Development of the VM platform happens on the `vm` branch.

| Directory | Purpose |
| --- | --- |
| [`apps/`](apps/) | PoliNetwork applications deployed with Docker Compose |
| [`core/`](core/) | Komodo bootstrap plus the Komodo-managed `core` Stack |
| [`bootstrap/`](bootstrap/) | Reproducible VM bootstrap and disaster-recovery tooling |
| [`k8s-apps/`](k8s-apps/) | Legacy Kubernetes applications kept during the incremental migration |

Terraform remains in the separate `PoliNetworkOrg/terraform` repository. It
creates the Azure infrastructure; this repository configures and runs the
services on the resulting host. `bootstrap/prepare-secrets.sh` restores runtime
secrets as service-scoped Compose secrets. Non-secret environment settings are
tracked directly in Compose, so Docker commands need no env file.

After host and secret recovery, Komodo starts directly from `core/komodo`; its
Git-backed Resource Sync manages the aggregate `core` Stack and the separate
`applications` Stack. Adding `core/x/compose.yaml` or `apps/x/compose.yaml`
automatically adds that folder to the corresponding deployment; no central
service list is maintained.
