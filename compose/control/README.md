# Control project

The Wave 1 control project runs Komodo Core, Komodo Periphery, MongoDB and
OpenBao on the ARM64 lab host.

- Core and Periphery are pinned to Komodo `2.2.0`.
- MongoDB is pinned to the supported `8.0.28` LTS patch.
- No service publishes a host port.
- Core joins `pn-edge` only for Traefik routing through
  `komodo.polinetwork.org`.
- MongoDB and Periphery communicate with Core on the internal `control-api`
  network. Periphery also joins its own `control-egress` bridge so it can clone
  Git repositories and inspect registries without sharing an application
  network.
- MongoDB data, Komodo communication keys and backups use bind mounts under
  `/srv/polinetwork/state/komodo` on `disk-core`.
- Runtime credentials live only in
  `/srv/polinetwork/state/komodo/compose.env` with mode `0600`; the example file
  contains no usable secret.
- Periphery terminal and container-exec features are disabled for the lab.
- OpenBao is pinned to `2.5.4`, uses integrated Raft storage below
  `/srv/polinetwork/state/openbao`, and is routed as
  `openbao.polinetwork.org`. It is never started in development mode.
- OpenBao uses the image's default entrypoint and persistent `/openbao/file`
  contract. The state directory is created initially by `pnadmin`; the
  entrypoint assigns it to the image's `openbao` account before dropping root.
  Compose retains only the capabilities required for that ownership repair and
  privilege drop.
- The `server` command also uses the image's default `/openbao/config`
  discovery; no duplicate `-config` argument is supplied.
- `secrets-api` is internal and reserved for OpenBao workload clients. Only
  OpenBao itself also joins `pn-edge` for the Access-protected UI/API route.
- Initialization output, unseal shares and root tokens must never be committed
  or retained unencrypted on the VM.

Deploy only with the external environment file:

```sh
docker compose \
  --env-file /srv/polinetwork/state/komodo/compose.env \
  -f compose.yaml \
  up -d --pull always --wait --wait-timeout 120
```

The route requires a dedicated VM Cloudflare Tunnel and a Cloudflare Access
policy with MFA restricted to tech administrators. Do not reuse the AKS tunnel
token: keeping separate connectors preserves deterministic origin rollback.
