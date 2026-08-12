#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
env_file="${PN_KOMODO_ENV_FILE:-/srv/polinetwork/state/komodo/compose.env}"
bootstrap_access="${PN_KOMODO_BOOTSTRAP_ACCESS:-false}"

fail() {
  printf 'start-komodo: %s\n' "$*" >&2
  exit 1
}

komodo_compose() {
  if [ "$bootstrap_access" = true ]; then
    docker compose --env-file "$env_file" \
      -f "$script_dir/compose.yaml" \
      -f "$script_dir/bootstrap-access.compose.yaml" "$@"
  else
    docker compose --env-file "$env_file" -f "$script_dir/compose.yaml" "$@"
  fi
}

command -v docker >/dev/null 2>&1 || fail 'docker is not installed'
docker info >/dev/null 2>&1 || fail 'docker is not available to this user'
[ -f "$env_file" ] || fail "protected environment file is missing: $env_file"

case "$bootstrap_access" in
  true|false) ;;
  *) fail 'PN_KOMODO_BOOTSTRAP_ACCESS must be true or false' ;;
esac

mode="$(stat -c '%a' "$env_file")"
case "$mode" in
  400|600) ;;
  *) fail "protected environment file mode must be 0400 or 0600, found $mode" ;;
esac

for variable in \
  KOMODO_DATABASE_USERNAME \
  KOMODO_DATABASE_PASSWORD \
  KOMODO_INIT_ADMIN_USERNAME \
  KOMODO_INIT_ADMIN_PASSWORD \
  KOMODO_WEBHOOK_SECRET \
  KOMODO_JWT_SECRET
do
  count="$(awk -F= -v key="$variable" '$1 == key && length($0) > length(key) + 1 { count++ } END { print count + 0 }' "$env_file")"
  [ "$count" -eq 1 ] || fail "$variable must occur exactly once with a non-empty value"
done

for legacy_service in mongo core periphery; do
  legacy_container="$(docker ps -aq \
    --filter label=com.docker.compose.project=control \
    --filter "label=com.docker.compose.service=$legacy_service")"
  [ -z "$legacy_container" ] || \
    fail 'the legacy control project still owns Komodo; complete the reviewed project cutover first'
done

komodo_compose config --quiet
komodo_compose pull
komodo_compose up -d --wait --wait-timeout 120
komodo_compose ps

if [ "$bootstrap_access" = true ]; then
  printf '%s\n' \
    'Komodo bootstrap access is bound only to 127.0.0.1:9120.' \
    'Use an SSH local forward to seed the Resource Sync, then rerun without PN_KOMODO_BOOTSTRAP_ACCESS to remove the binding.'
fi
