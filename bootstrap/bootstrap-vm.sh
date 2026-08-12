#!/bin/sh
set -eu

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(CDPATH= cd -- "$script_dir/.." && pwd)"
openbao_dir="$repo_root/infra/openbao"
doco_dir="$repo_root/infra/doco-cd"
state_root=/srv/polinetwork/state
secret_root="$state_root/zerobyte/secrets"
restore_root="$state_root/zerobyte/restore-tests"
openbao_container=infra-openbao-openbao-1
zerobyte_container=zerobyte-zerobyte-1
restored_openbao=
restored_zerobyte=
restore_target=
admin_password=
output_file=
recovered=false

fail() {
  printf 'bootstrap-vm: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$output_file" ]; then
    rm -f "$output_file"
  fi
  unset admin_password
}
trap cleanup EXIT HUP INT TERM

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
    [ "$attempt" -lt 60 ] || fail 'OpenBao API did not become ready within 120 seconds'
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

need_admin=false

[ "$(id -u)" -eq 0 ] || fail 'run as root through sudo'
[ "$repo_root" = /srv/polinetwork/compose/polinetwork-cd ] || \
  fail 'checkout must be /srv/polinetwork/compose/polinetwork-cd because tracked systemd units use that path'

"$script_dir/bootstrap-host.sh"

openbao_compose config --quiet
openbao_compose up -d --pull always
wait_for_openbao_api

if ! openbao_initialized; then
  output_file="$(mktemp)"
  chmod 0600 "$output_file"
  if ! "$repo_root/core/zerobyte/openbao-snapshot/disaster-restore.sh" \
    > "$output_file"; then
    cat "$output_file"
    fail 'direct Azure recovery failed'
  fi
  cat "$output_file"

  restored_openbao="$(sed -n 's/^OpenBao: //p' "$output_file" | tail -n 1)"
  restored_zerobyte="$(sed -n 's/^Zerobyte: //p' "$output_file" | tail -n 1)"
  rm -f "$output_file"
  output_file=
  [ -s "$restored_openbao" ] || fail 'recovery did not return an OpenBao snapshot'
  [ -s "$restored_zerobyte" ] || fail 'recovery did not return a Zerobyte database'

  case "$restored_openbao" in
    "$restore_root"/openbao-disaster-*/openbao/openbao-*.snap) ;;
    *) fail 'recovered OpenBao path is outside the guarded restore layout' ;;
  esac
  case "$restored_zerobyte" in
    "$restore_root"/openbao-disaster-*/zerobyte/zerobyte-*.db) ;;
    *) fail 'recovered Zerobyte path is outside the guarded restore layout' ;;
  esac

  restore_target="$(dirname "$(dirname "$restored_openbao")")"
  [ "$(dirname "$(dirname "$restored_zerobyte")")" = "$restore_target" ] || \
    fail 'OpenBao and Zerobyte artifacts did not come from the same restore'

  openbao_compose cp \
    "$restored_openbao" openbao:/tmp/openbao-production-restore.snap

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

  openbao_compose restart openbao
  openbao_compose up -d \
    --wait --wait-timeout 120
  recovered=true
  need_admin=true
else
  wait_for_health "$openbao_container" 60
fi

if [ ! -e "$state_root/zerobyte/data/data/zerobyte.db" ]; then
  if [ -z "$restored_zerobyte" ]; then
    set -- "$restore_root"/openbao-disaster-*/zerobyte/zerobyte-*.db
    [ "$#" -eq 1 ] && [ -s "$1" ] || \
      fail 'Zerobyte database is absent and exactly one recovered database was not found'
    restored_zerobyte="$1"
  fi
  if docker inspect "$zerobyte_container" >/dev/null 2>&1 && \
    [ "$(docker inspect -f '{{.State.Running}}' "$zerobyte_container")" = true ]; then
    fail 'Zerobyte is running without its database; refusing automatic replacement'
  fi
  "$repo_root/core/zerobyte/database-snapshot/restore.sh" "$restored_zerobyte"
fi

for credential in \
  "$state_root/openbao/approle/doco-cd/role-id" \
  "$state_root/openbao/approle/doco-cd/secret-id"
do
  [ -s "$credential" ] || need_admin=true
done

for credential in \
  "$state_root/openbao/approle/backup/role-id" \
  "$state_root/openbao/approle/backup/secret-id"
do
  [ -s "$credential" ] || need_admin=true
done

if [ "$need_admin" = true ]; then
  admin_password="$(systemd-ask-password 'OpenBao pnadmin password')"
  [ -n "$admin_password" ] || fail 'OpenBao administrator password is empty'

  printf '%s\n' "$admin_password" | \
    docker exec --user 0:0 -i "$openbao_container" sh -ec '
      IFS= read -r admin_password
      token="$(printf "%s\n" "$admin_password" | \
        bao write -field=token auth/userpass/login/pnadmin password=-)"
      unset admin_password
      test -n "$token"
      export BAO_TOKEN="$token"

      bao kv get -field=message -mount=secret apps/canary | \
        grep -qx openbao-agent-ok
      bao kv get -field=tunnel_token -mount=secret core/cloudflared >/dev/null
      bao kv get -field=app_secret -mount=secret core/zerobyte >/dev/null
      bao kv get -field=azure_storage_account_key \
        -mount=secret core/zerobyte >/dev/null

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
    '

  printf '%s\n' "$admin_password" | \
    "$repo_root/core/zerobyte/openbao-snapshot/bootstrap.sh"
  unset admin_password
fi

doco_compose config --quiet
doco_compose up -d --pull always \
  --wait --wait-timeout 180

wait_for_health "$zerobyte_container" 90

install -o root -g root -m 0644 \
  "$repo_root/core/zerobyte/openbao-snapshot/openbao-snapshot.service" \
  /etc/systemd/system/openbao-snapshot.service
install -o root -g root -m 0644 \
  "$repo_root/core/zerobyte/openbao-snapshot/openbao-snapshot.timer" \
  /etc/systemd/system/openbao-snapshot.timer
install -o root -g root -m 0644 \
  "$repo_root/core/zerobyte/database-snapshot/zerobyte-database-snapshot.service" \
  /etc/systemd/system/zerobyte-database-snapshot.service
install -o root -g root -m 0644 \
  "$repo_root/core/zerobyte/database-snapshot/zerobyte-database-snapshot.timer" \
  /etc/systemd/system/zerobyte-database-snapshot.timer

systemctl daemon-reload
systemctl start openbao-snapshot.service
systemctl start zerobyte-database-snapshot.service
systemctl enable --now \
  openbao-snapshot.timer \
  zerobyte-database-snapshot.timer

if [ "$recovered" = true ]; then
  case "$restore_target" in
    "$restore_root"/openbao-disaster-*) rm -r -- "$restore_target" ;;
    *) fail 'refusing unexpected restore cleanup target' ;;
  esac
  rm -f -- \
    "$secret_root/azure-storage-account-key" \
    "$secret_root/restic-recovery-key"
fi

docker inspect "$openbao_container" "$zerobyte_container" \
  --format '{{.Name}}={{.State.Status}} health={{.State.Health.Status}}'
systemctl is-active \
  openbao-snapshot.timer \
  zerobyte-database-snapshot.timer
printf 'VM bootstrap passed; OpenBao, Zerobyte, doco.cd and snapshot timers are converged.\n'
