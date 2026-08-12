# PoliNetwork deployment configuration

This repository contains both the current Kubernetes definitions and the
Docker Compose platform that is replacing AKS on the ARM64 `vm01` host.
Development of the VM platform happens on the `vm` branch.

| Directory | Purpose |
| --- | --- |
| [`apps/`](apps/) | PoliNetwork applications deployed with Docker Compose |
| [`core/`](core/) | Shared VM services: edge routing, control plane, secrets, data, observability and backups |
| [`bootstrap/`](bootstrap/) | Reproducible VM bootstrap and disaster-recovery tooling |
| [`k8s-apps/`](k8s-apps/) | Legacy Kubernetes applications kept during the incremental migration |

Terraform remains in the separate `PoliNetworkOrg/terraform` repository. It
creates the Azure infrastructure; this repository configures and runs the
services on the resulting host. Runtime secrets stay outside Git and are
restored from the documented Key Vault and break-glass sources.
