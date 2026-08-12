#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
openbao_dir="$repo_root/infra/openbao"
doco_dir="$repo_root/infra/doco-cd"
state_root=/srv/polinetwork/state
secret_root="$state_root/zerobyte/secrets"
restore_root="$state_root/zerobyte/restore-tests"
runtime_secret_root=/run/polinetwork-bootstrap-secrets
doco_webhook_secret="$state_root/doco-cd/secrets/github-webhook-secret"
openbao_container=infra-openbao-openbao-1
zerobyte_container=zerobyte-zerobyte-1
restored_openbao=
restored_zerobyte=
restore_target=
admin_password=
output_file=
current_step_file=
recovered=false
recovery_required=false
need_admin=false
force_admin=false
azure_secret_staged=false
restic_secret_staged=false
doco_secret_changed=false
runtime_secrets_staged=false
verbose="${PN_BOOTSTRAP_VERBOSE:-false}"
log_file=
phase_active=false
phase_label=

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  blue='\033[1;34m'
  green='\033[1;32m'
  red='\033[1;31m'
  bold='\033[1m'
  reset='\033[0m'
  interactive_output=true
else
  blue=
  green=
  red=
  bold=
  reset=
  interactive_output=false
fi

usage() {
  printf '%s\n' \
    'Usage: sudo bootstrap/bootstrap-vm.sh [--verbose] [--with-admin]' \
    '' \
    '  --verbose     Print captured command output after each phase.' \
    '  --with-admin  Ask for the OpenBao administrator password up front.' \
    '  --help        Show this help.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --verbose) verbose=true ;;
    --with-admin) force_admin=true ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
case "$verbose" in
  true|1|yes) verbose=true ;;
  false|0|no|'') verbose=false ;;
  *) printf 'PN_BOOTSTRAP_VERBOSE must be true or false.\n' >&2; exit 2 ;;
esac

ui() {
  color="$1"
  marker="$2"
  shift 2
  printf '%b%s%b %s\n' "$color" "$marker" "$reset" "$*"
}

info() {
  ui "$blue" '›' "$*"
}

ok() {
  ui "$green" '✓' "$*"
}

phase_begin() {
  phase_label="$*"
  phase_active=true
  if [ "$interactive_output" = true ]; then
    printf '%b…%b %s' "$blue" "$reset" "$phase_label"
  fi
}

phase_done() {
  result_label="${1:-$phase_label}"
  if [ "$interactive_output" = true ]; then
    printf '\r\033[2K%b✓%b %s\n' "$green" "$reset" "$result_label"
  else
    ok "$result_label"
  fi
  phase_active=false
  phase_label=
}

phase_error() {
  result_label="$1"
  if [ "$interactive_output" = true ]; then
    printf '\r\033[2K%b✗%b %s\n' "$red" "$reset" "$result_label" >&2
  else
    ui "$red" '✗' "$result_label" >&2
  fi
  phase_active=false
  phase_label=
}

log_event() {
  event="$1"
  shift
  printf '[%s] %-5s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$*" \
    >> "$log_file"
}

fail() {
  if [ "$phase_active" = true ]; then
    phase_error "$phase_label"
  fi
  ui "$red" '✗' "$*" >&2
  if [ -n "$log_file" ]; then
    printf '  Detailed log: %s\n' "$log_file" >&2
  fi
  exit 1
}

cleanup() {
  if [ -n "$output_file" ]; then
    rm -f -- "$output_file"
  fi
  if [ -n "$current_step_file" ]; then
    rm -f -- "$current_step_file"
  fi
  if [ "$runtime_secrets_staged" = true ] && [ -d "$runtime_secret_root" ]; then
    rm -rf -- "$runtime_secret_root"
  fi
  if [ "$azure_secret_staged" = true ]; then
    rm -f -- "$secret_root/azure-storage-account-key"
  fi
  if [ "$restic_secret_staged" = true ]; then
    rm -f -- "$secret_root/restic-recovery-key"
  fi
  docker exec --user 0:0 "$openbao_container" sh -c \
    'rm -f /tmp/bootstrap-cloudflare-token /tmp/bootstrap-zerobyte-app-secret /tmp/bootstrap-zerobyte-account-key' \
    >/dev/null 2>&1 || true
  unset admin_password
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

run_step() {
  label="$1"
  shift
  current_step_file="$(mktemp /run/polinetwork-bootstrap-step.XXXXXX)"
  chmod 0600 "$current_step_file"
  phase_begin "$label"
  log_event START "$label"

  if "$@" > "$current_step_file" 2>&1; then
    cat "$current_step_file" >> "$log_file"
    log_event OK "$label"
    if [ "$verbose" = true ]; then
      cat "$current_step_file"
    fi
    rm -f -- "$current_step_file"
    current_step_file=
    phase_done "$label"
    return 0
  else
    status=$?
  fi

  cat "$current_step_file" >> "$log_file"
  log_event FAIL "$label (exit $status)"
  phase_error "$label failed (exit $status)"
  printf '%s\n' '  Last output:' >&2
  tail -n 80 "$current_step_file" | sed 's/^/    /' >&2
  rm -f -- "$current_step_file"
  current_step_file=
  fail 'Bootstrap stopped at the failed phase.'
}

run_capture_step() {
  label="$1"
  capture_file="$2"
  shift 2
  phase_begin "$label"
  log_event START "$label"

  if "$@" > "$capture_file" 2>&1; then
    cat "$capture_file" >> "$log_file"
    log_event OK "$label"
    if [ "$verbose" = true ]; then
      cat "$capture_file"
    fi
    phase_done "$label"
    return 0
  else
    status=$?
  fi

  cat "$capture_file" >> "$log_file"
  log_event FAIL "$label (exit $status)"
  phase_error "$label failed (exit $status)"
  tail -n 80 "$capture_file" | sed 's/^/    /' >&2
  fail 'Bootstrap stopped at the failed phase.'
}

run_check() {
  label="$1"
  shift
  current_step_file="$(mktemp /run/polinetwork-bootstrap-step.XXXXXX)"
  chmod 0600 "$current_step_file"
  log_event START "$label"

  if "$@" > "$current_step_file" 2>&1; then
    cat "$current_step_file" >> "$log_file"
    log_event OK "$label"
    if [ "$verbose" = true ]; then
      info "$label"
      cat "$current_step_file"
      ok "$label"
    fi
    rm -f -- "$current_step_file"
    current_step_file=
    return 0
  else
    status=$?
  fi

  cat "$current_step_file" >> "$log_file"
  log_event FAIL "$label (exit $status)"
  ui "$red" '✗' "$label failed (exit $status)" >&2
  printf '%s\n' '  Last output:' >&2
  tail -n 80 "$current_step_file" | sed 's/^/    /' >&2
  rm -f -- "$current_step_file"
  current_step_file=
  fail 'Bootstrap stopped at the failed check.'
}

openbao_compose() {
  docker compose \
    --project-directory "$openbao_dir" \
    --file "$openbao_dir/compose.yaml" \
    "$@"
}

doco_compose() {
  docker compose \
    --project-directory "$doco_dir" \
    --file "$doco_dir/compose.yaml" \
    "$@"
}

wait_for_openbao_api() {
  attempt=0
  while :; do
    if docker exec "$openbao_container" sh -c '
      bao status -format=json >/dev/null 2>&1
      code=$?
      test "$code" -eq 0 -o "$code" -eq 2
    ' 2>/dev/null; then
      return
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -lt 60 ] || fail 'OpenBao API did not become ready within 120 seconds.'
    sleep 2
  done
}

wait_for_health() {
  container="$1"
  timeout_attempts="$2"
  attempt=0
  while :; do
    health="$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || true)"
    [ "$health" = healthy ] && return
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$timeout_attempts" ] || \
      fail "$container did not become healthy; last health: ${health:-unavailable}"
    sleep 2
  done
}

openbao_initialized() {
  status="$(docker exec "$openbao_container" bao status -format=json 2>/dev/null || true)"
  printf '%s\n' "$status" | grep -q '"initialized":[[:space:]]*true'
}

fetch_secret() {
  secret_name="$1"
  destination="$2"
  "$script_dir/fetch-keyvault-secret.sh" "$secret_name" "$destination"
}

run_snapshot_bootstrap() {
  printf '%s\n' "$admin_password" | \
    "$repo_root/core/zerobyte/openbao-snapshot/bootstrap.sh"
}

install_timers() {
  install -o root -g root -m 0644 \
    "$repo_root/core/zerobyte/openbao-snapshot/openbao-snapshot.service" \
    /etc/systemd/system/openbao-snapshot.service &&
  install -o root -g root -m 0644 \
    "$repo_root/core/zerobyte/openbao-snapshot/openbao-snapshot.timer" \
    /etc/systemd/system/openbao-snapshot.timer &&
  install -o root -g root -m 0644 \
    "$repo_root/core/zerobyte/database-snapshot/zerobyte-database-snapshot.service" \
    /etc/systemd/system/zerobyte-database-snapshot.service &&
  install -o root -g root -m 0644 \
    "$repo_root/core/zerobyte/database-snapshot/zerobyte-database-snapshot.timer" \
    /etc/systemd/system/zerobyte-database-snapshot.timer &&
  systemctl daemon-reload &&
  systemctl start openbao-snapshot.service &&
  systemctl start zerobyte-database-snapshot.service &&
  systemctl enable --now \
    openbao-snapshot.timer \
    zerobyte-database-snapshot.timer
}

recover_backup_artifacts() {
  output_file="$(mktemp /run/polinetwork-recovery-output.XXXXXX)"
  chmod 0600 "$output_file"
  run_capture_step 'Retrieve and verify the latest OpenBao and Zerobyte backup from Azure' \
    "$output_file" \
    "$repo_root/core/zerobyte/openbao-snapshot/disaster-restore.sh"

  restored_openbao="$(sed -n 's/^OpenBao: //p' "$output_file" | tail -n 1)"
  restored_zerobyte="$(sed -n 's/^Zerobyte: //p' "$output_file" | tail -n 1)"
  rm -f -- "$output_file"
  output_file=
  [ -s "$restored_openbao" ] || fail 'Recovery did not return an OpenBao snapshot.'
  [ -s "$restored_zerobyte" ] || fail 'Recovery did not return a Zerobyte database.'

  case "$restored_openbao" in
    "$restore_root"/openbao-disaster-*/openbao/openbao-*.snap) ;;
    *) fail 'Recovered OpenBao path is outside the guarded restore layout.' ;;
  esac
  case "$restored_zerobyte" in
    "$restore_root"/openbao-disaster-*/zerobyte/zerobyte-*.db) ;;
    *) fail 'Recovered Zerobyte path is outside the guarded restore layout.' ;;
  esac

  restore_target="$(dirname "$(dirname "$restored_openbao")")"
  [ "$(dirname "$(dirname "$restored_zerobyte")")" = "$restore_target" ] || \
    fail 'OpenBao and Zerobyte artifacts did not come from the same restore.'
  recovered=true
}

[ "$(id -u)" -eq 0 ] || fail 'Run this entry point through sudo.'
[ "$repo_root" = /srv/polinetwork/compose/polinetwork-cd ] || \
  fail 'Checkout must be /srv/polinetwork/compose/polinetwork-cd because tracked systemd units use that path.'
command -v flock >/dev/null 2>&1 || fail 'flock is required for single-run protection.'
systemctl is-active --quiet prepare-data-disks.service || \
  fail 'prepare-data-disks.service is not active; fix the data-disk mount before bootstrap.'
for mount_point in "$state_root" /srv/polinetwork/applications; do
  mountpoint -q "$mount_point" || \
    fail "$mount_point is not mounted; refusing to inspect or create state on the OS disk."
done
umask 077
exec 9>/run/polinetwork-bootstrap.lock
flock --nonblock 9 || fail 'Another VM bootstrap is already running.'

install -d -o root -g root -m 0700 /var/log/polinetwork
log_file="/var/log/polinetwork/bootstrap-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
install -o root -g root -m 0600 /dev/null "$log_file"

printf '%bPoliNetwork VM bootstrap%b\n' "$bold" "$reset"
printf 'Detailed log: %s\n\n' "$log_file"
log_event START 'PoliNetwork VM bootstrap'

if [ ! -s "$state_root/openbao/raft/vault.db" ]; then
  recovery_required=true
  need_admin=true
fi
if [ ! -s "$state_root/zerobyte/data/data/zerobyte.db" ]; then
  recovery_required=true
fi
for credential in \
  "$state_root/openbao/approle/doco-cd/role-id" \
  "$state_root/openbao/approle/doco-cd/secret-id" \
  "$state_root/openbao/approle/backup/role-id" \
  "$state_root/openbao/approle/backup/secret-id"
do
  [ -s "$credential" ] || need_admin=true
done
[ "$force_admin" = false ] || need_admin=true

if [ "$need_admin" = true ]; then
  info 'One protected input is required before bootstrap begins.'
  admin_password="$(systemd-ask-password 'OpenBao pnadmin password')"
  [ -n "$admin_password" ] || fail 'OpenBao administrator password is empty.'
  ok 'OpenBao administrator password collected; it will not be logged.'
else
  ok 'No operator input is required for this convergence run.'
fi

run_step 'Configure the host and install or verify Docker tools' \
  "$script_dir/bootstrap-host.sh"

webhook_secret_before=missing
if [ -s "$doco_webhook_secret" ]; then
  webhook_secret_before="$(sha256sum "$doco_webhook_secret" | awk '{print $1}')"
fi
run_step 'Retrieve the doco.cd webhook secret from Azure Key Vault' \
  fetch_secret doco-cd-github-webhook-secret "$doco_webhook_secret"
webhook_secret_after="$(sha256sum "$doco_webhook_secret" | awk '{print $1}')"
[ "$webhook_secret_before" = "$webhook_secret_after" ] || doco_secret_changed=true

if [ "$need_admin" = true ]; then
  install -d -o root -g root -m 0700 "$runtime_secret_root"
  runtime_secrets_staged=true
  run_step 'Retrieve the Cloudflare tunnel token from Azure Key Vault' \
    fetch_secret cloudflared-vm-tunnel-token \
    "$runtime_secret_root/cloudflared-vm-tunnel-token"
  run_step 'Retrieve the Zerobyte application secret from Azure Key Vault' \
    fetch_secret zerobyte-app-secret \
    "$runtime_secret_root/zerobyte-app-secret"
fi

if [ "$need_admin" = true ] || [ "$recovery_required" = true ]; then
  run_step 'Retrieve the Azure backup account key from Azure Key Vault' \
    fetch_secret zerobyte-azure-storage-account-key \
    "$secret_root/azure-storage-account-key"
  azure_secret_staged=true
fi

if [ "$recovery_required" = true ]; then
  run_step 'Retrieve the active Restic recovery key from Azure Key Vault' \
    fetch_secret zerobyte-restic-recovery-key \
    "$secret_root/restic-recovery-key"
  restic_secret_staged=true
fi

run_check 'Validate the OpenBao Compose model' openbao_compose config --quiet
run_step 'Start OpenBao and its internal TLS initializer' \
  openbao_compose up -d --pull always
phase_begin 'Wait for the OpenBao API'
wait_for_openbao_api
phase_done 'OpenBao API reachable over internal TLS'

if ! openbao_initialized; then
  [ -n "$admin_password" ] || \
    fail 'OpenBao is uninitialized. Rerun with --with-admin so input is collected up front.'
  [ -s "$secret_root/restic-recovery-key" ] || \
    fail 'OpenBao needs recovery but the Restic recovery key was not staged.'
  recover_backup_artifacts

  run_step 'Stage the verified Raft snapshot for production restoration' \
    openbao_compose cp \
    "$restored_openbao" openbao:/tmp/openbao-production-restore.snap

  run_step 'Restore the production OpenBao Raft state' \
    openbao_compose exec -T --user 0:0 \
    openbao sh -ec '
      umask 077
      init_file=/tmp/openbao-production-init.json
      test ! -e "$init_file"
      bao operator init \
        -recovery-shares=1 \
        -recovery-threshold=1 \
        -format=json > "$init_file"
      root_token="$(sed -n '\''s/^[[:space:]]*"root_token": "\([^"]*\)".*/\1/p'\'' "$init_file")"
      test -n "$root_token"
      BAO_TOKEN="$root_token" bao operator raft snapshot restore \
        -force /tmp/openbao-production-restore.snap
      unset root_token
      rm -f "$init_file" /tmp/openbao-production-restore.snap
    '

  run_step 'Restart restored OpenBao' openbao_compose restart openbao
  run_step 'Converge and health-check restored OpenBao' \
    openbao_compose up -d --wait --wait-timeout 120
  ok 'OpenBao is initialized, auto-unsealed, active, and healthy.'
else
  phase_begin 'Wait for OpenBao health'
  wait_for_health "$openbao_container" 60
  phase_done 'OpenBao initialized, auto-unsealed, active, and healthy'
fi

if [ ! -e "$state_root/zerobyte/data/data/zerobyte.db" ]; then
  if [ -z "$restored_zerobyte" ]; then
    set -- "$restore_root"/openbao-disaster-*/zerobyte/zerobyte-*.db
    if [ "$#" -eq 1 ] && [ -s "$1" ]; then
      restored_zerobyte="$1"
    else
      recover_backup_artifacts
    fi
  fi
  if docker inspect "$zerobyte_container" >/dev/null 2>&1 && \
    [ "$(docker inspect -f '{{.State.Running}}' "$zerobyte_container")" = true ]; then
    fail 'Zerobyte is running without its database; refusing automatic replacement.'
  fi
  run_step 'Restore the consistent Zerobyte database snapshot' \
    "$repo_root/core/zerobyte/database-snapshot/restore.sh" "$restored_zerobyte"
else
  ok 'Existing Zerobyte database is present; no restore is needed.'
fi

if [ "$need_admin" = true ]; then
  run_step 'Stage the Cloudflare value inside OpenBao for protected import' \
    docker cp "$runtime_secret_root/cloudflared-vm-tunnel-token" \
    "$openbao_container:/tmp/bootstrap-cloudflare-token"
  run_step 'Stage the Zerobyte application value inside OpenBao' \
    docker cp "$runtime_secret_root/zerobyte-app-secret" \
    "$openbao_container:/tmp/bootstrap-zerobyte-app-secret"
  run_step 'Stage the Zerobyte storage value inside OpenBao' \
    docker cp "$secret_root/azure-storage-account-key" \
    "$openbao_container:/tmp/bootstrap-zerobyte-account-key"

  phase_begin 'Converge OpenBao runtime values and least-privilege AppRoles'
  log_event START 'Converge OpenBao runtime values and least-privilege AppRoles'
  current_step_file="$(mktemp /run/polinetwork-bootstrap-step.XXXXXX)"
  chmod 0600 "$current_step_file"
  if printf '%s' "$admin_password" | \
    docker exec --user 0:0 -i "$openbao_container" sh -ec '
      cleanup() {
        rm -f \
          /tmp/bootstrap-cloudflare-token \
          /tmp/bootstrap-zerobyte-app-secret \
          /tmp/bootstrap-zerobyte-account-key
      }
      trap cleanup EXIT HUP INT TERM
      admin_password=
      IFS= read -r admin_password || test -n "$admin_password"
      token="$(printf "%s" "$admin_password" | \
        bao write -field=token auth/userpass/login/pnadmin password=-)"
      unset admin_password
      test -n "$token"
      export BAO_TOKEN="$token"

      chmod 0400 \
        /tmp/bootstrap-cloudflare-token \
        /tmp/bootstrap-zerobyte-app-secret \
        /tmp/bootstrap-zerobyte-account-key
      bao kv put -mount=secret core/cloudflared \
        tunnel_token=@/tmp/bootstrap-cloudflare-token >/dev/null
      bao kv put -mount=secret core/zerobyte \
        app_secret=@/tmp/bootstrap-zerobyte-app-secret \
        azure_storage_account_key=@/tmp/bootstrap-zerobyte-account-key \
        >/dev/null
      bao kv get -field=message -mount=secret apps/canary | \
        grep -qx openbao-agent-ok

      bao auth list -format=json | grep -q '"'"'approle/'"'"' || \
        bao auth enable approle >/dev/null
      printf "%s\n" \
        '"'"'path "secret/data/core/*" { capabilities = ["read"] }'"'"' \
        '"'"'path "secret/data/apps/*" { capabilities = ["read"] }'"'"' |
        bao policy write doco-cd - >/dev/null
      bao write auth/approle/role/doco-cd \
        token_policies=doco-cd \
        token_no_default_policy=true \
        token_period=24h \
        secret_id_num_uses=0 \
        secret_id_ttl=0 >/dev/null

      mkdir -p /openbao/file/approle/doco-cd
      chown 0:0 /openbao/file/approle/doco-cd
      chmod 0750 /openbao/file/approle/doco-cd
      rm -f \
        /openbao/file/approle/doco-cd/role-id \
        /openbao/file/approle/doco-cd/secret-id
      umask 077
      bao read -field=role_id auth/approle/role/doco-cd/role-id \
        > /openbao/file/approle/doco-cd/role-id
      bao write -field=secret_id -f auth/approle/role/doco-cd/secret-id \
        > /openbao/file/approle/doco-cd/secret-id
      chmod 0400 \
        /openbao/file/approle/doco-cd/role-id \
        /openbao/file/approle/doco-cd/secret-id
      chown 100:1000 \
        /openbao/file/approle/doco-cd/role-id \
        /openbao/file/approle/doco-cd/secret-id

      bao token revoke -self >/dev/null
      unset BAO_TOKEN token
    ' > "$current_step_file" 2>&1
  then
    cat "$current_step_file" >> "$log_file"
    log_event OK 'Converge OpenBao runtime values and least-privilege AppRoles'
    [ "$verbose" = false ] || cat "$current_step_file"
    rm -f -- "$current_step_file"
    current_step_file=
    phase_done 'OpenBao runtime values and doco.cd AppRole converged'
  else
    status=$?
    cat "$current_step_file" >> "$log_file"
    log_event FAIL "Converge OpenBao runtime values and least-privilege AppRoles (exit $status)"
    phase_error "OpenBao provisioning failed (exit $status)"
    tail -n 80 "$current_step_file" | sed 's/^/    /' >&2
    fail 'Bootstrap stopped while provisioning OpenBao.'
  fi

  run_step 'Regenerate and verify the snapshot AppRole' run_snapshot_bootstrap
  unset admin_password
else
  ok 'Existing doco.cd and snapshot AppRole credentials are present.'
fi

run_check 'Validate the doco.cd Compose model' doco_compose config --quiet
if [ "$doco_secret_changed" = true ]; then
  run_step 'Start doco.cd, reconcile once, and enable the signed webhook' \
    doco_compose up -d --pull always --force-recreate \
    --wait --wait-timeout 180 doco-cd
else
  run_step 'Converge doco.cd, reconcile once, and enable the signed webhook' \
    doco_compose up -d --pull always --wait --wait-timeout 180
fi

phase_begin 'Wait for Zerobyte reconciliation and health'
wait_for_health "$zerobyte_container" 90
phase_done 'Zerobyte running and healthy'

run_step 'Install, exercise, and enable platform snapshot timers' install_timers

if [ "$recovered" = true ]; then
  case "$restore_target" in
    "$restore_root"/openbao-disaster-*) rm -r -- "$restore_target" ;;
    *) fail 'Refusing unexpected restore cleanup target.' ;;
  esac
fi
rm -f -- \
  "$secret_root/azure-storage-account-key" \
  "$secret_root/restic-recovery-key"

openbao_health="$(docker inspect -f '{{.State.Health.Status}}' "$openbao_container")"
zerobyte_health="$(docker inspect -f '{{.State.Health.Status}}' "$zerobyte_container")"
[ "$openbao_health" = healthy ] || fail "OpenBao final health is $openbao_health."
[ "$zerobyte_health" = healthy ] || fail "Zerobyte final health is $zerobyte_health."
systemctl is-active --quiet openbao-snapshot.timer zerobyte-database-snapshot.timer || \
  fail 'One or more snapshot timers are inactive.'

printf '\n'
ok 'VM bootstrap passed.'
log_event OK 'PoliNetwork VM bootstrap'
printf '  OpenBao, doco.cd, Zerobyte, and both snapshot timers are converged.\n'
