#!/bin/sh
set -eu

openbao_container="${OPENBAO_CONTAINER:-control-openbao-1}"
staging_dir="${OPENBAO_SNAPSHOT_STAGING_DIR:-/srv/polinetwork/state/backup-staging/openbao}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
snapshot_name="openbao-$timestamp.snap"
container_snapshot="/openbao/file/backups/.$snapshot_name.tmp"
staging_snapshot="$staging_dir/$snapshot_name"
staging_tmp="$staging_snapshot.tmp"

cleanup() {
  rm -f "$staging_tmp"
  docker exec --user 0:0 "$openbao_container" \
    rm -f "$container_snapshot" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

test "$(docker inspect -f '{{.State.Running}}' "$openbao_container")" = true
install -d -o root -g root -m 0700 "$staging_dir"

docker exec --user 0:0 -i "$openbao_container" sh -s -- "$container_snapshot" <<'CONTAINER_SCRIPT'
set -eu

snapshot_token=
cleanup_token() {
  if [ -n "$snapshot_token" ]; then
    BAO_TOKEN="$snapshot_token" bao token revoke -self >/dev/null 2>&1 || true
  fi
  unset snapshot_token
}
trap cleanup_token EXIT HUP INT TERM

role_id="$(cat /openbao/file/approle/backup/role-id)"
secret_id="$(cat /openbao/file/approle/backup/secret-id)"
snapshot_token="$(bao write -field=token auth/approle/login \
  role_id="$role_id" secret_id="$secret_id")"
unset role_id secret_id

BAO_TOKEN="$snapshot_token" bao operator raft snapshot save "$1"
test -s "$1"
BAO_TOKEN="$snapshot_token" bao token revoke -self >/dev/null
snapshot_token=
CONTAINER_SCRIPT

docker cp "$openbao_container:$container_snapshot" "$staging_tmp"
test -s "$staging_tmp"
chown root:root "$staging_tmp"
chmod 0400 "$staging_tmp"
mv "$staging_tmp" "$staging_snapshot"
docker exec --user 0:0 "$openbao_container" rm -f "$container_snapshot"

find "$staging_dir" -type f -name 'openbao-*.snap' -mtime +7 -delete
printf '%s\n' "$staging_snapshot"
