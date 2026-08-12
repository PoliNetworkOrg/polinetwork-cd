#!/bin/sh
set -eu

read_secret() {
  variable="$1"
  path="$2"
  [ -s "$path" ] || {
    printf 'mongo-entrypoint: secret is missing or empty: %s\n' "$path" >&2
    exit 1
  }
  value="$(cat "$path")"
  export "$variable=$value"
  unset value
}

read_secret MONGO_INITDB_ROOT_USERNAME /run/secrets/database_username
read_secret MONGO_INITDB_ROOT_PASSWORD /run/secrets/database_password
exec /usr/local/bin/docker-entrypoint.sh "$@"
