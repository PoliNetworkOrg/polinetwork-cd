#!/bin/sh
set -eu

image='quay.io/openbao/openbao:2.5.4'
production_container="${OPENBAO_CONTAINER:-control-openbao-1}"
openbao_env="${OPENBAO_ENV_FILE:-/srv/polinetwork/state/openbao/compose.env}"
restore_root="${ZEROBYTE_RESTORE_ROOT:-/srv/polinetwork/state/zerobyte/restore-tests}"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
container="openbao-restore-rehearsal-$run_id"
network="openbao-restore-rehearsal-$run_id"
volume="openbao-restore-rehearsal-$run_id"
container_created=false
network_created=false
volume_created=false

cleanup() {
  unset pnadmin_password
  if [ "$container_created" = true ]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
  fi
  if [ "$volume_created" = true ]; then
    docker volume rm "$volume" >/dev/null 2>&1 || true
  fi
  if [ "$network_created" = true ]; then
    docker network rm "$network" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT HUP INT TERM

if [ "$(id -u)" -ne 0 ]; then
  printf 'Run this rehearsal as root through sudo; protected restore and OpenBao files are intentionally not pnadmin-readable.\n' >&2
  exit 2
fi

if [ ! -t 0 ]; then
  IFS= read -r pnadmin_password
else
  printf 'Pipe the pnadmin password to stdin; it must not be a command argument.\n' >&2
  exit 2
fi

test "$(docker inspect -f '{{.State.Health.Status}}' "$production_container")" = healthy
test -r "$openbao_env"

if [ "$#" -eq 1 ]; then
  restored_snapshot="$1"
  case "$restored_snapshot" in
    "$restore_root"/openbao-*.snap) ;;
    *)
      printf 'The restored snapshot must be an openbao-*.snap file directly below %s.\n' "$restore_root" >&2
      exit 1
      ;;
  esac
  test -f "$restored_snapshot"
elif [ "$#" -eq 0 ]; then
  set -- "$restore_root"/openbao-*.snap
  if [ ! -f "$1" ] || [ "$#" -ne 1 ]; then
    printf 'Expected exactly one restored OpenBao snapshot below %s; otherwise pass its absolute path.\n' "$restore_root" >&2
    exit 1
  fi
  restored_snapshot="$1"
else
  printf 'Usage: restore-rehearsal.sh [absolute-restored-snapshot]\n' >&2
  exit 2
fi

docker network create "$network" >/dev/null
network_created=true
docker volume create "$volume" >/dev/null
volume_created=true

docker run --rm \
  --network none \
  --volume "$volume:/openbao/file" \
  --entrypoint /bin/sh \
  "$image" -ec '
    mkdir -p /openbao/file/raft
    chown 100:1000 /openbao/file /openbao/file/raft
    chmod 0700 /openbao/file/raft
  '

docker run --detach \
  --name "$container" \
  --hostname openbao \
  --network "$network" \
  --env-file "$openbao_env" \
  --env BAO_ADDR=http://127.0.0.1:8200 \
  --env BAO_LOCAL_CONFIG='{"ui":false,"api_addr":"http://127.0.0.1:8200","cluster_addr":"https://openbao:8201","seal":{"azurekeyvault":{"vault_name":"kv-polinetwork","key_name":"openbao-unseal"}},"storage":{"raft":{"path":"/openbao/file/raft","node_id":"vm01"}},"listener":{"tcp":{"address":"127.0.0.1:8200","cluster_address":"0.0.0.0:8201","tls_disable":true}}}' \
  --volume "$volume:/openbao/file" \
  --volume "$restored_snapshot:/snapshot/openbao.snap:ro" \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  --cap-add CHOWN \
  --cap-add DAC_OVERRIDE \
  --cap-add SETGID \
  --cap-add SETUID \
  "$image" server >/dev/null
container_created=true

attempt=0
until test "$(docker inspect -f '{{.State.Running}}' "$container")" = true && \
  docker exec "$container" sh -c '
  bao status >/dev/null 2>&1
  code=$?
  test "$code" -eq 0 -o "$code" -eq 2
'; do
  attempt=$((attempt + 1))
  if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != true ]; then
    docker logs --tail 80 "$container" >&2
    exit 1
  fi
  if [ "$attempt" -ge 30 ]; then
    docker logs --tail 50 "$container" >&2
    exit 1
  fi
  sleep 1
done

docker exec --user 0:0 "$container" sh -ec '
  umask 077
  init_file=/tmp/restore-rehearsal-init.json
  bao operator init \
    -recovery-shares=1 \
    -recovery-threshold=1 \
    -format=json > "$init_file"
  root_token="$(sed -n '\''s/^[[:space:]]*"root_token": "\([^"]*\)".*/\1/p'\'' "$init_file")"
  test -n "$root_token"
  BAO_TOKEN="$root_token" bao operator raft snapshot restore \
    -force /snapshot/openbao.snap
  unset root_token
  rm -f "$init_file"
'

docker restart "$container" >/dev/null
attempt=0
until test "$(docker inspect -f '{{.State.Running}}' "$container")" = true && \
  docker exec "$container" bao status 2>/dev/null | grep -q '^Sealed[[:space:]]*false$'; do
  attempt=$((attempt + 1))
  if [ "$(docker inspect -f '{{.State.Running}}' "$container")" != true ]; then
    docker logs --tail 80 "$container" >&2
    exit 1
  fi
  if [ "$attempt" -ge 60 ]; then
    docker logs --tail 80 "$container" >&2
    exit 1
  fi
  sleep 1
done

printf '%s\n' "$pnadmin_password" | docker exec -i "$container" sh -ec '
  IFS= read -r pnadmin_password
  token="$(bao write -field=token auth/userpass/login/pnadmin password="$pnadmin_password")"
  unset pnadmin_password
  BAO_TOKEN="$token" bao kv get -field=message -mount=secret apps/canary |
    grep -qx openbao-agent-ok
  BAO_TOKEN="$token" bao token revoke -self >/dev/null 2>&1 || true
  unset token
'
unset pnadmin_password

test "$(docker inspect -f '{{.State.Health.Status}}' "$production_container")" = healthy
printf 'OpenBao isolated restore rehearsal passed; pnadmin login and canary secret read succeeded.\n'
