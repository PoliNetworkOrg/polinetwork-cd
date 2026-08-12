# Komodo

This Compose project runs Komodo Core and Periphery with the MongoDB instance
they require. MongoDB is part of this directory because it is private to
Komodo, not a shared database service.

Persistent data, generated communication keys and the protected environment
file live below `/srv/polinetwork/state/komodo`. Core is routed through Traefik
on `pn-edge`; MongoDB and Periphery use the project-private `komodo-api`
network, while Periphery also has outbound access for Git and registries.
Terminal and container-exec features remain disabled.

Deploy from this directory:

```sh
docker compose \
  --env-file /srv/polinetwork/state/komodo/compose.env \
  up -d --pull always --wait --wait-timeout 120
```
