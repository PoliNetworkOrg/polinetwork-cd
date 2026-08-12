#!/bin/sh
set -eu

test_snapshot=/openbao/file/backups/.bootstrap-snapshot-test.snap
snapshot_token=

cleanup() {
  rm -f "$test_snapshot"
  if [ -n "$snapshot_token" ]; then
    BAO_TOKEN="$snapshot_token" bao token revoke -self >/dev/null 2>&1 || true
  fi
  unset snapshot_token BAO_TOKEN
}
trap cleanup EXIT HUP INT TERM

IFS= read -r pnadmin_password
BAO_TOKEN="$(bao write -field=token auth/userpass/login/pnadmin password="$pnadmin_password")"
unset pnadmin_password
export BAO_TOKEN

bao policy write openbao-snapshot - >/dev/null <<'POLICY'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
POLICY

if ! bao auth list -format=json | grep -q '"approle/'; then
  bao auth enable approle >/dev/null
fi

bao write auth/approle/role/openbao-snapshot \
  token_policies=openbao-snapshot \
  token_no_default_policy=true \
  token_ttl=5m \
  token_max_ttl=5m \
  token_num_uses=3 \
  secret_id_ttl=0 \
  secret_id_num_uses=0 >/dev/null

mkdir -p /openbao/file/approle/backup
chown 0:0 /openbao/file/approle/backup
chmod 0700 /openbao/file/approle/backup
rm -f \
  /openbao/file/approle/backup/role-id \
  /openbao/file/approle/backup/secret-id
umask 077

bao read -field=role_id auth/approle/role/openbao-snapshot/role-id \
  > /openbao/file/approle/backup/role-id
bao write -field=secret_id -f auth/approle/role/openbao-snapshot/secret-id \
  > /openbao/file/approle/backup/secret-id

chmod 0600 \
  /openbao/file/approle/backup/role-id \
  /openbao/file/approle/backup/secret-id
chown -R 100:1000 /openbao/file/approle/backup

role_id="$(cat /openbao/file/approle/backup/role-id)"
secret_id="$(cat /openbao/file/approle/backup/secret-id)"
snapshot_token="$(bao write -field=token auth/approle/login \
  role_id="$role_id" secret_id="$secret_id")"
unset role_id secret_id BAO_TOKEN

BAO_TOKEN="$snapshot_token" bao operator raft snapshot save "$test_snapshot"
test -s "$test_snapshot"

if BAO_TOKEN="$snapshot_token" bao read sys/storage/raft/configuration >/dev/null 2>&1; then
  printf 'Snapshot AppRole unexpectedly read Raft configuration.\n' >&2
  exit 1
fi

BAO_TOKEN="$snapshot_token" bao token revoke -self >/dev/null
snapshot_token=
