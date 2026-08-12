# Core services

Each child directory owns one independently operated VM service: its Compose
file, non-secret configuration, helper scripts and local runbook.

| Service | Included dependency |
| --- | --- |
| [`traefik/`](traefik/) | Restricted Docker socket proxy |
| [`cloudflared/`](cloudflared/) | — |
| [`komodo/`](komodo/) | MongoDB and Periphery |
| [`openbao/`](openbao/) | — |
| [`zerobyte/`](zerobyte/) | OpenBao snapshot and restore tooling |

Shared Docker networks are created by
[`../bootstrap/bootstrap-host.sh`](../bootstrap/bootstrap-host.sh). No service
publishes a host port; routed HTTP services join `pn-edge` and declare an
explicit Traefik route.

Start services in dependency order: `traefik`, `cloudflared`, `komodo`,
`openbao`, and `zerobyte`, followed by [`../apps/`](../apps/). New databases or
observability components receive their own directory when introduced; they are
not grouped under generic category folders.
