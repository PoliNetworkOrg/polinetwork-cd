#!/bin/sh
set -eu

service_scope="${1:-}"
service_name="${2:-}"
openbao_container="${OPENBAO_CONTAINER:-core-openbao-1}"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
container_script=/tmp/polinetwork-provision-service-role.sh

fail() {
  printf 'provision-service-role: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker exec "$openbao_container" rm -f "$container_script" >/dev/null 2>&1 || true
  unset pnadmin_password
}
trap cleanup EXIT HUP INT TERM

case "$service_scope" in
  core|apps) ;;
  *) fail 'usage: provision-service-role.sh core|apps service-name' ;;
esac
case "$service_name" in
  [a-z0-9]*[a-z0-9]|[a-z0-9]) ;;
  *) fail 'service name must use lowercase letters, digits and internal hyphens' ;;
esac
case "$service_name" in
  *[!a-z0-9-]*) fail 'service name must use lowercase letters, digits and internal hyphens' ;;
esac

if [ ! -t 0 ]; then
  IFS= read -r pnadmin_password
else
  fail 'pipe the pnadmin password to stdin; it must not be a command argument'
fi
[ -n "$pnadmin_password" ] || fail 'pnadmin password cannot be empty'

docker cp "$script_dir/provision-service-role-container.sh" \
  "$openbao_container:$container_script"
printf '%s\n' "$pnadmin_password" | \
  docker exec -i "$openbao_container" sh "$container_script" \
    "$service_scope" "$service_name"
unset pnadmin_password

printf 'OpenBao AppRole for %s/%s can read only secret/%s/%s.\n' \
  "$service_scope" "$service_name" "$service_scope" "$service_name"
