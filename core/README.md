# Core services

Each child directory owns one VM service: its Compose file, non-secret
configuration, helper scripts and local runbook.

| Service | Included dependency |
| --- | --- |
| [`traefik/`](traefik/) | Restricted Docker socket proxy |
| [`cloudflared/`](cloudflared/) | — |
| [`komodo/`](komodo/) | MongoDB and Periphery |
| [`openbao/`](openbao/) | — |
| [`zerobyte/`](zerobyte/) | OpenBao snapshot and restore tooling |

[`compose.yaml`](compose.yaml) includes every service except Komodo as the
single `core` Stack. Docker Compose resolves each included file relative to its
own service directory, so folder-local dynamic files remain owned by that
service. Komodo is started first from [`komodo/`](komodo/) and then manages the
`core` and `applications` Stacks declared in
[`komodo/resources/stacks.toml`](komodo/resources/stacks.toml).

Shared Docker networks are created by
[`../bootstrap/bootstrap-host.sh`](../bootstrap/bootstrap-host.sh). No service
publishes a host port; routed HTTP services join `pn-edge` and declare an
explicit Traefik route. New databases or observability components receive
their own directory and are added to the aggregate file.
