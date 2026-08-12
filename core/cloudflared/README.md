# Cloudflared

This Compose project runs the dedicated `vm01` Cloudflare Tunnel connector.
It forwards the wildcard tunnel route to `traefik:80` over the shared
`pn-edge` network and publishes no host port.

The tunnel token is supplied only through the protected host file
`/srv/polinetwork/state/cloudflare/compose.env`. Do not reuse the AKS tunnel
token.

Deploy from this directory after Traefik is healthy:

```sh
docker compose up -d --pull always
```
