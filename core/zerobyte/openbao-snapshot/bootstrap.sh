#!/bin/sh
set -eu

openbao_container="${OPENBAO_CONTAINER:-core-openbao-1}"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
container_script=/tmp/polinetwork-openbao-snapshot-bootstrap.sh

cleanup() {
  docker exec "$openbao_container" rm -f "$container_script" >/dev/null 2>&1 || true
  unset pnadmin_password
}
trap cleanup EXIT HUP INT TERM

if [ ! -t 0 ]; then
  IFS= read -r pnadmin_password
else
  printf 'Pipe the pnadmin password to stdin; it must not be a command argument.\n' >&2
  exit 2
fi

docker cp \
  "$script_dir/bootstrap-container.sh" \
  "$openbao_container:$container_script"

printf '%s\n' "$pnadmin_password" | \
  docker exec --user 0:0 -i "$openbao_container" sh "$container_script"
unset pnadmin_password

printf 'OpenBao snapshot AppRole bootstrapped; snapshot save passed and unrelated sys access was denied.\n'
