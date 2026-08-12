# Edge project

This Compose project runs the dedicated Cloudflare Tunnel, Traefik and a
read-only Docker socket proxy. It is the only ingress layer for VM services;
no host ports are published.

The tunnel token is supplied through
`/srv/polinetwork/state/cloudflare/compose.env`. Traefik discovers only
explicitly enabled containers on `pn-edge` and validates OpenBao's internal TLS
certificate with `dynamic/openbao-tls.yaml`.

Deploy from this directory after the shared networks and protected environment
file exist:

```sh
docker compose up -d --pull always --wait --wait-timeout 120
```
