# Core services

This directory contains the independently deployable Docker Compose projects
shared by applications on `vm01`.

| Project | Purpose |
| --- | --- |
| [`edge/`](edge/) | Cloudflare Tunnel, Traefik and the Docker socket proxy |
| [`control/`](control/) | Komodo, MongoDB and OpenBao |
| [`backup/`](backup/) | Zerobyte, Restic and consistent snapshot tooling |
| [`data/`](data/) | PostgreSQL, MariaDB, Redis and InfluxDB definitions as they are migrated |
| [`observability/`](observability/) | Metrics, alerting, exporters and uptime monitoring |

Projects share the external Docker networks created by
[`../bootstrap/bootstrap-host.sh`](../bootstrap/bootstrap-host.sh). No
production service may publish a host port; HTTP services are exposed only by
joining `pn-edge` and declaring an explicit Traefik route.

Start projects in dependency order: `edge`, `control`, `backup`, `data`,
`observability`, then [`../apps/`](../apps/). Each project documents its own
state, secret and deployment requirements in its local README.
