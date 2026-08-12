#!/bin/sh
set -eu

vault_name="${PN_AZURE_KEY_VAULT_NAME:-kv-polinetwork}"
secret_name=zerobyte-restic-recovery-key
replace=false
work_dir=

fail() {
  printf 'seed-restic-recovery-key: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$work_dir" ]; then
    rm -rf -- "$work_dir"
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

usage() {
  printf '%s\n' \
    'Usage: bootstrap/seed-restic-recovery-key.sh [--replace] RESTIC_PASS_FILE' \
    '' \
    'Stores the exact active Zerobyte organization restic.pass in Azure Key Vault.' \
    'Use --replace only for a deliberate password rotation.'
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
if [ "${1:-}" = --replace ]; then
  replace=true
  shift
fi
[ "$#" -eq 1 ] || { usage >&2; exit 2; }

[ "$(id -u)" -ne 0 ] || fail 'run this workstation helper without sudo'
command -v az >/dev/null 2>&1 || fail 'az is required'
az account show >/dev/null 2>&1 || fail 'Azure CLI is not authenticated'

restic_pass_file="$1"
[ -f "$restic_pass_file" ] || fail 'RESTIC_PASS_FILE must be a regular file'
[ -r "$restic_pass_file" ] || fail 'RESTIC_PASS_FILE is not readable'
[ -s "$restic_pass_file" ] || fail 'RESTIC_PASS_FILE is empty'
work_dir="$(mktemp -d)"
chmod 0700 "$work_dir"

if az keyvault secret show \
  --vault-name "$vault_name" \
  --name "$secret_name" \
  --query id \
  --output tsv >/dev/null 2>&1; then
  [ "$replace" = true ] || \
    fail "$secret_name already exists; use --replace only for a deliberate rotation"
fi

az keyvault secret set \
  --vault-name "$vault_name" \
  --name "$secret_name" \
  --file "$restic_pass_file" \
  --encoding utf-8 \
  --content-type 'Exact active Zerobyte organization restic.pass for VM recovery' \
  --output none

az keyvault secret download \
  --vault-name "$vault_name" \
  --name "$secret_name" \
  --file "$work_dir/restic.pass" \
  --encoding utf-8 \
  --overwrite \
  --output none
chmod 0600 "$work_dir/restic.pass"
cmp -s "$restic_pass_file" "$work_dir/restic.pass" || \
  fail 'Key Vault round-trip did not preserve the exact restic.pass bytes'

enabled="$(az keyvault secret show \
  --vault-name "$vault_name" \
  --name "$secret_name" \
  --query attributes.enabled \
  --output tsv)"
[ "$enabled" = true ] || fail 'the stored Key Vault version is not enabled'
printf 'Stored and byte-verified an enabled %s version without printing its value.\n' "$secret_name"
