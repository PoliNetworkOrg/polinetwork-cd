# Control project

The Wave 1 control project runs Komodo Core, Komodo Periphery and MongoDB on the
ARM64 lab host.

- Core and Periphery are pinned to Komodo `2.2.0`.
- MongoDB is pinned to the supported `8.0.28` LTS patch.
- No service publishes a host port.
- Core joins `pn-edge` only for Traefik routing through `komodo.invalid`.
- MongoDB and Periphery communicate with Core on the internal `control-api`
  network.
- MongoDB data, Komodo communication keys and backups use bind mounts under
  `/srv/polinetwork/state/komodo` on `disk-core`.
- Runtime credentials live only in
  `/srv/polinetwork/state/komodo/compose.env` with mode `0600`; the example file
  contains no usable secret.
- Periphery terminal and container-exec features are disabled for the lab.

Deploy only with the external environment file:

```sh
docker compose \
  --env-file /srv/polinetwork/state/komodo/compose.env \
  -f compose.yaml \
  up -d --pull always --wait --wait-timeout 120
```

The `.invalid` hostname is intentionally non-public. A production admin route
requires the separately reviewed Cloudflare Access/MFA configuration.
