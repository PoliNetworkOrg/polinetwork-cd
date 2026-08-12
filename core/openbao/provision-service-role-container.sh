#!/bin/sh
set -eu

service_scope="$1"
service_name="$2"
identity_name="$service_scope-$service_name"
credential_dir="/openbao/file/approle/$identity_name"
policy_name="$identity_name"
secret_path="$service_scope/$service_name"

IFS= read -r pnadmin_password
BAO_TOKEN="$(bao write -field=token auth/userpass/login/pnadmin password="$pnadmin_password")"
unset pnadmin_password
export BAO_TOKEN

bao kv get -mount=secret "$secret_path" >/dev/null

printf 'path "secret/data/%s" {\n  capabilities = ["read"]\n}\n' "$secret_path" |
  bao policy write "$policy_name" - >/dev/null

if ! bao auth list -format=json | grep -q '"approle/'; then
  bao auth enable approle >/dev/null
fi

bao write "auth/approle/role/$policy_name" \
  "token_policies=$policy_name" \
  token_no_default_policy=true \
  token_period=20m \
  token_num_uses=0 \
  secret_id_ttl=0 \
  secret_id_num_uses=0 >/dev/null

credential_count=0
for credential in role-id secret-id; do
  [ ! -e "$credential_dir/$credential" ] || credential_count=$((credential_count + 1))
done

case "$credential_count" in
  0)
    install -d -o 100 -g 1000 -m 0700 "$credential_dir"
    umask 077
    bao read -field=role_id "auth/approle/role/$policy_name/role-id" \
      >"$credential_dir/role-id"
    bao write -field=secret_id -f "auth/approle/role/$policy_name/secret-id" \
      >"$credential_dir/secret-id"
    chown 100:1000 "$credential_dir/role-id" "$credential_dir/secret-id"
    chmod 0600 "$credential_dir/role-id" "$credential_dir/secret-id"
    ;;
  2) ;;
  *)
    printf 'Partial AppRole credentials exist at %s; refusing to replace them.\n' "$credential_dir" >&2
    exit 1
    ;;
esac

role_id="$(cat "$credential_dir/role-id")"
secret_id="$(cat "$credential_dir/secret-id")"
service_token="$(bao write -field=token auth/approle/login \
  role_id="$role_id" secret_id="$secret_id")"
BAO_TOKEN="$service_token" bao kv get -mount=secret "$secret_path" >/dev/null
test "$(BAO_TOKEN="$service_token" bao token capabilities "secret/data/$service_scope/not-$service_name")" = deny

unset role_id secret_id service_token BAO_TOKEN
