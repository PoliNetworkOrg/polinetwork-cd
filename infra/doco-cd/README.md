# doco.cd infrastructure

doco.cd polls the public `vm` branch every 60 seconds. The repository root
`.doco-cd.yaml` uses native auto-discovery for immediate `core/` and `apps/`
children, so adding a folder with `compose.yaml` requires no central edit.
Deleted folders remove their project but retain volumes and images.

doco.cd reads deployment secrets from OpenBao. Because its OpenBao provider
accepts a token rather than AppRole credentials, the small Agent sidecar logs
in and renews a periodic token in shared tmpfs. This is the only Agent needed;
application folders use native `external_secrets` references.

## One-time provisioning

After OpenBao is initialized or restored, authenticate without putting the
password or token in a command argument:

```sh
PN_OPENBAO_ADMIN_PASSWORD="$(systemd-ask-password 'OpenBao admin password')"
BAO_TOKEN="$(
  printf 'password=%s\n' "$PN_OPENBAO_ADMIN_PASSWORD" |
  docker exec -i infra-openbao-openbao-1 bao login \
    -method=userpass -token-only username=pnadmin -
)"
export BAO_TOKEN
unset PN_OPENBAO_ADMIN_PASSWORD
```

Enable AppRole once if `approle/` is not already listed by `bao auth list`,
then create the narrow policy and renewable role:

```sh
docker exec --user 0:0 -e BAO_TOKEN infra-openbao-openbao-1 sh -ec '
  bao auth list -format=json | grep -q '"'"'approle/'"'"' || bao auth enable approle
'

docker exec -i -e BAO_TOKEN infra-openbao-openbao-1 \
  bao policy write doco-cd - <<'POLICY'
path "secret/data/core/*" { capabilities = ["read"] }
path "secret/data/apps/*" { capabilities = ["read"] }
POLICY

docker exec -e BAO_TOKEN infra-openbao-openbao-1 bao write \
  auth/approle/role/doco-cd \
  token_policies=doco-cd token_no_default_policy=true token_period=24h \
  secret_id_num_uses=0 secret_id_ttl=0 >/dev/null
```

Write the regenerable credentials directly into the OpenBao state mount; no
value is printed or committed:

```sh
docker exec --user 0:0 -e BAO_TOKEN infra-openbao-openbao-1 sh -ec '
  mkdir -p /openbao/file/approle/doco-cd
  chown 0:0 /openbao/file/approle/doco-cd
  chmod 0750 /openbao/file/approle/doco-cd
  chown 100:1000 /openbao/file/approle/doco-cd
  umask 077
  bao read -field=role_id auth/approle/role/doco-cd/role-id \
    > /openbao/file/approle/doco-cd/role-id
  bao write -field=secret_id -f auth/approle/role/doco-cd/secret-id \
    > /openbao/file/approle/doco-cd/secret-id
  chmod 0400 /openbao/file/approle/doco-cd/role-id \
    /openbao/file/approle/doco-cd/secret-id
  chown 100:1000 /openbao/file/approle/doco-cd/role-id \
    /openbao/file/approle/doco-cd/secret-id
'
unset BAO_TOKEN
```

Before the first poll, ensure every committed reference exists in OpenBao. The
current paths are `secret/core/cloudflared`, `secret/core/zerobyte` and
`secret/apps/canary`; their key names are visible in the corresponding local
`.doco-cd.yaml`. The dedicated VM tunnel token is restored from Azure Key Vault
secret `cloudflared-vm-tunnel-token`; the two Zerobyte values use their names
listed in [`../../bootstrap/SECRETS.md`](../../bootstrap/SECRETS.md). Stream
values from those approved off-host sources—never place a value in Git or a
command argument.

Start the control plane:

```sh
docker compose up -d --pull always --wait --wait-timeout 120
```

The service has no published HTTP port or webhook. It does mount the Docker
socket, which is the trust boundary required for direct Compose deployment.
Its root process retains only `DAC_OVERRIDE` after dropping capabilities so it
can read the Agent-owned token and the host Docker socket without hard-coding
host-specific group IDs or making the token world-readable.
