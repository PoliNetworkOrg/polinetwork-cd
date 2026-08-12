#!/bin/sh
set -eu

mode="${1:-runtime}"
tmp_dir=
tty_mode=

fail() {
  printf 'prepare-secrets: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$tty_mode" ] && [ -e /dev/tty ]; then
    stty "$tty_mode" </dev/tty 2>/dev/null || true
  fi
  unset secret_value
  if [ -n "$tmp_dir" ]; then
    case "$tmp_dir" in
      /dev/shm/polinetwork-secrets.*)
        find "$tmp_dir" -type f -exec sh -c 'for file do : > "$file"; done' sh {} +
        rm -f "$tmp_dir"/*
        rmdir "$tmp_dir" 2>/dev/null || true
        ;;
      *) printf 'prepare-secrets: refusing unexpected temporary path: %s\n' "$tmp_dir" >&2 ;;
    esac
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

dotenv_value() {
  file="$1"
  key="$2"
  awk -v key="$key" '
    index($0, key "=") == 1 {
      count++
      value = substr($0, length(key) + 2)
      sub(/\r$/, "", value)
    }
    END {
      if (count != 1 || length(value) == 0) exit 1
      printf "%s", value
    }
  ' "$file"
}

prompt_secret() {
  label="$1"
  default_value="$2"
  [ -r /dev/tty ] || fail "a terminal is required to enter $label"
  if [ -n "$default_value" ]; then
    printf '%s [default: %s]: ' "$label" "$default_value" >/dev/tty
  else
    printf '%s: ' "$label" >/dev/tty
  fi
  tty_mode="$(stty -g </dev/tty)"
  stty -echo </dev/tty
  IFS= read -r secret_value </dev/tty || fail "could not read $label"
  stty "$tty_mode" </dev/tty
  tty_mode=
  printf '\n' >/dev/tty
  if [ -z "$secret_value" ]; then
    secret_value="$default_value"
  fi
  [ -n "$secret_value" ] || fail "$label cannot be empty"
}

prepare_secret() {
  target="$1"
  owner="$2"
  group="$3"
  permissions="$4"
  label="$5"
  default_value="$6"
  legacy_file="$7"
  legacy_key="$8"

  if [ -e "$target" ]; then
    [ -f "$target" ] && [ -s "$target" ] || fail "existing secret is not a non-empty file: $target"
    chown "$owner:$group" "$target"
    chmod "$permissions" "$target"
    printf 'Preserved %s.\n' "$target"
    return
  fi

  secret_value=
  if [ -n "$legacy_file" ] && [ -f "$legacy_file" ]; then
    secret_value="$(dotenv_value "$legacy_file" "$legacy_key" || true)"
  fi
  if [ -n "$secret_value" ]; then
    printf 'Migrated %s from the legacy protected environment file.\n' "$target"
  else
    prompt_secret "$label" "$default_value"
  fi

  temporary="$tmp_dir/secret"
  umask 077
  printf '%s' "$secret_value" >"$temporary"
  install -D -o "$owner" -g "$group" -m "$permissions" "$temporary" "$target"
  : >"$temporary"
  rm -f "$temporary"
  unset secret_value
}

prepare_runtime() {
  komodo_root=/srv/polinetwork/state/komodo
  komodo_secrets="$komodo_root/secrets"
  legacy_komodo="$komodo_root/compose.env"
  cloudflare_root=/srv/polinetwork/state/cloudflare
  legacy_cloudflare="$cloudflare_root/compose.env"
  zerobyte_secrets=/srv/polinetwork/state/zerobyte/secrets

  install -d -o root -g root -m 0711 "$komodo_secrets" "$cloudflare_root/secrets"
  install -d -o root -g root -m 0700 "$zerobyte_secrets"

  prepare_secret "$komodo_secrets/database-username" root root 0600 \
    'Komodo MongoDB username' komodo "$legacy_komodo" KOMODO_DATABASE_USERNAME
  prepare_secret "$komodo_secrets/database-password" root root 0600 \
    'Komodo MongoDB password (break-glass store)' '' "$legacy_komodo" KOMODO_DATABASE_PASSWORD
  prepare_secret "$komodo_secrets/init-admin-username" root root 0600 \
    'Komodo initial administrator username' admin "$legacy_komodo" KOMODO_INIT_ADMIN_USERNAME
  prepare_secret "$komodo_secrets/init-admin-password" root root 0600 \
    'Komodo initial administrator password (break-glass store)' '' "$legacy_komodo" KOMODO_INIT_ADMIN_PASSWORD
  prepare_secret "$komodo_secrets/webhook-secret" root root 0600 \
    'Komodo webhook secret (break-glass store)' '' "$legacy_komodo" KOMODO_WEBHOOK_SECRET
  prepare_secret "$komodo_secrets/jwt-secret" root root 0600 \
    'Komodo JWT secret (break-glass store)' '' "$legacy_komodo" KOMODO_JWT_SECRET
  prepare_secret "$cloudflare_root/secrets/tunnel-token" 65532 65532 0400 \
    'Dedicated vm01 Cloudflare Tunnel token (off-host store)' '' "$legacy_cloudflare" TUNNEL_TOKEN
  prepare_secret "$zerobyte_secrets/app-secret" root root 0600 \
    'Zerobyte APP secret (Key Vault: zerobyte-app-secret)' '' '' ''
  prepare_secret "$zerobyte_secrets/azure-storage-account-key" root root 0600 \
    'Zerobyte Azure account key (Key Vault: zerobyte-azure-storage-account-key)' '' '' ''

  if [ -f "$legacy_komodo" ] || [ -f "$legacy_cloudflare" ]; then
    printf '%s\n' 'Legacy compose.env files were not deleted; they are no longer used and may be removed after the new projects are accepted.'
  fi
}

prepare_recovery() {
  zerobyte_secrets=/srv/polinetwork/state/zerobyte/secrets
  install -d -o root -g root -m 0700 "$zerobyte_secrets"
  prepare_secret "$zerobyte_secrets/azure-storage-account-key" root root 0600 \
    'Zerobyte Azure account key (Key Vault: zerobyte-azure-storage-account-key)' '' '' ''
  prepare_secret "$zerobyte_secrets/restic-recovery-key" root root 0600 \
    'Zerobyte organization recovery key (break-glass store)' '' '' ''
}

[ "$(id -u)" -eq 0 ] || fail 'run as root through sudo'
case "$mode" in
  runtime|recovery|all) ;;
  *) fail 'usage: prepare-secrets.sh [runtime|recovery|all]' ;;
esac
tmp_dir="$(mktemp -d /dev/shm/polinetwork-secrets.XXXXXX)"

case "$mode" in
  runtime) prepare_runtime ;;
  recovery) prepare_recovery ;;
  all)
    prepare_runtime
    prepare_recovery
    ;;
esac

printf 'Protected %s secrets are ready; no value was printed or passed as a command argument.\n' "$mode"
