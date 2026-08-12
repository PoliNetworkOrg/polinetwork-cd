#!/bin/sh
set -eu

image='ghcr.io/nicotsx/zerobyte:v0.41@sha256:647706f3e44365e6ba8d8e9094efe57bcd36682a1bab4aa23a132d800bd9ad38'
restore_root="${ZEROBYTE_RESTORE_ROOT:-/srv/polinetwork/state/zerobyte/restore-tests}"
database_target="${ZEROBYTE_DATABASE_TARGET:-/srv/polinetwork/state/zerobyte/data/data/zerobyte.db}"

fail() {
  printf 'zerobyte-database-restore: %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail 'run as root through sudo'
[ "$#" -eq 1 ] || fail 'pass one restored zerobyte-*.db snapshot'

snapshot="$1"
case "$snapshot" in
  "$restore_root"/zerobyte-*.db | \
  "$restore_root"/*/zerobyte-*.db | \
  "$restore_root"/*/zerobyte/zerobyte-*.db) ;;
  *) fail "snapshot must be a zerobyte-*.db file below $restore_root" ;;
esac
[ -s "$snapshot" ] || fail "snapshot is missing or empty: $snapshot"

if docker inspect zerobyte-zerobyte-1 >/dev/null 2>&1 && \
  [ "$(docker inspect -f '{{.State.Running}}' zerobyte-zerobyte-1)" = true ]; then
  fail 'stop Zerobyte before restoring its database'
fi
[ ! -e "$database_target" ] || fail "refusing non-empty target: $database_target"

docker run --rm --network none \
  --read-only \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  --volume "$snapshot:/snapshot/zerobyte.db:ro" \
  --entrypoint bun \
  "$image" -e '
    import { Database } from "bun:sqlite";
    const db = new Database("/snapshot/zerobyte.db", { readonly: true });
    const result = db.query("PRAGMA integrity_check").get();
    db.close();
    if (result.integrity_check !== "ok") throw new Error("SQLite integrity check failed");
  '

install -d -o root -g root -m 0755 "$(dirname "$database_target")"
install -o root -g root -m 0644 "$snapshot" "$database_target"
printf 'Zerobyte database restored after a clean integrity check: %s\n' "$database_target"
