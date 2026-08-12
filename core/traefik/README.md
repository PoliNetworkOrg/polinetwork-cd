# Traefik

This Compose project runs Traefik with the restricted Docker socket proxy it
requires for service discovery. The proxy exposes only read operations needed
for routing and belongs with Traefik rather than as an independent platform
service.

Traefik accepts traffic only on the shared `pn-edge` Docker network; it
publishes no host port. `dynamic/openbao-tls.yaml` and the host-mounted OpenBao
CA configure certificate verification for the OpenBao upstream.

Deploy from this directory after shared networks and OpenBao TLS files exist:

```sh
docker compose up -d --pull always --wait --wait-timeout 120
```
