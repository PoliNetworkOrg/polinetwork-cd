# ARM64 Compose platform

This directory is the Git-backed source for the AKS replacement. The projects
remain independently deployable even though every PoliNetwork-owned workload is
kept in the single `applications` project.

| Project | Purpose |
| --- | --- |
| `applications` | PoliNetwork applications, bots, workers and student projects |
| `data` | PostgreSQL, temporary MariaDB, Redis and InfluxDB |
| `edge` | cloudflared, Docker socket proxy and Traefik |
| `observability` | Prometheus, Grafana, exporters and Uptime Kuma |
| `control` | Komodo and OpenBao |
| `backup` | Zerobyte and Restic orchestration for off-host Azure backups |

## Shared networks

Shared network lifecycle is deliberately outside every Compose project. Create
them once on a disposable ARM64 lab host before deploying any project:

```sh
docker network create \
  --driver bridge \
  --subnet 172.30.0.0/24 \
  --gateway 172.30.0.1 \
  --label com.polinetwork.role=edge \
  pn-edge

docker network create \
  --driver bridge \
  --subnet 172.30.1.0/24 \
  --gateway 172.30.1.1 \
  --label com.polinetwork.role=applications \
  pn-app

docker network create \
  --driver bridge \
  --internal \
  --subnet 172.30.2.0/24 \
  --gateway 172.30.2.1 \
  --label com.polinetwork.role=database \
  pn-db

docker network create \
  --driver bridge \
  --internal \
  --subnet 172.30.3.0/24 \
  --gateway 172.30.3.1 \
  --label com.polinetwork.role=secrets \
  pn-secrets
```

`pn-edge` is not a host or Internet exposure. The reviewed Compose definitions
control its membership: only cloudflared, Traefik and explicitly exposed HTTP
applications join it. Network labels are metadata and do not enforce access.
`pn-app` allows application-to-application communication and outbound access
without putting non-HTTP services on the edge network. `pn-db` has no external
routing because it is created with `--internal`; it is reserved for databases
and their clients. `pn-secrets` is also internal: only OpenBao and dedicated
Agent sidecars join it. Applications consume files rendered by their Agent and
never receive an OpenBao token or direct network access to OpenBao.

No production service in this repository may publish a host `ports:` mapping.
The Wave 1 canaries use `.invalid` hostnames and cannot be resolved publicly.

## OpenBao Agent canary

The `secrets-canary` profile proves the production secret-delivery pattern.
`openbao-agent-canary` authenticates with a path-scoped AppRole over verified
internal TLS and renders a dummy KV v2 value into a shared 1 MiB tmpfs volume.
`openbao-canary` mounts that volume read-only, has no network namespace, and
never receives an OpenBao token or AppRole credential.

The AppRole `SecretID` is deliberately persistent so the Agent can authenticate
again after a restart. It must remain mode `0600` below
`/srv/polinetwork/state/openbao/approle/canary`, mounted only into its Agent,
and be rotated if the VM or Agent boundary is compromised. The Agent-issued
token is periodic, short-lived and renewed automatically.

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
