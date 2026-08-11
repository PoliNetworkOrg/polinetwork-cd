# ARM64 Compose platform

This directory is the Git-backed source for the AKS replacement. The projects
remain independently deployable even though every PoliNetwork-owned workload is
kept in the single `applications` project.

| Project | Purpose |
| --- | --- |
| `applications` | PoliNetwork applications, bots, workers and student projects |
| `data` | PostgreSQL, temporary MariaDB, Redis and InfluxDB |
| `edge` | Docker socket proxy, Traefik and later cloudflared |
| `observability` | Prometheus, Grafana, exporters and Uptime Kuma |
| `control` | Komodo and OpenBao |

## Shared networks

Shared network lifecycle is deliberately outside every Compose project. Create
them once on a disposable ARM64 lab host before deploying any project:

```sh
docker network create pn-edge
docker network create --internal pn-db
```

`pn-edge` is not a host or Internet exposure. It only allows cloudflared,
Traefik and explicitly labelled HTTP applications to communicate. `pn-db` has
no external gateway and is reserved for databases and their clients.

No production service in this repository may publish a host `ports:` mapping.
The Wave 1 canaries use `.invalid` hostnames and cannot be resolved publicly.

## Wave 1 selective-update proof

1. Deploy `edge/compose.yaml`.
2. Deploy `applications/compose.yaml` with the `lab` profile.
3. Record both canary container IDs and start timestamps.
4. change only `wave1-canary-a` to another reviewed image version;
5. ask Komodo to update only that service;
6. prove that canary B kept the same container ID, start timestamp and process;
7. roll canary A back and record the same evidence.

Do not promote this skeleton to production until native ARM64 execution,
resource limits, health checks, socket-proxy denial tests and the selective
update/rollback evidence pass.
