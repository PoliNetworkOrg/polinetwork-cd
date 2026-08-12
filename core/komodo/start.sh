#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
bootstrap_access="${PN_KOMODO_BOOTSTRAP_ACCESS:-false}"
secrets_dir="/srv/polinetwork/state/komodo/secrets"

fail() {
  printf 'start-komodo: %s\n' "$*" >&2
  exit 1
}

komodo_compose() {
  if [ "$bootstrap_access" = true ]; then
    docker compose -f "$script_dir/compose.yaml" \
      -f "$script_dir/bootstrap-access.compose.yaml" "$@"
  else
    docker compose -f "$script_dir/compose.yaml" "$@"
  fi
}

command -v docker >/dev/null 2>&1 || fail 'docker is not installed'
docker info >/dev/null 2>&1 || fail 'docker is not available to this user'
case "$bootstrap_access" in
  true|false) ;;
  *) fail 'PN_KOMODO_BOOTSTRAP_ACCESS must be true or false' ;;
esac

for secret_file in \
  database-username \
  database-password \
  init-admin-username \
  init-admin-password \
  webhook-secret \
  jwt-secret
do
  path="$secrets_dir/$secret_file"
  [ -s "$path" ] || fail "protected secret is missing or empty: $path"
  mode="$(stat -c '%a' "$path")"
  case "$mode" in
    400|600) ;;
    *) fail "protected secret mode must be 0400 or 0600: $path is $mode" ;;
  esac
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
