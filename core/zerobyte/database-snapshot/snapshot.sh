#!/bin/sh
set -eu

zerobyte_container="${ZEROBYTE_CONTAINER:-zerobyte-zerobyte-1}"
staging_dir="${ZEROBYTE_DATABASE_STAGING_DIR:-/srv/polinetwork/state/backup-staging/zerobyte}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
snapshot_name="zerobyte-$timestamp.db"
container_snapshot="/var/lib/zerobyte/data/.$snapshot_name.tmp"
staging_snapshot="$staging_dir/$snapshot_name"
staging_tmp="$staging_snapshot.tmp"

cleanup() {
  rm -f "$staging_tmp"
  docker exec --user 0:0 "$zerobyte_container" \
    rm -f "$container_snapshot" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

test "$(docker inspect -f '{{.State.Health.Status}}' "$zerobyte_container")" = healthy
install -d -o root -g root -m 0700 "$staging_dir"

docker exec --user 0:0 \
  --env ZEROBYTE_SNAPSHOT_TARGET="$container_snapshot" \
  "$zerobyte_container" bun -e '
    import { Database } from "bun:sqlite";
    const target = process.env.ZEROBYTE_SNAPSHOT_TARGET;
    if (!target) throw new Error("ZEROBYTE_SNAPSHOT_TARGET is required");
    const db = new Database("/var/lib/zerobyte/data/zerobyte.db");
    db.run("VACUUM INTO ?", target);
    db.close();
    const copy = new Database(target, { readonly: true });
    const result = copy.query("PRAGMA integrity_check").get();
    copy.close();
    if (result.integrity_check !== "ok") throw new Error("SQLite integrity check failed");
  '

docker cp "$zerobyte_container:$container_snapshot" "$staging_tmp"
test -s "$staging_tmp"
chown root:root "$staging_tmp"
chmod 0400 "$staging_tmp"
mv "$staging_tmp" "$staging_snapshot"
docker exec --user 0:0 "$zerobyte_container" rm -f "$container_snapshot"

find "$staging_dir" -type f -name 'zerobyte-*.db' -mtime +7 -delete
printf '%s\n' "$staging_snapshot"
