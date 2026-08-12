#!/bin/sh
set -eu

vault_name="${PN_AZURE_KEY_VAULT_NAME:-kv-polinetwork}"
identity_client_id="${PN_AZURE_MANAGED_IDENTITY_CLIENT_ID:-aefbc677-c339-462f-a99b-3a473b8043db}"

fail() {
  printf 'fetch-keyvault-secret: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "${work_dir:-}" ]; then
    rm -rf -- "$work_dir"
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ "$(id -u)" -eq 0 ] || fail 'run as root through sudo'
[ "$#" -eq 2 ] || fail 'usage: fetch-keyvault-secret.sh SECRET_NAME DESTINATION'
command -v curl >/dev/null 2>&1 || fail 'curl is required'
command -v jq >/dev/null 2>&1 || fail 'jq is required'

secret_name="$1"
destination="$2"
case "$secret_name" in
  *[!a-zA-Z0-9-]*|'') fail 'secret name contains unsupported characters' ;;
esac
case "$secret_name" in
  cloudflared-vm-tunnel-token|doco-cd-github-webhook-secret|zerobyte-app-secret|zerobyte-azure-storage-account-key|zerobyte-restic-recovery-key) ;;
  *) fail "secret name is not in the bootstrap allowlist: $secret_name" ;;
esac
case "$destination" in
  /*) ;;
  *) fail 'destination must be an absolute path' ;;
esac

work_dir="$(mktemp -d /run/polinetwork-keyvault.XXXXXX)"
chmod 0700 "$work_dir"
token_response="$work_dir/token.json"
token_file="$work_dir/token"
curl_config="$work_dir/curl.conf"
secret_response="$work_dir/secret.json"
secret_file="$work_dir/value"

curl --fail --silent --show-error \
  --connect-timeout 5 --max-time 30 \
  --header 'Metadata: true' \
  --output "$token_response" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net&client_id=$identity_client_id"

jq -erj '.access_token | select(type == "string" and length > 0)' \
  "$token_response" > "$token_file" || fail 'managed-identity token response is invalid'
chmod 0600 "$token_file"

{
  printf 'silent\n'
  printf 'show-error\n'
  printf 'fail\n'
  printf 'connect-timeout = 5\n'
  printf 'max-time = 30\n'
  printf 'header = "Authorization: Bearer %s"\n' "$(cat "$token_file")"
  printf 'output = "%s"\n' "$secret_response"
} > "$curl_config"
chmod 0600 "$curl_config"

curl --config "$curl_config" \
  "https://$vault_name.vault.azure.net/secrets/$secret_name?api-version=2025-07-01"

jq -erj '.value | select(type == "string" and length > 0)' \
  "$secret_response" > "$secret_file" || fail "Key Vault secret is missing or empty: $secret_name"
chmod 0600 "$secret_file"

install -d -o root -g root -m 0700 "$(dirname "$destination")"
install -o root -g root -m 0600 "$secret_file" "$destination"
