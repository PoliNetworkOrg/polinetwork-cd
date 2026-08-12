#!/bin/sh
set -eu

docker_version="${PN_DOCKER_VERSION:-5:29.7.2-1~debian.13~trixie}"
containerd_version="${PN_CONTAINERD_VERSION:-2.3.3-1~debian.13~trixie}"
buildx_version="${PN_BUILDX_VERSION:-0.36.1-1~debian.13~trixie}"
compose_version="${PN_COMPOSE_VERSION:-5.4.0-1~debian.13~trixie}"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
files_dir="$script_dir/files"
config_changed=false

fail() {
  printf 'bootstrap-host: %s\n' "$*" >&2
  exit 1
}

install_tracked_file() {
  source_file="$1"
  target_file="$2"
  mode="$3"

  if [ ! -f "$target_file" ] || ! cmp -s "$source_file" "$target_file"; then
    install -D -o root -g root -m "$mode" "$source_file" "$target_file"
    config_changed=true
  fi
}

ensure_network() {
  network_name="$1"
  subnet="$2"
  gateway="$3"
  internal="$4"
  role="$5"

  if docker network inspect "$network_name" >/dev/null 2>&1; then
    actual="$(docker network inspect "$network_name" \
      --format '{{.Internal}}|{{(index .IPAM.Config 0).Subnet}}|{{(index .IPAM.Config 0).Gateway}}|{{index .Labels "com.polinetwork.role"}}')"
    expected="$internal|$subnet|$gateway|$role"
    [ "$actual" = "$expected" ] || fail "network $network_name differs from tracked definition: $actual"
    return
  fi

  if [ "$internal" = true ]; then
    docker network create --driver bridge --internal --subnet "$subnet" \
      --gateway "$gateway" --label "com.polinetwork.role=$role" "$network_name" >/dev/null
  else
    docker network create --driver bridge --subnet "$subnet" \
      --gateway "$gateway" --label "com.polinetwork.role=$role" "$network_name" >/dev/null
  fi
}

[ "$(id -u)" -eq 0 ] || fail 'run as root through sudo'
[ "$(dpkg --print-architecture)" = arm64 ] || fail 'expected Debian ARM64'
. /etc/os-release
[ "${ID:-}" = debian ] && [ "${VERSION_ID:-}" = 13 ] || fail 'expected Debian 13'
getent passwd pnadmin >/dev/null || fail 'pnadmin account is missing'
systemctl is-active --quiet prepare-data-disks.service || fail 'prepare-data-disks.service is not active'

for mount_point in /srv/polinetwork/state /srv/polinetwork/applications; do
  mountpoint -q "$mount_point" || fail "$mount_point is not a mount point"
  [ "$(findmnt -n -o FSTYPE -T "$mount_point")" = ext4 ] || fail "$mount_point is not ext4"
done

if command -v docker >/dev/null 2>&1 && \
  systemctl is-active --quiet docker.socket && \
  systemctl is-active --quiet docker.service && \
  [ -n "$(docker ps -aq 2>/dev/null)" ]; then
  for package_version in \
    "docker-ce:$docker_version" \
    "docker-ce-cli:$docker_version" \
    "containerd.io:$containerd_version" \
    "docker-buildx-plugin:$buildx_version" \
    "docker-compose-plugin:$compose_version"
  do
    package="${package_version%%:*}"
    version="${package_version#*:}"
    installed="$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)"
    [ "$installed" = "$version" ] || \
      fail "$package is $installed, expected $version; refusing to change an active container host"
  done

  cmp -s "$files_dir/etc/docker/daemon.json" /etc/docker/daemon.json || \
    fail 'Docker config differs from Git; refusing to change an active container host'
  cmp -s "$files_dir/etc/containerd/config.toml" /etc/containerd/config.toml || \
    fail 'containerd config differs from Git; refusing to change an active container host'
  cmp -s "$files_dir/etc/systemd/system/docker.service.d/storage.conf" \
    /etc/systemd/system/docker.service.d/storage.conf || \
    fail 'Docker systemd ordering differs from Git; refusing to change an active container host'
  cmp -s "$files_dir/etc/systemd/system/containerd.service.d/storage.conf" \
    /etc/systemd/system/containerd.service.d/storage.conf || \
    fail 'containerd systemd ordering differs from Git; refusing to change an active container host'

  ensure_network pn-edge 172.30.0.0/24 172.30.0.1 false edge
  ensure_network pn-app 172.30.1.0/24 172.30.1.1 false applications
  ensure_network pn-db 172.30.2.0/24 172.30.2.1 true database
  ensure_network pn-secrets 172.30.3.0/24 172.30.3.1 true secrets
  apt-mark hold docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  usermod --append --groups docker pnadmin
  printf 'Active host already matches the Git-backed bootstrap configuration; no service was restarted.\n'
  exit 0
fi

apt-get update
apt-get install --yes ca-certificates curl
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod 0644 /etc/apt/keyrings/docker.asc
install -m 0644 /dev/null /etc/apt/sources.list.d/docker.sources
printf '%s\n' \
  'Types: deb' \
  'URIs: https://download.docker.com/linux/debian' \
  'Suites: trixie' \
  'Components: stable' \
  'Architectures: arm64' \
  'Signed-By: /etc/apt/keyrings/docker.asc' \
  > /etc/apt/sources.list.d/docker.sources
apt-get update

for package_version in \
  "docker-ce:$docker_version" \
  "docker-ce-cli:$docker_version" \
  "containerd.io:$containerd_version" \
  "docker-buildx-plugin:$buildx_version" \
  "docker-compose-plugin:$compose_version"
do
  package="${package_version%%:*}"
  version="${package_version#*:}"
  apt-cache madison "$package" | awk '{print $3}' | grep -Fx "$version" >/dev/null || \
    fail "$package version $version is unavailable"
done

systemctl mask docker.service docker.socket containerd.service >/dev/null 2>&1 || true
apt-get install --yes --no-install-recommends \
  "docker-ce=$docker_version" \
  "docker-ce-cli=$docker_version" \
  "containerd.io=$containerd_version" \
  "docker-buildx-plugin=$buildx_version" \
  "docker-compose-plugin=$compose_version"

install -d -o root -g root -m 0711 \
  /srv/polinetwork/applications/docker \
  /srv/polinetwork/applications/containerd
install -d -o root -g root -m 0755 \
  /srv/polinetwork/applications/containerd/io.containerd.content.v1.content/blobs/sha256 \
  /srv/polinetwork/applications/containerd/io.containerd.content.v1.content/ingest

install_tracked_file "$files_dir/etc/docker/daemon.json" \
  /etc/docker/daemon.json 0644
install_tracked_file "$files_dir/etc/containerd/config.toml" \
  /etc/containerd/config.toml 0644
install_tracked_file "$files_dir/etc/systemd/system/docker.service.d/storage.conf" \
  /etc/systemd/system/docker.service.d/storage.conf 0644
install_tracked_file "$files_dir/etc/systemd/system/containerd.service.d/storage.conf" \
  /etc/systemd/system/containerd.service.d/storage.conf 0644

dockerd --validate --config-file=/etc/docker/daemon.json
containerd config dump >/dev/null
systemctl daemon-reload
systemctl unmask containerd.service docker.socket docker.service >/dev/null

if [ "$config_changed" = true ] && systemctl is-active --quiet docker.service && \
  [ -n "$(docker ps -aq 2>/dev/null)" ]; then
  fail 'tracked runtime config changed while containers exist; review and restart manually'
fi

systemctl enable --now containerd.service docker.socket docker.service
if [ "$config_changed" = true ]; then
  systemctl restart containerd.service docker.service
fi

apt-mark hold docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
usermod --append --groups docker pnadmin

ensure_network pn-edge 172.30.0.0/24 172.30.0.1 false edge
ensure_network pn-app 172.30.1.0/24 172.30.1.1 false applications
ensure_network pn-db 172.30.2.0/24 172.30.2.1 true database
ensure_network pn-secrets 172.30.3.0/24 172.30.3.1 true secrets

docker info --format 'DockerRootDir={{.DockerRootDir}} Driver={{.Driver}} LoggingDriver={{.LoggingDriver}}'
docker network inspect pn-edge pn-app pn-db pn-secrets \
  --format '{{.Name}} internal={{.Internal}} subnet={{(index .IPAM.Config 0).Subnet}} gateway={{(index .IPAM.Config 0).Gateway}} role={{index .Labels "com.polinetwork.role"}}'
printf 'Host bootstrap passed. Restore state and protected secret files before starting Compose projects.\n'
