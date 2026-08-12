# Cloudflared

This project runs the dedicated `vm01` Cloudflare Tunnel connector. It sends
the wildcard route to `traefik:80` over `pn-edge` and publishes no host port.

The local `.doco-cd.yaml` resolves `secret/core/cloudflared` key
`tunnel_token`. Compose mounts that value as `/run/secrets/tunnel_token`, and
Cloudflared reads it through `TUNNEL_TOKEN_FILE`. No env file or protected host
file is needed.
