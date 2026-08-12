#!/bin/sh
set -eu

vault_name="${PN_AZURE_KEY_VAULT_NAME:-kv-polinetwork}"
secret_name="${PN_DOCO_WEBHOOK_SECRET_NAME:-doco-cd-github-webhook-secret}"
repository="${PN_GITHUB_REPOSITORY:-PoliNetworkOrg/polinetwork-cd}"
webhook_url="${PN_DOCO_WEBHOOK_URL:-https://doco-cd.polinetwork.org/v1/webhook}"
work_dir=

fail() {
  printf 'configure-doco-webhook: %s\n' "$*" >&2
  exit 1
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  printf '%s\n' \
    'Usage: bootstrap/configure-doco-webhook.sh' \
    '' \
    'Creates or updates the push-only GitHub webhook and its Azure Key Vault HMAC secret.'
  exit 0
fi
[ "$#" -eq 0 ] || fail 'this helper accepts no arguments (use --help)'

cleanup() {
  if [ -n "$work_dir" ]; then
    rm -rf -- "$work_dir"
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ "$(id -u)" -ne 0 ] || fail 'run this workstation helper without sudo'
for tool in az gh jq openssl; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
az account show >/dev/null 2>&1 || fail 'Azure CLI is not authenticated'
gh auth status >/dev/null 2>&1 || fail 'GitHub CLI is not authenticated'
unset GH_DEBUG

work_dir="$(mktemp -d)"
chmod 0700 "$work_dir"
secret_file="$work_dir/webhook-secret"
hooks_file="$work_dir/hooks.json"
payload_file="$work_dir/payload.json"
azure_error_file="$work_dir/azure-error"

secret_exists=false
if az keyvault secret show \
  --vault-name "$vault_name" \
  --name "$secret_name" \
  --query id \
  --output tsv >/dev/null 2>"$azure_error_file"; then
  secret_exists=true
elif ! grep -q 'SecretNotFound' "$azure_error_file"; then
  sed 's/^/Azure: /' "$azure_error_file" >&2
  fail 'could not determine whether the Key Vault webhook secret exists'
fi

if [ "$secret_exists" = true ]; then
  az keyvault secret download \
    --vault-name "$vault_name" \
    --name "$secret_name" \
    --file "$secret_file" \
    --encoding utf-8 \
    --output none || fail 'could not download the existing Key Vault webhook secret'
else
  openssl rand -base64 48 > "$work_dir/webhook-secret-encoded"
  tr -d '\r\n' < "$work_dir/webhook-secret-encoded" > "$secret_file"
  chmod 0600 "$secret_file"
  az keyvault secret set \
    --vault-name "$vault_name" \
    --name "$secret_name" \
    --file "$secret_file" \
    --encoding utf-8 \
    --content-type 'GitHub HMAC secret for vm01 doco.cd webhook' \
    --output none
fi
[ -s "$secret_file" ] || fail 'webhook secret is empty'
chmod 0600 "$secret_file"
original_size="$(wc -c < "$secret_file" | tr -d ' ')"
single_line_size="$(tr -d '\r\n' < "$secret_file" | wc -c | tr -d ' ')"
[ "$original_size" = "$single_line_size" ] || \
  fail 'webhook secret must not contain CR or LF bytes'
if LC_ALL=C grep -q '^[[:space:]]' "$secret_file" || \
  LC_ALL=C grep -q '[[:space:]]$' "$secret_file"; then
  fail 'webhook secret must not start or end with whitespace'
fi

gh api "repos/$repository/hooks?per_page=100" > "$hooks_file"
hook_id="$(jq -r --arg url "$webhook_url" \
  '[.[] | select(.config.url == $url)] | if length > 1 then error("duplicate webhook URLs") else .[0].id // empty end' \
  "$hooks_file")" || fail 'could not inspect existing repository webhooks'
legacy_komodo_hooks="$(jq -r \
  '.[] | select(.config.url | startswith("https://komodo.polinetwork.org/listener/github/")) | .id' \
  "$hooks_file")"

jq -n \
  --arg url "$webhook_url" \
  --rawfile secret "$secret_file" \
  '{name:"web",active:true,events:["push"],config:{url:$url,content_type:"json",insecure_ssl:"0",secret:$secret}}' \
  > "$payload_file"

if [ -n "$hook_id" ]; then
  gh api --method PATCH "repos/$repository/hooks/$hook_id" \
    --input "$payload_file" >/dev/null
  printf 'Updated GitHub webhook %s for %s.\n' "$hook_id" "$webhook_url"
else
  gh api --method POST "repos/$repository/hooks" \
    --input "$payload_file" >/dev/null
  printf 'Created GitHub webhook for %s.\n' "$webhook_url"
fi

printf 'The shared HMAC secret is stored in Azure Key Vault as %s.\n' "$secret_name"
if [ -n "$legacy_komodo_hooks" ]; then
  printf 'Legacy Komodo webhook(s) remain unchanged: %s\n' \
    "$(printf '%s' "$legacy_komodo_hooks" | tr '\n' ' ')"
  printf 'Disable them only after a signed doco.cd delivery has passed.\n'
fi
printf '%s\n' \
  'The existing wildcard Cloudflare Tunnel route carries doco-cd.polinetwork.org to Traefik.' \
  'Do not place this HMAC-authenticated webhook hostname behind Cloudflare Access.'
