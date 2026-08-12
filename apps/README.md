# Docker applications

This directory contains PoliNetwork-owned applications deployed on `vm01` as
the Compose project named `applications`. Applications are moved here from
[`../k8s-apps/`](../k8s-apps/) only after their ARM64 image, secret delivery,
health checks, resource limits, backup/restore and rollback behavior pass the
migration gates.

`compose.yaml` currently contains the Wave 1 deployment canaries and the
OpenBao Agent secret-delivery canary. Production application containers use
`pn-app`; only routed HTTP services also join `pn-edge`. Applications consume
secret files rendered by dedicated OpenBao Agents and never receive an
OpenBao token or direct OpenBao network access.

Validate the project from this directory:

```sh
docker compose --profile lab --profile secrets-canary config --quiet
```

Komodo must use repository branch `vm`, Compose file `apps/compose.yaml` and
project name `applications` for this stack.
