# Cloudflared

This Compose project runs the dedicated `vm01` Cloudflare Tunnel connector.
It forwards the wildcard tunnel route to `traefik:80` over the shared
`pn-edge` network and publishes no host port.

The tunnel token is supplied through the Compose secret
`/srv/polinetwork/state/cloudflare/secrets/tunnel-token`. The pinned image
reads it with `TUNNEL_TOKEN_FILE`; it is never placed in the container
environment. Do not reuse the AKS tunnel token. Prepare it with
`bootstrap/prepare-secrets.sh runtime`.

Deploy from this directory after Traefik is healthy:

```sh
docker compose up -d --pull always
```
