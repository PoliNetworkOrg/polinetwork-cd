# Core services

Each immediate child directory is one independently deployed Compose project
containing the service and its non-secret dynamic files.

| Service | Purpose |
| --- | --- |
| [`traefik/`](traefik/) | Edge routing and restricted Docker socket proxy |
| [`cloudflared/`](cloudflared/) | Cloudflare Tunnel connector |
| [`zerobyte/`](zerobyte/) | Backups and OpenBao snapshot recovery tooling |

Adding `core/x/compose.yaml` is enough for doco.cd to discover and reconcile
it. If the project needs secrets, add `core/x/.doco-cd.yaml` with OpenBao
references and consume them as environment-backed Compose secrets. Use a
unique folder name across both `core/` and `apps/`; a nested config can set an
explicit `name` when that is not possible.

Shared networks come from [`../bootstrap/bootstrap-host.sh`](../bootstrap/bootstrap-host.sh).
Routed services join `pn-edge`; internal services should use the narrowest
appropriate network and publish no host ports.
