#!/bin/sh
set -eu

app_name="${1:-}"
openbao_container="${OPENBAO_CONTAINER:-core-openbao-1}"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
container_script=/tmp/polinetwork-provision-app-role.sh

fail() {
  printf 'provision-app-role: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  docker exec "$openbao_container" rm -f "$container_script" >/dev/null 2>&1 || true
  unset pnadmin_password
}
trap cleanup EXIT HUP INT TERM

case "$app_name" in
  [a-z0-9]*[a-z0-9]|[a-z0-9]) ;;
  *) fail 'application name must use lowercase letters, digits and internal hyphens' ;;
esac
case "$app_name" in
  *[!a-z0-9-]*) fail 'application name must use lowercase letters, digits and internal hyphens' ;;
esac

if [ ! -t 0 ]; then
  IFS= read -r pnadmin_password
else
  fail 'pipe the pnadmin password to stdin; it must not be a command argument'
fi
[ -n "$pnadmin_password" ] || fail 'pnadmin password cannot be empty'

docker cp "$script_dir/provision-app-role-container.sh" \
  "$openbao_container:$container_script"
printf '%s\n' "$pnadmin_password" | \
  docker exec -i "$openbao_container" sh "$container_script" "$app_name"
unset pnadmin_password

printf 'OpenBao AppRole for %s can read only secret/apps/%s.\n' "$app_name" "$app_name"
