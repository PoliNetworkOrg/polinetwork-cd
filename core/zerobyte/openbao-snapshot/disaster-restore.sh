#!/bin/sh
set -eu

image='ghcr.io/nicotsx/zerobyte:v0.41@sha256:647706f3e44365e6ba8d8e9094efe57bcd36682a1bab4aa23a132d800bd9ad38'
repository='azure:zerobyte:/'
snapshot_host="${RESTIC_SNAPSHOT_HOST:-pn-vm01}"
snapshot_path="${RESTIC_SNAPSHOT_PATH:-/data/openbao}"
secret_root="${ZEROBYTE_SECRET_ROOT:-/srv/polinetwork/state/zerobyte/secrets}"
restore_root="${ZEROBYTE_RESTORE_ROOT:-/srv/polinetwork/state/zerobyte/restore-tests}"
account_key="$secret_root/azure-storage-account-key"
repository_password="$secret_root/restic-recovery-key"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
container="openbao-disaster-restore-$run_id"
target="$restore_root/openbao-disaster-$run_id"

fail() {
  printf 'disaster-restore: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ "$(id -u)" -eq 0 ] || fail 'run as root through sudo'
command -v docker >/dev/null 2>&1 || fail 'Docker is not installed'
systemctl is-active --quiet docker.service || fail 'Docker is not active'

for secret_file in "$account_key" "$repository_password"; do
  [ -s "$secret_file" ] || fail "required secret file is missing or empty: $secret_file"
  [ "$(stat -c %u:%g "$secret_file")" = 0:0 ] || fail "secret must be owned by root:root: $secret_file"
  [ "$(stat -c %a "$secret_file")" = 600 ] || fail "secret must have mode 0600: $secret_file"
done

install -d -o root -g root -m 0700 "$restore_root"
[ ! -e "$target" ] || fail "refusing existing restore target: $target"
install -d -o root -g root -m 0700 "$target"

docker run --rm \
  --name "$container" \
  --read-only \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  --tmpfs /tmp:size=32m,mode=0700 \
  --tmpfs /cache:size=128m,mode=0700 \
  --env AZURE_ACCOUNT_NAME=polinetworkbackups \
  --env AZURE_ENDPOINT_SUFFIX=core.windows.net \
  --env RESTIC_CACHE_DIR=/cache \
  --volume "$account_key:/run/secrets/azure_storage_account_key:ro" \
  --volume "$repository_password:/run/secrets/restic_recovery_key:ro" \
  --volume "$target:/restore" \
  --entrypoint /bin/sh \
  "$image" -eu -c '
    export AZURE_ACCOUNT_KEY="$(tr -d "\r\n" < /run/secrets/azure_storage_account_key)"
    export RESTIC_PASSWORD_FILE=/run/secrets/restic_recovery_key
    restic --repo "$1" snapshots --host "$2" --path "$3" latest
    restic --repo "$1" check
    exec restic --repo "$1" restore --host "$2" --path "$3" \
      --target /restore "latest:$3"
  ' restore "$repository" "$snapshot_host" "$snapshot_path"

restored_snapshot="$(find "$target" -type f -name 'openbao-*.snap' -print | sort | tail -n 1)"
[ -n "$restored_snapshot" ] || fail "no openbao-*.snap was restored below $target"

chmod 0400 "$restored_snapshot"
chown root:root "$restored_snapshot"
sha256sum "$restored_snapshot"
printf 'OpenBao snapshot restored directly from Azure without Zerobyte state: %s\n' "$restored_snapshot"
printf 'Run restore-rehearsal.sh with REQUIRE_PRODUCTION_OPENBAO=false to validate it on a clean host.\n'
