# Kubernetes applications

This directory contains the legacy AKS/Kustomize deployment definitions. They
remain available as the production rollback source while workloads are moved
incrementally to Docker Compose.

Each child directory preserves the existing application layout and deployment
metadata. When an application is accepted on `vm01`, its Docker definition is
added to [`../apps/`](../apps/); the Kubernetes copy is removed only during the
separately approved AKS decommissioning phase.
