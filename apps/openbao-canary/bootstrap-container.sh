#!/bin/sh
set -eu

IFS= read -r pnadmin_password
BAO_TOKEN="$(bao write -field=token auth/userpass/login/pnadmin password="$pnadmin_password")"
unset pnadmin_password
export BAO_TOKEN

if ! bao secrets list -format=json | grep -q '"secret/'; then
  bao secrets enable -path=secret kv-v2 >/dev/null
fi

bao kv put -mount=secret apps/canary message=openbao-agent-ok >/dev/null
bao kv put -mount=secret apps/forbidden message=must-not-be-readable >/dev/null

bao policy write apps-canary - >/dev/null <<'POLICY'
path "secret/data/apps/canary" {
  capabilities = ["read"]
}
POLICY

if ! bao auth list -format=json | grep -q '"approle/'; then
  bao auth enable approle >/dev/null
fi

bao write auth/approle/role/apps-canary \
  token_policies=apps-canary \
  token_no_default_policy=true \
  token_period=20m \
  token_num_uses=0 \
  secret_id_ttl=0 \
  secret_id_num_uses=0 >/dev/null

mkdir -p /openbao/file/approle/canary
chown 0:0 /openbao/file/approle/canary
chmod 0700 /openbao/file/approle/canary
chown 100:1000 /openbao/file/approle/canary
umask 077

bao read -field=role_id auth/approle/role/apps-canary/role-id \
  > /openbao/file/approle/canary/role-id
bao write -field=secret_id -f auth/approle/role/apps-canary/secret-id \
  > /openbao/file/approle/canary/secret-id

chown 0:0 \
  /openbao/file/approle/canary/role-id \
  /openbao/file/approle/canary/secret-id
chmod 0600 \
  /openbao/file/approle/canary/role-id \
  /openbao/file/approle/canary/secret-id
chown 100:1000 \
  /openbao/file/approle/canary/role-id \
  /openbao/file/approle/canary/secret-id

role_id="$(cat /openbao/file/approle/canary/role-id)"
secret_id="$(cat /openbao/file/approle/canary/secret-id)"
app_token="$(bao write -field=token auth/approle/login \
  role_id="$role_id" secret_id="$secret_id")"

BAO_TOKEN="$app_token" bao kv get -mount=secret apps/canary >/dev/null
if BAO_TOKEN="$app_token" bao kv get -mount=secret apps/forbidden >/dev/null 2>&1; then
  printf 'AppRole unexpectedly read the forbidden path.\n' >&2
  exit 1
fi

bao kv delete -mount=secret apps/forbidden >/dev/null
unset role_id secret_id app_token BAO_TOKEN
