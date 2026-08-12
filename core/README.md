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

Every immediate child folder containing `compose.yaml` joins the `core` Stack
automatically. Adding `core/x/compose.yaml` requires no root Compose or Komodo
edit. A `.komodo-ignore` marker excludes the bootstrapped
[`komodo/`](komodo/) folder. Komodo is started first and then manages the
`core` and `applications` Stacks declared in
[`komodo/resources/stacks.toml`](komodo/resources/stacks.toml).

Shared Docker networks are created by
[`../bootstrap/bootstrap-host.sh`](../bootstrap/bootstrap-host.sh). No service
publishes a host port; routed HTTP services join `pn-edge` and declare an
explicit Traefik route. New databases or observability components receive
their own directory. For local validation, run
`../bootstrap/render-compose-catalog.sh .` and pass
`-f .komodo.compose.yaml` to Compose. Komodo renders the catalog automatically
inside a fresh deployment clone.
