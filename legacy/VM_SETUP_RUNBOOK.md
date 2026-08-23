# VM setup runbook

Chronological record of the manual configuration of `vm01` for the AKS-to-Docker
migration. This is a local working document: it records the commands proposed to
the operator and the observed outcome, so the final procedure can be rebuilt
after the migration.

Rules:

- Codex does not connect to or execute commands on the VM.
- Add commands here when they are proposed, before the operator runs them.
- Add results only from output reported by the operator; do not infer success.
- Never record secret values. Replace sensitive values with placeholders.
- Prefer idempotent commands and record why each state-changing command exists.

## Known initial state

Date: 2026-08-11

- Host: `vm01`
- Administrator: `pnadmin`
- OS: Debian 13 ARM64
- VM size: Azure `Standard_E2ps_v6`, 2 vCPU and 16 GiB RAM
- `/srv/polinetwork/state`: ext4 mount backed by `disk-core`
- `/srv/polinetwork/applications`: ext4 mount backed by `disk-services`
- `/srv/polinetwork/compose`: directory on the OS filesystem, intentionally not
  a data-disk mount; reserved for the small, version-controlled Compose checkout
  and its operational definitions
- 4 GiB swap configured with swappiness 10
- No manual host or Docker bootstrap has been performed yet.

Observed read-only check:

```console
pnadmin@vm01:~$ ls /srv/polinetwork/
applications  compose  state
```

## Decisions pending before bootstrap

- Confirm Docker `data-root`: proposed
  `/srv/polinetwork/applications/docker`.
- Define ownership for `/srv/polinetwork/compose` and the two data-disk trees.

## Storage roles

- `/srv/polinetwork/compose`: reproducible Compose files, deployment metadata
  and non-secret operational scripts. Its contents must remain small and
  recoverable from Git.
- `/srv/polinetwork/applications`: Docker engine data and mutable application
  files that do not belong on the OS disk.
- `/srv/polinetwork/state`: critical persistent state such as databases and
  OpenBao Raft data.
- Runtime secrets must not be stored in the Compose checkout; they will be
  rendered into a runtime-only location such as tmpfs.

## Execution log

### 2026-08-11 — Zsh preflight and Debian packages

Status: completed successfully.

Purpose: verify the target account and detect existing user configuration before
installing Zsh and Git from the configured Debian repositories.

```bash
whoami
getent passwd pnadmin
printf 'login shell: %s\n' "$SHELL"
ls -ld "$HOME/.oh-my-zsh" "$HOME/.zshrc" 2>/dev/null || true
sudo apt-get update
sudo apt-get install --yes zsh git
zsh --version
git --version
grep -Fx /usr/bin/zsh /etc/shells
```

Expected result:

- The active account is `pnadmin`.
- No existing `.oh-my-zsh` directory or `.zshrc` file is present. If either is
  listed, stop before installing Oh My Zsh and preserve the existing setup.
- Zsh and Git install successfully.
- `/usr/bin/zsh` is registered in `/etc/shells` and can therefore be selected
  with `chsh`.

Observed result:

- Executed as `pnadmin`; the initial login shell was `/bin/bash`.
- No existing `.oh-my-zsh` or `.zshrc` path was reported.
- APT used the Debian 13 `trixie`, `trixie-updates`, `trixie-backports` and
  `trixie-security` repositories through the Azure Debian mirror.
- Installed `zsh` 5.9 (`5.9-8+b23`, ARM64) and Git 2.47.3
  (`1:2.47.3-0+deb13u1`) with their dependencies.
- APT reported `0 upgraded`, `13 newly installed`, `0 removed` and
  `0 not upgraded`.
- `/usr/bin/zsh` is present in `/etc/shells`.

### 2026-08-11 — Oh My Zsh and default login shell

Status: completed successfully after remediation.

Purpose: install Oh My Zsh from its official Git repository without executing a
downloaded installer, create a minimal user configuration, disable unattended
framework updates and set Zsh as the login shell for `pnadmin`.

```bash
git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
{
  printf '%s\n' "zstyle ':omz:update' mode disabled"
  cat "$HOME/.oh-my-zsh/templates/zshrc.zsh-template"
} > "$HOME/.zshrc"
chmod 600 "$HOME/.zshrc"
git -C "$HOME/.oh-my-zsh" rev-parse HEAD
zsh -lic 'printf "zsh=%s oh-my-zsh=%s\\n" "$ZSH_VERSION" "$ZSH"'
sudo chsh --shell /usr/bin/zsh pnadmin
getent passwd pnadmin
```

Expected result:

- The repository is cloned into `/home/pnadmin/.oh-my-zsh` and its exact commit
  is printed for the final reproducibility record.
- A login-shell smoke test loads Zsh and Oh My Zsh successfully.
- The passwd entry for `pnadmin` ends in `/usr/bin/zsh`.
- The current SSH process remains Bash until the operator exits and reconnects.

Observed result:

- Git cloned the repository as `/home/pnadmin/ohmyzsh`, indicating that the
  intended destination argument `/home/pnadmin/.oh-my-zsh` was not applied.
- Creation of `.zshrc` continued after the failed `cat`; the resulting file is
  incomplete and does not source Oh My Zsh.
- The Zsh smoke test therefore reported `zsh=5.9 oh-my-zsh=`.
- The default login shell change succeeded; the passwd entry now ends in
  `/usr/bin/zsh`.

Remediation executed:

```bash
ls -ld "$HOME/ohmyzsh" "$HOME/.oh-my-zsh" "$HOME/.zshrc" 2>/dev/null || true
mv "$HOME/ohmyzsh" "$HOME/.oh-my-zsh"
cp "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" "$HOME/.zshrc"
sed -i "1i zstyle ':omz:update' mode disabled" "$HOME/.zshrc"
chmod 600 "$HOME/.zshrc"
git -C "$HOME/.oh-my-zsh" rev-parse HEAD
zsh -lic 'printf "zsh=%s oh-my-zsh=%s\\n" "$ZSH_VERSION" "$ZSH"'
getent passwd pnadmin
```

Remediation result:

- The existing clone was moved from `/home/pnadmin/ohmyzsh` to
  `/home/pnadmin/.oh-my-zsh`.
- `.zshrc` was rebuilt from the official template with automatic Oh My Zsh
  updates disabled and mode `0600`.
- Installed Oh My Zsh commit:
  `b54a71977574cfcf659cc2f15a5e6422f17a8da7`.
- Smoke test succeeded with `zsh=5.9` and
  `oh-my-zsh=/home/pnadmin/.oh-my-zsh`.
- The passwd entry confirms `/usr/bin/zsh` as the login shell.

### 2026-08-11 — Zsh login verification

Status: completed successfully, confirmed by the operator after reconnecting.

```bash
chmod -R go-w "$HOME/.oh-my-zsh"
exit
```

After reconnecting over SSH:

```zsh
printf 'login shell: %s\n' "$SHELL"
printf 'zsh version: %s\n' "$ZSH_VERSION"
printf 'oh-my-zsh: %s\n' "$ZSH"
ps -p $$ -o comm=
```

Expected result: `/usr/bin/zsh`, version `5.9`, the expected Oh My Zsh path and
`zsh` as the current process.

### 2026-08-11 — Docker repository and version discovery

Status: proposed, awaiting operator execution.

Purpose: verify the target data-disk mount and absence of conflicting Docker
packages/configuration, add Docker's official Debian 13 ARM64 APT repository and
discover the exact package versions to pin. This step does not install or start
the Docker daemon.

```zsh
findmnt -T /srv/polinetwork/applications -o TARGET,SOURCE,FSTYPE,OPTIONS
df -hT / /srv/polinetwork/applications
dpkg-query -W -f='${binary:Package}\t${Version}\n' docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc 2>/dev/null || true
sudo ls -l /etc/docker/daemon.json /etc/containerd/config.toml 2>/dev/null || true
sudo apt-get update
sudo apt-get install --yes ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
printf '%s\n' \
  'Types: deb' \
  'URIs: https://download.docker.com/linux/debian' \
  'Suites: trixie' \
  'Components: stable' \
  'Architectures: arm64' \
  'Signed-By: /etc/apt/keyrings/docker.asc' \
  | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
sudo apt-get update
apt-cache policy docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Expected result:

- `/srv/polinetwork/applications` resolves to the ext4 `disk-services` mount,
  not the OS filesystem.
- No conflicting package or pre-existing daemon configuration is reported.
- APT accepts the official Docker repository for `trixie/arm64`.
- Each of the five Docker packages has an explicit candidate version, which
  will be used in the installation command and recorded here.

Observed result: repository definition created, but the first `apt-get update`
failed safely because `/etc/apt/keyrings/docker.asc` did not exist. APT rejected
the unsigned repository, and no Docker package candidate or installation was
available. No Docker package was installed. The key was then downloaded from
Docker's official Debian endpoint with size 3,817 bytes and mode `0644`; the
subsequent APT update accepted the signed `trixie/stable arm64` repository.

Execution note: the first attempt to create `docker.sources` with a heredoc was
interrupted because the interactive Zsh prompt did not recognize the `EOF`
terminator. The command above is the replacement and does not use a heredoc.

Keyring remediation proposed, awaiting operator execution:

```zsh
sudo apt-get install --yes ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo test -s /etc/apt/keyrings/docker.asc
sudo ls -l /etc/apt/keyrings/docker.asc
sudo apt-get update
apt-cache policy docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Keyring remediation result: completed successfully.

Selected candidate versions for explicit installation:

- `docker-ce`: `5:29.7.2-1~debian.13~trixie`
- `docker-ce-cli`: `5:29.7.2-1~debian.13~trixie`
- `containerd.io`: `2.3.3-1~debian.13~trixie`
- `docker-buildx-plugin`: `0.36.1-1~debian.13~trixie`
- `docker-compose-plugin`: `5.4.0-1~debian.13~trixie`

Final mount/conflict evidence remains pending before installation because its
output was not included in the operator report.

Final preflight result:

- `/srv/polinetwork/applications` is `/dev/sdc`, ext4, mounted read-write with
  `nosuid,nodev`; approximately 60 GiB of 63 GiB is available.
- The OS filesystem has approximately 25 GiB of 32 GiB available.
- `prepare-data-disks.service` is active.
- No conflicting Docker/containerd package was reported.

### 2026-08-11 — Pinned Docker installation and storage configuration

Status: proposed, awaiting operator execution.

Purpose: install the selected official packages without allowing their services
to start against OS-disk defaults, configure persistent Docker and containerd
storage on `disk-services`, enforce bounded local container logs and require the
data-disk mount before either runtime starts.

Selected package versions:

- Docker Engine and CLI: `5:29.7.2-1~debian.13~trixie`
- containerd: `2.3.3-1~debian.13~trixie`
- Buildx: `0.36.1-1~debian.13~trixie`
- Compose: `5.4.0-1~debian.13~trixie`

Commands:

```zsh
sudo systemctl mask docker.service docker.socket containerd.service

sudo apt-get install --yes --no-install-recommends \
  'docker-ce=5:29.7.2-1~debian.13~trixie' \
  'docker-ce-cli=5:29.7.2-1~debian.13~trixie' \
  'containerd.io=2.3.3-1~debian.13~trixie' \
  'docker-buildx-plugin=0.36.1-1~debian.13~trixie' \
  'docker-compose-plugin=5.4.0-1~debian.13~trixie'

sudo install -d -m 0711 -o root -g root \
  /srv/polinetwork/applications/docker \
  /srv/polinetwork/applications/containerd
sudo install -d -m 0755 -o root -g root \
  /etc/docker \
  /etc/containerd \
  /etc/systemd/system/docker.service.d \
  /etc/systemd/system/containerd.service.d

printf '%s\n' \
  '{' \
  '  "data-root": "/srv/polinetwork/applications/docker",' \
  '  "log-driver": "local",' \
  '  "log-opts": {' \
  '    "max-size": "20m",' \
  '    "max-file": "5"' \
  '  },' \
  '  "live-restore": true' \
  '}' \
  | sudo tee /etc/docker/daemon.json >/dev/null

printf '%s\n' \
  'version = 4' \
  'root = "/srv/polinetwork/applications/containerd"' \
  'state = "/run/containerd"' \
  | sudo tee /etc/containerd/config.toml >/dev/null

printf '%s\n' \
  '[Unit]' \
  'Requires=prepare-data-disks.service' \
  'After=prepare-data-disks.service' \
  'RequiresMountsFor=/srv/polinetwork/applications' \
  | sudo tee /etc/systemd/system/docker.service.d/storage.conf >/dev/null

printf '%s\n' \
  '[Unit]' \
  'Requires=prepare-data-disks.service' \
  'After=prepare-data-disks.service' \
  'RequiresMountsFor=/srv/polinetwork/applications' \
  | sudo tee /etc/systemd/system/containerd.service.d/storage.conf >/dev/null

sudo dockerd --validate --config-file=/etc/docker/daemon.json
sudo containerd config dump >/dev/null
sudo systemctl daemon-reload
sudo systemctl unmask containerd.service docker.socket docker.service
sudo systemctl enable --now containerd.service docker.service
sudo apt-mark hold docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod --append --groups docker pnadmin
```

Stop at the first error. Do not unmask/start the services if either configuration
validation command fails.

Execution progress:

- `docker.service`, `docker.socket` and `containerd.service` did not exist before
  package installation, as expected.
- systemd successfully created masks for all three units under
  `/etc/systemd/system`; package post-install scripts cannot start the runtimes
  against default OS-disk paths.
- Package installation and subsequent configuration remain pending.

Package installation result:

- Completed successfully with the five explicitly selected Docker packages and
  the required `libjansson4`, `libnftables1` and `nftables` dependencies.
- APT reported `0 upgraded`, `8 newly installed`, `0 removed`, `0 not
  upgraded`, 79.5 MB downloaded and approximately 348 MB installed.
- Recommended but unnecessary `docker-ce-rootless-extras` and `pigz` packages
  were not installed because `--no-install-recommends` was used.
- Package post-install scripts reported preset/start failures for the three
  masked units, as intended; containerd and Docker remained stopped.
- Storage configuration, validation and service startup remain pending.

Configuration execution note:

- The Docker systemd storage drop-in was created successfully.
- Creation of the containerd drop-in failed because the pasted redirection
  `>/dev/null` was split into `>/dev/` and a separate `null` command.
- The following `chmod` reported the missing containerd drop-in. No runtime was
  unmasked or started.
- Remediation uses `tee` without output redirection to avoid the same paste
  failure.
- The first containerd validation succeeded but warned that configuration
  version 2 was migrated in memory. Since the installed containerd 2.3.3 uses
  version 4 natively and this file contains only compatible global `root` and
  `state` settings, the final configuration changes only the header to version
  4 and is validated again before startup.
- The operator confirmed that containerd version 4 validation, Docker daemon
  validation and `systemctl daemon-reload` completed successfully. Services
  remain masked and stopped pending the controlled first start.

First-start commands proposed:

```zsh
sudo systemctl unmask containerd.service docker.socket docker.service
sudo systemctl daemon-reload
sudo systemctl enable --now containerd.service
sudo systemctl enable --now docker.service
systemctl is-active containerd.service docker.service
sudo docker info --format 'DockerRootDir={{.DockerRootDir}} Driver={{.Driver}} LoggingDriver={{.LoggingDriver}}'
findmnt -T /srv/polinetwork/applications/docker -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T /srv/polinetwork/applications/containerd -o TARGET,SOURCE,FSTYPE,OPTIONS
```

Expected result: both services are active, Docker reports the configured data
root and `local` logging driver, and both persistent runtime paths resolve to
the `/dev/sdc` ext4 mount.

First-start result:

- All three systemd masks were removed successfully.
- `containerd.service` and `docker.service` were enabled for boot and started.
- Both services reported `active`.
- Docker reported
  `DockerRootDir=/srv/polinetwork/applications/docker`, storage driver
  `overlayfs` and logging driver `local`.
- Both Docker and containerd persistent paths resolve to `/dev/sdc`, ext4,
  mounted with `rw,nosuid,nodev,relatime`.

Final installation checks proposed:

```zsh
sudo apt-mark hold docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod --append --groups docker pnadmin
apt-mark showhold
getent group docker
docker --version
sudo docker compose version
sudo docker buildx version
sudo docker run --rm --pull=always hello-world
sudo docker image inspect hello-world --format 'Architecture={{.Architecture}} OS={{.Os}}'
sudo docker system df
```

After these checks, reconnect over SSH before testing Docker without `sudo`, as
supplementary group membership is fixed when the login session starts.

Final installation check result:

- All five selected Docker packages were placed on APT hold.
- Group `docker` has GID 990 and includes `pnadmin`.
- Docker Engine: `29.7.2`, build `a7dcaa6`.
- Docker Compose: `v5.4.0`.
- Docker Buildx: `v0.36.1`, build
  `1d8dde89b8aba914e05e45366770736fea1fd690`.
- `hello-world:latest` pulled digest
  `sha256:7f4da0fc94bcece205a8c0b6f4d11c8196924654ffe5c4d1aa439b7f632048b2`
  and completed successfully.
- The pulled image was verified as `Architecture=arm64 OS=linux`.
- After the disposable container exited, Docker reported one small inactive
  image, zero containers, zero local volumes and zero build cache.

Fresh-login verification proposed:

```zsh
exit
```

After reconnecting over SSH:

```zsh
id
docker info --format 'DockerRootDir={{.DockerRootDir}} LoggingDriver={{.LoggingDriver}}'
docker ps
```

Expected result: `id` includes group `docker`, and both Docker commands succeed
without `sudo`.

Fresh-login verification result: completed successfully, confirmed by the
operator. `pnadmin` can access the Docker daemon without `sudo`.

Docker installation status: complete. Daemon-restart and full-host reboot
recovery tests remain pending.

### 2026-08-11 — Docker daemon restart test

Status: proposed, awaiting operator execution.

```zsh
systemctl is-enabled docker.service containerd.service
systemctl is-active docker.service containerd.service
sudo systemctl restart docker.service
systemctl is-active docker.service containerd.service
docker info --format 'DockerRootDir={{.DockerRootDir}} Driver={{.Driver}} LoggingDriver={{.LoggingDriver}}'
findmnt -T /srv/polinetwork/applications/docker -o TARGET,SOURCE,FSTYPE,OPTIONS
sudo journalctl -u docker.service --since '-2 minutes' --no-pager
```

Expected result: both units remain enabled and active, the restart completes
without errors, Docker retains its configured storage/logging settings, and its
data path still resolves to the `/dev/sdc` ext4 mount.

Observed result:

- Docker and containerd were enabled and active before the test and active
  afterward.
- Docker shut down cleanly and restarted in approximately one second.
- Configuration remained unchanged: Docker root on
  `/srv/polinetwork/applications/docker`, `overlayfs`, local logging, `/dev/sdc`
  ext4 underneath.
- The daemon reconnected to `/run/containerd/containerd.sock`, restored its
  state, initialized BuildKit and exposed `/run/docker.sock` successfully.
- Non-blocking startup messages recorded for future comparison:
  - optional fs-verity support is unavailable for the Docker plugin storage
    path on this host;
  - cleanup attempted to delete absent initial Docker nftables tables.
  Neither prevented network, storage or API initialization.

### 2026-08-11 — Full host reboot test

Status: proposed, awaiting operator execution.

Reboot command:

```zsh
sudo reboot
```

Post-reconnect verification:

```zsh
uptime -s
systemctl is-active prepare-data-disks.service containerd.service docker.service
findmnt -T /srv/polinetwork/state -o TARGET,SOURCE,FSTYPE,OPTIONS
findmnt -T /srv/polinetwork/applications -o TARGET,SOURCE,FSTYPE,OPTIONS
swapon --show
docker info --format 'DockerRootDir={{.DockerRootDir}} Driver={{.Driver}} LoggingDriver={{.LoggingDriver}}'
docker run --rm hello-world
systemd-analyze critical-chain docker.service
sudo journalctl -b -u prepare-data-disks.service -u containerd.service -u docker.service -p warning --no-pager
```

Expected result: both disks and swap are present, the three services are active,
Docker retains its configuration and runs the existing ARM64 test image without
pulling it again, and the critical chain shows disk preparation before the
container runtimes.

Observed result:

- Boot time reported as `2026-08-11 20:35:56`.
- `prepare-data-disks.service`, `containerd.service` and `docker.service` all
  reported `active`.
- Both ext4 filesystems remounted with `rw,nosuid,nodev,relatime`.
- Kernel device names changed across the reboot: `state` appeared as `/dev/sdc`
  and `applications` as `/dev/sdb`. Mountpoints remained correct because fstab
  uses stable filesystem labels rather than `/dev/sdX` names.
- Docker retained its configured root, `overlayfs` and local logging driver;
  the existing ARM64 `hello-world` test completed without `sudo`.
- The critical chain showed `prepare-data-disks.service` completing before
  containerd, followed by Docker initialization.
- The warning-only journal query produced no output.
- The unprivileged Zsh PATH did not contain `swapon`; swap verification remains
  pending and will use sudo explicitly.

Final swap verification proposed:

```zsh
sudo swapon --show
sudo sysctl vm.swappiness
```

Expected result: `/swapfile` is active at 4 GiB and `vm.swappiness = 10`.

Final swap verification result: completed successfully, confirmed by the
operator. The full reboot gate is complete.

## Platform network preparation

The versioned Wave 1 scaffold already exists in `polinetwork-cd/compose` with
projects for `edge`, `applications`, `data`, `control` and `observability`.
`pn-edge` and `pn-db` are declared as shared external networks in the existing
README/manifests. The migration architecture additionally specifies `pn-app`;
the repository scaffold must be aligned before platform deployment.

### 2026-08-11 — Docker network address preflight

Status: proposed, awaiting operator execution.

```zsh
ip -4 route
docker network ls
docker network inspect bridge --format 'bridge={{(index .IPAM.Config 0).Subnet}} gateway={{(index .IPAM.Config 0).Gateway}}'
```

Purpose: select explicit, reproducible CIDRs for `pn-edge`, `pn-app` and the
internal-only `pn-db` without overlapping the Azure VNet, host routes or
Docker's existing default bridge.

Observed result:

- Azure subnet and default route: `10.42.1.0/24`, host `10.42.1.4`, gateway
  `10.42.1.1`; the enclosing VNet is `10.42.0.0/16`.
- Docker default bridge: `172.17.0.0/16`, gateway `172.17.0.1`.
- Only Docker's default `bridge`, `host` and `none` networks exist.

Selected shared network CIDRs:

- `pn-edge`: `172.30.0.0/24`, normal bridge with outbound connectivity.
- `pn-app`: `172.30.1.0/24`, normal bridge with outbound connectivity.
- `pn-db`: `172.30.2.0/24`, internal bridge without external routing.

Creation commands proposed:

```zsh
docker network create --driver bridge --subnet 172.30.0.0/24 --gateway 172.30.0.1 --label com.polinetwork.role=edge pn-edge
docker network create --driver bridge --subnet 172.30.1.0/24 --gateway 172.30.1.1 --label com.polinetwork.role=applications pn-app
docker network create --driver bridge --internal --subnet 172.30.2.0/24 --gateway 172.30.2.1 --label com.polinetwork.role=database pn-db
docker network inspect pn-edge pn-app pn-db --format '{{.Name}} internal={{.Internal}} subnet={{(index .IPAM.Config 0).Subnet}} gateway={{(index .IPAM.Config 0).Gateway}} role={{index .Labels "com.polinetwork.role"}}'
```

Expected result: the selected non-overlapping subnets are present, with
`internal=false` for edge/app and `internal=true` only for the database network.

Observed result: completed successfully with the exact selected subnets and
internal flags.

## Compose source checkout

Migration-plan constraints for GitHub integration:

- The migration plans remain authoritative for platform and GitHub integration
  decisions; this runbook records their execution and must not silently replace
  them with an ad-hoc workflow.
- A manual public HTTPS clone is allowed only to bootstrap and validate the Wave
  1 laboratory scaffold.
- Steady-state deployments must be Git-backed and managed through Komodo, with
  an auditable commit history and service-scoped update/rollback evidence.
- Private GHCR pulls must use a read-only, minimally scoped machine credential;
  never copy a personal GitHub SSH key or personal token onto the VM.
- Delivery must use an authenticated GitHub webhook with replay protection or
  controlled polling, according to the final reviewed Komodo configuration.
- Production platform images must use reviewed strict versions; application
  rollback evidence must record the prior Git commit and resolved image digest.
- Compose files use explicit version tags rather than embedded digest pins. The
  resolved digests are recorded as deployment evidence and for rollback, not in
  the `image:` reference itself.
- The Wave 1 migration branch is laboratory input, not an authorization to
  deploy unmerged configuration to production.

- GitHub repository: `https://github.com/PoliNetworkOrg/polinetwork-cd`.
- Visibility: public; no GitHub credential is required for a read-only HTTPS
  clone.
- Default branch: `main`.
- Current Wave 1 source branch: `migration/compose-wave1`.
- Expected initial Wave 1 commit: `6616eef`.

Checkout preflight proposed:

```zsh
ls -ld /srv/polinetwork/compose
find /srv/polinetwork/compose -mindepth 1 -maxdepth 1 -printf '%f\n'
```

Expected result: the root-owned directory exists and contains no entries. Only
after confirming it is empty will ownership be assigned to `pnadmin` and the
public Wave 1 branch cloned into it.

Checkout preflight result: directory exists and is empty, confirmed by the
operator.

For tighter ownership, `/srv/polinetwork/compose` remains root-owned. The
operator-owned laboratory checkout will live in the dedicated child directory
`/srv/polinetwork/compose/polinetwork-cd`.

Clone commands proposed:

```zsh
sudo install -d -m 0755 -o pnadmin -g pnadmin /srv/polinetwork/compose/polinetwork-cd
git clone --single-branch --branch migration/compose-wave1 https://github.com/PoliNetworkOrg/polinetwork-cd.git /srv/polinetwork/compose/polinetwork-cd
git -C /srv/polinetwork/compose/polinetwork-cd status --short --branch
git -C /srv/polinetwork/compose/polinetwork-cd rev-parse HEAD
find /srv/polinetwork/compose/polinetwork-cd/compose -maxdepth 2 -type f -print | sort
```

Expected result: clean branch `migration/compose-wave1`, commit `6616eef...`,
and the versioned Wave 1 project files. No Compose project is started by this
step.

Observed result:

- Clean branch `migration/compose-wave1` tracking its matching remote branch.
- Exact commit: `6616eef898b0c8bab87272cbb7a020ccb4089cc4`.
- Expected files are present for the root README and the `applications`,
  `control`, `data`, `edge` and `observability` projects.

### Wave 1 static and ARM64 validation

Status: proposed, awaiting operator execution. This step does not pull images or
start containers.

```zsh
PN_COMPOSE_ROOT=/srv/polinetwork/compose/polinetwork-cd/compose
docker compose -f "$PN_COMPOSE_ROOT/edge/compose.yaml" config --quiet
docker compose -f "$PN_COMPOSE_ROOT/applications/compose.yaml" --profile lab config --quiet
docker buildx imagetools inspect ghcr.io/tecnativa/docker-socket-proxy:0.4.2
docker buildx imagetools inspect traefik:v3.7.1
docker buildx imagetools inspect nginx:1.29.1-alpine
```

Gate: both Compose models must validate and every image manifest must include
`linux/arm64`. The repository's `pn-app` declarations must also be aligned with
the migration plan before the scaffold is promoted beyond the initial lab.

Observed image validation failure:

- `ghcr.io/tecnativa/docker-socket-proxy:0.4.2` returned `not found`.
- The official release tag includes the `v` prefix: `v0.4.2`.
- No fallback to `latest` is allowed. The corrected GHCR tag must expose a
  `linux/arm64` manifest before the Git-backed Compose source is changed.

Corrected manifest check proposed:

```zsh
docker buildx imagetools inspect ghcr.io/tecnativa/docker-socket-proxy:v0.4.2
```

The VM checkout must not be edited ad hoc; after validation, the correction
will be made in the source branch and delivered through Git.

Corrected manifest result:

- `ghcr.io/tecnativa/docker-socket-proxy:v0.4.2` exists.
- Multi-platform OCI index digest:
  `sha256:1f3a6f303320723d199d2316a3e82b2e2685d86c275d5e3deeaf182573b47476`.
- Native `linux/arm64` manifest digest:
  `sha256:864554ad193d7bfa24275dc5a39d17ed9ed95af3549223877bf23ebe33f179f3`.
- The registry inspection was accidentally repeated; both calls were read-only
  and produced the same result.

Remaining filtered manifest checks proposed:

```zsh
docker buildx imagetools inspect traefik:v3.7.1 | grep -E '^(Name:|Digest:|  Platform:)'
docker buildx imagetools inspect nginx:1.29.1-alpine | grep -E '^(Name:|Digest:|  Platform:)'
```

Remaining manifest results:

- Traefik `v3.7.1` index digest:
  `sha256:6b9cbca6fac42ab0075f5437d8dc1685cfd188626d8d515839ea94f8b6271c42`;
  includes `linux/arm64/v8`.
- Nginx `1.29.1-alpine` index digest:
  `sha256:42a516af16b852e33b7682d5ef8acbd5d13fe08fecadc7ed98605ba5e3b26ab8`;
  includes `linux/arm64/v8`.
- Compose references retain explicit version tags; resolved digests are recorded
  as deployment/rollback evidence rather than embedded into `image:` values.

Source corrections delivered through Git:

- `7def926da4f27b06e9995db914f810d983a1df97`: remove the local-only
  post-migration tracker from `polinetwork-cd`.
- `54d284506757f8da00908deab7d800914370d256`: correct socket proxy tag to
  `v0.4.2`, add `pn-app` to the canaries and document all reviewed network
  CIDRs.
- Both commits contain SSH signatures produced through the configured
  1Password signing agent.
- Branch `migration/compose-wave1` pushed to GitHub.
- Pull request opened: `https://github.com/PoliNetworkOrg/polinetwork-cd/pull/10`.
- Initial PR state: open and mergeable; CodeRabbit pending. No Compose service
  has been deployed.

PR source validation proposed on the VM:

```zsh
git -C /srv/polinetwork/compose/polinetwork-cd pull --ff-only
git -C /srv/polinetwork/compose/polinetwork-cd rev-parse HEAD
PN_COMPOSE_ROOT=/srv/polinetwork/compose/polinetwork-cd/compose
docker compose -f "$PN_COMPOSE_ROOT/edge/compose.yaml" config --quiet
docker compose -f "$PN_COMPOSE_ROOT/applications/compose.yaml" --profile lab config --quiet
```

Expected result: fast-forward to `54d284506757f8da00908deab7d800914370d256`
and both Compose configurations validate without output.

PR review follow-up:

- CodeRabbit's MariaDB finding was withdrawn after the owner clarified that
  10.9.4 is a non-production migration placeholder.
- The request to embed image digests was intentionally not applied: reviewed
  version tags remain in Compose, while resolved digests remain deployment and
  rollback evidence.
- The network semantics finding was fixed by signed commit
  `18684cb34961d7be8c69fa15996dca56922166b1`: Compose definitions control
  membership, labels are metadata, and `pn-db` disables external routing rather
  than lacking a gateway.
- Replies documenting both the fix and the digest decision were posted to the
  PR review threads.
- GitHub reports the check as passing, although the post-fix CodeRabbit rerun was
  rate-limited.
- Merge remains blocked on VM-side Compose validation of the latest commit.

Updated VM validation target:

```zsh
git -C /srv/polinetwork/compose/polinetwork-cd pull --ff-only
git -C /srv/polinetwork/compose/polinetwork-cd rev-parse HEAD
PN_COMPOSE_ROOT=/srv/polinetwork/compose/polinetwork-cd/compose
docker compose -f "$PN_COMPOSE_ROOT/edge/compose.yaml" config --quiet
docker compose -f "$PN_COMPOSE_ROOT/applications/compose.yaml" --profile lab config --quiet
```

Expected HEAD: `18684cb34961d7be8c69fa15996dca56922166b1`.

Latest VM validation result: completed successfully, confirmed by the operator.
The checkout reached the expected HEAD and both edge and lab applications
Compose models passed `config --quiet` without errors. PR #10 is eligible for
final merge checks.

Merge result:

- PR `PoliNetworkOrg/polinetwork-cd#10` passed its required check and was clean
  and mergeable at the validated head.
- Merged normally into `main` on 2026-08-11 at 21:04:04 UTC.
- Merge commit: `702f49d47a034619f93364d31648600d2a49b537`.
- The remote migration branch was intentionally retained until the first
  post-merge VM validation and lab deployment complete.

VM checkout transition to `main` proposed:

```zsh
git -C /srv/polinetwork/compose/polinetwork-cd remote set-branches --add origin main
git -C /srv/polinetwork/compose/polinetwork-cd fetch origin
git -C /srv/polinetwork/compose/polinetwork-cd switch --track origin/main
git -C /srv/polinetwork/compose/polinetwork-cd rev-parse HEAD
git -C /srv/polinetwork/compose/polinetwork-cd status --short --branch
```

Expected result: local branch `main` tracking `origin/main`, clean status, at
merge commit `702f49d47a034619f93364d31648600d2a49b537`.

VM checkout transition result: completed successfully, confirmed by the
operator.

### Wave 1 post-merge image pull

Status: proposed, awaiting operator execution. This step validates the merged
models and pulls images but does not create or start containers.

```zsh
PN_COMPOSE_ROOT=/srv/polinetwork/compose/polinetwork-cd/compose
docker compose -f "$PN_COMPOSE_ROOT/edge/compose.yaml" config --quiet
docker compose -f "$PN_COMPOSE_ROOT/applications/compose.yaml" --profile lab config --quiet
docker compose -f "$PN_COMPOSE_ROOT/edge/compose.yaml" pull
docker compose -f "$PN_COMPOSE_ROOT/applications/compose.yaml" --profile lab pull
docker image inspect ghcr.io/tecnativa/docker-socket-proxy:v0.4.2 --format 'socket-proxy arch={{.Architecture}} digests={{json .RepoDigests}}'
docker image inspect traefik:v3.7.1 --format 'traefik arch={{.Architecture}} digests={{json .RepoDigests}}'
docker image inspect nginx:1.29.1-alpine --format 'nginx arch={{.Architecture}} digests={{json .RepoDigests}}'
```

Gate: all three local images must be ARM64 and resolve to the reviewed index
digests before the edge project is started.

Execution policy adjustment requested by the owner:

- This is a non-production laboratory phase with AKS unchanged and no host
  application ports.
- Combine reversible pull/deploy/verification steps instead of pausing after
  every read-only check.
- Keep explicit pauses only for secrets, public routing, stateful data,
  destructive actions, production cutover and unresolved security failures.

Accelerated Wave 1 deployment proposed:

```zsh
PN_COMPOSE_ROOT=/srv/polinetwork/compose/polinetwork-cd/compose
docker compose -f "$PN_COMPOSE_ROOT/edge/compose.yaml" up -d --pull always
docker compose -f "$PN_COMPOSE_ROOT/applications/compose.yaml" --profile lab up -d --pull always
docker compose -f "$PN_COMPOSE_ROOT/edge/compose.yaml" ps
docker compose -f "$PN_COMPOSE_ROOT/applications/compose.yaml" --profile lab ps
docker run --rm --network pn-edge nginx:1.29.1-alpine wget -qO- --header='Host: wave1-a.invalid' http://traefik
docker run --rm --network pn-edge nginx:1.29.1-alpine wget -qO- --header='Host: wave1-b.invalid' http://traefik
```

Minimum gate: all four services are running/healthy and both internal Traefik
routes return the nginx page. No public route is created.

Observed result:

- `edge-docker-socket-proxy-1` running with only container port `2375/tcp`
  exposed internally.
- `edge-traefik-1` running and healthy with only container port `80/tcp`
  exposed internally.
- Both nginx canaries running and healthy with only container port `80/tcp`
  exposed internally.
- No host/IP port binding appeared in Compose status.
- Requests through Traefik on `pn-edge` with hosts `wave1-a.invalid` and
  `wave1-b.invalid` both returned the expected nginx page.

Wave 1 edge and applications lab deployment gate: passed.

Next macro-step: add the pinned ARM64 Komodo control-plane definition to the
Git-backed Compose source, then use it for the required service-scoped update
and rollback proof.

Execution note: the first applications validation attempt did not run because
the pasted absolute path was split after `applications/`. Compose displayed its
usage and Zsh reported `compose.yaml` as an unknown command. The replacement
above uses `PN_COMPOSE_ROOT` to keep paths short and paste-safe.

Planned storage configuration for the next step:

- Docker daemon data: `/srv/polinetwork/applications/docker`.
- containerd content and snapshots:
  `/srv/polinetwork/applications/containerd`.
- Runtime-only containerd state remains under `/run/containerd`.

### Komodo Wave 1 control plane

- PR `PoliNetworkOrg/polinetwork-cd#11` merged into `main` as
  `be65e002103c008d8c9fd1119d9eb1d6e3b82610`.
- Komodo Core and Periphery are pinned to `2.2.0`; MongoDB is pinned to
  `8.0.28`.
- Runtime secrets are stored only in
  `/srv/polinetwork/state/komodo/compose.env` with restrictive permissions.
- MongoDB data, Komodo keys and backups are bind-mounted below
  `/srv/polinetwork/state/komodo`.
- Core is reachable only through `pn-edge`; MongoDB and Periphery use the
  internal `control-api` network. No host port is published.

Observed initial deployment result:

- `control-mongo-1` healthy on its container-only `27017/tcp` port.
- `control-core-1` running on its container-only `9120/tcp` port.
- `control-periphery-1` running on its container-only `8120/tcp` port.

Gate still pending: verify Core health through Traefik, confirm Periphery has
connected to Core, and confirm that the communication keys were generated.

Observed functional validation:

- The Komodo UI returned HTML through the internal Traefik route.
- Core started successfully, created the initial `admin` user and listened on
  container port `9120`.
- Periphery generated its key pair and connected to Core as server `vm01`.
- Core and Periphery generated `core.key`, `core.pub`, `periphery.key` and
  `periphery.pub` in the persistent keys directory.
- The initial Periphery connection refusal was a startup race; the following
  retry authenticated successfully. Failure to discover a public IP is
  non-blocking because the agent connects outbound over the internal network.

Komodo Wave 1 control-plane connectivity gate: passed.

### Dedicated VM Cloudflare Tunnel and Komodo Access

- PR `PoliNetworkOrg/polinetwork-cd#12` added pinned
  `cloudflare/cloudflared:2026.7.2` to the edge project and changed the Komodo
  router to `komodo.polinetwork.org`.
- The VM uses a dedicated Cloudflare Tunnel token. The existing AKS tunnel
  token was deliberately not reused, preventing connectors with different
  local routes from sharing production traffic.
- The token exists only in
  `/srv/polinetwork/state/cloudflare/compose.env`; it is not committed to Git.
- The tunnel has one wildcard public-hostname route:
  `*.polinetwork.org` to `http://traefik:80`.
- Cloudflare DNS has a proxied wildcard CNAME targeting the dedicated VM
  tunnel. Existing explicit DNS records retain precedence over the wildcard.
- Docker Compose labels remain the per-service routing authority after DNS and
  Tunnel deliver the original hostname to Traefik.
- Traefik continues to use `exposedByDefault=false`; an unmapped wildcard
  hostname returned HTTP `404` through Cloudflare, proving fail-closed routing.
- `komodo.polinetwork.org` returned HTTP `302` to the PoliNetwork Cloudflare
  Access login endpoint. Its Access application requires the approved
  tech-admin authentication policy; no VM host port was opened.

Cloudflare wildcard routing and Komodo protected-access gate: passed.

Next macro-step: import the existing `applications` Compose project into
Komodo as a public GitHub-backed Stack, then configure an HMAC-authenticated
GitHub webhook and prove service-scoped update and rollback behavior.

### Komodo Git-backed applications Stack

- The existing `applications` project was registered as a Komodo Stack backed
  by public repository `PoliNetworkOrg/polinetwork-cd`, branch `main`, Compose
  file `compose/applications/compose.yaml` and project name `applications`.
- The lab profile is enabled with `COMPOSE_PROFILES=lab`; no Git credential is
  required for this public repository.
- GitHub webhook requests reach Komodo through the dedicated
  `/listener/github/*` Cloudflare Access bypass. Komodo still authenticates
  every request with the configured GitHub HMAC secret; the remaining UI stays
  behind the tech-admin Access/MFA policy.
- The initial GitHub `ping` delivery authenticated but was not a push payload
  and therefore lacked `ref`; this was non-blocking.
- The first real deployment failed before cloning because Periphery was joined
  only to the internal `control-api` network. This also explained its earlier
  Docker Hub DNS warning: Docker intentionally blocks external egress from an
  internal network.
- Commit `1cc1a5c` added a dedicated non-shared `control-egress` bridge to
  Periphery. It retains the internal Core connection without joining an
  application network or publishing a host port.
- After recreating Periphery with the new network, Git clone and Komodo Stack
  deployment succeeded. The failed run directory was not created manually;
  Komodo now manages it as intended.

Git-backed clone and deployment gate: passed.

Selective update and rollback evidence:

- Baseline before Komodo takeover:
  - canary A ID `4eec7c549ba31e8da33c0e9c3623618d8c26252cba9490a3850fcc7f9af372ca`;
  - canary B ID `e565c4f98a058ac456cb8b28114ad35ddb01f341bc2f123a74f851073878ac06`.
- Commit `5b4b40a` added only the canary A revision label. The first successful
  Komodo deployment recreated both services because it also took ownership of
  a project originally launched from a different working directory. That
  transition was treated as adoption evidence, not selective-update evidence.
- Stable Komodo-managed baseline after takeover:
  - canary A ID `31fae98138591267b088a1e78a00b60a676dd57ef4e82d6dd77fa8a135214587`;
  - canary B ID `921010914df01d3b5f1349c760eed07b1ed838788ad69fd749c8dc30bb888902`,
    started `2026-08-11T22:14:17.247914809Z`.
- The GitHub webhook was corrected, then rollback commit `fa29e57` was
  delivered from `main`.
- Rollback removed only the canary A revision label:
  - canary A changed to ID
    `87dd2b60a49b8c52a5a7fc8bbf9cfac2494376d2c24708939a7449adabc2634f`;
  - canary B retained both ID
    `921010914df01d3b5f1349c760eed07b1ed838788ad69fd749c8dc30bb888902`
    and its exact start timestamp;
  - both services were healthy after deployment.

GitHub webhook, service-scoped Compose update and rollback gate: passed.

### OpenBao source readiness and first VM deployment

Status: source ready; VM deployment pending operator execution over SSH.

The Git-backed control project first added OpenBao at commit `d6c6a2b`; the
deployment-ready correction is commit
`c826f95920b0d1d72ba41fed1f9683dc585e063f`. This records source readiness only:
OpenBao has not yet been created, started or initialized on `vm01`.

Safety boundary before deployment:

- Create a Cloudflare Access application for `openbao.polinetwork.org` with the
  same approved tech-admin/MFA boundary used for Komodo.
- Verify from a client outside the VM that the hostname redirects to Access.
  Do not expose an uninitialized OpenBao API through the wildcard tunnel without
  this policy.
- The first SSH step starts OpenBao sealed and uninitialized. It deliberately
  does not run `bao operator init`, handle unseal shares or create a root token.

External Access check proposed before the SSH deployment:

```zsh
curl -sS -o /dev/null -D - --max-time 15 https://openbao.polinetwork.org/
```

Expected result: an HTTP redirect to the PoliNetwork Cloudflare Access login.
A direct origin response, an OpenBao response or an unprotected Cloudflare
Tunnel error does not pass this gate.

Observed result: the operator confirmed that the external request is
intercepted by the configured Cloudflare Access application. The pre-deployment
public-route protection gate passed; no OpenBao container was running during
this check.

First deployment commands proposed for the existing SSH session on `vm01`:

```zsh
git -C /srv/polinetwork/compose/polinetwork-cd pull --ff-only
git -C /srv/polinetwork/compose/polinetwork-cd rev-parse HEAD
git -C /srv/polinetwork/compose/polinetwork-cd status --short --branch

PN_CONTROL=/srv/polinetwork/compose/polinetwork-cd/compose/control
PN_KOMODO_ENV=/srv/polinetwork/state/komodo/compose.env
docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" config --quiet
docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" pull openbao
docker image inspect quay.io/openbao/openbao:2.5.4 --format 'arch={{.Architecture}} user={{.Config.User}} digests={{json .RepoDigests}}'
findmnt --target /srv/polinetwork/state
df -h /srv/polinetwork/state
sudo install -d -o pnadmin -g pnadmin -m 0700 /srv/polinetwork/state/openbao
sudo install -d -o pnadmin -g pnadmin -m 0700 /srv/polinetwork/state/openbao/raft
sudo install -d -o pnadmin -g pnadmin -m 0700 /srv/polinetwork/state/openbao/backups

docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" up -d --no-deps --pull never --wait --wait-timeout 120 openbao
docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" ps openbao
docker inspect control-openbao-1 --format 'health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} ports={{json .NetworkSettings.Ports}} networks={{json .NetworkSettings.Networks}}'
stat -c '%u:%g %a %n' /srv/polinetwork/state/openbao /srv/polinetwork/state/openbao/raft /srv/polinetwork/state/openbao/backups
docker run --rm --entrypoint id quay.io/openbao/openbao:2.5.4 openbao
docker top control-openbao-1 -eo pid,user,group,comm,args
docker exec control-openbao-1 bao status
docker logs --tail 80 control-openbao-1
```

Environment-file clarification:

- OpenBao has no bootstrap secret or `OPENBAO_*` variable in
  `/srv/polinetwork/state/komodo/compose.env`.
- The existing Komodo environment file is supplied because Compose interpolates
  and validates the complete `control` model, whose MongoDB/Komodo services
  declare required variables, even when only the `openbao` service is targeted.
- Shamir unseal shares and the initial root token are generated later by the
  explicitly separated `bao operator init` ceremony. They must never be added
  to this environment file.

Expected result:

- checkout is clean at
  `c826f95920b0d1d72ba41fed1f9683dc585e063f` or an explicitly reviewed later
  `main` commit;
- the local image is native `arm64` and its registry digest is recorded;
- persistent state is on `/srv/polinetwork/state`; after startup its ownership
  matches the numeric `openbao` identity printed inside the container;
- `control-openbao-1` is running and healthy with no host port binding;
- `bao status` reports `Initialized: false` and `Sealed: true`. Exit status 2 is
  expected for this state and is not a deployment failure;
- logs contain no permission, Raft or listener startup errors.

After the SSH checks, repeat the external Access request. The response must
still be the Access redirect; do not initialize OpenBao until both the container
checks and the protected-route check pass.

Execution correction recorded before directory creation:

- The first identity probe used `--entrypoint id` without naming the image's
  `openbao` account and therefore returned the entrypoint process identity
  `uid=0 gid=0`.
- Overriding the entrypoint bypasses its normal startup behavior; `0:0` was not
  accepted as the persistent-directory owner.
- A corrected probe can query `id ... openbao` explicitly, but the final
  implementation does not require the operator to pre-apply that numeric ID.
- The operator proposed owning state as `pnadmin` and relying on the container
  to remap its UID/GID. Review of the pinned 2.5.4 entrypoint showed that it
  drops from root to `openbao` but only attempts ownership repair for
  `/openbao/config`, `/openbao/logs` and `/openbao/file`; the configured Raft
  and backup mounts are `/openbao/data` and `/openbao/backups`.
- Bind mounts preserve numeric ownership and this Compose definition does not
  use user-namespace remapping or PUID/PGID variables. The source was therefore
  aligned with the image-supported persistent path `/openbao/file`, which the
  2.5.4 entrypoint explicitly ownership-repairs before dropping privileges.
- The original `cap_drop: ALL` removed capabilities required by that entrypoint.
  The correction retains only `CHOWN`, `DAC_OVERRIDE`, `SETGID` and `SETUID`:
  state starts owned by `pnadmin`, the entrypoint changes it to `openbao`, and
  the server then runs as `openbao`. Do not deploy commit `d6c6a2b`.
- The corrected source was committed with an SSH signature as `c826f95` and
  pushed to `main`. It also uses `command: [server]` to override the image's
  development-mode default and relies on the entrypoint's default
  `/openbao/config` discovery without a duplicate `-config` argument.

First deployment observation:

- `control-openbao-1` was created without a host port binding and the image
  entrypoint changed `/srv/polinetwork/state/openbao` to numeric ownership
  `100:1000`, matching `uid=100(openbao) gid=1000(openbao)` in the pinned image.
- Non-root `pnadmin` then received `Permission denied` while traversing the
  intentionally mode-`0700` state directory; future host-side inspections use
  `sudo stat` and this is not treated as a state failure.
- The OpenBao server did not start: every attempt reported that
  `/openbao/config/openbao.hcl` was permission denied. No initialization was
  performed and no useful Raft state was written.
- Deployment is paused in the restart loop before changing permissions. The
  next action is to stop only OpenBao and compare the host file metadata,
  container mount metadata and a one-shot read using the pinned image.

Permission diagnosis result:

- The OpenBao restart loop was stopped cleanly.
- The VM checkout had `compose/control/openbao` at mode `0700` and
  `openbao.hcl` at mode `0600`, both owned by `pnadmin:pnadmin`.
- The bind mount itself was correct and read-only. A one-shot container running
  as `uid=100(openbao) gid=1000(openbao)` saw the mounted file but received
  `Permission denied`, reproducing the server failure independently of Compose.
- The HCL file contains configuration only and no secret values. Its Git index
  mode is regular non-executable `100644`; Git does not preserve arbitrary
  owner/group/read-mode metadata beyond the executable bit.
- Remediation is limited to mode `0755` on the configuration directory and
  `0644` on `openbao.hcl`. Raft and backup state remain `0700` and owned by the
  container's numeric OpenBao identity.

Permission remediation and retry proposed:

```zsh
PN_CONTROL=/srv/polinetwork/compose/polinetwork-cd/compose/control
PN_KOMODO_ENV=/srv/polinetwork/state/komodo/compose.env
chmod 0755 "$PN_CONTROL/openbao"
chmod 0644 "$PN_CONTROL/openbao/openbao.hcl"
stat -c '%u:%g %a %n' "$PN_CONTROL/openbao" "$PN_CONTROL/openbao/openbao.hcl"
git -C /srv/polinetwork/compose/polinetwork-cd status --short

docker run --rm \
  --user openbao \
  --entrypoint sh \
  --volume "$PN_CONTROL/openbao/openbao.hcl:/openbao/config/openbao.hcl:ro" \
  quay.io/openbao/openbao:2.5.4 \
  -c 'head -n 3 /openbao/config/openbao.hcl >/dev/null && echo config-readable'

docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" up -d --no-deps --pull never openbao
docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" ps openbao
docker top control-openbao-1 -eo pid,user,group,comm,args
docker exec control-openbao-1 bao status
docker logs --tail 80 control-openbao-1
```

Expected result: the one-shot test prints `config-readable`, Git remains clean,
the server process runs as numeric UID/GID `100:1000`, and `bao status` reports
uninitialized and sealed without configuration permission errors.

Remediation retry result:

- After applying `0755` to the checkout directory and `0644` to the HCL file,
  the one-shot read passed and OpenBao became healthy.
- `bao status` confirmed OpenBao 2.5.4, Raft storage, `Initialized: false` and
  `Sealed: true`.
- The repeated permission errors shown by `docker logs` preceded the successful
  start and remained in the same container's historical log stream. They were
  not new failures after the permission change.
- The server process ran as numeric `100:1000`; `docker top` rendered those IDs
  using the host's unrelated `dhcpcd` and `pnadmin` account names.

The owner requested a source-level fix followed by removal and clean
installation of all OpenBao runtime artifacts on the VM. Commit
`6779275b1d974ad8039bb5905d7eefc663342507` replaces the checkout bind mount
with the image-supported `BAO_LOCAL_CONFIG` mechanism, removes the redundant
HCL file, is SSH-signed and has been pushed to `main`.

Clean reinstall commands proposed:

```zsh
PN_REPO=/srv/polinetwork/compose/polinetwork-cd
PN_CONTROL="$PN_REPO/compose/control"
PN_KOMODO_ENV=/srv/polinetwork/state/komodo/compose.env

git -C "$PN_REPO" pull --ff-only
git -C "$PN_REPO" rev-parse HEAD
git -C "$PN_REPO" status --short --branch
docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" config --quiet

docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" rm --stop --force -v openbao
docker ps -a --filter name=control-openbao --format '{{.ID}} {{.Names}} {{.Status}}'

sudo rm -rf -- /srv/polinetwork/state/openbao
sudo install -d -o pnadmin -g pnadmin -m 0700 /srv/polinetwork/state/openbao
sudo install -d -o pnadmin -g pnadmin -m 0700 /srv/polinetwork/state/openbao/raft
sudo install -d -o pnadmin -g pnadmin -m 0700 /srv/polinetwork/state/openbao/backups

docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" pull openbao
docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" up -d --no-deps --pull never --wait --wait-timeout 120 openbao
docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" ps openbao
docker inspect control-openbao-1 --format '{{range .Mounts}}{{println .Source "->" .Destination "rw=" .RW}}{{end}}'
docker exec control-openbao-1 sh -c 'test -r /openbao/config/local.json && stat -c "%u:%g %a %n" /openbao/config/local.json'
sudo stat -c '%u:%g %a %n' /srv/polinetwork/state/openbao /srv/polinetwork/state/openbao/raft /srv/polinetwork/state/openbao/backups
docker top control-openbao-1 -eo pid,user,group,comm,args
docker exec control-openbao-1 bao status
docker logs --since 5m control-openbao-1
```

Deletion scope and recovery note:

- `compose rm ... -v openbao` removes only the stopped OpenBao container and its
  anonymous `/openbao/logs` volume.
- `/srv/polinetwork/state/openbao` is then deleted explicitly. The observed
  instance is uninitialized, so it contains no accepted secrets, unseal
  material or useful Raft backup. This deletion is not recoverable from the VM;
  no other control-plane state is in scope.
- The pinned image may remain in Docker's content store; `pull openbao`
  revalidates it against the registry. Removing cached immutable layers is not
  required for a clean state/container installation.

Clean-install gate: the new container has no checkout configuration mount,
`local.json` is readable without printing its contents, only the expected state
and anonymous log mounts exist, current logs contain no permission errors, and
status is uninitialized/sealed. Internal listener TLS remains an explicit gate
before any application workload is allowed to depend on OpenBao.

Clean reinstall observed result: passed.

- The VM checkout fast-forwarded cleanly to signed commit
  `6779275b1d974ad8039bb5905d7eefc663342507`.
- The previous OpenBao container and anonymous log volume were removed, the
  uninitialized state tree was deleted, and a new state tree was created.
- The replacement container became healthy using a freshly pulled OpenBao
  2.5.4 image. It exposes only container port `8200/tcp`; no host binding exists.
- The only mounts are `/srv/polinetwork/state/openbao` at `/openbao/file` and a
  new anonymous volume at `/openbao/logs`. The checkout HCL bind mount is gone.
- `/openbao/config/local.json` exists as `0:0` mode `0644` and is readable by
  the server after its privilege drop. Its contents were not printed.
- State, Raft and backup directories are all `100:1000` mode `0700`.
- The OpenBao server process runs as numeric `100:1000`; host-side process tools
  display the unrelated local names `dhcpcd:pnadmin` for those numeric IDs.
- Current logs contain a clean server start followed only by the expected
  pre-initialization messages. Status confirms OpenBao 2.5.4, Shamir seal, Raft,
  `Initialized: false` and `Sealed: true`.

OpenBao clean installation gate: passed. Initialization is intentionally
paused until encrypted custody is selected for five Shamir shares, the
three-share threshold and the initial root token. No initialization command has
been proposed or run, and no sensitive value has entered this register.

### OpenBao lab custody preparation

- The owner confirmed that no existing PGP/Keybase multi-custodian setup is
  available and requested a simpler lab bootstrap using the local 1Password
  CLI.
- A Secure Note named `OpenBao vm01 - LAB bootstrap` was created in the
  `PoliNetwork` vault with empty concealed fields `Unseal Key` and
  `Initial Root Token`. Item ID:
  `yoszyppyfhck57iwxuf2thmm6q`.
- No OpenBao secret exists yet and no existing 1Password item was read.
- The local SSH configuration contains the existing `pn-vm01` alias and uses
  the 1Password SSH agent. Direct VM execution remains paused pending explicit
  authorization to change the runbook's original no-direct-SSH boundary.
- Proposed lab-only ceremony after authorization: initialize with one Shamir
  share and threshold one, capture JSON without echoing it, write both values
  directly into the prepared 1Password item, verify the saved fields, remove
  transient plaintext only after verification, and unseal by piping the saved
  key directly from `op` to the VM. Before production dependency, rekey to the
  required multi-custodian threshold and complete the recovery drill.

Owner decision superseding the lab proposal:

- Direct Codex SSH access was declined; the operator will continue executing
  all VM commands.
- The one-share/threshold-one lab initialization was cancelled before it ran.
  The prepared 1Password note remains empty and contains no OpenBao material.
- The owner requested proceeding directly toward a production setup. OpenBao
  remains uninitialized and sealed while two production prerequisites are
  completed: internal TLS and distributed recovery custody.
- The target Shamir ceremony remains five shares with threshold three. Shares
  must be assigned to distinct custodians or genuinely independent offline
  locations; storing all five in the same 1Password account is not accepted as
  distributed custody.

Pre-initialization exposure pause proposed:

```zsh
PN_CONTROL=/srv/polinetwork/compose/polinetwork-cd/compose/control
PN_KOMODO_ENV=/srv/polinetwork/state/komodo/compose.env
docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" stop openbao
```

Reason: Cloudflare Access protects the public route, but the uninitialized API
is also reachable directly by containers sharing `pn-edge`. Stop the empty
instance until the seal and initialization decisions are complete. Awaiting
operator confirmation; do not infer that it is stopped.

Production seal clarification:

- With the current Shamir seal, a restart discards the in-memory unseal key and
  OpenBao remains sealed until the threshold number of shares is submitted
  again. Normal operation requires no repeated share entry until a restart,
  explicit seal or unrecoverable storage error.
- Auto Unseal moves startup decryption to a KMS/HSM. Azure Key Vault with the
  VM's managed identity is a candidate, but OpenBao 2.5.4 requires the external
  Azure KMS provider plugin and creates a strict recovery dependency on the Key
  Vault key. This must be built, pinned, permissioned and restore-tested before
  initialization; it is not enabled implicitly.
- Internal TLS is defense in depth rather than a universal Docker requirement.
  The current shared `pn-edge` design carries secret-management traffic in
  plaintext between Traefik and OpenBao, so removing the TLS gate requires an
  explicit threat-model acceptance or stronger network separation. External
  Cloudflare HTTPS/Access does not encrypt that final internal hop.

### OpenBao production seal and internal TLS decision

This section supersedes the earlier candidate design and its statement that
OpenBao 2.5.4 needs an external Azure KMS plugin.

- The owner selected internal TLS between Traefik and OpenBao and Azure Key
  Vault Auto Unseal. OpenBao remains uninitialized; the earlier lab ceremony
  and recurring manual Shamir unseal workflow remain cancelled.
- OpenBao 2.5.4 includes the Azure Key Vault seal integration. No external seal
  plugin is required for the pinned image version.
- Terraform branch `migration/openbao-auto-unseal`, signed commit `518cefc`, and
  PR `PoliNetworkOrg/terraform#77` provision a dedicated user-assigned managed
  identity, attach it to `vm01`, grant only `Get`, `WrapKey`, and `UnwrapKey`,
  and create the RSA-3072 `openbao-unseal` key in `kv-polinetwork` with annual
  automatic rotation.
- Compose branch `migration/openbao-tls-auto-unseal`, signed commit `39a9ab0`,
  and PR `PoliNetworkOrg/polinetwork-cd#13` configure the built-in Azure seal,
  a TLS 1.2-or-newer OpenBao listener, CA validation by Traefik with server name
  `openbao`, and no host port publication.
- The Key Vault key is a strict recovery dependency. Its purge protection,
  managed-identity access and versioned rotation are retained. Recovery keys
  will still be generated during initialization for privileged recovery
  operations, but routine VM/container restarts will not require an operator
  to submit keys.
- The accepted threat model does not justify Azure Key Vault Premium/HSM or a
  fixed expiration date on the initial key version in addition to the annual
  rotation policy. On owner instruction, PR 77 records targeted Checkov
  exceptions `CKV_AZURE_40` and `CKV_AZURE_112`; Checkov is not disabled for
  unrelated resources or checks. The exceptions were pushed in signed commit
  `514d135`.
- Required order remains: merge and apply Terraform PR 77; place the resulting
  OpenBao managed-identity client ID in the VM-only OpenBao environment file;
  generate and permission the private-CA/server TLS files on the VM; deploy the
  edge trust configuration and OpenBao configuration from PR 13; verify TLS,
  identity and seal connectivity; only then initialize OpenBao.
- The earlier stop command is still awaiting operator confirmation. Do not
  infer that the currently empty OpenBao instance is stopped.

Terraform PR 77 plan audit:

- The CI plan for signed commit `514d135` completed successfully, but detailed
  inspection found `Plan: 3 to add, 2 to change, 1 to destroy`.
- The destroy was not an intended OpenBao operation. The existing custom role
  `module.aks.azurerm_role_definition.aks_reader` was scheduled for replacement
  because `module.aks` depends on the changing Key Vault module and its internal
  subscription data source was therefore deferred until apply, making the role
  scope unknown during planning.
- Applying that plan was rejected despite the green job. The corrective change
  passes the already-known subscription ID into the AKS module and builds the
  subscription scope from that stable input. A new CI plan must show no role
  replacement and no destruction before PR 77 may be merged or applied.

Corrected Terraform plan result: passed.

- Signed commit `14e7857` contains the stable AKS role-scope correction.
- GitHub Actions run `31546363744` completed successfully on that commit.
- The audited result is `Plan: 2 to add, 2 to change, 0 to destroy`.
- Creates: dedicated user-assigned identity `id-vm01-openbao` and RSA-3072 Key
  Vault key `openbao-unseal` with the declared annual rotation policy.
- In-place updates: attach the new identity to `vm01` while retaining the
  existing backup identity, and extend `kv-polinetwork` with the OpenBao access
  policy plus the rotation-policy permissions required by Terraform.
- The prior `aks_reader` replacement is absent. The AKS credentials data source
  is deferred because of the module's pre-existing dependency, but no AKS
  resource change is planned.
- Outputs added after apply: OpenBao managed-identity client ID and principal
  ID, plus the stable key name `openbao-unseal`.
- Terraform PR 77 is safe to merge/apply with respect to destructive changes.
  Checkov remains intentionally non-blocking/red under the accepted targeted
  risk exceptions; this does not invalidate the Terraform plan result.

Terraform PR 77 merge and first production apply:

- PR 77 merged to `stable` as `e09d7f2`; Compose PR 13 merged to `main` as
  `b565711`.
- GitHub Actions run `31546523360` generated the production plan and waited on
  the protected `production` environment. After confirming no second apply
  workflow was active, the gate was approved with the audited-plan rationale.
- The apply was partial: `id-vm01-openbao` was created, the Key Vault policy was
  updated, and the identity was attached to `vm01`. Creation of
  `openbao-unseal` then failed with HTTP 403 `ForbiddenByPolicy`.
- Root cause: the GitHub Actions OIDC principal with object ID prefix `f220ce5b`
  had only `Get` and `List` on keys. The separate administrator policy had key
  lifecycle permissions, but it is not the identity used by CI.
- No rollback was attempted: the successful changes are intended and recorded
  in Terraform state. OpenBao must remain uninitialized until the missing key
  is created and a convergence plan succeeds.
- On owner instruction, the correction is being committed directly to
  `stable`. The Terraform OIDC principal receives key lifecycle permissions
  `Create`, `Update`, `Delete`, `Recover`, `Rotate`, `GetRotationPolicy`, and
  `SetRotationPolicy`, in addition to its existing `Get` and `List`. Secret and
  certificate permissions are unchanged.

Terraform production convergence:

- The direct-to-`stable` correction was signed and pushed as `a0282c9`; GitHub
  recorded the explicitly authorized bypass of the pull-request rule.
- The first apply had already persisted the intended identity, Key Vault policy
  and VM identity attachment. The new residual plan was rendered from its saved
  artifact and showed `1 to add, 1 to change, 0 to destroy`: only the Terraform
  OIDC policy update and `openbao-unseal` creation.
- Production run `31546855491` was approved and completed successfully:
  `Apply complete! Resources: 1 added, 1 changed, 0 destroyed.`
- Key `openbao-unseal` was created in `kv-polinetwork` with version ID prefix
  `b442b70e`. The dedicated identity client ID is
  `d76681da-d260-4ee9-a1e9-42526cca0cb4`; it is a non-secret selector and is the
  value required in the VM-only OpenBao Compose environment file.
- A further no-change plan was intentionally skipped at the owner's request to
  proceed without excessive verification. Terraform is considered applied;
  OpenBao remains uninitialized.

### OpenBao production TLS and Auto Unseal VM deployment

The following operator block is proposed for `vm01`. It stops the old empty
OpenBao instance before pulling the merged Compose source, creates an internal
CA and server certificate, permanently discards the CA private key after
signing, writes only the non-secret managed-identity client ID to the Compose
environment, deploys Traefik trust first, then starts OpenBao. It does not
initialize OpenBao or create any recovery/root material.

```zsh
set -euo pipefail

PN_REPO=/srv/polinetwork/compose/polinetwork-cd
PN_CONTROL="$PN_REPO/compose/control"
PN_EDGE="$PN_REPO/compose/edge"
PN_KOMODO_ENV=/srv/polinetwork/state/komodo/compose.env
PN_OPENBAO_STATE=/srv/polinetwork/state/openbao

docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" stop openbao

git -C "$PN_REPO" pull --ff-only
git -C "$PN_REPO" rev-parse HEAD

PN_TLS_TMP="$(mktemp -d /dev/shm/openbao-tls.XXXXXX)"
umask 077

openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days 3650 \
  -subj '/CN=PoliNetwork OpenBao Internal CA' \
  -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
  -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout "$PN_TLS_TMP/ca.key" \
  -out "$PN_TLS_TMP/ca.crt"

openssl req -new -newkey rsa:3072 -nodes -sha256 \
  -subj '/CN=openbao' \
  -addext 'subjectAltName=DNS:openbao,DNS:openbao.polinetwork.org,IP:127.0.0.1' \
  -addext 'basicConstraints=critical,CA:FALSE' \
  -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
  -addext 'extendedKeyUsage=serverAuth' \
  -keyout "$PN_TLS_TMP/tls.key" \
  -out "$PN_TLS_TMP/tls.csr"

openssl x509 -req -sha256 -days 397 \
  -in "$PN_TLS_TMP/tls.csr" \
  -CA "$PN_TLS_TMP/ca.crt" \
  -CAkey "$PN_TLS_TMP/ca.key" \
  -CAcreateserial \
  -copy_extensions copy \
  -out "$PN_TLS_TMP/tls.crt"

sudo chmod 0710 "$PN_OPENBAO_STATE"
sudo install -d -o root -g root -m 0755 "$PN_OPENBAO_STATE/tls"
sudo install -o root -g root -m 0644 "$PN_TLS_TMP/ca.crt" "$PN_OPENBAO_STATE/tls/ca.crt"
sudo install -o 100 -g 1000 -m 0644 "$PN_TLS_TMP/tls.crt" "$PN_OPENBAO_STATE/tls/tls.crt"
sudo install -o 100 -g 1000 -m 0600 "$PN_TLS_TMP/tls.key" "$PN_OPENBAO_STATE/tls/tls.key"

printf '%s\n' 'AZURE_CLIENT_ID=d76681da-d260-4ee9-a1e9-42526cca0cb4' \
  | sudo tee "$PN_OPENBAO_STATE/compose.env" >/dev/null
sudo chown pnadmin:pnadmin "$PN_OPENBAO_STATE/compose.env"
sudo chmod 0600 "$PN_OPENBAO_STATE/compose.env"

case "$PN_TLS_TMP" in
  /dev/shm/openbao-tls.*) rm -rf -- "$PN_TLS_TMP" ;;
  *) printf '%s\n' 'Refusing to remove unexpected TLS temporary path' >&2; exit 1 ;;
esac

docker compose -f "$PN_EDGE/compose.yaml" config --quiet
docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" config --quiet

docker compose -f "$PN_EDGE/compose.yaml" up -d --pull always --wait --wait-timeout 120 traefik
docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" \
  up -d --no-deps --pull always --wait --wait-timeout 120 openbao

docker compose --env-file "$PN_KOMODO_ENV" -f "$PN_CONTROL/compose.yaml" ps openbao
docker exec control-openbao-1 bao status
docker logs --since 5m control-openbao-1
```

Expected pre-initialization status: healthy container, TLS listener, Azure Key
Vault seal type, `Initialized: false`, and `Sealed: true`. The temporary CA
private key, CSR and serial file are removed with the validated temporary
directory; only the public CA, server certificate and server private key remain
on the VM. Awaiting operator output; do not infer this block has run.

Observed OpenBao TLS/Auto Unseal deployment result: passed.

- `control-openbao-1` became healthy on OpenBao 2.5.4 without a host port.
- `bao status` reported seal type `azurekeyvault`, recovery seal type `shamir`,
  Raft storage, HA enabled, `Initialized: false`, and `Sealed: true`.
- The SSH connection then closed before the final log command. This was not an
  OpenBao or SSH failure: `bao status` intentionally returns exit status `2`
  for a healthy-but-sealed server, and the operator block's `set -e` terminated
  the remote shell on that non-zero status.
- Future pre-initialization status checks must explicitly accept exit codes 0
  and 2, or be run without `set -e`. Initialization remains pending.

Pre-initialization log interpretation:

- Repeated `stored unseal keys are supported, but none were found: is the
  server initialized?`, `security barrier not initialized`, and
  `seal configuration missing, not initialized` messages are expected before
  the first initialization with an Auto Unseal seal. The stored key does not
  exist until `operator init` creates it and wraps it through Azure Key Vault.
- The startup configuration confirms Azure Public Cloud, vault
  `kv-polinetwork`, key `openbao-unseal`, TLS enabled, and the expected API and
  cluster addresses. No additional infrastructure correction is required.

Production initialization ceremony proposed:

- Accepted single-operator custody model: one recovery share with threshold
  one. Azure Auto Unseal handles routine restarts; this recovery key is for
  privileged recovery operations, not routine unseal.
- Run initialization from the operator workstation through SSH, capturing JSON
  only in a mode-`0600` temporary file on the workstation's `/dev/shm`. No
  initialization output is written to VM storage or displayed.
- Before initialization, require successful access to the existing empty
  1Password item `yoszyppyfhck57iwxuf2thmm6q` in vault `PoliNetwork` and verify
  that its two expected concealed fields exist.
- Update the item through a piped JSON template so recovery key and initial root
  token never appear in command arguments. Rename it to
  `OpenBao vm01 - production bootstrap` and relabel `Unseal Key` as
  `Recovery Key`.
- Delete the temporary JSON only after a structural 1Password verification
  confirms both concealed values were saved. If any 1Password step fails, do
  not delete the temporary file and do not rerun `operator init`.
- After initialization, Auto Unseal should make status `Initialized: true` and
  `Sealed: false`. Awaiting operator execution; no secret values belong in this
  register or chat.

OpenBao production initialization result: passed.

- Initialization completed with one recovery share and threshold one. The
  recovery key and initial root token were transferred directly into the
  existing 1Password item, which was renamed for production; neither value was
  displayed or entered in this register.
- Status reports `Initialized: true`, `Sealed: false`, Azure Key Vault seal,
  Shamir recovery seal, OpenBao 2.5.4, Raft active mode, committed/applied index
  30, cluster name `vault-cluster-4f62eeba`, and cluster ID
  `5ab52aac-3719-74ab-b9ce-99e09298697e`.
- Auto Unseal succeeded for the initialization transition. One controlled
  container restart remains the production gate proving that the VM identity
  can retrieve and unwrap the stored key after process state is lost.

Auto Unseal restart gate: passed.

- After a controlled container restart, OpenBao returned healthy,
  `Initialized: true`, `Sealed: false`, Raft active mode, and committed/applied
  index 34. The active timestamp changed to
  `2026-08-11T23:56:02.260887953Z`, proving a new server process successfully
  retrieved and unwrapped the stored key through Azure Key Vault.
- No manual recovery key submission was required. Azure Auto Unseal is now
  accepted for routine container and VM restarts.
- Before enabling the file audit device, replace the image-created anonymous
  `/openbao/logs` volume with a persistent bind at
  `/srv/polinetwork/state/openbao/audit`; audit persistence is the next source
  and VM deployment step.

OpenBao audit persistence source change:

- On explicit owner instruction, the audit bind change was committed directly
  to `polinetwork-cd/main` as signed commit `4f43c55`, bypassing a separate PR.
- The control Compose now mounts `/srv/polinetwork/state/openbao/audit` at
  `/openbao/logs`; the README states that the file audit device must not be
  enabled before this bind is deployed.
- Proposed next operation: create the host audit directory as numeric
  `100:1000` mode `0700`, pull commit `4f43c55`, recreate only OpenBao, then
  stream the 1Password-held root token through SSH/container stdin to enable a
  file audit device at `/openbao/logs/audit.log` mode `0600`. No token may be
  placed in an argument, environment file, terminal output, or this register.

Audit API attempt and declarative correction:

- The bind was deployed and OpenBao remained operational, but `bao audit
  enable file` returned HTTP 400: API audit creation is disabled and OpenBao
  requires declarative, configuration-based audit management. No audit device
  was created and the root token was not exposed.
- The official OpenBao 2.5 configuration model uses an `audit` array. The
  control Compose now declares a `file` device at logical path
  `persistent-file`, writing `/openbao/logs/audit.log` with mode `0600`.
- This replaces the earlier API-enable proposal. After the new Compose commit
  is deployed, the server creates the audit device during startup without any
  root-token operation.
- The declarative audit correction was JSON-parsed successfully and pushed
  directly to `polinetwork-cd/main` as signed commit `6d1c726`.

Declarative audit deployment result: passed.

- OpenBao loaded the configuration-created audit device at path
  `persistent-file/`, type `file`, description `Persistent OpenBao audit log`.
- Audit data is now written through the persistent host bind rather than an
  anonymous Docker volume. API-based audit creation is no longer part of the
  procedure.

Administrative bootstrap proposed:

- Create a dedicated 1Password Login item for username `pnadmin` with a random
  40-character password; no password or token is displayed.
- Use the initial root token only through a stdin pipe to define a
  `platform-admin` policy, enable the `userpass` auth method, and create the
  `pnadmin` account with an 8-hour token TTL and 24-hour maximum TTL.
- Verify the userpass login with output discarded, create the first encrypted
  Raft snapshot in `/openbao/file/backups`, then revoke the initial root token.
- After confirmed revocation, clear and relabel its 1Password field while
  retaining the recovery key. Do not revoke root until both admin login and
  snapshot creation have succeeded.

Administrative bootstrap partial result:

- A persistent Raft snapshot was created at
  `/openbao/file/backups/bootstrap-platform-admin.snap`, mode `0600`, size
  17,579 bytes. It was initially owned by numeric `0:0` because `docker exec`
  defaults to root; ownership must be normalized to OpenBao `100:1000`.
- The 1Password Login item for `pnadmin` has ID
  `76ls5pdfpgq3hzah6hvrm3bhzq`. No password was displayed or recorded.
- The operator output did not include the expected `pnadmin-login-ok` marker.
  Do not infer successful login and do not revoke the initial root token until
  an isolated userpass login check passes.

Administrative bootstrap completion: passed.

- The isolated userpass authentication check returned `pnadmin-login-ok` for
  1Password item `76ls5pdfpgq3hzah6hvrm3bhzq`.
- Snapshot `bootstrap-platform-admin.snap` was normalized to numeric owner/group
  `100:1000`, mode `0600`, size 17,579 bytes.
- The initial root token revoked itself successfully and is no longer usable.
  Its 1Password field was cleared and relabelled `Revoked Initial Root Token`;
  the production recovery key remains present.
- The active administrative path is now `userpass` account `pnadmin` with the
  `platform-admin` policy. No root token remains in active custody.
- OpenBao production bootstrap gate is complete. Remaining operational work
  includes audit-log rotation, scheduled/off-host Raft snapshots, and the
  application-specific auth/policy/secret migration.

OpenBao public UI routing issue:

- The owner reports that both `/` and the correct UI path `/ui/` return
  Traefik's 404 page. A root-path 404 from OpenBao can be normal, but a Traefik
  404 on `/ui/` means the request reaches the VM edge and no matching OpenBao
  router is active.
- OpenBao itself remains healthy and is not implicated by this response. The
  next diagnostic is limited to the running container's Traefik labels,
  `pn-edge` membership and recent Traefik provider log messages.

Routing diagnostic result:

- `control-openbao-1` has the expected Host rule, HTTPS backend, file-provider
  transport reference and membership in `pn-edge`.
- Traefik repeatedly reports `servers transport not found openbao-tls@file` for
  `openbao@docker`. The Docker router is discovered, but is rejected because
  the dynamic `ServersTransport` is absent from Traefik's active file-provider
  configuration. The 404 is therefore an edge configuration-load problem, not
  an OpenBao backend or certificate failure.

Dynamic file permission root cause:

- The running Traefik command includes the expected file provider and both bind
  mounts resolve to the intended host paths. The CA is readable.
- Reading `/etc/traefik/dynamic/openbao-tls.yaml` inside Traefik fails with
  `Permission denied`. The checkout's restrictive creation umask affected this
  newly added non-secret directory/file, so the non-root Traefik process could
  not load the transport.
- Required host repair: directory mode `0755`, YAML mode `0644`, followed by a
  Traefik restart. No OpenBao restart or configuration change is required.

OpenBao public UI routing result: passed.

- The host dynamic directory was changed to mode `0755` and
  `openbao-tls.yaml` to `0644`; Traefik was restarted healthy and loaded the
  `openbao-tls@file` transport.
- `https://openbao.polinetwork.org/ui/` now works through Cloudflare Access,
  the dedicated tunnel, Traefik and the CA-validated internal TLS hop.
- The incident required no OpenBao restart and did not affect Raft, seal state,
  audit configuration or credentials.

OpenBao AppRole/Agent canary source prepared:

- The source was committed and pushed directly to `polinetwork-cd/main` as
  signed commit `e0e9f4a`, following the owner's direct-main instruction.
- Replace the project-local `control_secrets-api` network with the external,
  internal-only `pn-secrets` bridge at `172.30.3.0/24`. This lets an Agent in a
  different Compose project reach OpenBao without putting either the Agent or
  OpenBao API on an application network. Application containers do not join
  `pn-secrets`.
- The `secrets-canary` profile adds an OpenBao 2.5.4 Agent and a minimal Alpine
  consumer. The Agent authenticates over CA-verified TLS and renders only the
  canary value into a shared 1 MiB tmpfs. The consumer mounts that tmpfs
  read-only, uses numeric identity `100:1000`, has no network namespace and
  receives neither an OpenBao token nor AppRole credentials.
- AppRole `apps-canary` is restricted to read exactly
  `secret/data/apps/canary`, excludes the default policy and issues renewable
  20-minute periodic tokens. Its RoleID and SecretID are written directly
  inside the OpenBao state bind at
  `/srv/polinetwork/state/openbao/approle/canary`, numeric owner `100:1000`,
  mode `0600`; no credential is printed or committed.
- For restartability on this single trusted VM, the Agent retains its SecretID
  file and the AppRole permits unlimited SecretID uses and lifetime. This is a
  revocable bootstrap credential, not the runtime token. It must be mounted
  only into the matching Agent and rotated after any VM/Agent compromise.
- `bootstrap.sh` reads the `pnadmin` password only from stdin, enables KV v2
  and AppRole if absent, installs the dummy canary secret and exact policy,
  writes fresh credential files, proves the own-path read, and requires the
  cross-path read to fail. It then deletes the temporary foreign test value.

Proposed VM deployment and acceptance commands (not yet executed):

```sh
cd /srv/polinetwork/compose/polinetwork-cd
git pull --ff-only

docker network inspect pn-secrets >/dev/null 2>&1 || docker network create \
  --driver bridge \
  --internal \
  --subnet 172.30.3.0/24 \
  --gateway 172.30.3.1 \
  --label com.polinetwork.role=secrets \
  pn-secrets

docker compose \
  --env-file /srv/polinetwork/state/komodo/compose.env \
  -f compose/control/compose.yaml \
  up -d --no-deps --pull never --wait --wait-timeout 120 openbao

docker exec control-openbao-1 bao status
```

From the operator workstation, provision the dummy path and AppRole without
displaying the password or generated credentials:

```sh
op read 'op://PoliNetwork/76ls5pdfpgq3hzah6hvrm3bhzq/password' | \
  ssh pn-vm01 \
  'cd /srv/polinetwork/compose/polinetwork-cd && \
   compose/applications/openbao-canary/bootstrap.sh'
```

Then, on the VM:

```sh
cd /srv/polinetwork/compose/polinetwork-cd

docker compose \
  -f compose/applications/compose.yaml \
  --profile secrets-canary \
  pull openbao-agent-canary openbao-canary

docker compose \
  -f compose/applications/compose.yaml \
  --profile secrets-canary \
  up -d --no-deps --pull never --wait --wait-timeout 120 \
  openbao-agent-canary openbao-canary

docker compose \
  -f compose/applications/compose.yaml \
  --profile secrets-canary \
  ps openbao-agent-canary openbao-canary

stat -c '%u:%g %a %n' \
  /srv/polinetwork/state/openbao/approle/canary \
  /srv/polinetwork/state/openbao/approle/canary/role-id \
  /srv/polinetwork/state/openbao/approle/canary/secret-id

docker inspect applications-openbao-canary-1 \
  --format 'network-mode={{.HostConfig.NetworkMode}} mounts={{json .Mounts}}'

docker exec applications-openbao-agent-canary-1 \
  rm -f /run/secrets/canary.env
docker restart applications-openbao-agent-canary-1

docker compose \
  -f compose/applications/compose.yaml \
  --profile secrets-canary \
  up -d --no-deps --pull never --wait --wait-timeout 120 \
  openbao-agent-canary openbao-canary

docker exec applications-openbao-canary-1 \
  grep -qx 'CANARY_MESSAGE=openbao-agent-ok' /run/secrets/canary.env
docker logs --since 5m applications-openbao-agent-canary-1
```

Acceptance requires both containers healthy, credential paths at `0600`, the
consumer at Docker network mode `none`, successful regeneration after deleting
the rendered file and restarting only the Agent, and no authentication or TLS
errors in Agent logs. Do not record file contents, IDs, SecretIDs or tokens.

First AppRole canary bootstrap attempt: failed safely.

- The bootstrap reached creation of
  `/srv/polinetwork/state/openbao/approle/canary`, then failed at `chmod` with
  `Operation not permitted`. No credential value was displayed.
- Root cause: the hardened OpenBao container retains `CAP_CHOWN` but not
  `CAP_FOWNER`. The script transferred directory ownership to numeric UID 100
  before changing its mode; restricted container root could no longer chmod a
  path it did not own.
- Correction: temporarily normalize each newly created credential path to
  `0:0`, apply its restrictive mode, and only then transfer final ownership to
  `100:1000`. This preserves the reduced capability set and is idempotent for
  the partially created directory. Rerunning the bootstrap intentionally
  rotates/replaces the canary SecretID.
- The correction passed shell syntax and diff checks and was pushed directly
  to `polinetwork-cd/main` as signed commit `ee230c4`.

Second AppRole canary bootstrap attempt: failed safely; prior fix superseded.

- The container reported `syntax error: unexpected end of file (expecting
  "fi")`. No credential value was printed.
- Root cause: the outer `bootstrap.sh` embedded the complete container program
  in a single-quoted `docker exec sh -ec` argument. A later single-quoted
  diagnostic string terminated that outer quoting early. `sh -n` validated the
  resulting outer script as syntactically legal, but did not validate the exact
  malformed argument received by the container shell.
- At the owner's explicit request, local `polinetwork-cd/main` was hard-reset
  from `ee230c4` to its parent `e0e9f4a`. The replacement fix removes nested
  shell quoting entirely: `bootstrap.sh` copies a standalone, non-secret
  `bootstrap-container.sh` to container `/tmp`, pipes only the pnadmin password
  to that file's stdin, and removes the temporary script with an exit trap.
- Both the host wrapper and the exact standalone container script pass POSIX
  `sh -n` parsing; unlike the superseded form, the exact file executed in the
  container is now directly parse-checked. The container script also uses the
  corrected ownership/mode order compatible with `CAP_CHOWN` without
  `CAP_FOWNER`.
- The replacement was committed as signed commit `c274051` and published by
  `git push --force-with-lease`; `polinetwork-cd/main` now contains `c274051`
  instead of the superseded `ee230c4`.

OpenBao AppRole canary bootstrap result: passed.

- The corrected bootstrap completed with the expected success marker.
- AppRole authentication succeeded, its token read
  `secret/data/apps/canary`, and the explicit read attempt against the foreign
  application path was denied. The temporary foreign test value was deleted.
- No RoleID, SecretID, pnadmin password or OpenBao token was displayed or
  recorded. Runtime Agent rendering and restart/re-authentication remain to be
  tested.

OpenBao Agent canary initial runtime result: passed.

- Docker created the tmpfs-backed
  `applications_openbao-canary-secrets` volume. Both
  `applications-openbao-agent-canary-1` and
  `applications-openbao-canary-1` became healthy.
- The consumer reports Docker network mode `none`, proving it has no direct
  network route to OpenBao. It became healthy from the Agent-rendered dummy
  file only.
- The AppRole directory is numeric owner `100:1000`, mode `0700`. Direct
  `pnadmin` stat calls for its child credential files correctly returned
  `Permission denied` because the directory is not traversable by the host
  operator. File ownership/mode must be checked with `sudo stat` without
  reading their contents.
- Remaining gate: delete the rendered tmpfs file, restart only the Agent,
  require it to authenticate and regenerate the file, and prove the consumer
  retained the same container ID.

OpenBao Agent restart and re-authentication result: passed.

- The AppRole directory remained `100:1000` mode `0700`; both `role-id` and
  `secret-id` are `100:1000` mode `0600`.
- The rendered `canary.env` was explicitly removed from the shared tmpfs and
  its absence was confirmed from the consumer container.
- Restarting only `applications-openbao-agent-canary-1` produced a fresh
  successful AppRole authentication, started token renewal and rendered the
  template again. The consumer read the regenerated value and returned to
  healthy.
- `applications-openbao-canary-1` retained the same container ID throughout,
  proving that Agent credential recovery and secret re-rendering do not
  require recreating the application container.
- The least-privilege AppRole/Agent delivery pattern is accepted for
  production application adaptation. The next OpenBao gate is an off-host
  Raft snapshot followed by a clean, isolated restore rehearsal.

OpenBao off-host backup tooling discovery:

- `azcopy`, Azure CLI (`az`), `age` and `restic` are all absent from `vm01`.
- Use the dedicated lightweight ARM64 AzCopy client with the existing
  `id-vm01-backup` managed identity; do not install the full Azure CLI or store
  a storage key/SAS on the VM.
- Encrypt each Raft snapshot with `age` before upload. The age private identity
  must remain off-host in 1Password; only the public recipient belongs in the
  VM backup configuration.
- Official artifacts selected for the implementation: AzCopy 10.32.6 ARM64
  Debian package, SHA-256
  `906a633d2e6b8e843fac668d7a549bcfdd524d3aff6139c7127475f82096a719`.
  The age package will come from the signed Debian 13 repository and its exact
  installed version will be recorded after installation.

Zerobyte alternative evaluation (no deployment yet):

- Zerobyte provides a useful Restic-based UI for encrypted, incremental
  backups, schedules, retention, monitoring and restores. It is still a 0.x
  project and explicitly warns that major changes may occur between releases;
  any adoption must pin an exact image digest and include its own state in the
  recovery procedure.
- It cannot replace `bao operator raft snapshot save`: copying live Raft files
  is not the accepted OpenBao backup method. A native snapshot producer must
  first write a consistent file into a staging directory; Zerobyte may then
  back up that directory.
- Zerobyte's documented native Azure backend requires a storage account key,
  while `polinetworkbackups` intentionally disables shared keys. Direct native
  Azure configuration is therefore incompatible with the current security
  model. A viable proof of concept would use Zerobyte's rclone backend with
  Azure Managed Identity and the dedicated `id-vm01-backup`; this must be
  proven before adoption.
- The local-directory-only deployment does not require `SYS_ADMIN` or
  `/dev/fuse`. Zerobyte must receive only a read-only snapshot staging mount,
  never the live OpenBao Raft directory or Docker socket.
- Zerobyte's APP_SECRET and Restic repository recovery password must be kept
  outside OpenBao (for example in 1Password plus a protected bootstrap file),
  otherwise restoring OpenBao would depend circularly on an unavailable
  OpenBao instance.

Zerobyte Azure authentication decision revised by owner:

- The owner explicitly selected Zerobyte's native Azure Blob backend and
  authorized enabling shared access keys on `polinetworkbackups`, replacing the
  proposed rclone/Managed Identity path.
- `APP_SECRET`, the Restic repository password and the selected storage account
  key will be stored in the existing Azure Key Vault `kv-polinetwork`, not in
  OpenBao. No additional Key Vault will be created.
- The VM backup identity will not receive `Get/List` on the existing Key Vault:
  legacy access-policy permissions apply to every secret in the vault and
  cannot be scoped to only the three Zerobyte names. An administrator will
  transfer the values from Key Vault into dedicated mode-`0600` VM files during
  bootstrap and clean-host recovery.
- Terraform changes only `shared_access_key_enabled` from `false` to `true`.
  It does not read, generate or manage the account key or Zerobyte secrets, so
  no sensitive value is added to Terraform state.
- Local formatting and out-of-sandbox Terraform validation passed. The saved
  production plan contains exactly one in-place update:
  `module.foundation.azurerm_storage_account.backup` changes
  `shared_access_key_enabled` from `false` to `true`. It contains no creates,
  replacements or destroys.

Zerobyte shared-key Terraform deployment attempt:

- Signed Conventional Commit `2490242` (`feat(backup): enable shared keys for
  Zerobyte`) was pushed directly to `terraform/stable` after the owner rejected
  the initial non-Conventional commit message before publication.
- Workflow run `31550904035` independently confirmed the intended plan as
  `0 to add, 1 to change, 0 to destroy`, changing only
  `polinetworkbackups.shared_access_key_enabled` from false to true, but failed
  before apply.
- The failure is unrelated to shared keys: the workflow OIDC principal with
  object ID prefix `81dd9fd1` has Key Vault key `Get/List` but lacks
  `GetRotationPolicy`, now required when refreshing the managed
  `openbao-unseal` rotation policy. No Azure resource was changed.
- Correction: add only `GetRotationPolicy` to that principal's existing key
  permissions. Because the failing principal cannot plan the policy that would
  grant itself this read permission, apply the same tracked policy once through
  an already-authorized administrator, then rerun the normal workflow.
- The one-time live policy update completed without output; tracked
  Conventional Commit `d7d5af2` (`fix(terraform): allow CI to read key rotation
  policy`) was then pushed to `stable`.
- Replacement workflow run `31551069240` completed its Terraform plan
  successfully and is waiting at the protected `production` apply gate. No
  storage-account change has been applied yet.

Zerobyte shared-key Terraform deployment result: passed.

- Protected workflow run `31551069240` completed successfully. Both the
  Terraform Plan and Terraform Apply jobs passed; shared-key access is now
  enabled on `polinetworkbackups`.

Zerobyte Compose preparation (source only; not deployed yet):

- Added an independent `backup` project under
  `polinetwork-cd/compose/backup`, routed by Traefik at
  `backups.polinetwork.org` with no published host port. The route must be
  protected by Cloudflare Access before deployment.
- Selected official Zerobyte `v0.41` and pinned its verified Linux ARM64
  manifest digest
  `sha256:647706f3e44365e6ba8d8e9094efe57bcd36682a1bab4aa23a132d800bd9ad38`.
- The container receives no Docker socket, FUSE device or `SYS_ADMIN`; all
  capabilities are dropped. It has bounded CPU, memory and PID resources and
  a local Bun HTTP liveness probe because the upstream image defines no image
  health check.
- Zerobyte state uses `/srv/polinetwork/state/zerobyte/data`. Its only backup
  source is the read-only `/srv/polinetwork/state/backup-staging` tree; the
  live OpenBao Raft directory is not mounted.
- Compose secret files are fixed root-owned host paths for `APP_SECRET`, the
  Azure account key and the Restic repository password. The deployment guide
  retrieves their values from the existing `kv-polinetwork` vault without
  displaying or committing them.
- The existing Azure Blob `backups` container is not suitable as a Restic
  repository: its 30-day immutable retention would prevent Restic from
  removing locks and obsolete packs. Zerobyte will use a separate private
  `zerobyte` container in the same storage account, without WORM or an
  out-of-band lifecycle deletion rule. Creating that container remains a
  Terraform prerequisite.
- The committed provisioning schema is intentionally empty for first startup,
  because Zerobyte requires an organization ID created during UI onboarding.
  The documented second phase provisions the Azure repository and read-only
  OpenBao snapshot volume using file secret references; backup jobs and
  schedules still require the UI in Zerobyte schema version 1.
- The source was published directly to `polinetwork-cd/main` as signed
  Conventional Commit `094225f` (`feat(backup): add Zerobyte compose project`).

Zerobyte Azure container deployment:

- Added a private Terraform-managed `zerobyte` Blob container in the existing
  `polinetworkbackups` account. It deliberately has no immutability policy or
  lifecycle deletion rule, and Terraform protects it with `prevent_destroy`.
- The saved local plan contained exactly `1 to add, 0 to change, 0 to destroy`:
  `module.foundation.azurerm_storage_container.zerobyte` only. Applying that
  exact plan completed with `1 added, 0 changed, 0 destroyed`.
- An Azure management-plane read confirmed `publicAccess: None`,
  `hasImmutabilityPolicy: false` and `hasLegalHold: false`. The subsequent
  post-apply Terraform plan returned `No changes`.
- The tracked change is signed Conventional Commit `cad6db6`
  (`feat(backup): provision Zerobyte blob container`) on branch
  `feat/zerobyte-container`. Terraform PR #78 targets `stable`; it may be
  merged only after all checks pass and its CI Terraform plan is empty.

Zerobyte recovery secrets:

- Confirmed no existing secret name prefixed `zerobyte-` was present in the
  existing `kv-polinetwork` vault.
- Generated and stored three enabled secrets without displaying their values:
  `zerobyte-app-secret`, `zerobyte-restic-password`, and
  `zerobyte-azure-storage-account-key`. The last value is the currently
  selected shared key for `polinetworkbackups`; rotation must update both Key
  Vault and the VM secret file before Zerobyte restarts.
- Created the Zerobyte state, secret and OpenBao staging directories on `vm01`.
  The three Key Vault values were transferred directly over SSH into files
  owned by `root:root` with mode `0600`. Their observed byte sizes were 64 for
  `app-secret`, 64 for `restic-repository-password`, and 88 for
  `azure-storage-account-key`, confirming that all files are non-empty and
  have the expected encoded lengths without exposing their contents.
- Updated the VM checkout of `polinetwork-cd/main` from `c274051` to `094225f`.
  `docker compose config --quiet` for the new backup project passed, and the
  resolved image is the intended pinned ARM64 manifest
  `ghcr.io/nicotsx/zerobyte:v0.41@sha256:647706f3e44365e6ba8d8e9094efe57bcd36682a1bab4aa23a132d800bd9ad38`.
- A dedicated Cloudflare Access application/policy is active for the Zerobyte
  administrative hostname `backups.polinetwork.org`; the UI may now be started
  behind the existing Cloudflare Tunnel and Traefik route.

Zerobyte initial runtime result: passed.

- Pulled the pinned `v0.41` ARM64 manifest and started
  `backup-zerobyte-1`. The container became healthy with only internal port
  `4096/tcp`; no host port was published.
- Zerobyte completed database migration checkpoints `00001` through `00007`,
  started its scheduler, and synchronized the intentionally empty
  provisioning file as `0` repositories and `0` volumes.
- Built-in cleanup, volume health, repository health, backup execution and
  volume auto-remount schedules were registered. No backup job exists yet.

Zerobyte organization and tracked provisioning:

- Initial UI onboarding created organization ID
  `019ff37d-9fbf-7000-8479-39d166d43ab2`.
- Updated the schema-v1 provisioning file with a managed Azure repository
  `azure-primary` targeting container `zerobyte`, using
  `file://azure_storage_account_key` and
  `file://restic_repository_password`. Added managed directory volume
  `openbao-snapshots` at `/data/openbao`.
- No credential value is present in the provisioning JSON. Signed Conventional
  Commit `8896e44` (`feat(backup): provision Zerobyte Azure repository`) was
  pushed directly to `polinetwork-cd/main`.
- Terraform PR #78 was merged into `stable` as merge commit `36e54c9` after
  Terraform Plan reported `No changes` and Unit Tests, Infracost and CodeRabbit
  passed. Checkov remained ignored per the owner's explicit instruction.
- The owner confirmed that the Zerobyte organization recovery key is stored in
  the PoliNetwork 1Password vault. This is the independent break-glass copy;
  duplicating it into Azure Key Vault is not required for recovery and would
  add no protection against an Azure account outage.

Zerobyte Azure repository provisioning result: passed.

- Recreated the healthy Zerobyte container with tracked provisioning. Zerobyte
  initialized Restic at `azure:zerobyte:/`, added a repository key associated
  with host `pn-vm01`, and reported `1` synchronized provisioned repository and
  `1` provisioned volume.
- The initial informational inability to unmount the new directory volume was
  followed immediately by mounting `/data/openbao`; it is not a runtime
  failure. Scheduler tasks remained active and the service stayed healthy.

OpenBao snapshot producer source:

- Added a dedicated `openbao-snapshot` AppRole bootstrap. Its token has no
  default policy, a five-minute maximum TTL, three uses, and exact read access
  only to `sys/storage/raft/snapshot`. Bootstrap tests both a successful native
  Raft snapshot and denial of Raft configuration access.
- Added an atomic host snapshot script that authenticates inside the OpenBao
  container, writes a native Raft snapshot, copies it into the root-owned
  Zerobyte staging directory, revokes its short-lived token and retains staging
  files for seven days. It never copies live Raft storage.
- Added a hardened systemd oneshot and persistent hourly timer scheduled at
  minute `05` with up to two minutes of jitter. The intended Zerobyte backup
  job runs later in the hour.
- All three exact POSIX shell files pass `sh -n`; both systemd units pass unit
  parsing apart from expected sandbox warnings from the local verifier. Signed
  Conventional Commit `949534c` (`feat(backup): automate OpenBao raft
  snapshots`) was pushed directly to `polinetwork-cd/main`.

OpenBao snapshot bootstrap first-run correction:

- The first bootstrap created the policy/AppRole and successfully reached the
  explicit token self-revocation, but OpenBao denied that call with HTTP 403.
  Because `token_no_default_policy=true`, the minimal snapshot policy also
  needs `update` on `auth/token/revoke-self`; this is not granted implicitly.
- The command stopped at that point due to `set -e`, before installing or
  enabling either systemd unit. Cleanup removed the temporary test snapshot;
  no timer-driven backup was started.
- Added only the missing self-revocation capability. The snapshot endpoint
  remains read-only and the unrelated Raft configuration denial test remains
  in place. POSIX parsing passed and signed Conventional Commit `7074159`
  (`fix(backup): allow snapshot token self-revocation`) was pushed to
  `polinetwork-cd/main`.

OpenBao snapshot bootstrap repeatability correction:

- The second bootstrap stopped while applying mode `0600` to the existing
  RoleID and SecretID. Those files were owned by OpenBao UID 100 from the first
  run; with `CAP_FOWNER` intentionally absent, container root cannot chmod a
  file owned by another UID even though `CAP_CHOWN` and `DAC_OVERRIDE` allow
  the surrounding workflow.
- The bootstrap now takes ownership of the dedicated directory, removes only
  the two old credential files, recreates them under umask `0077`, sets their
  mode and then returns the tree to UID/GID `100:1000`. This preserves
  the reduced capability set and makes credential rotation repeatable.
- The failed command again stopped before installing either systemd unit.
  POSIX parsing passed; signed Conventional Commit `2eae07c`
  (`fix(backup): make snapshot bootstrap repeatable`) was pushed to
  `polinetwork-cd/main`.

OpenBao snapshot producer deployment result: passed.

- The corrected bootstrap completed and reported that native snapshot save
  passed while unrelated Raft system access was denied.
- Installed and enabled `openbao-snapshot.service` and its persistent timer.
  The timer is active; its next observed run was `02:06:33 UTC`, consistent
  with minute `05` plus the configured randomized delay of up to two minutes.
- The first scheduled-format snapshot exists at
  `/srv/polinetwork/state/backup-staging/openbao/openbao-20260812T011208Z.snap`,
  owned by `root:root`, mode `0400`, size `48350` bytes. No live Raft file is
  exposed to Zerobyte.
- Verified from inside `backup-zerobyte-1` that the staged snapshot is readable
  at `/data/openbao/openbao-20260812T011208Z.snap`, still mode `0400` and size
  `48350` bytes. Docker inspection confirms the whole host staging tree is
  mounted at `/data` with `rw=false`; Zerobyte cannot change or delete source
  snapshots.

Zerobyte first OpenBao backup result: data path passed; schedule correction
required.

- The manual `OpenBao hourly` run completed with status `Success` and created
  one Restic snapshot of `47.2 KiB`, consistent with the staged 48,350-byte
  native Raft snapshot plus Restic's displayed unit rounding.
- The UI screenshot shows the saved schedule as `0 * * * *`, with the next run
  at the top of the hour. This is too early because the native snapshot timer
  runs at minute `05` plus up to two minutes of jitter. Change the job to the
  exact custom cron expression `15 * * * *` before accepting automation.
- The owner corrected the job to custom cron `15 * * * *`, sequencing the
  off-host Restic backup after the native snapshot timer.
- Added a dedicated writable restore-test bind mount from
  `/srv/polinetwork/state/zerobyte/restore-tests` to `/restore-tests`. The live
  source remains read-only at `/data`; recovery rehearsals must target only a
  fresh child of `/restore-tests`. Signed Conventional Commit `baf321c`
  (`feat(backup): add isolated restore test target`) was pushed directly to
  `polinetwork-cd/main`.
- Created the restore-test directory on `vm01`, updated to the tracked Compose
  change and recreated only Zerobyte. The container returned healthy and Docker
  inspection confirms `/srv/polinetwork/state/zerobyte/restore-tests` is
  mounted at `/restore-tests` with `rw=true`; `/data` remains the separate
  read-only source mount.
- First restore verification did not find the requested host directory
  `restore-tests/openbao-first-rehearsal`. The source snapshot SHA-256 is
  `350146a3a87dbffb2a89cae449fd86a1e7c7d698273a42189be43bdd75684fb3`.
  Restore is not accepted until Zerobyte's actual target/error is identified
  and the restored file hash matches this value.
- Zerobyte restored directly into the selected `/restore-tests` target rather
  than creating the proposed child directory. The host and container both see
  `openbao-20260812T011208Z.snap`, mode `0400`, owner `root:root`, size `48350`.
  Zerobyte logged `Restic restore completed` for snapshot prefix `5b921480` with
  `1 restored, 0 skipped`. Its warnings that rclone and `SYS_ADMIN` are disabled
  are expected security properties of this native-Azure/local-directory setup.
- The source and restored OpenBao snapshot both have SHA-256
  `350146a3a87dbffb2a89cae449fd86a1e7c7d698273a42189be43bdd75684fb3`.
  The end-to-end native snapshot -> Restic encryption/upload -> Azure Blob ->
  Restic download/restore path is byte-identical and passed its integrity gate.
  The remaining recovery gate is starting an isolated OpenBao from the restored
  snapshot and verifying known application data/authentication.
- Added an automated isolated recovery rehearsal that accepts the existing
  `pnadmin` password on stdin and never prints it. It creates uniquely named
  temporary Docker network, volume and container resources, publishes no port,
  joins no production network, and mounts only the restored snapshot read-only.
- The disposable cluster uses the production Azure Auto Unseal key, is
  initialized only to authorize a force restore, restarts from the restored
  Raft data, then verifies `pnadmin` login and the known canary KV value. It
  asserts that production OpenBao remains healthy and removes every temporary
  resource through an exit trap.
- POSIX parsing and the exact root-token JSON extraction passed locally. Signed
  Conventional Commit `3ad0612` (`test(backup): add isolated OpenBao restore
  rehearsal`) was pushed directly to `polinetwork-cd/main`.

OpenBao restore rehearsal permission correction:

- The first rehearsal invocation as `pnadmin` could not traverse the
  intentionally `root:root` mode-`0700` restore directory, so its snapshot glob
  remained literal and it exited before creating any temporary Docker resource.
  The protected OpenBao environment file would likewise not be readable by
  `pnadmin`.
- The script now explicitly requires root and directs operators to invoke it
  through `sudo` while continuing to accept the `pnadmin` password only on
  stdin. It can also accept one explicit absolute `openbao-*.snap` path below
  the fixed restore-test root for future rehearsals containing multiple files.
- POSIX parsing passed. Signed Conventional Commit `6ce25a7`
  (`fix(backup): run restore rehearsal with root access`) was pushed directly
  to `polinetwork-cd/main`.

OpenBao restore rehearsal Raft identity correction:

- The next isolated run reported that its temporary container was no longer
  running. The exit trap removed the container, volume and network as designed;
  production was not modified.
- The restored Raft state belongs to node ID `vm01` at cluster hostname
  `openbao`. The temporary server had initially used a different node ID and
  loopback cluster address, which is incompatible after the restored Raft
  configuration becomes active.
- The isolated container now uses hostname `openbao`, node ID `vm01` and
  cluster address `https://openbao:8201`, while remaining on its unique bridge
  with no published port or production-network membership. Readiness loops now
  stop immediately and print the temporary container logs if its process exits.
- POSIX parsing passed. Signed Conventional Commit `b1d8fb5`
  (`fix(backup): preserve Raft identity during rehearsal`) was pushed directly
  to `polinetwork-cd/main`.

OpenBao restore rehearsal empty-volume correction:

- Improved diagnostics showed the temporary server exited before initialization
  because `/openbao/file/raft/vault.db` could not be opened: the `raft`
  directory did not exist on the brand-new Docker volume. This is an isolated
  clean-volume bootstrap issue, not a snapshot or Azure failure.
- Added a one-shot init container with `network_mode=none` semantics that creates
  only `/openbao/file/raft`, assigns numeric ownership `100:1000` and mode
  `0700`, then removes itself before the rehearsal server starts.
- Cleanup again removed the failed run's uniquely named resources. POSIX
  parsing passed; signed Conventional Commit `c571522`
  (`fix(backup): initialize rehearsal Raft directory`) was pushed directly to
  `polinetwork-cd/main`.

OpenBao clean-volume restore rehearsal result: passed.

- The final isolated rehearsal completed successfully from the exact snapshot
  restored by Zerobyte from Azure Blob.
- A disposable OpenBao cluster started on a fresh Docker volume, force-restored
  the native Raft snapshot, restarted and auto-unsealed through the existing
  Azure Key Vault seal key.
- Authentication with the post-bootstrap `pnadmin` account succeeded, and the
  restored cluster returned the known `openbao-agent-ok` canary value from
  `secret/apps/canary`. This proves recovery of application data and auth state,
  not only byte-level archive integrity.
- The production `control-openbao-1` container remained healthy. The rehearsal
  published no ports, joined no production network and removed its temporary
  container, bridge network and Docker volume at exit.
- The OpenBao native snapshot -> Zerobyte/Restic -> Azure Blob -> isolated
  clean-volume restore gate is accepted. Keep the restored test file only until
  operational evidence is recorded, then remove it from the writable rehearsal
  directory; the encrypted Azure repository and source staging retention remain
  independent.

Migration documentation organization:

- Moved this runbook, both migration plans, the active migration TODO and the
  post-migration TODO into `/aks-vm-migration` at the workspace root.
- Added a concise subtree `AGENTS.md` defining fresh-session reading order,
  operational recording rules, repository/branch conventions, secret handling
  and the accepted recovery checkpoint.

### Git-backed host bootstrap and clean-host Restic recovery source

Status: source originally committed as `18dbc35` and preserved in the cleaned
`polinetwork-cd/vm` history as signed Conventional Commit `731d703`
(`refactor(vm): organize deployment sources`). No VM command in this section
has been executed; no recovery result is inferred.

Gap identified after the accepted OpenBao rehearsal:

- The existing test restored through the already-running Zerobyte UI. Loss of
  the VM also loses Zerobyte's local SQLite database, accounts, schedules and
  UI configuration, so that test alone does not prove disaster recovery.
- The Azure Restic repository itself is independent of that database. Its
  external recovery roots are the Azure storage account key in
  `kv-polinetwork` and the organization recovery key in the approved
  break-glass store; the pinned Zerobyte image contains the matching Restic
  0.19.1 binary.
- Source inspection of Zerobyte 0.41 confirmed that a repository created with
  `isExistingRepository: false` is initialized with the organization recovery
  key. The independently generated `zerobyte-restic-password` was ignored by
  that path and is not a key for this repository. The tracked provisioning now
  removes that unused custom-password reference and the Compose runtime no
  longer mounts it. Its existing Key Vault value is left untouched pending a
  separately reviewed cleanup.
- The tracked provisioning incorrectly continued to describe the initialized
  Azure repository as new. It is now marked `isExistingRepository: true` so a
  rebuilt instance must attach to, never initialize, the existing repository.
- Docker/containerd daemon files and systemd storage-ordering drop-ins existed
  only as commands in this chronological runbook. They are now tracked under
  `bootstrap/files`, with a guarded `bootstrap-host.sh` that installs
  the exact accepted package versions and verifies the four shared networks.
- The host script is only the first layer of the eventual one-script recovery.
  Full-stack acceptance remains blocked on application-consistent backup and
  clean-host restore coverage for Komodo/Mongo and each migrated stateful app.

Prepared source changes in `polinetwork-cd`:

- The local development branch is now `vm`. Legacy AKS definitions are grouped
  below `k8s-apps/`; Docker applications live in `apps/`; shared Compose
  services live in `core/`; and VM lifecycle tooling lives in `bootstrap/`.
- Each independently operated core service owns a directory and Compose
  project: `core/traefik` (with its required socket proxy),
  `core/cloudflared`, `core/komodo` (with its required MongoDB and Periphery),
  `core/openbao`, and `core/zerobyte`. Generic `control`, `edge`, `data`, and
  `observability` category directories are no longer used. Future databases
  and monitoring services receive their own directories when implemented.
- `bootstrap/README.md` defines the configuration/secret custody
  contract and the remaining full-stack gates.
- `bootstrap/bootstrap-host.sh` installs the pinned Docker runtime,
  copies Git-backed configuration, verifies the data mounts and creates or
  exactly validates `pn-edge`, `pn-app`, `pn-db` and `pn-secrets`.
- `core/openbao/prepare.sh` takes only the non-secret Terraform
  managed-identity client ID, renders the OpenBao environment file and creates
  or validates host-local internal TLS without persisting the CA private key.
- `core/zerobyte/openbao-snapshot/disaster-restore.sh` opens
  `azure:zerobyte:/` directly, runs a Restic metadata check and restores only
  the latest `pn-vm01` `/data/openbao` subtree into a new root-only directory.
  It does not start Zerobyte or read its local state.
- The isolated OpenBao rehearsal accepts
  `REQUIRE_PRODUCTION_OPENBAO=false` for a clean host. This skips only the
  impossible production-container health assertion; the disposable network,
  fresh volume, Azure Auto Unseal, `pnadmin` login and canary read remain
  mandatory.

Source inspection proposed after publishing the reviewed commit and before any
new-host execution:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
git pull --ff-only
git status --short --branch
git rev-parse HEAD
sh -n bootstrap/bootstrap-host.sh
sh -n core/openbao/prepare.sh
sh -n core/zerobyte/openbao-snapshot/disaster-restore.sh
sh -n core/zerobyte/openbao-snapshot/restore-rehearsal.sh
```

Clean-host foundation command proposed only for a Terraform-created Debian 13
ARM64 host with both data mounts active. Do not run this over an active host
until its refusal and runtime-restart behavior have been reviewed:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
sudo bootstrap/bootstrap-host.sh
sudo PN_OPENBAO_CLIENT_ID=REPLACE_WITH_TERRAFORM_OUTPUT \
  core/openbao/prepare.sh
```

After an administrator streams the Azure account key from Key Vault and the
organization recovery key from the approved break-glass store into the
documented root-owned secret paths, direct restore proposed:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
sudo core/zerobyte/openbao-snapshot/disaster-restore.sh
```

Expected result: Restic opens the Azure repository with the external secret
files, identifies the latest snapshot for host `pn-vm01` and path
`/data/openbao`, passes repository metadata checking, restores exactly one
`openbao-*.snap` below a new
`/srv/polinetwork/state/zerobyte/restore-tests/openbao-disaster-*` directory and
prints its SHA-256. Secret values must not appear in output or Docker metadata.

Clean-host isolated verification proposed after creating the non-secret
OpenBao managed-identity env file. Supply the `pnadmin` password only on stdin
and replace the snapshot path with the exact path printed above:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
printf '%s\n' "$PN_OPENBAO_ADMIN_PASSWORD" |
  sudo REQUIRE_PRODUCTION_OPENBAO=false \
  core/zerobyte/openbao-snapshot/restore-rehearsal.sh \
  /srv/polinetwork/state/zerobyte/restore-tests/openbao-disaster-REPLACE/openbao-REPLACE.snap
unset PN_OPENBAO_ADMIN_PASSWORD
```

Acceptance requires this sequence to run on a clean replacement host without
starting Zerobyte, then prove Azure Auto Unseal, `pnadmin` authentication and
the canary secret. Only the operator-reported result may be appended here.

### Per-service Compose project transition

Status: source originally committed as `ce5f5cd` and preserved in the cleaned
`polinetwork-cd/vm` history as signed Conventional Commit `986803b`
(`refactor(core): isolate compose services`); not executed on `vm01`. The
running `control`, `edge`, and `backup` projects remain unchanged.

Local source validation passed with the same Docker Compose `v5.4.0` release
pinned for `vm01`: all six Compose models parsed with consistency checks, all
shell scripts passed `sh -n`, every JSON/YAML file parsed, every relative bind
source and README link resolved, Kustomize resources remained valid after the
legacy-directory move, and no current source reference uses the removed core
category paths.

The source split changes Compose project and container identities:

| Old project/container | New project/container |
| --- | --- |
| `edge-traefik-1` and `edge-docker-socket-proxy-1` | `traefik-traefik-1` and `traefik-docker-socket-proxy-1` |
| `edge-cloudflared-1` | `cloudflared-cloudflared-1` |
| `control-core-1`, `control-periphery-1`, `control-mongo-1` | `komodo-core-1`, `komodo-periphery-1`, `komodo-mongo-1` |
| `control-openbao-1` | `openbao-openbao-1` |
| `backup-zerobyte-1` | `zerobyte-zerobyte-1` |

Persistent bind-mount paths do not change. Do not run the new projects beside
the old stateful containers: concurrent MongoDB, OpenBao or Zerobyte processes
against the same bind mount would be unsafe. Before transition, publish and
pull the reviewed `vm` commit, validate every new Compose model and take a
fresh OpenBao snapshot/off-host backup.

Static validation proposed before stopping any old container:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
git switch vm
git pull --ff-only
docker compose -f core/traefik/compose.yaml config --quiet
docker compose -f core/cloudflared/compose.yaml config --quiet
docker compose -f core/komodo/compose.yaml config --quiet
docker compose -f core/openbao/compose.yaml config --quiet
docker compose -f core/zerobyte/compose.yaml config --quiet
docker compose -f apps/compose.yaml --profile lab --profile secrets-canary config --quiet
```

The actual cutover command block remains intentionally unproposed until the
new models have passed this validation and an exact stop/start/rollback order
is reviewed. No old container should be removed during the first transition;
stopped containers preserve a quick identity-level rollback while the new
projects are verified.

### Komodo-first bootstrap and aggregate core Stack

Status: feasible and published on `polinetwork-cd/vm` as signed Conventional
Commit `8152388` (`feat(core): add komodo-managed stack`); not executed on
`vm01`. This design supersedes operating Traefik, Cloudflared, OpenBao and
Zerobyte as four separate Komodo Stacks. Their service-owned directories and
Compose files remain.

Feasibility findings against the pinned Komodo `2.2.0` source and Docker
Compose `v5.4.0`:

- Komodo must remain its own Compose project and start first; it must not deploy
  or replace itself from the Stack it controls.
- `core/compose.yaml` uses Compose `include` to assemble Traefik, Cloudflared,
  OpenBao and Zerobyte as project `core`. Included relative paths resolve from
  each service directory, preserving ownership of dynamic files.
- `core/komodo/resources/stacks.toml` declares the existing `applications`
  Stack, the new `core` Stack and a self-describing Git-backed Resource Sync.
  Neither Stack has `deploy = true`; initial live cutover remains a deliberate
  operator action and cannot accidentally start duplicate stateful containers.
- On a clean Komodo database, the edge is not running yet, so the normal public
  UI is unavailable. An explicit bootstrap override binds Core only to
  `127.0.0.1:9120`; the operator reaches it through SSH, seeds the single
  Resource Sync, deploys `core`, then reruns the base Komodo model to remove the
  binding. A restored Komodo/Mongo database already contains the sync.
- A completely lost Komodo database still needs that one Resource Sync seed.
  Automating the authenticated seed is deferred to the guarded top-level
  recovery orchestrator; Git contains the desired resources but Komodo does not
  auto-discover an unregistered Resource Sync at startup.

Local source validation passed: the aggregate renders as project `core` with
exactly the expected five services; service-local Traefik and Zerobyte files
resolve correctly; both normal and loopback Komodo Compose models validate;
all shell scripts pass POSIX parsing; and Komodo `2.2.0`'s own Rust resource
types parse the TOML as one Resource Sync and two Stacks.

Static validation proposed after the reviewed commit is published; it does not
start or stop containers:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
git switch vm
git pull --ff-only
git status --short --branch
git rev-parse HEAD
sh -n core/komodo/start.sh
docker compose -f core/komodo/compose.yaml config --quiet
docker compose -f core/komodo/compose.yaml \
  -f core/komodo/bootstrap-access.compose.yaml config --quiet
docker compose -f core/compose.yaml config --quiet
docker compose -f apps/compose.yaml \
  --profile lab --profile secrets-canary config --quiet
```

For a clean host only, after protected Komodo state/secrets are restored and
the host bootstrap has passed, the first control-plane start is proposed:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
PN_KOMODO_BOOTSTRAP_ACCESS=true core/komodo/start.sh
```

The loopback port is not remotely reachable. From the operator workstation,
create a temporary local forward with `ssh -L 9120:127.0.0.1:9120 pn-vm01`,
open `http://127.0.0.1:9120`, and seed `polinetwork-vm` from public repo
`PoliNetworkOrg/polinetwork-cd`, branch `vm`, resource path
`core/komodo/resources`. After applying the sync and deploying/accepting the
`core` Stack, remove bootstrap access by rerunning:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
core/komodo/start.sh
```

These clean-host commands are not the live `vm01` migration procedure. The
running legacy `control`, `edge` and `backup` projects require a separate
stop/import/start rollback sequence; `core/komodo/start.sh` refuses to start
while legacy `control` Komodo containers exist.

### Operator-requested clean bootstrap preflight

Status: proposed, awaiting operator output. The owner reports that `vm01`
currently has no workload that needs to be retained and wants to clean the old
Compose layer and exercise the new bootstrap. Historical runbook state says the
legacy projects existed, so no cleanup or startup command is authorized from
that statement alone. The first pass is read-only and does not print secret
contents.

The `vm` branch is published from the trusted workstation; its current head is
signed commit `8152388`. Proposed workstation verification commands:

```zsh
cd /home/lorenzo/dev/PoliNetwork/polinetwork-cd
git status --short --branch
git log -1 --oneline
git fetch origin
git rev-parse vm origin/vm
```

Proposed read-only VM inventory:

```zsh
set -eu
PN_REPO=/srv/polinetwork/compose/polinetwork-cd

hostname
uname -m
dpkg --print-architecture
sed -n '1,12p' /etc/os-release
findmnt /srv/polinetwork/state /srv/polinetwork/applications
systemctl is-active prepare-data-disks.service docker.service containerd.service

git -C "$PN_REPO" status --short --branch
git -C "$PN_REPO" rev-parse HEAD
git -C "$PN_REPO" remote -v

docker compose ls --all
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}'
docker network ls --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}'
docker volume ls --format 'table {{.Name}}\t{{.Driver}}'

for path in \
  /srv/polinetwork/state/komodo/compose.env \
  /srv/polinetwork/state/komodo/secrets/database-username \
  /srv/polinetwork/state/komodo/secrets/database-password \
  /srv/polinetwork/state/komodo/secrets/init-admin-username \
  /srv/polinetwork/state/komodo/secrets/init-admin-password \
  /srv/polinetwork/state/komodo/secrets/webhook-secret \
  /srv/polinetwork/state/komodo/secrets/jwt-secret \
  /srv/polinetwork/state/cloudflare/compose.env \
  /srv/polinetwork/state/cloudflare/secrets/tunnel-token \
  /srv/polinetwork/state/openbao/compose.env \
  /srv/polinetwork/state/openbao/tls/ca.crt \
  /srv/polinetwork/state/openbao/tls/tls.crt \
  /srv/polinetwork/state/openbao/tls/tls.key \
  /srv/polinetwork/state/zerobyte/secrets/app-secret \
  /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key
do
  if sudo test -e "$path"; then
    sudo stat -c 'present %U:%G %a %s %n' "$path"
  else
    printf 'missing %s\n' "$path"
  fi
done

sudo du -x -h -d 1 \
  /srv/polinetwork/state/komodo \
  /srv/polinetwork/state/openbao \
  /srv/polinetwork/state/zerobyte 2>/dev/null || true
```

Gate before cleanup: identify every old Compose project/container, confirm both
data mounts and Docker are healthy, and classify each protected input as
present or missing. Do not run `docker compose down`, remove containers,
volumes, networks or anything under `/srv/polinetwork/state` until this output
has been reviewed. Cleanup will preserve bind-mounted state and will not use
`--volumes`.

Repository branch separation completed before the VM preflight:

- The last commit before the ARM64 Compose migration is
  `6ff993a523f6c82de90786b898450dd7735df3be`; the migration began at its child
  `6616eef`.
- Remote and local `main` were moved from `c571522` back to `6ff993a` using an
  exact force-with-lease. A post-push remote read confirms that value.
- The migration work was condensed into signed commit `8dc3f72`
  (`feat(vm): add compose migration platform`), followed by signed commits
  `731d703`, `986803b` and `8152388` for the three recent structural changes.
- The cleaned branch was published as remote `vm` at `8152388`. Its final tree
  was compared byte-for-byte with the pre-rewrite `vm` tree and is identical;
  Compose and shell validation passed again after the rewrite.
- Local-only safety branches retain the former `main` and `vm` tips until the
  bootstrap is accepted. They were not published and do not affect either
  remote branch.

### Service-scoped Compose secrets and tracked non-secret environment

Status: published on `polinetwork-cd/vm` as signed Conventional Commit
`ff656b6` (`feat(bootstrap): scope compose secrets per service`); not executed
on `vm01`. This supersedes the pending Komodo `--env-file` commands above.
Historical commands remain unchanged where they record what was actually run.

Audit findings and design:

- Komodo was the remaining Compose project that required a CLI env file, and
  its single file was supplied to both Core and Periphery. Periphery did not
  need the six bootstrap secrets.
- Komodo Core `2.2.0` supports `_FILE` inputs for its database, initial-admin,
  webhook and JWT values. MongoDB `8.0.28` does not support `_FILE`, so a
  service-local wrapper reads only its two Compose secret mounts before
  delegating to the official entrypoint.
- Cloudflared `2026.7.2` supports `TUNNEL_TOKEN_FILE`; its token is now a
  Compose secret readable by the image's numeric user. OpenBao's managed
  identity client ID is non-secret and is tracked directly in Compose.
- The VM identities were not granted Key Vault secret access. The existing
  access-policy model cannot scope that permission to only the two Zerobyte
  secrets, so broad `Get/List` would expose unrelated vault content.
- `bootstrap/prepare-secrets.sh` keeps valid existing files, parses but never
  sources legacy environment files, splits them into least-privilege secret
  files and silently asks for missing values. `runtime`, `recovery` and `all`
  modes keep the Restic organization key out of normal runtime staging.

Local validation passed with Docker Compose `5.4.0`: the normal and temporary
loopback Komodo models, aggregate `core` Stack and profiled applications model
all render without an env file; all shell scripts parse. The tracked MongoDB
wrapper reached the official image entrypoint, and the pinned Cloudflared
binary exposes `--token-file` through `TUNNEL_TOKEN_FILE`. No service was
started on `vm01`.

After the read-only VM inventory is reviewed, the proposed preparation and
static validation commands are:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
git switch vm
git pull --ff-only
sudo bootstrap/prepare-secrets.sh runtime
sudo core/openbao/prepare.sh
docker compose -f core/komodo/compose.yaml config --quiet
docker compose -f core/komodo/compose.yaml \
  -f core/komodo/bootstrap-access.compose.yaml config --quiet
docker compose -f core/compose.yaml config --quiet
docker compose -f apps/compose.yaml \
  --profile lab --profile secrets-canary config --quiet
```

The secret preparation writes or normalizes protected files but does not
start, stop or remove containers. It leaves legacy `compose.env` files in
place until the replacement projects have been accepted.

### Folder-discovered Komodo stacks

Status: published on `polinetwork-cd/vm` as signed Conventional Commits
`6d84c1c` (`feat(vm): discover compose service folders`) and `2222be3`
(`fix(openbao): provision roles for both catalogs`); not executed on `vm01`.
This supersedes the manually maintained aggregate Compose includes and Komodo
`config_files` list described above.

The requested repository contract is now:

- add `core/x/compose.yaml` or `apps/x/compose.yaml` and push `vm`;
- no root Compose include or per-service Komodo resource is edited;
- `.komodo-ignore` excludes an exceptional immediate child folder, currently
  only bootstrapped `core/komodo`;
- one `deploy-polinetwork-vm` procedure syncs Git declarations, deploys the
  discovered core folders, then deploys the discovered application folders;
- both stacks use a fresh Komodo clone and a tracked pre-deploy script to
  replace the placeholder root Compose file only inside that disposable clone;
  `--remove-orphans` removes a service deleted from Git on the next deploy.

Komodo `2.2.0` has no native wildcard discovery for Stack `file_paths` or
`config_files`. The deterministic `bootstrap/render-compose-catalog.sh` hook is
therefore the smallest adapter: it scans only immediate `*/compose.yaml`
children, sorts them through the shell glob, validates folder names and fails
when none are found. The generated catalog is runtime material and is ignored
by Git.

Secret-bearing applications continue to use the already accepted
per-application OpenBao Agent pattern. Docker Compose cannot reference an
OpenBao URI natively. The generic guarded helper
`core/openbao/provision-service-role.sh core|apps x` now creates or verifies an
AppRole that can read only `secret/core/x` or `secret/apps/x`; the folder's
Agent template references keys from that path and renders only the resulting
file into a shared tmpfs. OpenBao's own Azure Auto Unseal and bootstrap secrets
remain outside this mechanism.

Local validation passed without touching the VM:

- discovery found the expected four core and two application folders;
- the generated normal and secret-canary Compose models render with Compose
  `5.4.0`, including correct folder-relative Agent/template paths;
- a disposable-clone simulation replaced both root placeholders and rendered
  successfully, matching Komodo's `reclone` plus pre-deploy sequence;
- every shell script parses; and
- Komodo `2.2.0`'s own Rust types parse one Resource Sync, two Stacks and the
  ordered three-stage procedure.

After publishing and after the separate live-state inventory/cutover review,
the only new Komodo setup action will be creating the Git webhook for procedure
`deploy-polinetwork-vm` on branch `vm`. The legacy projects must not be deployed
through it before their reviewed ownership transition.

### doco.cd replacement and minimal bootstrap boundary

Status: published on `polinetwork-cd/vm` as signed Conventional Commit
`b4d3dda` (`feat(vm): replace komodo with doco cd`); not executed on `vm01`.
This section supersedes the pending Komodo folder-discovery, generated-catalog
and env-preparation procedures above. Historical commands and reported
outcomes remain unchanged.

The replacement deliberately has only two layers:

- `infra/openbao` and `infra/doco-cd` are one-time bootstrap projects outside
  reconciliation because doco.cd depends on both;
- doco.cd polls the public `vm` branch and natively auto-discovers immediate
  `core/*/compose.yaml` and `apps/*/compose.yaml` projects.

Folder-local `.doco-cd.yaml` files add native OpenBao references and optional
profiles. doco.cd injects resolved values into environment-backed Compose
secrets; no CLI env file, generated aggregate Compose file, central service
list, per-application Agent or provisioning helper is involved. The sole
OpenBao Agent is beside doco.cd itself because the doco.cd OpenBao provider
accepts a token; it obtains and renews that token from a regenerable AppRole in
tmpfs. OpenBao continues to use the Terraform-managed VM identity and Azure Key
Vault Auto Unseal key.

Deletion reconciliation is enabled but deliberately retains volumes and
images. The doco.cd HTTP/webhook port is not published; polling is sufficient
for this public repository. Direct Docker socket access is the explicit
simplicity/trust tradeoff.

Local validation actually completed:

- doco.cd `0.108.0`'s own Go configuration parser discovered exactly
  `cloudflared`, `traefik`, `zerobyte`, `openbao-canary` and
  `wave1-canaries`, including nested secret/profile configuration;
- Docker Compose `5.4.0` rendered every infrastructure, core and application
  project, including environment-backed secret sources;
- the pinned doco.cd manifest includes Linux ARM64 and resolves to manifest
  list digest `sha256:7b444cbd9b350e0d65a93942cfa025ae62fe52d5f00b7b791d93630ef6909cef`;
- all retained POSIX shell scripts parse, and `git diff --check` passes; and
- the `alpine/openssl:3.5.4` bootstrap image contains the required `install`
  utility.

No VM cleanup, service stop, start, secret mutation or deployment command is
proposed or executed by this source-only change. Before live replacement, run
the already-recorded read-only VM inventory again and write a separate exact
Komodo-to-doco.cd transition sequence after reviewing that current output.

### Full bootstrap rehearsal: cleanup preflight

Status: proposed, awaiting operator output. The requested end-to-end rehearsal
will model total VM-local state loss, but no destructive command is issued
until the current Docker ownership, mounts, timers, latest OpenBao snapshot and
external recovery inputs are confirmed. The preflight below is read-only and
does not print secret values:

```zsh
set -eu
PN_REPO=/srv/polinetwork/compose/polinetwork-cd

hostname
uname -m
sed -n '1,12p' /etc/os-release
findmnt /srv/polinetwork/state /srv/polinetwork/applications
systemctl is-active prepare-data-disks.service docker.service containerd.service

git -C "$PN_REPO" status --short --branch
git -C "$PN_REPO" rev-parse HEAD
git -C "$PN_REPO" remote -v

docker compose ls --all
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}'
docker network ls --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}'
docker volume ls --format 'table {{.Name}}\t{{.Driver}}'

systemctl list-timers --all 'openbao-snapshot*' --no-pager
systemctl status openbao-snapshot.timer --no-pager || true
sudo find /srv/polinetwork/state/backup-staging/openbao \
  -maxdepth 1 -type f -name 'openbao-*.snap' \
  -printf '%TY-%Tm-%TdT%TH:%TM:%TS %s %p\n' 2>/dev/null | sort | tail -5

for path in \
  /srv/polinetwork/state/openbao/raft \
  /srv/polinetwork/state/openbao/tls/ca.crt \
  /srv/polinetwork/state/openbao/tls/tls.crt \
  /srv/polinetwork/state/openbao/tls/tls.key \
  /srv/polinetwork/state/zerobyte/data \
  /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key
do
  if sudo test -e "$path"; then
    sudo stat -c 'present %F %U:%G %a %s %n' "$path"
  else
    printf 'missing %s\n' "$path"
  fi
done

sudo du -x -h -d 1 /srv/polinetwork/state 2>/dev/null | sort -h
```

Cleanup gate: verify the most recent OpenBao snapshot is present off-host and
that both the Azure account key and Restic recovery key can be reacquired from
their canonical off-host stores. The cleanup sequence will then stop the
snapshot timer first, remove only the inventoried Compose projects and Docker
objects, and clear VM-local application/control-plane state without touching
the mounted filesystem itself, Azure Blob, Key Vault, AKS or Terraform.

Operator result: the host is Debian 13 ARM64 and all data-mount, Docker and
containerd services reported active. The checkout is still old `main` at
`c571522`. Legacy Compose projects `applications`, `backup`, `control` and
`edge` own eleven containers; MongoDB is restarting while the other reported
containers are running. The legacy project networks, shared `pn-*` networks,
one named canary tmpfs volume and six anonymous volumes are present. The
OpenBao snapshot timer is enabled and waiting, but the latest staging snapshot
shown by the inventory is only `2026-08-12T03:05:19Z`, despite the timer last
running around 12:06 UTC. Backup freshness is therefore not yet established.

The first proposed path-inspection loop failed because it used `path` as its
iterator under Zsh. Zsh ties the special `path` array to `PATH`, so the loop
removed executable search directories and caused `sudo` and other commands to
appear missing; `set -e` then ended the session. Reconnect (or explicitly
restore the standard PATH) and use the corrected read-only continuation:

```zsh
for target_path in \
  /srv/polinetwork/state/openbao/raft \
  /srv/polinetwork/state/openbao/tls/ca.crt \
  /srv/polinetwork/state/openbao/tls/tls.crt \
  /srv/polinetwork/state/openbao/tls/tls.key \
  /srv/polinetwork/state/zerobyte/data \
  /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key
do
  if sudo test -e "$target_path"; then
    sudo stat -c 'present %F %U:%G %a %s %n' "$target_path"
  else
    printf 'missing %s\n' "$target_path"
  fi
done

sudo du -x -h -d 1 /srv/polinetwork/state 2>/dev/null | sort -h
systemctl status openbao-snapshot.service --no-pager || true
sudo journalctl -u openbao-snapshot.service --since '2026-08-12 03:00:00 UTC' \
  --no-pager -n 120
sudo find /srv/polinetwork/state/backup-staging/openbao \
  -maxdepth 1 -type f -name 'openbao-*.snap' \
  -printf '%TY-%Tm-%TdT%TH:%TM:%TS %s %p\n' 2>/dev/null | sort | tail -10
```

This continuation remains read-only. Do not clean up while the apparent
snapshot freshness failure is unresolved.

Operator result: the corrected inspection completed. OpenBao Raft state and
TLS exist; the host-side `dhcpcd:pnadmin` names correspond to the numeric
container ownership already used by the deployment. Zerobyte's Azure account
key is staged mode `0600`; the Restic recovery key is intentionally absent and
must be reacquired before disaster recovery. Total OpenBao state consumes
approximately 30 GB, while Komodo uses 205 MB and Zerobyte 608 KB.

The snapshot freshness issue is confirmed. The last successful snapshot was
`2026-08-12T03:05:19Z`. Every hourly attempt from 04:05 through 12:06 failed at
AppRole login with OpenBao HTTP 500, usually `local node not active but active
cluster node not found`. The Docker health check did not detect this because
it treats the OpenBao standby/no-leader status code as healthy. Cleanup remains
blocked until OpenBao leadership is recovered, a fresh native snapshot is
created and its off-host Restic copy is verified.

Proposed read-only diagnosis, which does not print tokens or secret values:

```zsh
date -u
df -h /srv/polinetwork/state /srv/polinetwork/applications
df -i /srv/polinetwork/state /srv/polinetwork/applications

docker inspect control-openbao-1 \
  --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{end}} restarts={{.RestartCount}} started={{.State.StartedAt}}'
docker exec control-openbao-1 bao status -format=json || true
docker logs --since 12h --tail 300 control-openbao-1 2>&1

sudo du -x -h -d 2 /srv/polinetwork/state/openbao 2>/dev/null | sort -h
sudo find /srv/polinetwork/state/openbao -xdev -type f -size +100M \
  -printf '%s %TY-%Tm-%TdT%TH:%TM:%TS %p\n' 2>/dev/null | sort -n | tail -30

docker stats --no-stream --format \
  'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.BlockIO}}' control-openbao-1
```

Do not restart OpenBao or truncate/remove its audit or Raft files until this
output is reviewed. Separately confirm only whether the Zerobyte organization
recovery key can be retrieved from the approved off-host store; do not paste
the key into the runbook or chat.

Operator result: `/dev/sdc`, the 32 GB state filesystem, has zero available
space and is 100% full; inode use is only 1%. OpenBao Raft is approximately
616 KB and its database indices remain committed/applied at 395, while
`/srv/polinetwork/state/openbao/audit/audit.log` alone is 31,549,341,696 bytes.
OpenBao repeatedly wins single-node elections but cannot commit the leader log
because `raft.db` receives `no space left on device`, then loses leadership.
This fully explains both the misleading healthy container and failed snapshot
AppRole logins.

The replacement source was corrected and published as signed Conventional
Commit `4aad781` (`fix(openbao): bound audit log storage`). New OpenBao audit
events go to stdout under Docker's tracked bounded `local` driver (five 20 MB
files), the unbounded audit bind mount is removed, and the single-node health
check now requires active status rather than accepting standby/no-leader exit
code 2. Compose `5.4.0` validation passed; this source change is not yet
deployed on `vm01`.

The operator requested cleanup for a total-loss bootstrap rehearsal, so
discarding the exact local audit file is within scope and necessary to recover
Raft long enough to create a current backup. The audit history cannot be
recovered after the truncate. Proposed recovery and snapshot commands:

```zsh
sudo systemctl stop openbao-snapshot.timer
sudo truncate --size=0 /srv/polinetwork/state/openbao/audit/audit.log
sync
df -h /srv/polinetwork/state
sudo stat -c '%U:%G %a %s %n' \
  /srv/polinetwork/state/openbao/audit/audit.log

sleep 15
docker exec control-openbao-1 bao status -format=json

sudo systemctl start openbao-snapshot.service
systemctl status openbao-snapshot.service --no-pager
sudo find /srv/polinetwork/state/backup-staging/openbao \
  -maxdepth 1 -type f -name 'openbao-*.snap' \
  -printf '%TY-%Tm-%TdT%TH:%TM:%TS %s %p\n' | sort | tail -3

docker stop control-openbao-1
df -h /srv/polinetwork/state
```

Gates: `bao status` must show a non-zero `active_time`; the one-shot systemd
service must succeed and produce a new snapshot with a current UTC timestamp.
OpenBao is stopped immediately afterward so the legacy unbounded audit config
cannot consume the reclaimed space again. Next, run the existing OpenBao
backup job once from the Access-protected Zerobyte UI. Do not remove containers
or state until the job reports success and direct Restic recovery of that new
snapshot has passed using the off-host organization recovery key.

Operator result: truncating the exact audit file reclaimed the state disk from
100% use to 1% use (approximately 30 GB available), while preserving its
ownership and mode. OpenBao remained initialized and unsealed but did not
recover active leadership in-place; `active_time` stayed at the zero value and
the immediate one-shot snapshot retry failed with the same no-active-node
AppRole error. No new snapshot was created.

With filesystem capacity restored, a controlled restart of only the OpenBao
container is now proposed. Azure Auto Unseal and restart recovery have already
passed; no Raft or TLS file is manually changed. The retry is gated on active
leadership:

```zsh
docker restart control-openbao-1

for attempt_number in {1..30}; do
  if docker exec control-openbao-1 bao status >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

docker exec control-openbao-1 bao status -format=json
docker inspect control-openbao-1 \
  --format 'status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{end}} restarts={{.RestartCount}} started={{.State.StartedAt}}'
docker logs --since 2m --tail 120 control-openbao-1 2>&1
df -h /srv/polinetwork/state
```

Only if `active_time` is non-zero and the logs show active operation, retry the
snapshot and stop OpenBao after success:

```zsh
sudo systemctl reset-failed openbao-snapshot.service
sudo systemctl start openbao-snapshot.service
systemctl status openbao-snapshot.service --no-pager
sudo find /srv/polinetwork/state/backup-staging/openbao \
  -maxdepth 1 -type f -name 'openbao-*.snap' \
  -printf '%TY-%Tm-%TdT%TH:%TM:%TS %s %p\n' | sort | tail -3

docker stop control-openbao-1
df -h /srv/polinetwork/state
```

If leadership is still absent, do not start the snapshot or stop/delete other
services; report the restart output for a Raft recovery decision.

Operator result: the controlled restart succeeded. Azure Auto Unseal completed,
the single node won election at term 360, acquired the active lock, and reports
`is_self: true`, active time `2026-08-12T13:11:20Z`, and matching committed and
applied Raft index 446. The state disk remains at 1% use. The container health
was still in its start period when inspected; the OpenBao status and logs
independently confirm active operation. Proceed with the already-recorded
one-shot snapshot and stop only after that service succeeds.

Operator result: the one-shot native snapshot succeeded at
`2026-08-12T13:12:52Z`, producing 26,899-byte
`openbao-20260812T131252Z.snap`. Legacy OpenBao was then stopped and the state
disk remains at 1% use. The operator manually ran the Zerobyte backup job and
reported it complete. Direct recovery from Azure remains the final cleanup
gate.

The live checkout at old `main` commit `c571522` predates the direct disaster
restore entry point. To avoid switching files underneath legacy running bind
mounts, clone current `vm` commit `4aad781` beside it and verify that checkout
before use. Proposed commands:

```zsh
PN_RECOVERY_ROOT="$(mktemp -d /tmp/polinetwork-recovery.XXXXXX)"
PN_RECOVERY_REPO="$PN_RECOVERY_ROOT/repo"
git clone --branch vm --single-branch \
  https://github.com/PoliNetworkOrg/polinetwork-cd.git "$PN_RECOVERY_REPO"
git -C "$PN_RECOVERY_REPO" status --short --branch
git -C "$PN_RECOVERY_REPO" rev-parse HEAD
printf '%s  %s\n' \
  7e468ee145ce918053fe615f3cb665f2de363fa43cc7ed3227a1d674ba7e2e99 \
  "$PN_RECOVERY_REPO/core/zerobyte/openbao-snapshot/disaster-restore.sh" |
  sha256sum --check
```

Stage the Zerobyte organization recovery key without echoing it or placing it
in an argument, run the direct Azure/Restic recovery, and remove the temporary
runtime copy only after success:

```zsh
sudo install -d -o root -g root -m 0700 \
  /srv/polinetwork/state/zerobyte/secrets
PN_RESTIC_RECOVERY_KEY="$(systemd-ask-password \
  'Zerobyte organization recovery key')"
printf '%s' "$PN_RESTIC_RECOVERY_KEY" |
  sudo install -o root -g root -m 0600 /dev/stdin \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key
unset PN_RESTIC_RECOVERY_KEY

sudo "$PN_RECOVERY_REPO/core/zerobyte/openbao-snapshot/disaster-restore.sh"

sudo rm /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key
rm -rf "$PN_RECOVERY_ROOT"
unset PN_RECOVERY_REPO PN_RECOVERY_ROOT
```

The restore must select and restore `openbao-20260812T131252Z.snap`; selection
of an older snapshot means the manual Zerobyte job did not upload the current
producer output and cleanup remains blocked. The exact temporary recovery-key
file is intentionally removed after the successful proof; canonical custody
remains off-host.

Operator result: direct Restic access reached the repository but failed with
`wrong password or no key found`. Zerobyte v0.41 source confirms that the
required artifact is the plaintext `restic.pass` downloaded for the currently
active organization. It is distinct from the user login password, APP secret,
and keys for other organizations. Migration
`00007-require-recovery-key-redownload` specifically marks existing admins for
a fresh download, so a previously retained artifact may be stale.

Proposed correction: while the legacy Zerobyte instance and database still
exist, select the organization owning repository `azure-primary`, download a
new recovery key from Settings, and stream that exact downloaded file from the
workstation without copying it through a shell variable:

```zsh
ssh pn-vm01 'sudo install -d -o root -g root -m 0700 \
  /srv/polinetwork/state/zerobyte/secrets && \
  sudo install -o root -g root -m 0600 /dev/stdin \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key' \
  < "$HOME/Downloads/restic.pass"
```

On the VM, verify only metadata and retry direct recovery:

```zsh
sudo stat -c '%U:%G %a %s %n' \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key
sudo "$PN_RECOVERY_REPO/core/zerobyte/openbao-snapshot/disaster-restore.sh"
```

Do not print or paste the file. If the fresh active-organization artifact still
fails, leave Zerobyte and its database intact: the next diagnosis is whether
`azure-primary` was imported with a per-repository custom password. Cleanup
remains blocked.

Operator result: the freshly downloaded 64-byte active-organization
`restic.pass` authenticated successfully. Direct Restic recovery found the
new Azure snapshot `8dfb63fb` created at 13:15 UTC for host `pn-vm01` and path
`/data/openbao`; `restic check` verified all packs, snapshots, trees and blobs
with no errors, and 170.068 KiB was restored without Zerobyte database access.
The script then failed only in its final local-file assertion because Restic
preserved `data/openbao` below the target while the script expected exactly one
snapshot directly at the target root. This does not invalidate the completed
repository authentication, integrity check, or restore.

The locator was corrected to search recursively and select the newest native
Raft snapshot from the restored backup. The fix was validated and published as
signed Conventional Commit `7640fb8` (`fix(backup): locate restored raft
snapshots`). Before cleanup, verify the already-restored current snapshot
against its producer source:

```zsh
PN_RESTORE_TARGET=/srv/polinetwork/state/zerobyte/restore-tests/openbao-disaster-20260812T134145Z-1154668
sudo find "$PN_RESTORE_TARGET" -type f -name 'openbao-*.snap' \
  -printf '%TY-%Tm-%TdT%TH:%TM:%TS %s %p\n' | sort

PN_RESTORED_SNAPSHOT="$(sudo find "$PN_RESTORE_TARGET" -type f \
  -name 'openbao-20260812T131252Z.snap' -print -quit)"
test -n "$PN_RESTORED_SNAPSHOT"
sudo sha256sum \
  /srv/polinetwork/state/backup-staging/openbao/openbao-20260812T131252Z.snap \
  "$PN_RESTORED_SNAPSHOT"
unset PN_RESTORED_SNAPSHOT PN_RESTORE_TARGET
```

The two SHA-256 values must match. After that proof, remove the temporary
staged recovery key. The restored rehearsal directory may remain until the
subsequent full local-state cleanup.

Operator result: the restored Azure backup contained all four producer
snapshots, including `openbao-20260812T131252Z.snap`. The current producer and
Azure-restored copies both have SHA-256
`5fdd378147f22a3670103e57f28d2ca8697548fce7cbf04b1bd950a52a8750c6`.
The temporary VM copy of `restic.pass` was removed. The clean-host recovery
gate is therefore satisfied for OpenBao and destructive VM-local cleanup is
now authorized by the operator's full bootstrap rehearsal request.

The exact legacy inventory contains Compose projects `applications`,
`backup`, `control`, and `edge`; twelve named containers; four legacy project
networks, four shared `pn-*` networks, one named canary tmpfs volume and six
anonymous volumes. The cleanup below stops/removes only those recorded Docker
objects, disables/removes the old snapshot unit, and deletes only the explicit
VM-local state directories now proven recoverable. It does not remove the
state or applications mount, `lost+found`, Docker engine storage, images,
Azure Blob, Key Vault, Terraform, or AKS.

```zsh
sudo systemctl disable --now openbao-snapshot.timer
sudo systemctl stop openbao-snapshot.service 2>/dev/null || true

docker rm -f -v \
  backup-zerobyte-1 \
  applications-openbao-canary-1 \
  applications-openbao-agent-canary-1 \
  control-openbao-1 \
  edge-traefik-1 \
  applications-wave1-canary-a-1 \
  applications-wave1-canary-b-1 \
  control-periphery-1 \
  control-core-1 \
  control-mongo-1 \
  edge-cloudflared-1 \
  edge-docker-socket-proxy-1

docker volume rm \
  applications_openbao-canary-secrets \
  8a71268b164e59351a90889f994ea51fda9c86132edb7692b717a22b3c9f0ce2 \
  8f3f49de72959f8c80bc9ad8a49b1f1fb8c4dbb127afad6407e3eff25eeaf2ff \
  ab77a3639816e6234d70f5f68f135f08978648b141265f1b3de324c36f3c9013 \
  c5259f1b59868334d294d94c7f9ef32aab158fff88604dcc2d67b5e2487c16fb \
  e158c62f4b512faacaa33d7fd9577b85d4950ee20ac7a5ad23446490f8cee0a6 \
  e34960fc100fdb5349314b448f9b9b4f46b6ee658b2bac7031c6b3391fe4a38d \
  2>/dev/null || true

docker network rm \
  control_control-api \
  control_control-egress \
  control_secrets-api \
  edge_socket-api \
  pn-app pn-db pn-edge pn-secrets

sudo rm -f \
  /etc/systemd/system/openbao-snapshot.service \
  /etc/systemd/system/openbao-snapshot.timer
sudo systemctl daemon-reload
sudo systemctl reset-failed openbao-snapshot.service 2>/dev/null || true

sudo rm -rf -- \
  /srv/polinetwork/state/backup-staging \
  /srv/polinetwork/state/cloudflare \
  /srv/polinetwork/state/komodo \
  /srv/polinetwork/state/openbao \
  /srv/polinetwork/state/zerobyte
```

Post-cleanup verification:

```zsh
docker compose ls --all
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}'
docker network ls --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}'
docker volume ls --format 'table {{.Name}}\t{{.Driver}}'
systemctl list-timers --all 'openbao-snapshot*' --no-pager
sudo find /srv/polinetwork/state -mindepth 1 -maxdepth 1 \
  -printf '%f\n' | sort
df -h /srv/polinetwork/state /srv/polinetwork/applications
```

Expected result: no Compose project or container; only built-in Docker
networks; no Docker volumes; no OpenBao timer; only `lost+found` under the
state mount. Any difference must be reviewed before starting the bootstrap.

Operator result: cleanup matched the expected result exactly. There are no
Compose projects, containers, Docker volumes, or snapshot timers. Docker has
only `bridge`, `host`, and `none`; `/srv/polinetwork/state` contains only
`lost+found` and has approximately 30 GB available. The applications disk has
approximately 56 GB available. The VM-local deployment is now clean.

### Full bootstrap rehearsal: Git and host layer

Status: passed. The operator switched the old live checkout from historical
`main` commit `c571522` to the published `vm` branch at exact commit
`7640fb84b27a27f49b94bce0e71c2827d93cf9d0`, then ran the tracked host
bootstrap:

```zsh
PN_REPO=/srv/polinetwork/compose/polinetwork-cd
cd "$PN_REPO"
git status --short --branch
git fetch --prune origin

if git show-ref --verify --quiet refs/heads/vm; then
  git switch vm
else
  git switch --create vm --track origin/vm
fi
git merge --ff-only origin/vm

test "$(git rev-parse HEAD)" = \
  7640fb84b27a27f49b94bce0e71c2827d93cf9d0
git status --short --branch

sudo bootstrap/bootstrap-host.sh
```

The bootstrap may stop and restart Docker because no containers remain. It
must validate Debian 13 ARM64, both mounted data disks, exact pinned package
versions, tracked Docker/containerd configuration, and create `pn-edge`,
`pn-app`, `pn-db`, and `pn-secrets`. Post-bootstrap verification:

```zsh
docker version
docker compose version
docker info --format \
  'DockerRootDir={{.DockerRootDir}} Driver={{.Driver}} LoggingDriver={{.LoggingDriver}}'
docker network inspect pn-edge pn-app pn-db pn-secrets \
  --format '{{.Name}} internal={{.Internal}} subnet={{(index .IPAM.Config 0).Subnet}} gateway={{(index .IPAM.Config 0).Gateway}} role={{index .Labels "com.polinetwork.role"}}'
systemctl is-active prepare-data-disks.service containerd.service docker.service
git status --short --branch
```

Expected: Docker root `/srv/polinetwork/applications/docker`, `overlay2`,
`local` logging, the four exact tracked networks, three active systemd units,
and a clean `vm` checkout. Do not start OpenBao until this output is reviewed.

Operator result: the tracked host bootstrap completed successfully. Docker uses
`/srv/polinetwork/applications/docker`, the `local` logging driver and its
reported `overlayfs` storage driver. All four shared networks have the exact
tracked subnets, gateways, internal flags and role labels. The script's final
host gate passed and no Compose project was started. The reported driver name
differs from the older `overlay2` expectation, but the selected applications
disk and the bootstrap's configuration checks are correct, so this does not
block recovery.

### Full bootstrap rehearsal: recover the native OpenBao snapshot

Status: proposed, awaiting operator output. The restore must begin only from
Git, Azure Blob, Azure Key Vault and the separately retained active-organization
`restic.pass`; it must not use any deleted Zerobyte database or old VM state.

First update the clean VM checkout to the documentation fix published after
the host bootstrap:

```zsh
PN_REPO=/srv/polinetwork/compose/polinetwork-cd
cd "$PN_REPO"
git fetch --prune origin
git merge --ff-only origin/vm
test "$(git rev-parse HEAD)" = \
  ecf254d845be189625981c8aba7858cf09b9b09e
git status --short --branch
```

From the operator workstation, stream the Azure account key and the exact
downloaded active-organization `restic.pass` into protected VM files. Neither
secret is printed or placed in a command argument:

```zsh
test -s "$HOME/Downloads/restic.pass"

az keyvault secret show \
  --vault-name kv-polinetwork \
  --name zerobyte-azure-storage-account-key \
  --query value --output tsv |
  tr -d '\r\n' |
  ssh pn-vm01 'sudo install -d -o root -g root -m 0700 \
    /srv/polinetwork/state/zerobyte/secrets && \
    sudo install -o root -g root -m 0600 /dev/stdin \
    /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key'

ssh pn-vm01 'sudo install -d -o root -g root -m 0700 \
  /srv/polinetwork/state/zerobyte/secrets && \
  sudo install -o root -g root -m 0600 /dev/stdin \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key' \
  < "$HOME/Downloads/restic.pass"
```

On the VM, verify only file metadata and run the repository-independent direct
recovery:

```zsh
sudo stat -c '%U:%G %a %s %n' \
  /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key

sudo core/zerobyte/openbao-snapshot/disaster-restore.sh
```

Acceptance: Restic finds the `pn-vm01` backup, its full repository check has no
errors, and the selected restored file is
`openbao-20260812T131252Z.snap` with SHA-256
`5fdd378147f22a3670103e57f28d2ca8697548fce7cbf04b1bd950a52a8750c6`.
Leave the two temporary secret files and restored snapshot in place until the
production OpenBao restore has passed. Do not initialize OpenBao yet; the exact
restored path reported by this command is an input to the next guarded step.

Operator result: both staged files have the required `root:root` ownership and
mode `0600` (88-byte Azure account key and 64-byte active-organization
`restic.pass`). Recovery did not reach Restic: Docker failed while resolving
the pinned Zerobyte image because its containerd metadata references the
manifest blob
`sha256:647706f3e44365e6ba8d8e9094efe57bcd36682a1bab4aa23a132d800bd9ad38`,
but that blob is absent from the applications disk. This is stale image-cache
state retained below `/srv/polinetwork/applications`; it is not a backup,
credential or Azure failure.

Proposed narrow repair: remove only the broken pinned-image reference through
Docker and pull it again. No container exists and the staged recovery inputs
remain untouched:

```zsh
PN_ZEROBYTE_IMAGE='ghcr.io/nicotsx/zerobyte:v0.41@sha256:647706f3e44365e6ba8d8e9094efe57bcd36682a1bab4aa23a132d800bd9ad38'

docker image inspect "$PN_ZEROBYTE_IMAGE" \
  --format 'id={{.Id}} repo-digests={{json .RepoDigests}}' || true
docker image rm --force "$PN_ZEROBYTE_IMAGE" || true
docker pull "$PN_ZEROBYTE_IMAGE"

sudo core/zerobyte/openbao-snapshot/disaster-restore.sh
unset PN_ZEROBYTE_IMAGE
```

If the pull reports the same missing blob after the Docker-level image removal,
stop at that error. The next repair would remove the single stale containerd
content record after confirming its namespace and lease references; do not
wipe either runtime root.

Operator result: Docker successfully untagged and deleted the stale Zerobyte
manifest record. The next pull no longer failed on that blob; it instead exposed
that the containerd content plugin's required
`io.containerd.content.v1.content/ingest` directory is absent. Consequently
both the explicit pull and the recovery script failed before downloading any
image. No recovery data or secret was changed.

The containerd project documents `blobs` and `ingest` as the two directories
owned by its content plugin and warns against editing that plugin storage
directly while containerd runs. Because the host has no containers, first use
a controlled service restart to let the plugin initialize its own directory;
do not create or delete plugin paths manually:

```zsh
sudo systemctl restart containerd.service docker.service
systemctl is-active containerd.service docker.service

sudo stat -c '%U:%G %a %F %n' \
  /srv/polinetwork/applications/containerd/io.containerd.content.v1.content \
  /srv/polinetwork/applications/containerd/io.containerd.content.v1.content/ingest

PN_ZEROBYTE_IMAGE='ghcr.io/nicotsx/zerobyte:v0.41@sha256:647706f3e44365e6ba8d8e9094efe57bcd36682a1bab4aa23a132d800bd9ad38'
docker pull "$PN_ZEROBYTE_IMAGE"
sudo core/zerobyte/openbao-snapshot/disaster-restore.sh
unset PN_ZEROBYTE_IMAGE
```

If the `stat` of `ingest` fails, or the pull still cannot create an ingest, stop
before the pull/recovery continuation. That would prove plugin initialization
cannot repair the retained runtime root and justify quarantining the clean
host's cache under stopped services rather than manipulating containerd's
internal directories in place.

Operator result: containerd became active, but Docker failed to restart and
remained activating. The content-plugin root exists as `root:root` mode `0755`,
while `ingest` is still absent. The guarded stop condition was reached; no pull
or recovery retry is authorized yet.

Proposed read-only diagnosis: capture the complete systemd failure, both daemon
logs from this boot, the tracked runtime roots, and the top-level plugin layout.
Do not create `ingest`, delete runtime data, or restart either daemon during
this inspection:

```zsh
sudo systemctl status docker.service containerd.service --no-pager --full
sudo journalctl -b -u docker.service -u containerd.service \
  --no-pager --output=short-iso -n 200

sudo containerd config dump | sed -n '1,45p'
sudo stat -c '%U:%G %a %F %n' \
  /srv/polinetwork/applications/docker \
  /srv/polinetwork/applications/containerd \
  /srv/polinetwork/applications/containerd/io.containerd.content.v1.content

sudo find /srv/polinetwork/applications/containerd \
  -mindepth 1 -maxdepth 2 -printf '%y %u:%g %m %p\n' | sort
```

The output must distinguish a failed content-plugin initialization from a
Docker metadata dependency on the retained cache before the runtime roots are
quarantined. The VM still has no containers or volumes, so a cache reset is
feasible, but it remains a separately reviewed mutation.

Operator result: diagnosis confirms two independent runtime issues. Docker's
only startup error is `failed to load listeners: no sockets found via socket
activation`; its packaged unit uses `-H fd://`, but `docker.socket` was not
started with the direct service restart. Containerd itself starts cleanly, but
its retained root is inconsistent: metadata remains in `meta.db` while both
the content store's `blobs` and `ingest` directories are absent, and its
overlay snapshot directory had also previously been absent. This is a partial
runtime cache, not an application or recovery-state failure.

The host has already passed the explicit empty-runtime inventory: no container,
Compose project or Docker volume exists. The following repair is therefore
authorized within the clean-host rehearsal. It stops the socket and both
daemons, moves the two exact runtime roots into a same-filesystem reversible
quarantine, recreates empty parent roots with the tracked bootstrap modes, then
reruns the Git-backed bootstrap. It does not touch `/srv/polinetwork/state`,
the staged recovery credentials, Git, Azure or either mount itself.

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
git fetch --prune origin
git merge --ff-only origin/vm
test "$(git rev-parse HEAD)" = \
  3d813354f5aa6faa6ab25611c4839f063475bdc8

PN_RUNTIME_QUARANTINE=/srv/polinetwork/applications/runtime-quarantine-20260812T1410Z
test ! -e "$PN_RUNTIME_QUARANTINE"

sudo systemctl stop docker.socket docker.service containerd.service
sudo install -d -o root -g root -m 0700 "$PN_RUNTIME_QUARANTINE"

sudo mv /srv/polinetwork/applications/docker \
  "$PN_RUNTIME_QUARANTINE/docker"
sudo mv /srv/polinetwork/applications/containerd \
  "$PN_RUNTIME_QUARANTINE/containerd"

sudo install -d -o root -g root -m 0711 \
  /srv/polinetwork/applications/docker \
  /srv/polinetwork/applications/containerd

sudo systemctl reset-failed docker.service docker.socket containerd.service
sudo bootstrap/bootstrap-host.sh
```

Verify that socket activation and the freshly initialized content store are
now complete before pulling anything:

```zsh
systemctl is-active docker.socket docker.service containerd.service
sudo stat -c '%U:%G %a %F %n' \
  /srv/polinetwork/applications/containerd/io.containerd.content.v1.content/blobs \
  /srv/polinetwork/applications/containerd/io.containerd.content.v1.content/ingest
docker info --format \
  'DockerRootDir={{.DockerRootDir}} Driver={{.Driver}} LoggingDriver={{.LoggingDriver}}'
docker ps -a
docker volume ls
```

Acceptance: all three units are active, both content-store directories exist,
Docker still reports no containers or volumes, and its data root remains the
applications disk. Keep the quarantine until OpenBao recovery and the core
bootstrap pass; it is rollback evidence and must not yet be deleted.

The tracked bootstrap was updated to explicitly enable and start
`docker.socket`, and to require the socket in its active-host fast path. The fix
was syntax-checked and published as signed Conventional Commit `3d81335`
(`fix(bootstrap): enable Docker socket explicitly`).

Operator result: the quarantined-root bootstrap produced a clean runtime: the
socket, Docker and containerd are all active; Docker uses the applications disk
with `overlayfs` and `local` logging; and there are no containers or volumes.
However, a completely fresh custom containerd root still did not materialize
`blobs` or `ingest` at daemon startup. This proves the missing parents are an
initialization requirement of our non-default root, rather than damage that
survived quarantine.

The tracked bootstrap now idempotently creates the content plugin's documented
store skeleton (`blobs/sha256` and `ingest`, root-owned mode `0755`) before
starting containerd. The script and documentation change passed shell syntax
and whitespace validation and was published as signed Conventional Commit
`2e1b478` (`fix(bootstrap): initialize containerd content store`).

Proposed continuation: update the VM, rerun the tracked bootstrap to initialize
the fresh root while no containers exist, verify the store, then retry the
pinned image pull and direct recovery:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
git fetch --prune origin
git merge --ff-only origin/vm
test "$(git rev-parse HEAD)" = \
  2e1b47806b47bbd37aa5e6527ffcd0999fc01c0d

sudo bootstrap/bootstrap-host.sh

systemctl is-active docker.socket docker.service containerd.service
sudo stat -c '%U:%G %a %F %n' \
  /srv/polinetwork/applications/containerd/io.containerd.content.v1.content/blobs \
  /srv/polinetwork/applications/containerd/io.containerd.content.v1.content/blobs/sha256 \
  /srv/polinetwork/applications/containerd/io.containerd.content.v1.content/ingest

PN_ZEROBYTE_IMAGE='ghcr.io/nicotsx/zerobyte:v0.41@sha256:647706f3e44365e6ba8d8e9094efe57bcd36682a1bab4aa23a132d800bd9ad38'
docker pull "$PN_ZEROBYTE_IMAGE"
sudo core/zerobyte/openbao-snapshot/disaster-restore.sh
unset PN_ZEROBYTE_IMAGE
```

Acceptance remains the exact native snapshot and SHA-256 recorded above. Keep
the runtime quarantine and both recovery-secret files until the restored
OpenBao instance has passed its application-level checks.

Operator result: the corrected bootstrap initialized the custom containerd
content store, the pinned Zerobyte image downloaded successfully, and direct
Azure recovery completed. Restic found snapshot `8dfb63fb`, checked all 14 of
14 repository objects with no errors, and restored four files/directories. The
selected native snapshot is
`/srv/polinetwork/state/zerobyte/restore-tests/openbao-disaster-20260812T141643Z-1177454/openbao-20260812T131252Z.snap`;
its SHA-256 is exactly
`5fdd378147f22a3670103e57f28d2ca8697548fce7cbf04b1bd950a52a8750c6`.
The full-VM-loss backup retrieval and byte-integrity gate has passed without
the deleted Zerobyte database.

### Full bootstrap rehearsal: restore production OpenBao state

Status: proposed, awaiting operator output. The production state directory is
empty. Start the tracked Compose project without its active-only wait gate,
because an uninitialized OpenBao correctly reports unhealthy. Verify the
recovered snapshot once more, then copy it into the temporary container
filesystem:

```zsh
PN_OPENBAO_SNAPSHOT=/srv/polinetwork/state/zerobyte/restore-tests/openbao-disaster-20260812T141643Z-1177454/openbao-20260812T131252Z.snap
test "$(sudo sha256sum "$PN_OPENBAO_SNAPSHOT" | awk '{print $1}')" = \
  5fdd378147f22a3670103e57f28d2ca8697548fce7cbf04b1bd950a52a8750c6

cd /srv/polinetwork/compose/polinetwork-cd/infra/openbao
docker compose up -d --pull always
docker compose ps
sleep 3
docker compose exec -T openbao sh -c '
  bao status
  code=$?
  test "$code" -eq 0 -o "$code" -eq 2
'

sudo docker compose cp "$PN_OPENBAO_SNAPSHOT" \
  openbao:/tmp/openbao-production-restore.snap
```

Initialize only the empty temporary cluster so that it can authorize the
forced Raft restore. The temporary recovery material and root token remain in
a mode-`0600` file inside the container, are never printed, and are deleted as
part of the same command. The accepted snapshot then replaces that temporary
cluster state:

```zsh
sudo docker compose exec -T --user 0:0 openbao sh -ec '
  umask 077
  init_file=/tmp/openbao-production-init.json
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

docker compose restart openbao
docker compose up -d --wait --wait-timeout 120
docker compose ps
docker compose exec -T openbao bao status
```

Finally, verify restored application-level state using the retained `pnadmin`
password from the approved break-glass store. The password is read silently by
the operator shell and streamed to `bao write` through stdin using the CLI's
`password=-` input convention; it is not placed in an argument or file:

```zsh
read -r -s 'PN_OPENBAO_ADMIN_PASSWORD?OpenBao pnadmin password: '
printf '\n'
printf '%s\n' "$PN_OPENBAO_ADMIN_PASSWORD" |
  docker compose exec -T openbao sh -ec '
    token="$(bao write -field=token \
      auth/userpass/login/pnadmin password=-)"
    BAO_TOKEN="$token" bao kv get -field=message \
      -mount=secret apps/canary | grep -qx openbao-agent-ok
    BAO_TOKEN="$token" bao token revoke -self >/dev/null 2>&1 || true
    unset token
  '
unset PN_OPENBAO_ADMIN_PASSWORD PN_OPENBAO_SNAPSHOT
```

Acceptance: Compose reports OpenBao healthy, `bao status` reports initialized,
unsealed, Raft and active HA state, and the restored `pnadmin` identity reads
the exact canary value. Do not remove the Restic recovery key, recovered
snapshot or runtime quarantine until this gate passes.

Operator result: image pulls succeeded, but Compose rejected `tls-init` before
creating either service container: `mode=0700` was parsed as a second tmpfs
mount path. The cause is YAML flow-sequence syntax in
`tmpfs: [/tmp:size=16m,mode=0700]`; its unquoted comma separates list items.
The other repository tmpfs declarations use block sequences and are unaffected.
No OpenBao initialization or snapshot mutation occurred.

The single flow entry is now quoted as one scalar. Whitespace validation passed
and the fix was published as signed Conventional Commit `11825af`
(`fix(openbao): quote tmpfs mount options`). Proposed retry:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
git fetch --prune origin
git merge --ff-only origin/vm
test "$(git rev-parse HEAD)" = \
  11825af6c7571dbabed8ec12938349e1697cb6bb

cd infra/openbao
docker compose config --quiet
docker compose down --remove-orphans
docker compose up -d --pull always
docker compose ps
sleep 3
docker compose exec -T openbao sh -c '
  bao status
  code=$?
  test "$code" -eq 0 -o "$code" -eq 2
'
```

Acceptance for this retry is a running uninitialized OpenBao (`Initialized
false`), after which the already-recorded snapshot-copy and forced-restore
commands continue unchanged.

Operator result: the corrected Compose file parsed, removed the prior default
network and recreated the project. Both images are available and the OpenBao
container definition was created, but it was not started because the one-shot
`tls-init` dependency exited with status 1. No OpenBao API, initialization or
Raft restore command ran.

Proposed read-only diagnosis: inspect the full one-shot log, exit metadata and
the host TLS directory without modifying a potentially partial certificate
set:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/openbao
docker compose ps -a
docker compose logs --no-color --timestamps tls-init
docker inspect infra-openbao-tls-init-1 \
  --format 'exit={{.State.ExitCode}} error={{json .State.Error}} oom={{.State.OOMKilled}}'

sudo find /srv/polinetwork/state/openbao/tls \
  -mindepth 1 -maxdepth 1 -printf '%f %u:%g %m %s\n' | sort
```

Do not rerun `up`, delete TLS files or copy the snapshot until the exact
initializer failure is reviewed. If a partial TLS set exists, the tracked guard
will intentionally refuse to replace it.

Operator result: TLS key and certificate generation, CSR signing, CA
verification and hostname verification all succeeded. The final
`install -o 100 -g 1000 -m ...` failed because `install` transferred ownership
before applying the final mode; after that chown, the capability-restricted
root process was no longer the file owner and lacked `CAP_FOWNER`. The failed
attempt left only known generated `ca.crt` (root-owned, mode `0644`, 1891 bytes)
and `tls.crt` (UID 100/GID 1000, mode `0600`, 1777 bytes); `tls.key` was never
written. These files have never been used by OpenBao and contain no restored
state.

The initializer now installs the leaf certificate and key with their final
modes while root-owned, then performs a final chown. This retains the existing
minimal `CHOWN` and `DAC_OVERRIDE` capability set instead of adding
`CAP_FOWNER`. The change passed whitespace validation and was published as
signed Conventional Commit `b6ddbc3` (`fix(openbao): finalize TLS files before
chown`).

Proposed retry: update the VM and validate Compose, remove only the two exact
disposable partial outputs after stopping/removing the failed project, then
allow the idempotent initializer to generate a complete set:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
git fetch --prune origin
git merge --ff-only origin/vm
test "$(git rev-parse HEAD)" = \
  b6ddbc396208c32cbf662e2b2e6dc96b51d59c91

cd infra/openbao
docker compose config --quiet
docker compose down --remove-orphans

sudo test ! -e /srv/polinetwork/state/openbao/tls/tls.key
sudo rm -- \
  /srv/polinetwork/state/openbao/tls/ca.crt \
  /srv/polinetwork/state/openbao/tls/tls.crt

docker compose up -d --pull always
docker compose ps -a
sleep 3
docker compose exec -T openbao sh -c '
  bao status
  code=$?
  test "$code" -eq 0 -o "$code" -eq 2
'

sudo find /srv/polinetwork/state/openbao/tls \
  -mindepth 1 -maxdepth 1 -printf '%f %u:%g %m %s\n' | sort
```

The two partial public certificate files are removed permanently but are
disposable and regenerated in this same operation. Acceptance is a complete
three-file TLS set and a running OpenBao reporting `Initialized false`; only
then may the verified snapshot be copied into the container.

Operator result: the corrected `tls-init` exited successfully, OpenBao started
with its health check in the starting state, and the complete TLS set exists:
`ca.crt` and `tls.crt` are mode `0644`; `tls.key` is mode `0600`; all are owned
by runtime UID 100/GID 1000 after the OpenBao entrypoint prepared its mounted
state tree. The CA certificate is public and the leaf private key retains its
required restrictive mode. The immediate API check produced no reported
status, consistent with running less than one second when inspected.

Proposed readiness gate, with no mutation:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/openbao
sleep 5
docker compose ps -a
docker compose exec -T openbao sh -c '
  bao status
  code=$?
  test "$code" -eq 0 -o "$code" -eq 2
'
```

Acceptance is `Initialized false` from the API. If the command instead fails
or the container is no longer running, inspect `docker compose logs --tail 80
openbao` before any snapshot copy.

Operator result: OpenBao entered a restart loop before exposing its API. Its
only storage error is `open /openbao/file/raft/vault.db: no such file or
directory`: the clean state disk has no `raft` directory, while the previous
deployment had created it outside the current Compose project. TLS initialization
remains successful and no Raft database or snapshot restore exists yet.

The one-shot service is now named `state-init` and prepares both pieces of
non-secret filesystem state: it creates `/state/raft`, enforces UID 100/GID
1000 and mode `0700`, then generates or validates TLS. On normal converges it
does not change an already-correct Raft directory. OpenBao depends on this
successful one-shot service. The source and concise README update passed
whitespace validation and were published as signed Conventional Commit
`dd41902` (`fix(openbao): initialize empty Raft storage`).

Proposed retry, preserving the valid TLS set and recovered snapshot:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
git fetch --prune origin
git merge --ff-only origin/vm
test "$(git rev-parse HEAD)" = \
  dd419027cee163a03278d8256ef1119cfc700586

cd infra/openbao
docker compose config --quiet
docker compose down --remove-orphans
docker compose up -d --pull always
docker compose ps -a
sleep 5
docker compose exec -T openbao sh -c '
  bao status
  code=$?
  test "$code" -eq 0 -o "$code" -eq 2
'

sudo stat -c '%U:%G %a %F %n' \
  /srv/polinetwork/state/openbao/raft
```

Acceptance is `state-init` exited 0, the Raft directory is UID 100/GID 1000
mode `0700`, and OpenBao reports `Initialized false`. No TLS or restore file
needs deletion for this retry.

Operator result: `state-init` exited 0, OpenBao was started, and the Raft
directory has the exact runtime ownership and mode `0700`. The API probe raced
the container at less than one second of runtime and received connection
refused; this is not a storage-initialization failure.

Proposed bounded readiness check: allow up to 60 seconds for the API and Azure
seal integration, accepting both initialized status 0 and uninitialized status
2. Print detailed state only after readiness or on timeout:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/openbao
PN_OPENBAO_READY=false
PN_OPENBAO_ATTEMPT=0

while [ "$PN_OPENBAO_ATTEMPT" -lt 30 ]; do
  if docker compose exec -T openbao sh -c '
    bao status >/dev/null 2>&1
    code=$?
    test "$code" -eq 0 -o "$code" -eq 2
  '; then
    PN_OPENBAO_READY=true
    break
  fi
  PN_OPENBAO_ATTEMPT=$((PN_OPENBAO_ATTEMPT + 1))
  sleep 2
done

if [ "$PN_OPENBAO_READY" = true ]; then
  docker compose ps -a
  docker compose exec -T openbao bao status || test "$?" -eq 2
else
  docker compose ps -a
  docker compose logs --no-color --tail 80 openbao
  false
fi

unset PN_OPENBAO_READY PN_OPENBAO_ATTEMPT
```

Acceptance remains a stable running container reporting `Initialized false`.
This polling behavior must later replace fixed sleeps in the converged recovery
entry point.

Operator result: local state initialization remains correct, but OpenBao cannot
finish Azure seal configuration. Its log shows an HTTPS timeout to the resolved
Key Vault address `13.69.111.192:443`. The process subsequently restarted its
startup sequence, while the container remained up with health `starting`.
Because direct Azure Restic access already passed from this host, the current
leading hypothesis is a container default route through internal `pn-secrets`
instead of egress-capable `pn-edge`; no snapshot has been copied or applied.

Proposed read-only network diagnosis:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/openbao

curl --silent --show-error --output /dev/null \
  --connect-timeout 5 --write-out 'host_keyvault_http=%{http_code}\n' \
  'https://kv-polinetwork.vault.azure.net/'

docker inspect infra-openbao-openbao-1 \
  --format '{{json .NetworkSettings.Networks}}'
docker network inspect pn-secrets pn-edge \
  --format '{{.Name}} internal={{.Internal}} gateway={{(index .IPAM.Config 0).Gateway}}'

docker exec infra-openbao-openbao-1 cat /proc/net/route
docker exec infra-openbao-openbao-1 cat /etc/resolv.conf
docker exec infra-openbao-openbao-1 sh -c \
  'command -v wget || true; command -v curl || true; command -v ip || true'
```

If `wget` or `curl` is present, run one non-secret in-container endpoint probe
using the available command and a five-second timeout; otherwise the route
table and endpoint metadata are sufficient for the next change. Do not expose
Azure credentials or query a key path during this test.

Operator result: host HTTPS reaches Key Vault and receives HTTP 404. Container
metadata confirms `pn-edge` has gateway `172.30.0.1`, `pn-secrets` has no
gateway, and `/proc/net/route` selects the `pn-edge` gateway as its default.
The wrong-gateway hypothesis is rejected. However, DNS answers differed: the
host reached `13.69.111.192`, while the container's `wget` resolved
`13.69.64.72` and timed out.

Proposed read-only isolation: prove whether generic container HTTPS works and
whether the container-selected Key Vault frontend is also unreachable when
forced from the host:

```zsh
docker exec infra-openbao-openbao-1 sh -c '
  ip route
  wget -T 5 -S -O /dev/null https://ghcr.io/v2/ 2>&1
'

getent ahostsv4 kv-polinetwork.vault.azure.net
curl --silent --show-error --output /dev/null \
  --connect-timeout 5 \
  --resolve 'kv-polinetwork.vault.azure.net:443:13.69.64.72' \
  --write-out 'host_forced_13_69_64_72_http=%{http_code}\n' \
  'https://kv-polinetwork.vault.azure.net/'

docker exec infra-openbao-openbao-1 sh -c '
  wget -T 5 --no-check-certificate -S -O /dev/null \
    https://13.69.111.192/ 2>&1
'
```

HTTP 401 from `ghcr.io/v2/` proves general container NAT/TLS egress. If the
host also times out when forced to `13.69.64.72`, Docker is exonerated for the
Key Vault timeout and the next action is DNS/frontend handling. If generic
container HTTPS also times out, inspect Docker forwarding/NAT instead. The
direct-IP container probe deliberately disables only certificate verification
because its purpose is TCP/TLS reachability to the host-working address; it
sends no credential.

Operator result: host DNS lists three Key Vault frontends. The host reaches
both its normal `13.69.111.192` selection and forced `13.69.64.72` with HTTP
404, while the container times out even when directly targeting the
host-working `13.69.111.192`. Azure frontend selection and DNS are therefore
exonerated. The generic container HTTPS result was not included, so Docker
forwarding/NAT remains the leading but not yet proven cause.

Proposed final read-only egress diagnosis:

```zsh
docker exec infra-openbao-openbao-1 sh -c '
  wget -T 5 -S -O /dev/null https://ghcr.io/v2/ 2>&1
'

sysctl net.ipv4.ip_forward net.ipv4.conf.all.forwarding
sudo iptables -S FORWARD 2>&1
sudo iptables -t nat -S DOCKER 2>&1
sudo iptables-save 2>/dev/null | grep -E \
  '172\.30\.0\.0/24|172\.30\.3\.0/24|DOCKER|MASQUERADE' | tail -80

sudo nft list tables 2>&1
sudo journalctl -b -u docker.service --no-pager -n 120 | \
  grep -Ei 'firewall|forward|iptables|nft|bridge|error|warning' || true
```

HTTP 401 from GHCR would disprove a general NAT failure and require inspection
of destination-specific filtering. A GHCR timeout together with missing
MASQUERADE/FORWARD rules proves Docker bridge egress was not programmed after
the clean runtime rebuild. These commands do not alter packet-filter state.

Operator result: GHCR also times out from OpenBao, proving the issue is general
HTTPS egress from that container rather than Azure-specific. Docker has a
FORWARD policy of DROP but explicit current `pn-edge` ACCEPT rules, plus a
current `172.30.0.0/24` MASQUERADE rule. `DOCKER-USER` has no reported deny
rule. The daemon's nftables cleanup messages are benign absent-table notices;
the active firewall tables and iptables-compatible Docker chains exist.
The unprivileged shell lacks `sysctl` in PATH, so forwarding state remains
unconfirmed.

The earlier successful direct Restic recovery used Docker's default bridge
after the runtime rebuild, making a `pn-edge`-specific route/MTU problem more
likely. Proposed isolated A/B test using the already-present Alpine/OpenSSL
image; the two containers are ephemeral, receive no mounts or secrets, and are
removed automatically:

```zsh
cat /proc/sys/net/ipv4/ip_forward
cat /proc/sys/net/ipv4/conf/all/forwarding

docker run --rm --network bridge --entrypoint /bin/sh \
  alpine/openssl:3.5.4 -c '
    echo default-bridge
    ip route
    ping -c 1 -W 2 1.1.1.1 || true
    wget -T 5 -S -O /dev/null https://ghcr.io/v2/ 2>&1
  '

docker run --rm --network pn-edge --entrypoint /bin/sh \
  alpine/openssl:3.5.4 -c '
    echo pn-edge
    ip route
    ping -c 1 -W 2 1.1.1.1 || true
    wget -T 5 -S -O /dev/null https://ghcr.io/v2/ 2>&1
  '

ip -br link show | grep -E '^(docker0|br-bac4e33190ed)[[:space:]]'
ip route show

sudo iptables -t nat -L POSTROUTING -v -n --line-numbers | \
  grep -E 'Chain|172\.30\.0\.0/24|172\.17\.0\.0/16'
sudo iptables -L DOCKER-FORWARD -v -n --line-numbers | \
  grep -E 'Chain|br-bac4e33190ed|docker0'
```

If the default bridge succeeds and `pn-edge` fails, compare MTU and rule
counters and recreate only `pn-edge` with a tracked MTU correction if proven.
If both fail while forwarding is enabled, inspect post-NAT host firewall and
the runtime restart sequence. If forwarding is `0`, correct that host bootstrap
dependency instead of changing Compose.

Operator result: the default bridge reaches `1.1.1.1` and GHCR (HTTP 401),
while `pn-edge` reaches neither. Packet counters increment on the current
`pn-edge` forwarding and MASQUERADE rules, so firewall programming is present.
The host route table reveals the actual cause: every `172.30.x.0/24` has both a
current Docker bridge and an orphaned link-down bridge from before the runtime
root quarantine. In particular, current `pn-edge` is `br-bac4e33190ed`, while
orphan `br-5e2a3c72bf51` advertises the same subnet. Reply routing can select
the orphan and black-hole traffic. This is transient kernel state created by
quarantining Docker's metadata while its old bridge devices remained; it is
not a Compose MTU or Azure issue.

Before removing kernel interfaces, resolve all current bridge identities and
show the four duplicate pairs:

```zsh
docker network inspect pn-edge pn-app pn-db pn-secrets \
  --format '{{.Name}} br-{{slice .Id 0 12}} subnet={{(index .IPAM.Config 0).Subnet}}'

ip -br link show | grep -E \
  '^(br-(bac4e33190ed|5e2a3c72bf51|3707f52378ec|972a6495471c|0dd3add8fd88|b66dd5258b3b|2ee7d196e14a|14c6cbe657a8))[[:space:]]'
```

Expected current bridges from Docker/firewall evidence are `bac4e33190ed`,
`3707f52378ec`, `0dd3add8fd88` and `2ee7d196e14a`; expected orphans are
`5e2a3c72bf51`, `972a6495471c`, `b66dd5258b3b` and `14c6cbe657a8`. Delete
nothing unless Docker's identity map confirms all four distinctions.

Operator result: Docker's identity map matches all four expected current
bridges and subnets exactly. The other four named bridges all exist, are
link-down with no carrier, and are absent from Docker's current network IDs.
They are conclusively orphaned kernel devices and safe to remove within this
clean-host rehearsal.

Proposed guarded cleanup and egress recovery:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/openbao
docker compose down --remove-orphans

test "$(cat /sys/class/net/br-5e2a3c72bf51/operstate)" = down
test "$(cat /sys/class/net/br-972a6495471c/operstate)" = down
test "$(cat /sys/class/net/br-b66dd5258b3b/operstate)" = down
test "$(cat /sys/class/net/br-14c6cbe657a8/operstate)" = down

sudo systemctl stop docker.socket docker.service
sudo ip link delete dev br-5e2a3c72bf51 type bridge
sudo ip link delete dev br-972a6495471c type bridge
sudo ip link delete dev br-b66dd5258b3b type bridge
sudo ip link delete dev br-14c6cbe657a8 type bridge

sudo systemctl start docker.socket docker.service
systemctl is-active docker.socket docker.service containerd.service

ip route show | grep -E '^172\.30\.[0-3]\.0/24'

docker run --rm --network pn-edge --entrypoint /bin/sh \
  alpine/openssl:3.5.4 -c '
    ping -c 1 -W 2 1.1.1.1
    wget -T 5 -S -O /dev/null https://ghcr.io/v2/ 2>&1 || test "$?" -eq 1
  '

docker compose up -d --pull always
docker compose ps -a
```

The four deleted objects are only orphaned in-kernel bridge interfaces and are
not recoverable as those identities; they contain no data and must not be
recreated. Acceptance: exactly one route remains for each shared subnet, all
three runtime units are active, `pn-edge` ping succeeds, GHCR responds HTTP
401, and OpenBao stays running. Then use the bounded API readiness gate before
copying the snapshot.

Operator result: after orphan-bridge cleanup and project restart, OpenBao stays
running and successfully completes Azure Key Vault seal-wrapper discovery. Its
configuration reports the expected vault `kv-polinetwork` and key
`openbao-unseal`; the earlier network timeout is gone. Logs now report only the
expected empty-cluster condition: the security barrier is not initialized and
no stored unseal key exists yet. The production restore precondition has
passed.

Proposed snapshot application. Reassert the exact source path and hash, confirm
the API reports uninitialized, then copy it into the container:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/openbao
PN_OPENBAO_SNAPSHOT=/srv/polinetwork/state/zerobyte/restore-tests/openbao-disaster-20260812T141643Z-1177454/openbao-20260812T131252Z.snap

test "$(sudo sha256sum "$PN_OPENBAO_SNAPSHOT" | awk '{print $1}')" = \
  5fdd378147f22a3670103e57f28d2ca8697548fce7cbf04b1bd950a52a8750c6
docker compose exec -T openbao bao status || test "$?" -eq 2

sudo docker compose cp "$PN_OPENBAO_SNAPSHOT" \
  openbao:/tmp/openbao-production-restore.snap
```

Create a temporary initialization solely to authorize the force restore. Its
generated recovery key and root token are kept inside a mode-`0600` temporary
file, never printed, and deleted in the same command after the accepted
snapshot replaces the temporary state:

```zsh
sudo docker compose exec -T --user 0:0 openbao sh -ec '
  umask 077
  init_file=/tmp/openbao-production-init.json
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

docker compose restart openbao
docker compose up -d --wait --wait-timeout 120
docker compose ps -a
docker compose exec -T openbao bao status
unset PN_OPENBAO_SNAPSHOT
```

Acceptance: OpenBao becomes healthy and reports initialized, unsealed, Raft
storage and active HA leadership with the restored cluster identity. Keep all
break-glass inputs and quarantine until the subsequent `pnadmin` canary read
passes.

Operator result: production snapshot application passed. `state-init` exited
0 and OpenBao is healthy. It reports Azure Key Vault seal, initialized true,
sealed false, Raft storage, active HA mode and committed/applied index 473. The
restored cluster name `vault-cluster-4f62eeba` and cluster ID
`5ab52aac-3719-74ab-b9ce-99e09298697e` exactly match the pre-destruction
instance. The clean-host native Raft restore is operationally successful.

Proposed final application-level recovery gate. Read the retained `pnadmin`
password silently in zsh and stream it through stdin; OpenBao's `password=-`
input prevents it from appearing in process arguments. Keep the resulting
token only inside the container shell, use it for the exact restored canary
read, then revoke it:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/openbao
read -r -s 'PN_OPENBAO_ADMIN_PASSWORD?OpenBao pnadmin password: '
printf '\n'

printf '%s\n' "$PN_OPENBAO_ADMIN_PASSWORD" |
  docker compose exec -T openbao sh -ec '
    token="$(bao write -field=token \
      auth/userpass/login/pnadmin password=-)"
    test -n "$token"
    BAO_TOKEN="$token" bao kv get -field=message \
      -mount=secret apps/canary | grep -qx openbao-agent-ok
    BAO_TOKEN="$token" bao token revoke -self >/dev/null 2>&1 || true
    unset token
    printf "Restored pnadmin login and canary read passed.\n"
  '

unset PN_OPENBAO_ADMIN_PASSWORD

docker compose exec -T openbao sh -ec '
  test ! -e /tmp/openbao-production-init.json
  test ! -e /tmp/openbao-production-restore.snap
'
```

Acceptance: the explicit success line is printed, the recovered identity and
secret are usable, the short-lived verification token is revoked, and neither
temporary restore file remains. Only after this passes may recovery inputs be
cleaned and doco.cd credentials be regenerated from restored OpenBao.

Operator result: the restored userpass endpoint responded, but rejected the
first login as invalid username or password. The verification command streamed
`printf '%s\n'`, appending a newline; OpenBao's `password=-` reads stdin as the
field value, so this can change the credential bytes. Token creation failed and
no OpenBao mutation occurred.

Proposed corrected retry: stream the exact password bytes without a newline.
The operator is prompted again because the prior shell correctly unset its
variable:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/openbao
read -r -s 'PN_OPENBAO_ADMIN_PASSWORD?OpenBao pnadmin password: '
printf '\n'

printf '%s' "$PN_OPENBAO_ADMIN_PASSWORD" |
  docker compose exec -T openbao sh -ec '
    token="$(bao write -field=token \
      auth/userpass/login/pnadmin password=-)"
    test -n "$token"
    BAO_TOKEN="$token" bao kv get -field=message \
      -mount=secret apps/canary | grep -qx openbao-agent-ok
    BAO_TOKEN="$token" bao token revoke -self >/dev/null 2>&1 || true
    unset token
    printf "Restored pnadmin login and canary read passed.\n"
  '

PN_OPENBAO_VERIFY_STATUS=$?
unset PN_OPENBAO_ADMIN_PASSWORD
test "$PN_OPENBAO_VERIFY_STATUS" -eq 0
unset PN_OPENBAO_VERIFY_STATUS
```

If this exact-byte attempt is still rejected, stop rather than retrying: that
would prove the supplied break-glass password does not match the credential in
the accepted 13:12 UTC snapshot, and recovery validation must use another
restored authentication identity or an authorized recovery-key procedure.

Operator result: exact-byte stdin authentication succeeded. The restored
`pnadmin` identity obtained a token, read `secret/apps/canary` with the exact
value `openbao-agent-ok`, and revoked the verification token. Clean-host
OpenBao disaster recovery has passed at storage, cluster, identity and
application-secret layers.

### Full bootstrap rehearsal: remove temporary recovery artifacts

Status: proposed, awaiting operator output. Canonical backup custody remains in
Azure Blob, the Azure account key remains in Key Vault, and `restic.pass`
remains off-host. The recovered production OpenBao no longer depends on any
temporary artifact below `zerobyte/restore-tests`, either staged direct-recovery
credential, or the pre-reset Docker/containerd quarantine.

First reassert the healthy recovered service and inspect the exact cleanup
targets without reading secret content:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/openbao
test "$(docker inspect -f '{{.State.Health.Status}}' \
  infra-openbao-openbao-1)" = healthy

sudo stat -c '%U:%G %a %s %n' \
  /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key
sudo du -sh \
  /srv/polinetwork/state/zerobyte/restore-tests \
  /srv/polinetwork/applications/runtime-quarantine-20260812T1410Z
```

Remove only those exact temporary targets:

```zsh
sudo rm -f -- \
  /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key
sudo rm -rf -- \
  /srv/polinetwork/state/zerobyte/restore-tests \
  /srv/polinetwork/applications/runtime-quarantine-20260812T1410Z
sudo rmdir /srv/polinetwork/state/zerobyte/secrets 2>/dev/null || true
```

Verify absence and continued OpenBao health:

```zsh
sudo test ! -e /srv/polinetwork/state/zerobyte/restore-tests
sudo test ! -e \
  /srv/polinetwork/applications/runtime-quarantine-20260812T1410Z
sudo test ! -e \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key
sudo test ! -e \
  /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key
test "$(docker inspect -f '{{.State.Health.Status}}' \
  infra-openbao-openbao-1)" = healthy
df -h /srv/polinetwork/state /srv/polinetwork/applications
printf 'Temporary recovery artifacts removed; OpenBao remains healthy.\n'
```

The local copies are permanently deleted; recovery remains possible by
restaging both protected inputs and retrieving the same Azure backup. Do not
delete the Azure repository, Key Vault secret, or off-host `restic.pass`.

Operator result: both temporary direct-recovery credentials, the restored test
copy and the quarantined obsolete runtime roots were removed. The state disk is
1% used with about 30 GB available; the applications disk is 2% used with about
59 GB available. OpenBao remained healthy. Canonical recovery sources are now
external again.

### Full bootstrap rehearsal: provision doco.cd identity

Status: proposed, awaiting operator output. Current committed references require
exactly these restored fields: `secret/core/cloudflared:tunnel_token`,
`secret/core/zerobyte:app_secret`,
`secret/core/zerobyte:azure_storage_account_key`, and
`secret/apps/canary:message`. Verify each by discarding its value, then converge
the narrow doco.cd policy/role and generate fresh AppRole files. No secret value
is printed or committed.

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/openbao
PN_OPENBAO_ADMIN_PASSWORD="$(systemd-ask-password 'OpenBao pnadmin password')"
BAO_TOKEN="$(
  printf '%s' "$PN_OPENBAO_ADMIN_PASSWORD" |
    docker compose exec -T openbao bao write -field=token \
      auth/userpass/login/pnadmin password=-
)"
unset PN_OPENBAO_ADMIN_PASSWORD
test -n "$BAO_TOKEN"
export BAO_TOKEN

docker exec -e BAO_TOKEN infra-openbao-openbao-1 sh -ec '
  bao kv get -field=tunnel_token -mount=secret core/cloudflared >/dev/null
  bao kv get -field=app_secret -mount=secret core/zerobyte >/dev/null
  bao kv get -field=azure_storage_account_key \
    -mount=secret core/zerobyte >/dev/null
  bao kv get -field=message -mount=secret apps/canary >/dev/null
  printf "All committed OpenBao secret references exist.\n"
'

docker exec -e BAO_TOKEN infra-openbao-openbao-1 sh -ec '
  bao auth list -format=json | grep -q approle/ || \
    bao auth enable approle >/dev/null
'

docker exec -i -e BAO_TOKEN infra-openbao-openbao-1 \
  bao policy write doco-cd - <<'POLICY'
path "secret/data/core/*" { capabilities = ["read"] }
path "secret/data/apps/*" { capabilities = ["read"] }
POLICY

docker exec -e BAO_TOKEN infra-openbao-openbao-1 bao write \
  auth/approle/role/doco-cd \
  token_policies=doco-cd \
  token_no_default_policy=true \
  token_period=24h \
  secret_id_num_uses=0 \
  secret_id_ttl=0 >/dev/null

docker exec --user 0:0 -e BAO_TOKEN infra-openbao-openbao-1 sh -ec '
  install -d -o 100 -g 1000 -m 0750 \
    /openbao/file/approle/doco-cd
  umask 077
  bao read -field=role_id auth/approle/role/doco-cd/role-id \
    > /openbao/file/approle/doco-cd/role-id
  bao write -field=secret_id -f auth/approle/role/doco-cd/secret-id \
    > /openbao/file/approle/doco-cd/secret-id
  chown 100:1000 \
    /openbao/file/approle/doco-cd/role-id \
    /openbao/file/approle/doco-cd/secret-id
  chmod 0400 \
    /openbao/file/approle/doco-cd/role-id \
    /openbao/file/approle/doco-cd/secret-id
'

docker exec -e BAO_TOKEN infra-openbao-openbao-1 \
  bao token revoke -self >/dev/null
unset BAO_TOKEN

sudo stat -c '%U:%G %a %s %n' \
  /srv/polinetwork/state/openbao/approle/doco-cd/role-id \
  /srv/polinetwork/state/openbao/approle/doco-cd/secret-id
```

Acceptance: all four fields exist, policy/role convergence succeeds, the admin
token is revoked, and both non-empty credentials are UID 100/GID 1000 mode
`0400`. Do not print either file. Starting doco.cd and allowing reconciliation
is the following separately observed gate.

Operator result: verification stopped on the first reference because
`secret/data/core/cloudflared` does not exist. The accepted snapshot predates
the doco.cd-era `secret/core/*` layout; this is not restore corruption. No
AppRole provisioning command was run. The temporary admin token remains active
in the operator shell and must be used only for a metadata-safe inventory, then
revoked.

Proposed field-by-field inventory with values discarded:

```zsh
test -n "$BAO_TOKEN"

for PN_SECRET_CHECK in \
  'core/cloudflared:tunnel_token' \
  'core/zerobyte:app_secret' \
  'core/zerobyte:azure_storage_account_key' \
  'apps/canary:message'
do
  PN_SECRET_PATH=${PN_SECRET_CHECK%%:*}
  PN_SECRET_FIELD=${PN_SECRET_CHECK#*:}
  if docker exec -e BAO_TOKEN infra-openbao-openbao-1 \
    bao kv get -field="$PN_SECRET_FIELD" -mount=secret \
    "$PN_SECRET_PATH" >/dev/null 2>&1
  then
    printf 'present %s:%s\n' "$PN_SECRET_PATH" "$PN_SECRET_FIELD"
  else
    printf 'missing %s:%s\n' "$PN_SECRET_PATH" "$PN_SECRET_FIELD"
  fi
done

unset PN_SECRET_CHECK PN_SECRET_PATH PN_SECRET_FIELD
docker exec -e BAO_TOKEN infra-openbao-openbao-1 \
  bao token revoke -self >/dev/null
unset BAO_TOKEN
```

The Cloudflare tunnel token was historically VM-local and was intentionally
removed in the clean-host cleanup; it must be reseeded from approved off-host
custody or replaced with a newly issued token. Zerobyte `app_secret` and
`azure_storage_account_key` remain externally recoverable from Key Vault names
`zerobyte-app-secret` and `zerobyte-azure-storage-account-key`. The canary is
expected to remain present from the restored snapshot. Populate only fields
reported missing in the next guarded step.

Operator result: all three post-snapshot runtime fields are missing and the
restored canary field is present. The temporary inventory token was revoked.
This exactly matches the boundary between the older accepted snapshot and the
new doco.cd secret layout.

Proposed external-secret reseed. From the authenticated operator workstation,
stream the two known Key Vault values into short-lived root-only VM files:

```zsh
az keyvault secret show \
  --vault-name kv-polinetwork \
  --name zerobyte-app-secret \
  --query value --output tsv |
  tr -d '\r\n' |
  ssh pn-vm01 'sudo install -d -o root -g root -m 0700 \
    /srv/polinetwork/state/bootstrap-secrets && \
    sudo install -o root -g root -m 0600 /dev/stdin \
    /srv/polinetwork/state/bootstrap-secrets/zerobyte-app-secret'

az keyvault secret show \
  --vault-name kv-polinetwork \
  --name zerobyte-azure-storage-account-key \
  --query value --output tsv |
  tr -d '\r\n' |
  ssh pn-vm01 'sudo install -d -o root -g root -m 0700 \
    /srv/polinetwork/state/bootstrap-secrets && \
    sudo install -o root -g root -m 0600 /dev/stdin \
    /srv/polinetwork/state/bootstrap-secrets/zerobyte-azure-storage-account-key'
```

On the VM, acquire a new short-lived admin token and enter the dedicated VM
Cloudflare tunnel token through a silent prompt. Use only the token retained in
approved off-host custody or a newly issued token for the same VM tunnel; never
reuse the AKS tunnel token:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/openbao
sudo stat -c '%U:%G %a %s %n' \
  /srv/polinetwork/state/bootstrap-secrets/zerobyte-app-secret \
  /srv/polinetwork/state/bootstrap-secrets/zerobyte-azure-storage-account-key

PN_OPENBAO_ADMIN_PASSWORD="$(systemd-ask-password 'OpenBao pnadmin password')"
BAO_TOKEN="$(
  printf '%s' "$PN_OPENBAO_ADMIN_PASSWORD" |
    docker compose exec -T openbao bao write -field=token \
      auth/userpass/login/pnadmin password=-
)"
unset PN_OPENBAO_ADMIN_PASSWORD
test -n "$BAO_TOKEN"
export BAO_TOKEN

PN_CLOUDFLARE_TUNNEL_TOKEN="$(
  systemd-ask-password 'Dedicated VM Cloudflare tunnel token'
)"
test -n "$PN_CLOUDFLARE_TUNNEL_TOKEN"
printf '%s' "$PN_CLOUDFLARE_TUNNEL_TOKEN" |
  docker exec -i -e BAO_TOKEN infra-openbao-openbao-1 \
    bao kv put -mount=secret core/cloudflared tunnel_token=- >/dev/null
unset PN_CLOUDFLARE_TUNNEL_TOKEN
```

Copy the two protected files into the container by file path, write both fields
in one KV-v2 version, and remove the container copies in the same shell:

```zsh
sudo docker cp \
  /srv/polinetwork/state/bootstrap-secrets/zerobyte-app-secret \
  infra-openbao-openbao-1:/tmp/zerobyte-app-secret
sudo docker cp \
  /srv/polinetwork/state/bootstrap-secrets/zerobyte-azure-storage-account-key \
  infra-openbao-openbao-1:/tmp/zerobyte-azure-storage-account-key

docker exec --user 0:0 -e BAO_TOKEN infra-openbao-openbao-1 sh -ec '
  chmod 0400 \
    /tmp/zerobyte-app-secret \
    /tmp/zerobyte-azure-storage-account-key
  bao kv put -mount=secret core/zerobyte \
    app_secret=@/tmp/zerobyte-app-secret \
    azure_storage_account_key=@/tmp/zerobyte-azure-storage-account-key \
    >/dev/null
  rm -f \
    /tmp/zerobyte-app-secret \
    /tmp/zerobyte-azure-storage-account-key
'

docker exec -e BAO_TOKEN infra-openbao-openbao-1 sh -ec '
  bao kv get -field=tunnel_token -mount=secret core/cloudflared >/dev/null
  bao kv get -field=app_secret -mount=secret core/zerobyte >/dev/null
  bao kv get -field=azure_storage_account_key \
    -mount=secret core/zerobyte >/dev/null
  bao kv get -field=message -mount=secret apps/canary >/dev/null
  printf "All committed OpenBao secret references exist.\n"
'

docker exec -e BAO_TOKEN infra-openbao-openbao-1 \
  bao token revoke -self >/dev/null
unset BAO_TOKEN

sudo rm -f -- \
  /srv/polinetwork/state/bootstrap-secrets/zerobyte-app-secret \
  /srv/polinetwork/state/bootstrap-secrets/zerobyte-azure-storage-account-key
sudo rmdir /srv/polinetwork/state/bootstrap-secrets
```

Acceptance: both staged Key Vault files are non-empty and mode `0600`, the
four-reference verification prints its success line, the admin token is
revoked, and the staging directory is removed. Secret values must never appear
in output. AppRole provisioning then resumes from the policy step.

Owner correction: the dedicated VM Cloudflare tunnel token must also have
canonical custody in Azure Key Vault. This closes the recovery gap exposed by
the clean-host test. It must not be stored in or shared with AKS; the VM tunnel
remains intentionally separate. The recovery contract and doco.cd README were
updated and published as signed Conventional Commit `2d466c4`
(`docs(bootstrap): externalize Cloudflare recovery token`).

The previous prompt-based Cloudflare reseed is superseded. On the operator
workstation, create a protected temporary file, enter the token silently, and
use Azure CLI's official `--file` input so the value never appears in a command
argument:

```zsh
PN_CLOUDFLARE_TOKEN_FILE="$(mktemp)"
chmod 0600 "$PN_CLOUDFLARE_TOKEN_FILE"
PN_CLOUDFLARE_TUNNEL_TOKEN="$(
  systemd-ask-password 'Dedicated VM Cloudflare tunnel token'
)"
test -n "$PN_CLOUDFLARE_TUNNEL_TOKEN"
printf '%s' "$PN_CLOUDFLARE_TUNNEL_TOKEN" \
  > "$PN_CLOUDFLARE_TOKEN_FILE"
unset PN_CLOUDFLARE_TUNNEL_TOKEN

az keyvault secret set \
  --vault-name kv-polinetwork \
  --name cloudflared-vm-tunnel-token \
  --file "$PN_CLOUDFLARE_TOKEN_FILE" \
  --encoding utf-8 \
  --content-type 'Cloudflare Tunnel token for vm01' \
  --output none

rm -f -- "$PN_CLOUDFLARE_TOKEN_FILE"
unset PN_CLOUDFLARE_TOKEN_FILE
```

Then stage all three Key Vault values on the VM as root-only temporary files,
using the two Zerobyte transfer commands above plus:

```zsh
az keyvault secret show \
  --vault-name kv-polinetwork \
  --name cloudflared-vm-tunnel-token \
  --query value --output tsv |
  tr -d '\r\n' |
  ssh pn-vm01 'sudo install -d -o root -g root -m 0700 \
    /srv/polinetwork/state/bootstrap-secrets && \
    sudo install -o root -g root -m 0600 /dev/stdin \
    /srv/polinetwork/state/bootstrap-secrets/cloudflared-vm-tunnel-token'
```

On the VM, update to the recovery-contract commit, authenticate as already
documented, copy all three files into the container, and seed OpenBao entirely
from external custody. A trap removes container copies even if an OpenBao write
fails:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
git fetch --prune origin
git merge --ff-only origin/vm
test "$(git rev-parse HEAD)" = \
  2d466c4f378d11a53f5c975732551c20567574cd

cd infra/openbao
sudo stat -c '%U:%G %a %s %n' \
  /srv/polinetwork/state/bootstrap-secrets/cloudflared-vm-tunnel-token \
  /srv/polinetwork/state/bootstrap-secrets/zerobyte-app-secret \
  /srv/polinetwork/state/bootstrap-secrets/zerobyte-azure-storage-account-key

PN_OPENBAO_ADMIN_PASSWORD="$(systemd-ask-password 'OpenBao pnadmin password')"
BAO_TOKEN="$(
  printf '%s' "$PN_OPENBAO_ADMIN_PASSWORD" |
    docker compose exec -T openbao bao write -field=token \
      auth/userpass/login/pnadmin password=-
)"
unset PN_OPENBAO_ADMIN_PASSWORD
test -n "$BAO_TOKEN"
export BAO_TOKEN

sudo docker cp \
  /srv/polinetwork/state/bootstrap-secrets/cloudflared-vm-tunnel-token \
  infra-openbao-openbao-1:/tmp/cloudflared-vm-tunnel-token
sudo docker cp \
  /srv/polinetwork/state/bootstrap-secrets/zerobyte-app-secret \
  infra-openbao-openbao-1:/tmp/zerobyte-app-secret
sudo docker cp \
  /srv/polinetwork/state/bootstrap-secrets/zerobyte-azure-storage-account-key \
  infra-openbao-openbao-1:/tmp/zerobyte-azure-storage-account-key

docker exec --user 0:0 -e BAO_TOKEN infra-openbao-openbao-1 sh -ec '
  cleanup() {
    rm -f \
      /tmp/cloudflared-vm-tunnel-token \
      /tmp/zerobyte-app-secret \
      /tmp/zerobyte-azure-storage-account-key
  }
  trap cleanup EXIT HUP INT TERM
  chmod 0400 \
    /tmp/cloudflared-vm-tunnel-token \
    /tmp/zerobyte-app-secret \
    /tmp/zerobyte-azure-storage-account-key
  bao kv put -mount=secret core/cloudflared \
    tunnel_token=@/tmp/cloudflared-vm-tunnel-token >/dev/null
  bao kv put -mount=secret core/zerobyte \
    app_secret=@/tmp/zerobyte-app-secret \
    azure_storage_account_key=@/tmp/zerobyte-azure-storage-account-key \
    >/dev/null
'
```

Continue with the already-recorded four-field verification, token revocation
and deletion of all three host staging files. Acceptance now additionally
requires the Key Vault secret `cloudflared-vm-tunnel-token` to be enabled and
non-empty; do not output its value.

Operator result: the owner reports the Cloudflare Key Vault custody step and
staging are done. No secret value was reported. Proceed with metadata-only
staging verification and OpenBao import; any missing/non-empty check must stop
the sequence before authentication or writes.

Operator result: all three external secrets were imported successfully, all
four committed OpenBao references passed value-discarding checks, the temporary
admin token was revoked, and the VM staging directory was removed. Secret
values were not reported. The external-secret reseed gate has passed.

Resume doco.cd identity provisioning with a new short-lived admin token. After
generating the role files, authenticate once through those files and prove the
narrow policy can read only the expected application namespace canary; revoke
the AppRole test token and admin token before inspection:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/openbao
PN_OPENBAO_ADMIN_PASSWORD="$(systemd-ask-password 'OpenBao pnadmin password')"
BAO_TOKEN="$(
  printf '%s' "$PN_OPENBAO_ADMIN_PASSWORD" |
    docker compose exec -T openbao bao write -field=token \
      auth/userpass/login/pnadmin password=-
)"
unset PN_OPENBAO_ADMIN_PASSWORD
test -n "$BAO_TOKEN"
export BAO_TOKEN

docker exec -e BAO_TOKEN infra-openbao-openbao-1 sh -ec '
  bao auth list -format=json | grep -q approle/ || \
    bao auth enable approle >/dev/null
'

docker exec -i -e BAO_TOKEN infra-openbao-openbao-1 \
  bao policy write doco-cd - <<'POLICY'
path "secret/data/core/*" { capabilities = ["read"] }
path "secret/data/apps/*" { capabilities = ["read"] }
POLICY

docker exec -e BAO_TOKEN infra-openbao-openbao-1 bao write \
  auth/approle/role/doco-cd \
  token_policies=doco-cd \
  token_no_default_policy=true \
  token_period=24h \
  secret_id_num_uses=0 \
  secret_id_ttl=0 >/dev/null

docker exec --user 0:0 -e BAO_TOKEN infra-openbao-openbao-1 sh -ec '
  install -d -o 100 -g 1000 -m 0750 \
    /openbao/file/approle/doco-cd
  umask 077
  bao read -field=role_id auth/approle/role/doco-cd/role-id \
    > /openbao/file/approle/doco-cd/role-id
  bao write -field=secret_id -f auth/approle/role/doco-cd/secret-id \
    > /openbao/file/approle/doco-cd/secret-id
  chown 100:1000 \
    /openbao/file/approle/doco-cd/role-id \
    /openbao/file/approle/doco-cd/secret-id
  chmod 0400 \
    /openbao/file/approle/doco-cd/role-id \
    /openbao/file/approle/doco-cd/secret-id
'

docker exec infra-openbao-openbao-1 sh -ec '
  role_id="$(cat /openbao/file/approle/doco-cd/role-id)"
  secret_id="$(cat /openbao/file/approle/doco-cd/secret-id)"
  token="$(bao write -field=token auth/approle/login \
    role_id="$role_id" secret_id="$secret_id")"
  unset role_id secret_id
  test -n "$token"
  BAO_TOKEN="$token" bao kv get -field=message \
    -mount=secret apps/canary | grep -qx openbao-agent-ok
  BAO_TOKEN="$token" bao token revoke -self >/dev/null 2>&1 || true
  unset token
  printf "doco.cd AppRole authentication and canary read passed.\n"
'

docker exec -e BAO_TOKEN infra-openbao-openbao-1 \
  bao token revoke -self >/dev/null
unset BAO_TOKEN

sudo stat -c '%U:%G %a %s %n' \
  /srv/polinetwork/state/openbao/approle/doco-cd/role-id \
  /srv/polinetwork/state/openbao/approle/doco-cd/secret-id
```

Acceptance: the AppRole success line is printed; both files are non-empty,
owned by runtime UID 100/GID 1000 and mode `0400`; no token or credential is
printed. Starting doco.cd remains the next observed gate.

Operator result: policy upload and role convergence succeeded. Credential-file
generation stopped before either file was written because
`install -d -o 100 -g 1000 -m 0750` transferred directory ownership before
applying its final mode; restricted container root lacks `CAP_FOWNER`. The
temporary admin token remains active. This is the same ordering issue corrected
earlier for TLS files.

The tracked doco.cd procedure now creates the directory as root, sets its mode,
then chowns it; generated files are likewise chmodded before chown. It also
explicitly uses container root for filesystem preparation. The documentation
fix passed whitespace validation and was published as signed Conventional
Commit `c9ab712` (`docs(doco-cd): fix AppRole file preparation`).

Proposed resume with the still-active admin token:

```zsh
test -n "$BAO_TOKEN"

docker exec --user 0:0 -e BAO_TOKEN infra-openbao-openbao-1 sh -ec '
  mkdir -p /openbao/file/approle/doco-cd
  chown 0:0 /openbao/file/approle/doco-cd
  chmod 0750 /openbao/file/approle/doco-cd
  chown 100:1000 /openbao/file/approle/doco-cd
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
'
```

Then continue with the already-recorded AppRole login/canary test, admin-token
revocation and metadata-only `stat`. Update the VM checkout to `c9ab712` after
the active token is revoked; the runtime command does not depend on that README
update.

Operator result: corrected credential generation, AppRole authentication,
canary read, token revocation, metadata checks and VM checkout update all
passed. The doco.cd bootstrap identity is ready and no admin token remains.

### Full bootstrap rehearsal: start doco.cd and first reconciliation

Status: proposed, awaiting operator output. doco.cd runs as root by upstream
design because it controls Docker and host-path deployments. Its writable data
directory may contain checked-out deployment material and resolved runtime
configuration, so create it explicitly as root-only instead of relying on
Docker's default bind-source mode.

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/doco-cd
docker compose config --quiet
sudo install -d -o root -g root -m 0700 \
  /srv/polinetwork/state/doco-cd

docker compose up -d --pull always --wait --wait-timeout 180
docker compose ps -a
sudo stat -c '%U:%G %a %F %n' /srv/polinetwork/state/doco-cd
```

Observe the initial poll and resulting projects without printing container
environment or Compose-rendered secret values:

```zsh
docker compose logs --no-color --tail 200
docker compose ls --all
docker ps -a --format \
  'table {{.Names}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}'
```

Acceptance: OpenBao Agent and doco.cd are healthy; the Agent token stays only
in the tmpfs volume; doco.cd clones public branch `vm`, discovers the immediate
`core/*` and `apps/*` projects, resolves external secrets, and begins their
Compose reconciliation without exposing a host port. Any first-poll error must
be reviewed before manually starting a discovered project.

Operator result: OpenBao Agent is healthy and the data directory is root-owned
mode `0700`, but doco.cd restarts before polling. Its only error is permission
denied opening `/run/openbao/token`. No repository reconciliation or discovered
project mutation occurred.

Proposed read-only identity diagnosis:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/doco-cd
docker inspect infra-doco-cd-doco-cd-1 \
  --format 'doco-config-user={{json .Config.User}}'
docker inspect infra-doco-cd-openbao-agent-1 \
  --format 'agent-config-user={{json .Config.User}}'

docker compose exec -T openbao-agent \
  stat -c 'token %u:%g %a %s %n' /run/openbao/token
stat -c 'docker-socket %u:%g %a %n' /var/run/docker.sock

docker volume inspect infra-doco-cd_openbao-token \
  --format 'volume={{.Name}} options={{json .Options}}'
```

Do not change token mode or start discovered projects. If doco.cd declares a
non-root image user while upstream requires root for host bind deployment and
Docker socket access, explicitly setting `user: 0:0` is the narrow fix and
retains token mode `0640`. If it already runs as root, inspect user-namespace or
mount behavior instead.

Operator result: doco.cd is configured as UID 0, Agent uses the image default,
the token is UID 100/GID 1000 mode `0640`, and the Docker socket is UID 0/GID
990 mode `0660`. The shared tmpfs is correctly UID 100/GID 1000 mode `0770`.
Because doco.cd drops all capabilities, its UID 0 cannot bypass either protected
mount's DAC permissions. The failure is not an Agent or AppRole problem.

Hard-coding supplementary GIDs 1000 and 990 would not reproduce across fresh
hosts, and making the token world-readable would weaken it. The doco.cd service
now adds only `DAC_OVERRIDE` after dropping all capabilities. This permits its
intended root process to access the Agent token and Docker socket; socket access
already defines its host-control trust boundary. The change and explanation
passed whitespace validation and were published as signed Conventional Commit
`1154fee` (`fix(doco-cd): allow protected runtime mounts`).

Proposed retry, recreating only doco.cd while preserving the healthy Agent and
its tmpfs token:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
git fetch --prune origin
git merge --ff-only origin/vm
test "$(git rev-parse HEAD)" = \
  1154fee4ab15c65e9bd040ea01dfd18902e4c53c

cd infra/doco-cd
docker compose config --quiet
docker compose up -d --pull always --force-recreate \
  --wait --wait-timeout 180 doco-cd
docker compose ps -a
docker compose logs --no-color --tail 200
```

Acceptance: doco.cd remains healthy, initializes the OpenBao provider, connects
to Docker, and begins its first poll. Review that log before acting on any
discovered-project failure.

Operator result: doco.cd and its OpenBao Agent are healthy. doco.cd initialized
the OpenBao provider, polled public branch `vm`, discovered the expected stacks
and began reconciliation. `wave1-canaries`, `zerobyte` and `traefik` advanced,
while `openbao-canary` and `cloudflared` failed before container creation with
the same validation error: an environment-backed Compose secret cannot be
created for a read-only service; `file` is the sole supported option. No manual
project start was attempted. This is now the next source-level compatibility
gate.

The error originates in Docker Compose v5's secret injection path: content and
environment sources are copied into an already-created container, which is
refused when the service root filesystem is read-only. doco.cd resolves OpenBao
values into the Compose interpolation environment and does not materialize a
protected host file, so changing these sources to `file:` would reintroduce the
host-secret preparation that this design intentionally removed. Commit
`3d764ac` (`fix(compose): support managed secrets`) therefore removes only
`read_only: true` from `openbao-canary` and `cloudflared`; their capability
drops, no-new-privileges setting, resource limits, narrow networks and Compose
secret mounts remain. The limitation is documented for future projects.

Proposed observation after doco.cd's next one-minute poll; do not manually
start either project:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/doco-cd

docker compose logs --no-color --since 3m doco-cd
docker compose ls --all
docker ps -a --format \
  'table {{.Names}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}'
```

Acceptance: a poll of commit `3d764ac` reconciles `openbao-canary` and
`cloudflared` without the read-only secret error; both services become healthy
or running as appropriate. Review any independent failure before proceeding.

Operator result: doco.cd polled commit `3d764ac`, deployed both previously
blocked projects and completed the job successfully in 9.211 seconds.
`openbao-canary` is healthy and `cloudflared` is running. The independently
discovered `traefik`, `wave1-canaries` and `zerobyte` projects are also running,
with every health-checked long-running service healthy. Both `infra/` projects
remain outside the reconciliation loop as designed; OpenBao, doco.cd and its
Agent are healthy, and OpenBao's one-shot `state-init` exited successfully.

### Full bootstrap rehearsal: restore hourly OpenBao snapshot production

The Raft restore recovered the OpenBao snapshot policy and role, but the role
and secret ID files deliberately live outside Raft and were lost with the old
VM state. The systemd unit and timer were also removed during cleanup. Recreate
that narrow identity through the tracked bootstrap, install the tracked units,
run one snapshot synchronously, and only then enable the hourly timer. The
password is read silently and streamed through stdin; it is never placed in an
argument or shell variable.

```zsh
cd /srv/polinetwork/compose/polinetwork-cd

systemd-ask-password 'OpenBao pnadmin password' |
  sudo core/zerobyte/openbao-snapshot/bootstrap.sh

sudo install -o root -g root -m 0644 \
  core/zerobyte/openbao-snapshot/openbao-snapshot.service \
  /etc/systemd/system/openbao-snapshot.service
sudo install -o root -g root -m 0644 \
  core/zerobyte/openbao-snapshot/openbao-snapshot.timer \
  /etc/systemd/system/openbao-snapshot.timer

sudo systemctl daemon-reload
sudo systemctl start openbao-snapshot.service
sudo systemctl enable --now openbao-snapshot.timer

systemctl status openbao-snapshot.service --no-pager
systemctl status openbao-snapshot.timer --no-pager
systemctl list-timers openbao-snapshot.timer --no-pager

sudo find /srv/polinetwork/state/backup-staging/openbao \
  -maxdepth 1 -type f -name 'openbao-*.snap' \
  -printf '%TY-%Tm-%TdT%TH:%TM:%TS %s %p\n' |
  sort |
  tail -3

docker inspect infra-openbao-openbao-1 \
  --format 'openbao={{.State.Status}} health={{.State.Health.Status}}'
docker inspect zerobyte-zerobyte-1 \
  --format 'zerobyte={{.State.Status}} health={{.State.Health.Status}}'
```

Acceptance: the bootstrap reports that its snapshot save and denied unrelated
Raft access both passed; the one-shot service exits successfully; the timer is
enabled and waiting; a new non-empty snapshot appears with the current UTC
timestamp; OpenBao and Zerobyte remain healthy. This proves snapshot production
only—the new file must still be observed in a fresh off-host Zerobyte backup
before the rebuilt backup path is accepted.

Operator result: both long-running services remained healthy, but snapshot
production exposed two missing clean-host prerequisites. The AppRole bootstrap
could not save its test snapshot because `/openbao/file/backups` did not exist.
The service then failed at systemd namespace setup with status 226 because
`/srv/polinetwork/state/backup-staging/openbao`, named by `ReadWritePaths`, also
did not exist. The timer was enabled and waiting despite the failed service.
No snapshot was created. Stop the timer before retrying after the tracked
bootstrap is corrected.

The tracked bootstrap now creates both missing root-only directories before
testing the AppRole. Shell syntax and whitespace validation passed, and the
fix was published as signed Conventional Commit `6c9aed7`
(`fix(backup): initialize snapshot directories`). Proposed retry:

```zsh
sudo systemctl stop openbao-snapshot.timer

cd /srv/polinetwork/compose/polinetwork-cd
git fetch --prune origin
git merge --ff-only origin/vm
test "$(git rev-parse HEAD)" = \
  6c9aed7f7fff5126eaf4279be7dff68d29d4b8bb

systemd-ask-password 'OpenBao pnadmin password' |
  sudo core/zerobyte/openbao-snapshot/bootstrap.sh

sudo systemctl reset-failed openbao-snapshot.service
sudo systemctl start openbao-snapshot.service
sudo systemctl enable --now openbao-snapshot.timer

systemctl status openbao-snapshot.service --no-pager -l
systemctl status openbao-snapshot.timer --no-pager -l
systemctl list-timers openbao-snapshot.timer --no-pager

sudo stat -c '%U:%G %a %F %n' \
  /srv/polinetwork/state/openbao/backups \
  /srv/polinetwork/state/backup-staging/openbao

sudo find /srv/polinetwork/state/backup-staging/openbao \
  -maxdepth 1 -type f -name 'openbao-*.snap' \
  -printf '%TY-%Tm-%TdT%TH:%TM:%TS %s %p\n' |
  sort |
  tail -3

docker inspect infra-openbao-openbao-1 \
  --format 'openbao={{.State.Status}} health={{.State.Health.Status}}'
docker inspect zerobyte-zerobyte-1 \
  --format 'zerobyte={{.State.Status}} health={{.State.Health.Status}}'
```

Acceptance remains: the bootstrap's allowed snapshot and denied unrelated
read both pass, the one-shot service succeeds, the timer waits for its next
run, both directories are root-only, a current non-empty snapshot exists, and
OpenBao and Zerobyte remain healthy.

Operator result: the corrected clean-host bootstrap passed. Its permitted
snapshot save succeeded and unrelated system access was denied. The one-shot
service exited 0 after producing the current non-empty native snapshot
`openbao-20260812T154351Z.snap` (44,197 bytes). The timer is enabled and waiting
for 16:05 UTC. Both required directories are `root:root` mode `0700`, and
OpenBao and Zerobyte remain healthy. Native snapshot production is restored;
fresh off-host ingestion remains the next gate.

Upstream source inspection of pinned Zerobyte `v0.41.0` and current main shows
that provisioning schema version 1 supports only repositories and volumes; it
does not support backup schedules. A healthy process therefore does not prove
that the clean instance has an active backup. Its tracked organization ID may
also be absent from the new empty database. Proposed metadata and startup-log
inspection before using the UI or changing backup architecture:

```zsh
docker logs --since 15m --tail 300 zerobyte-zerobyte-1 2>&1 |
  grep -E -i \
    'provision|organization|repositor|volume|schedule|backup|error|failed|health'

sudo find /srv/polinetwork/state/zerobyte/data \
  -mindepth 1 -maxdepth 2 \
  -printf '%y %u:%g %m %s %p\n' |
  sort
```

Do not create a UI schedule yet. Acceptance for this diagnostic: determine
whether the tracked repository and volume synchronized into the rebuilt
database and whether any schedule exists. Secret values must not be printed.

Operator result: the filtered log emitted no matching lines. The rebuilt state
contains only Zerobyte's `cache.db` and `zerobyte.db`; their presence proves
database initialization but not provisioning or scheduling. Proposed
read-only, non-secret metadata query using the image's bundled SQLite client:

```zsh
docker exec zerobyte-zerobyte-1 bun -e '
  import { Database } from "bun:sqlite";
  const db = new Database("/var/lib/zerobyte/data/zerobyte.db", {
    readonly: true,
  });
  const queries = {
    organizations: "SELECT id, name FROM organization ORDER BY name",
    repositories: "SELECT name, status, provisioning_id FROM repositories_table ORDER BY name",
    volumes: "SELECT name, status, provisioning_id FROM volumes_table ORDER BY name",
    schedules: "SELECT name, enabled, last_backup_status, last_backup_at FROM backup_schedules_table ORDER BY name",
  };
  for (const [label, sql] of Object.entries(queries)) {
    console.log(label + "=" + JSON.stringify(db.query(sql).all()));
  }
  db.close();
'
```

The selected fields contain identifiers and operational status only. They do
not include repository configuration, credentials, session data or password
material. Acceptance: establish exact clean-instance resource and schedule
state before any UI mutation.

Operator result: all four result sets are empty. Zerobyte is process-healthy
but has no organization, repository, volume or schedule. This proves its former
configuration existed only in the deleted SQLite database. The tracked
provisioning file cannot create its referenced organization and upstream
provisioning cannot declare schedules, so off-host backup is not currently
operational. Do not treat this clean-host rehearsal as complete or manually
recreate only the schedule without first defining durable recovery for the
Zerobyte database itself.

Operator result: initial administrator and `PoliNetwork` organization
onboarding completed. Zerobyte issued a different `restic.pass`, as expected
for a newly created organization. Do not overwrite the former break-glass file:
the existing Azure Restic repository is encrypted with the old organization's
password, while the new file belongs to the new organization. Repository
attachment or separation must be resolved before provisioning is enabled.

Upstream v0.41 has no supported way to import a former organization's Restic
password and its Azure backend always addresses the container root. Restic
itself supports multiple repository keys, however. The safe migration is to
authenticate with the former break-glass password and add the new
organization's password as an additional key. This preserves all existing
snapshots and keeps both break-glass credentials valid. Never overwrite either
external file; label them by organization and repository.

First obtain only the new non-secret organization identifier so tracked
provisioning can be updated:

```zsh
docker exec zerobyte-zerobyte-1 bun -e '
  import { Database } from "bun:sqlite";
  const db = new Database("/var/lib/zerobyte/data/zerobyte.db", {
    readonly: true,
  });
  console.log(JSON.stringify(
    db.query("SELECT id, name FROM organization ORDER BY name").all(),
  ));
  db.close();
'
```

Acceptance: exactly one `PoliNetwork` organization is returned. This query does
not access its encrypted metadata or Restic password. Do not stage either
password on the VM or alter repository keys until the identifier is recorded
and the guarded key-add command is prepared.

Owner decision: the old Restic repository contains laboratory-only data and
does not need to remain in the active recovery chain. Leave it untouched for
now rather than performing an implicit destructive cleanup. The new
`PoliNetwork` organization ID is
`019ff6aa-484a-7000-a4c1-7d2ed01b6ad2`. Use a new Terraform-managed Azure Blob
container initialized with the new organization's password, and retain only
the new `restic.pass` as the active break-glass credential after the new backup
and restore proof passes.

Owner correction: reuse the existing Terraform-managed `zerobyte` container
and delete its laboratory repository contents. Azure Blob versioning and
30-day soft delete remain the recovery net; do not delete the container or its
Terraform resource. Tracked provisioning now uses the new organization ID and
marks the repository for initialization. JSON and whitespace validation
passed; signed Conventional Commit `ecc8335`
(`fix(backup): reset Zerobyte repository`) was published to `vm`.

Proposed guarded reset. Pause doco.cd before stopping Zerobyte so it cannot
reconcile the service during deletion. Copy the already-mounted Azure account
key to a temporary root-only file without printing it. A pinned multi-arch
Azure CLI container lists the exact active-blob count, deletes active blobs in
only `polinetworkbackups/zerobyte`, and confirms the count is zero. The secret
is read inside that short-lived container and is never a command argument or
container environment entry.

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/doco-cd
docker compose stop doco-cd
docker stop zerobyte-zerobyte-1

PN_AZURE_KEY_FILE="$(sudo mktemp /run/zerobyte-reset-key.XXXXXX)"
sudo docker cp \
  zerobyte-zerobyte-1:/run/secrets/azure_storage_account_key \
  "$PN_AZURE_KEY_FILE"
sudo chown root:root "$PN_AZURE_KEY_FILE"
sudo chmod 0600 "$PN_AZURE_KEY_FILE"
sudo stat -c '%U:%G %a %s %n' "$PN_AZURE_KEY_FILE"

sudo docker run --rm --network host \
  --read-only \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  --tmpfs /tmp:size=64m,mode=0700 \
  --volume "$PN_AZURE_KEY_FILE:/run/secrets/storage-key:ro" \
  --entrypoint /bin/sh \
  mcr.microsoft.com/azure-cli:2.87.0@sha256:e02c9723b6e2296e98f54eeb3630b95206aef06aa04251e097ce8390904ba396 \
  -ec '
    export AZURE_STORAGE_KEY="$(tr -d "\r\n" < /run/secrets/storage-key)"
    export AZURE_CONFIG_DIR=/tmp/azure
    printf "active_blobs_before="
    az storage blob list \
      --account-name polinetworkbackups \
      --container-name zerobyte \
      --query "length(@)" --output tsv
    az storage blob delete-batch \
      --account-name polinetworkbackups \
      --source zerobyte \
      --delete-snapshots include \
      --output none
    printf "active_blobs_after="
    az storage blob list \
      --account-name polinetworkbackups \
      --container-name zerobyte \
      --query "length(@)" --output tsv
  '

sudo rm -f "$PN_AZURE_KEY_FILE"
unset PN_AZURE_KEY_FILE

cd /srv/polinetwork/compose/polinetwork-cd
git fetch --prune origin
git merge --ff-only origin/vm
test "$(git rev-parse HEAD)" = \
  ecc83355931e2d52279045ff6c285fbd889523c9

cd infra/doco-cd
docker compose up -d --wait --wait-timeout 180 doco-cd
```

Acceptance for this destructive step: the exact container has at least one
active blob before deletion and zero afterward; no key value is printed; the
temporary key file is removed; the VM checkout reaches `ecc8335`; doco.cd is
healthy and will reconcile Zerobyte from the new provisioning. Do not create a
schedule until repository initialization is observed.

Operator result: the owner reports that the guarded container reset, checkout
update and doco.cd resume completed. Exact blob counts were not included in the
reported output, so repository initialization remains to be observed before
the reset is accepted.

Proposed automatic-reconciliation and non-secret database inspection:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/doco-cd

docker compose ps -a
docker compose logs --no-color --since 10m doco-cd 2>&1 |
  grep -E 'polling repository|zerobyte|job completed|deployment failed'

docker logs --since 10m --tail 300 zerobyte-zerobyte-1 2>&1 |
  grep -E -i \
    'provision|organization|repositor|volume|schedule|backup|error|failed|health'

docker exec zerobyte-zerobyte-1 bun -e '
  import { Database } from "bun:sqlite";
  const db = new Database("/var/lib/zerobyte/data/zerobyte.db", {
    readonly: true,
  });
  const queries = {
    organizations: "SELECT id, name FROM organization ORDER BY name",
    repositories: "SELECT name, status, provisioning_id FROM repositories_table ORDER BY name",
    volumes: "SELECT name, status, provisioning_id FROM volumes_table ORDER BY name",
    schedules: "SELECT name, enabled, last_backup_status, last_backup_at FROM backup_schedules_table ORDER BY name",
  };
  for (const [label, sql] of Object.entries(queries)) {
    console.log(label + "=" + JSON.stringify(db.query(sql).all()));
  }
  db.close();
'

docker inspect zerobyte-zerobyte-1 \
  --format 'zerobyte={{.State.Status}} health={{.State.Health.Status}}'
```

Acceptance: doco.cd's poll of `ecc8335` succeeds; Zerobyte is healthy; the
single expected organization remains; `Azure primary` has provisioning ID
`provisioned:019ff6aa-484a-7000-a4c1-7d2ed01b6ad2:azure-primary` and no error
status; `OpenBao snapshots` has the analogous managed provisioning ID and is
mounted; schedules remain empty. No secret-bearing repository configuration is
queried.

Operator result: doco.cd reconciled `ecc8335` successfully and Zerobyte is
healthy. The new organization exists as `pnadmin's Workspace`; the managed
OpenBao volume is mounted and schedules are empty. Repository initialization
failed because Azure still returned an initialized Restic master key and
`config`; the managed repository row therefore has status `error`. A later
restart synchronized the existing failed row without retrying initialization.
The reset is not accepted yet.

Proposed read-only Azure metadata diagnosis. Recreate the protected temporary
key from the running Zerobyte container, query active blob names and the exact
`config` existence result, then query only version/deletion metadata for that
one blob. Do not delete anything in this step.

```zsh
PN_AZURE_KEY_FILE="$(sudo mktemp /run/zerobyte-inspect-key.XXXXXX)"
sudo docker cp \
  zerobyte-zerobyte-1:/run/secrets/azure_storage_account_key \
  "$PN_AZURE_KEY_FILE"
sudo chown root:root "$PN_AZURE_KEY_FILE"
sudo chmod 0600 "$PN_AZURE_KEY_FILE"

sudo docker run --rm --network host \
  --read-only \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  --tmpfs /tmp:size=64m,mode=0700 \
  --volume "$PN_AZURE_KEY_FILE:/run/secrets/storage-key:ro" \
  --entrypoint /bin/sh \
  mcr.microsoft.com/azure-cli:2.87.0@sha256:e02c9723b6e2296e98f54eeb3630b95206aef06aa04251e097ce8390904ba396 \
  -ec '
    export AZURE_STORAGE_KEY="$(tr -d "\r\n" < /run/secrets/storage-key)"
    export AZURE_CONFIG_DIR=/tmp/azure
    printf "active_blob_count="
    az storage blob list \
      --account-name polinetworkbackups \
      --container-name zerobyte \
      --query "length(@)" --output tsv
    az storage blob list \
      --account-name polinetworkbackups \
      --container-name zerobyte \
      --query "[].name" --output tsv
    az storage blob exists \
      --account-name polinetworkbackups \
      --container-name zerobyte \
      --name config \
      --query exists --output tsv
    az storage blob list \
      --account-name polinetworkbackups \
      --container-name zerobyte \
      --prefix config \
      --include d v \
      --query "[].{name:name,deleted:deleted,current:isCurrentVersion,version:versionId}" \
      --output json
  '

sudo rm -f "$PN_AZURE_KEY_FILE"
unset PN_AZURE_KEY_FILE
```

Acceptance: metadata only is printed and the temporary key is removed. The
result determines the next exact deletion; do not mutate the failed Zerobyte
row or create a schedule yet.

Operator result: Azure reports zero active blobs and `config` does not exist,
so the container is now genuinely empty. Azure CLI 2.87 rejected `v` in the
optional `--include` metadata query, but that does not affect the two decisive
active-state checks. The failed initialization occurred before the empty state
was visible and Zerobyte then retained its failed managed repository row, which
startup synchronization intentionally does not reinitialize. A declarative
provisioning-ID replacement is required; no Azure deletion or version handling
remains.

Tracked provisioning now tombstones failed ID `azure-primary` and declares
fresh ID `azure-primary-v2` against the confirmed-empty container. JSON and
whitespace validation passed; signed Conventional Commit `8adc604`
(`fix(backup): retry repository initialization`) was published. doco.cd detects
changes to the bind-mounted provisioning file and recreates Zerobyte; no manual
restart is required.

Proposed observation after the next poll:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd/infra/doco-cd

docker compose logs --no-color --since 5m doco-cd 2>&1 |
  grep -E 'polling repository|zerobyte|job completed|deployment failed'
docker logs --since 5m --tail 200 zerobyte-zerobyte-1 2>&1 |
  grep -E -i 'initializ|provision|repositor|volume|error|failed'

docker exec zerobyte-zerobyte-1 bun -e '
  import { Database } from "bun:sqlite";
  const db = new Database("/var/lib/zerobyte/data/zerobyte.db", {
    readonly: true,
  });
  console.log("repositories=" + JSON.stringify(db.query(
    "SELECT name, status, provisioning_id FROM repositories_table ORDER BY name",
  ).all()));
  console.log("volumes=" + JSON.stringify(db.query(
    "SELECT name, status, provisioning_id FROM volumes_table ORDER BY name",
  ).all()));
  console.log("schedules=" + JSON.stringify(db.query(
    "SELECT name, enabled FROM backup_schedules_table ORDER BY name",
  ).all()));
  db.close();
'

docker inspect zerobyte-zerobyte-1 \
  --format 'zerobyte={{.State.Status}} health={{.State.Health.Status}}'
```

Acceptance: doco.cd deploys the Zerobyte folder and completes; Zerobyte reports
successful repository initialization with no error; exactly one repository
row exists with managed ID ending `azure-primary-v2` and non-error status; the
volume remains mounted; schedules remain empty; Zerobyte is healthy.

Operator result: fresh repository initialization passed. Zerobyte initialized
`azure:zerobyte:/`, added its host key, and synchronized provisioning. The
database contains exactly one healthy `Azure primary` row with managed ID
ending `azure-primary-v2`, one mounted managed `OpenBao snapshots` volume, and
no schedules. The temporary failed-ID tombstone can now be removed from the
steady-state provisioning file.

The tombstone was removed, leaving exactly one tracked repository declaration.
JSON and whitespace validation passed; signed Conventional Commit `0589333`
(`chore(backup): remove repository tombstone`) was published to `vm`.

Proposed one-time schedule creation in the Zerobyte UI at
`https://backups.polinetwork.org`:

- Name: `OpenBao hourly`
- Volume: `OpenBao snapshots`
- Repository: `Azure primary`
- Frequency: `Custom (Cron)` with `15 * * * *`
- Include paths/patterns and exclusions: leave empty, backing up the whole
  staged volume
- Retention: keep 24 hourly, 7 daily, 4 weekly and 6 monthly snapshots; leave
  the other retention fields empty
- Keep the schedule enabled and leave advanced Restic parameters empty

Save it, then use `Run now` once. Do not delete the local staged snapshot. The
new organization's downloaded `restic.pass` must already be stored under a
distinct active label in the approved break-glass store; the former lab file
must not be mistaken for it.

Acceptance: the manual run completes successfully. This proves the UI-managed
schedule can write to the fresh repository; direct recovery with the new
`restic.pass` and durable recovery of Zerobyte's own database remain separate
gates.

Owner feedback: hourly off-host backup plus the initially proposed retention
is more aggressive than this low-change OpenBao workload requires. The revised
schedule is `15 */6 * * *`, retaining the last 8 snapshots, 7 daily, 4 weekly
and 3 monthly; other retention fields remain empty. Hourly native snapshots
still provide local recovery, while total VM loss has a maximum six-hour RPO.

Operator result: the first manual backup completed successfully and Zerobyte
shows one 43.2 KiB snapshot in the fresh Azure repository. The screenshot still
shows cron `15 * * * *`, however, so the schedule remains hourly and must be
edited to the accepted `15 */6 * * *` cadence. After saving, the next-run time
must align to the next 00:15, 06:15, 12:15 or 18:15 local-time slot. Do not run
another backup merely to validate the cron edit.

Operator result: the owner reports that the schedule edit and revised
retention are complete. The accepted six-hour schedule is now the active
off-host backup policy.

### Full bootstrap rehearsal: direct restore from the new repository

From the operator workstation, point only to the newly downloaded production
organization file (not the old lab file), then stream both recovery inputs into
temporary root-only VM files without printing them:

```zsh
PN_ACTIVE_RESTIC_PASS=/absolute/path/to/new-production/restic.pass
test -s "$PN_ACTIVE_RESTIC_PASS"

az keyvault secret show \
  --vault-name kv-polinetwork \
  --name zerobyte-azure-storage-account-key \
  --query value --output tsv |
  tr -d '\r\n' |
  ssh pn-vm01 'sudo install -d -o root -g root -m 0700 \
    /srv/polinetwork/state/zerobyte/secrets && \
    sudo install -o root -g root -m 0600 /dev/stdin \
    /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key'

ssh pn-vm01 'sudo install -d -o root -g root -m 0700 \
  /srv/polinetwork/state/zerobyte/secrets && \
  sudo install -o root -g root -m 0600 /dev/stdin \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key' \
  < "$PN_ACTIVE_RESTIC_PASS"

unset PN_ACTIVE_RESTIC_PASS
```

On the VM, verify metadata only and restore directly from Azure:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd

sudo stat -c '%U:%G %a %s %n' \
  /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key

sudo test -s \
  /srv/polinetwork/state/backup-staging/openbao/openbao-20260812T154351Z.snap

sudo core/zerobyte/openbao-snapshot/disaster-restore.sh

sudo find \
  /srv/polinetwork/state/backup-staging/openbao \
  /srv/polinetwork/state/zerobyte/restore-tests \
  -type f -name 'openbao-20260812T154351Z.snap' \
  -exec sha256sum {} +
```

Acceptance: the new `restic.pass` authenticates; Restic finds the fresh
`pn-vm01` `/data/openbao` snapshot; full repository check has no errors; the
restore succeeds without Zerobyte database access; the selected restored file
is `openbao-20260812T154351Z.snap`; and its SHA-256 exactly matches the local
staged source. Leave temporary files in place only until this output is
reviewed.

Operator result: direct recovery from the new repository passed. The new
64-byte `restic.pass` and 88-byte Azure key had correct root-only metadata.
Restic found only fresh snapshot `d11d4dc7` for `pn-vm01` and
`/data/openbao`, checked the complete repository with no errors, and restored
`openbao-20260812T154351Z.snap` without Zerobyte database state. Both source
and restored file have SHA-256
`16bf83b2a461c797dc2dfce329bd27bf9f7a014da9ebb13591ea1546b3708117`.
Byte-integrity and database-independent Azure recovery are accepted.

Proposed semantic restore proof using the already-restored file. The rehearsal
creates an isolated temporary network and volume, applies the snapshot to a
temporary OpenBao instance using Azure Auto Unseal, checks the restored
`pnadmin` login and canary value, then removes its temporary Docker resources.
It also asserts that production OpenBao remains healthy:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd

systemd-ask-password 'OpenBao pnadmin password' |
  sudo core/zerobyte/openbao-snapshot/restore-rehearsal.sh \
  /srv/polinetwork/state/zerobyte/restore-tests/openbao-disaster-20260812T160837Z-1267009/openbao-20260812T154351Z.snap

docker inspect infra-openbao-openbao-1 \
  --format 'production-openbao={{.State.Status}} health={{.State.Health.Status}}'
```

Acceptance: the script reports that isolated restore, `pnadmin` login and
canary read succeeded; its temporary container/network/volume are removed; and
production OpenBao remains healthy. Only then remove the restored directory and
the two temporary VM recovery-secret files.

Operator result: semantic recovery passed. The isolated OpenBao restore,
restored `pnadmin` authentication and canary secret read all succeeded, while
production OpenBao remained running and healthy. Together with the matching
SHA-256 and clean Restic check, the new repository's OpenBao recovery path is
accepted.

Proposed cleanup of exact temporary VM artifacts only:

```zsh
sudo rm -rf -- \
  /srv/polinetwork/state/zerobyte/restore-tests/openbao-disaster-20260812T160837Z-1267009

sudo rm -f -- \
  /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key

sudo test ! -e \
  /srv/polinetwork/state/zerobyte/restore-tests/openbao-disaster-20260812T160837Z-1267009
sudo test ! -e \
  /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key
sudo test ! -e \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key

docker ps -a --filter name=openbao-restore-rehearsal --format '{{.Names}}'
docker network ls --filter name=openbao-restore-rehearsal --format '{{.Name}}'
docker volume ls --filter name=openbao-restore-rehearsal --format '{{.Name}}'

docker inspect infra-openbao-openbao-1 \
  --format 'openbao={{.State.Status}} health={{.State.Health.Status}}'
docker inspect zerobyte-zerobyte-1 \
  --format 'zerobyte={{.State.Status}} health={{.State.Health.Status}}'
```

Acceptance: the three absence checks succeed; all three filtered Docker lists
are empty; OpenBao and Zerobyte remain healthy. The deleted VM files remain
recoverable from Azure Key Vault and the approved off-host break-glass store;
the accepted Azure repository is not modified.

Operator result: the owner confirmed cleanup passed and asked to continue.
Temporary restored data and VM recovery-secret copies are gone; canonical
Azure and break-glass custody remain.

### Full bootstrap rehearsal: preserve Zerobyte's own recovery state

The clean-host rehearsal proved that Zerobyte's organization and schedule live
only in its SQLite database. Tracked provisioning cannot recreate either the
organization or schedule. The minimal durable solution uses SQLite's online
`VACUUM INTO` inside the healthy container, validates the copy with
`PRAGMA integrity_check`, and stages it beside the OpenBao snapshots. The
single managed Zerobyte volume now covers safe staging root `/data`; it still
never sees either live database.

The new database timer runs at approximately `:08`, after OpenBao's `:05`
producer and before the accepted six-hour Restic run at `:15`. Direct disaster
restore now requires and returns both snapshot types, and a guarded database
restore refuses a running Zerobyte instance or existing target. Shell syntax,
JSON and whitespace validation passed. Signed Conventional Commit `3bd5f06`
(`feat(backup): preserve Zerobyte recovery state`) was published.

Proposed deployment and local producer proof:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd
git fetch --prune origin
git merge --ff-only origin/vm
test "$(git rev-parse HEAD)" = \
  3bd5f06365ec2c0958524a548e83d448aee75d59

sudo install -o root -g root -m 0644 \
  core/zerobyte/database-snapshot/zerobyte-database-snapshot.service \
  /etc/systemd/system/zerobyte-database-snapshot.service
sudo install -o root -g root -m 0644 \
  core/zerobyte/database-snapshot/zerobyte-database-snapshot.timer \
  /etc/systemd/system/zerobyte-database-snapshot.timer

sudo systemctl daemon-reload
sudo systemctl start zerobyte-database-snapshot.service
sudo systemctl enable --now zerobyte-database-snapshot.timer

systemctl status zerobyte-database-snapshot.service --no-pager -l
systemctl status zerobyte-database-snapshot.timer --no-pager -l
systemctl list-timers \
  openbao-snapshot.timer \
  zerobyte-database-snapshot.timer \
  --no-pager

sudo find /srv/polinetwork/state/backup-staging \
  -maxdepth 2 -type f \
  \( -name 'openbao-*.snap' -o -name 'zerobyte-*.db' \) \
  -printf '%TY-%Tm-%TdT%TH:%TM:%TS %s %u:%g %m %p\n' |
  sort

docker inspect zerobyte-zerobyte-1 \
  --format 'zerobyte={{.State.Status}} health={{.State.Health.Status}}'
```

Acceptance: the one-shot exits successfully; a current, non-empty
`zerobyte-*.db` is root-owned mode `0400`; both hourly timers are enabled and
waiting in the intended order; live Zerobyte remains healthy. Wait for doco.cd
to reconcile the `/data` volume change before running the next off-host backup.

Operator result: the first producer invocation raced doco.cd's expected
Zerobyte recreation for the `/data` volume change. Zerobyte reported health
`starting`, so the producer's immediate healthy assertion exited 1 before
creating a database snapshot. The timer was nevertheless enabled and waiting.
OpenBao snapshot production remained normal. Stop the database timer until a
bounded readiness wait is added and the one-shot retry succeeds.

The producer now waits up to 180 seconds for healthy Zerobyte state, handling
normal doco.cd recreation and boot ordering while still failing a persistently
unhealthy service. Shell and whitespace validation passed; signed Conventional
Commit `472cb2a` (`fix(backup): wait for Zerobyte readiness`) was published.
The installed unit needs no replacement because it executes the tracked script
from the checkout.

Proposed guarded retry:

```zsh
sudo systemctl stop zerobyte-database-snapshot.timer

cd /srv/polinetwork/compose/polinetwork-cd
git fetch --prune origin
git merge --ff-only origin/vm
test "$(git rev-parse HEAD)" = \
  472cb2aff6915f191fba07962c2041156971b3dd

sudo systemctl reset-failed zerobyte-database-snapshot.service
sudo systemctl start zerobyte-database-snapshot.service
sudo systemctl enable --now zerobyte-database-snapshot.timer

systemctl status zerobyte-database-snapshot.service --no-pager -l
systemctl status zerobyte-database-snapshot.timer --no-pager -l
systemctl list-timers \
  openbao-snapshot.timer \
  zerobyte-database-snapshot.timer \
  --no-pager

sudo find /srv/polinetwork/state/backup-staging \
  -maxdepth 2 -type f \
  \( -name 'openbao-*.snap' -o -name 'zerobyte-*.db' \) \
  -printf '%TY-%Tm-%TdT%TH:%TM:%TS %s %u:%g %m %p\n' |
  sort

docker inspect zerobyte-zerobyte-1 \
  --format 'zerobyte={{.State.Status}} health={{.State.Health.Status}}'
```

Acceptance remains a successful one-shot, current root-owned mode `0400`
SQLite snapshot, both timers waiting in order, and healthy live Zerobyte.

Operator result: the corrected producer created
`zerobyte-20260812T161622Z.db`, 368,640 bytes, owned by root and mode `0400`.
Because the script publishes only after `VACUUM INTO` and
`PRAGMA integrity_check` pass, consistent local SQLite staging is accepted.
Both previously staged OpenBao snapshots remain intact. Timer and live-health
output were not included, so those and the reconciled volume/schedule state
remain to be observed before off-host backup.

Proposed non-secret state verification:

```zsh
systemctl status zerobyte-database-snapshot.timer --no-pager -l
systemctl list-timers \
  openbao-snapshot.timer \
  zerobyte-database-snapshot.timer \
  --no-pager

docker inspect zerobyte-zerobyte-1 \
  --format 'zerobyte={{.State.Status}} health={{.State.Health.Status}}'

docker exec zerobyte-zerobyte-1 bun -e '
  import { Database } from "bun:sqlite";
  const db = new Database("/var/lib/zerobyte/data/zerobyte.db", {
    readonly: true,
  });
  console.log("volume=" + JSON.stringify(db.query(
    "SELECT name, status, config FROM volumes_table ORDER BY name",
  ).all()));
  console.log("schedule=" + JSON.stringify(db.query(
    "SELECT name, enabled, cron_expression, retention_policy, last_backup_status, last_backup_at FROM backup_schedules_table ORDER BY name",
  ).all()));
  db.close();
'
```

The directory-volume config and schedule policy are non-secret. Acceptance:
database timer is enabled/waiting; OpenBao runs before Zerobyte at `:05`/`:08`;
live Zerobyte is healthy; volume name is `Platform recovery staging`, status is
mounted and config path is `/data`; schedule remains enabled at `15 */6 * * *`
with the accepted retention and no failed last backup.

Operator result: the complete local gate passed. The timers are enabled and
ordered at approximately `:05` and `:08`; Zerobyte is healthy; the managed
volume is mounted as `Platform recovery staging` with path `/data`; and enabled
schedule `openbao` uses cron `15 */6 * * *` with retention `keepLast=8`,
`keepDaily=7`, `keepWeekly=4`, `keepMonthly=3`. Its last backup succeeded, but
its timestamp precedes the first SQLite snapshot by roughly one minute, so it
cannot contain that database snapshot.

Proposed UI action: select schedule `openbao` at
`https://backups.polinetwork.org` and click `Backup now` once. Do not change the
schedule or retention. Acceptance: the manual run completes successfully after
16:16 UTC and creates a new repository snapshot. This is the first candidate
containing both staged recovery artifact types; direct restore will prove its
contents next.

Operator result: the owner reports that the manual combined backup completed.
The repository now has a candidate snapshot taken after both local producers.

Proposed direct combined recovery. From the operator workstation, stream the
active production organization `restic.pass` and Azure key into temporary
root-only VM files, exactly as in the prior proof:

```zsh
PN_ACTIVE_RESTIC_PASS=/absolute/path/to/new-production/restic.pass
test -s "$PN_ACTIVE_RESTIC_PASS"

az keyvault secret show \
  --vault-name kv-polinetwork \
  --name zerobyte-azure-storage-account-key \
  --query value --output tsv |
  tr -d '\r\n' |
  ssh pn-vm01 'sudo install -d -o root -g root -m 0700 \
    /srv/polinetwork/state/zerobyte/secrets && \
    sudo install -o root -g root -m 0600 /dev/stdin \
    /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key'

ssh pn-vm01 'sudo install -d -o root -g root -m 0700 \
  /srv/polinetwork/state/zerobyte/secrets && \
  sudo install -o root -g root -m 0600 /dev/stdin \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key' \
  < "$PN_ACTIVE_RESTIC_PASS"

unset PN_ACTIVE_RESTIC_PASS
```

On the VM:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd

sudo stat -c '%U:%G %a %s %n' \
  /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key

sudo core/zerobyte/openbao-snapshot/disaster-restore.sh
```

Acceptance: Restic selects the newest `pn-vm01` snapshot for path `/data`, the
full check has no errors, and the script restores and prints SHA-256 for both a
newest `openbao-*.snap` and `zerobyte-*.db`. Keep the restored directory and
temporary keys only until byte comparison and SQLite restore validation pass.

Operator result: combined direct recovery passed against snapshot `7115de5f`,
taken at 16:19:02 UTC from `/data`. Restic's full repository check found no
errors and restored both required artifacts: OpenBao snapshot
`openbao-20260812T160531Z.snap` with SHA-256
`afd7122fa2befcfc58e31be777d233c9fca01f0c39b6ad1f2f684cb8b0766d88`, and
Zerobyte database `zerobyte-20260812T161622Z.db` with SHA-256
`6808cc37faea956ac0bc8e091b38e1f80a1bee1935ed37276a43921240a9ca75`.
The repository is independently readable from Azure using only the two
break-glass files. Byte equality with local staging and restored SQLite
semantics remain to be checked before removing temporary recovery material.

Proposed non-disruptive combined-artifact validation:

```zsh
PN_COMBINED_RESTORE=/srv/polinetwork/state/zerobyte/restore-tests/openbao-disaster-20260812T162123Z-1283001

sudo sha256sum \
  /srv/polinetwork/state/backup-staging/openbao/openbao-20260812T160531Z.snap \
  "$PN_COMBINED_RESTORE/openbao/openbao-20260812T160531Z.snap" \
  /srv/polinetwork/state/backup-staging/zerobyte/zerobyte-20260812T161622Z.db \
  "$PN_COMBINED_RESTORE/zerobyte/zerobyte-20260812T161622Z.db"

sudo cmp --silent \
  /srv/polinetwork/state/backup-staging/openbao/openbao-20260812T160531Z.snap \
  "$PN_COMBINED_RESTORE/openbao/openbao-20260812T160531Z.snap" && \
  echo 'openbao-byte-identity=passed'

sudo cmp --silent \
  /srv/polinetwork/state/backup-staging/zerobyte/zerobyte-20260812T161622Z.db \
  "$PN_COMBINED_RESTORE/zerobyte/zerobyte-20260812T161622Z.db" && \
  echo 'zerobyte-byte-identity=passed'

sudo docker run --rm --pull never --network none \
  --read-only \
  --security-opt no-new-privileges:true \
  --cap-drop ALL \
  --user 0:0 \
  --volume \
  "$PN_COMBINED_RESTORE/zerobyte/zerobyte-20260812T161622Z.db:/snapshot/zerobyte.db:ro" \
  --entrypoint bun \
  'ghcr.io/nicotsx/zerobyte:v0.41@sha256:647706f3e44365e6ba8d8e9094efe57bcd36682a1bab4aa23a132d800bd9ad38' \
  -e '
    import { Database } from "bun:sqlite";
    const db = new Database("/snapshot/zerobyte.db", { readonly: true });
    console.log("integrity=" + db.query("PRAGMA integrity_check").get().integrity_check);
    console.log("organizations=" + JSON.stringify(db.query(
      "SELECT id, name FROM organization ORDER BY name",
    ).all()));
    console.log("repositories=" + JSON.stringify(db.query(
      "SELECT name, status, provisioning_id FROM repositories_table ORDER BY name",
    ).all()));
    console.log("volumes=" + JSON.stringify(db.query(
      "SELECT name, status, provisioning_id FROM volumes_table ORDER BY name",
    ).all()));
    console.log("schedules=" + JSON.stringify(db.query(
      "SELECT name, enabled, cron_expression, retention_policy, last_backup_status FROM backup_schedules_table ORDER BY name",
    ).all()));
    db.close();
  '

unset PN_COMBINED_RESTORE
```

Acceptance: each local/restored hash pair is identical; both `cmp` checks
print `passed`; SQLite integrity is `ok`; the restored database contains the
expected organization, healthy `Azure primary`, mounted `Platform recovery
staging`, and enabled `openbao` schedule with cron `15 */6 * * *` and the
accepted retention. This command does not stop or mutate the live Zerobyte
instance.

Operator result: combined recovery validation passed. OpenBao and Zerobyte
artifacts are byte-identical to their local staged sources and the restored
SQLite database reports `integrity=ok`. It contains organization
`019ff6aa-484a-7000-a4c1-7d2ed01b6ad2`, healthy repository `Azure primary`
with managed ID ending `azure-primary-v2`, mounted volume `Platform recovery
staging`, and enabled schedule `openbao` at `15 */6 * * *` with retention
`keepLast=8`, `keepDaily=7`, `keepWeekly=4`, `keepMonthly=3`; its last backup
status is successful. This accepts independent Azure recovery of all durable
control-plane state required to reconstruct both OpenBao and Zerobyte.

Proposed cleanup of the now-accepted combined recovery test and temporary
break-glass files, followed by live-state confirmation:

```zsh
sudo rm -r -- \
  /srv/polinetwork/state/zerobyte/restore-tests/openbao-disaster-20260812T162123Z-1283001

sudo rm -- \
  /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key

test ! -e \
  /srv/polinetwork/state/zerobyte/restore-tests/openbao-disaster-20260812T162123Z-1283001 && \
  echo 'combined-restore-test-removed=passed'

test ! -e \
  /srv/polinetwork/state/zerobyte/secrets/azure-storage-account-key && \
test ! -e \
  /srv/polinetwork/state/zerobyte/secrets/restic-recovery-key && \
  echo 'temporary-recovery-files-removed=passed'

docker inspect infra-openbao-openbao-1 zerobyte-zerobyte-1 \
  --format '{{.Name}}={{.State.Status}} health={{.State.Health.Status}}'

systemctl is-active \
  openbao-snapshot.timer \
  zerobyte-database-snapshot.timer
```

This removes only reproducible local restore-test output and temporary copies
of credentials retained in Azure Key Vault/operator break-glass custody. The
accepted Azure backup and local production staging are unchanged. Acceptance:
both absence checks pass, both production containers remain healthy, and both
snapshot timers remain active.

Operator result: the owner reports the cleanup complete. The combined restore
test and temporary VM copies of both recovery credentials were removed; the
accepted Azure repository, Key Vault custody, off-host `restic.pass`, and live
staging were not targeted. Exact container-health and timer output was not
included in the report, so the next bootstrap convergence gate must reassert
live state before changing services.

### Converge the accepted sequence into one VM entry point

The accepted manual sequence is now implemented by the guarded, idempotent
`bootstrap/bootstrap-vm.sh`. It runs the existing host layer, starts OpenBao,
detects initialized state, and performs direct Azure recovery only for an
uninitialized instance. During clean recovery it requires both artifacts from
the same Restic snapshot, force-restores OpenBao only through the accepted
temporary initialization, restores Zerobyte only into an absent database,
verifies all currently referenced OpenBao keys, regenerates host-local doco.cd
and snapshot AppRoles, starts doco.cd, waits for Zerobyte, installs both tracked
systemd timers, and deletes temporary recovery material only after every gate.

On an already recovered host it takes the non-destructive convergence path:
exact host/runtime validation, ordinary Compose convergence, health checks and
fresh consistent snapshots. It neither needs the removed Restic credentials
nor prompts for the administrator password while both AppRole credential sets
are present. The wrapper refuses an unexpected checkout path, partially
missing Zerobyte state, ambiguous recovered database, artifacts from different
restore directories, or an unexpected cleanup target.

Shell syntax, executable mode, provisioning JSON and whitespace checks passed.
The workstation lacks a Docker Compose plugin, so Compose rendering remains a
VM deployment gate; all unchanged Compose files were already accepted with VM
Docker Compose `5.4.0`. Signed Conventional Commit `a45c4be`
(`feat(bootstrap): converge VM recovery`) was published on `vm`; the raw commit
contains an SSH signature, although this workstation lacks the allowed-signers
file needed to verify identities locally.

Proposed first idempotent convergence run on the currently healthy VM. Observe
state before updating, fast-forward exactly to the published commit, render the
two infrastructure projects with the VM's Compose plugin, then run the single
entry point:

```zsh
cd /srv/polinetwork/compose/polinetwork-cd

docker inspect \
  infra-openbao-openbao-1 \
  infra-doco-cd-doco-cd-1 \
  infra-doco-cd-openbao-agent-1 \
  zerobyte-zerobyte-1 \
  --format '{{.Name}}={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'

systemctl is-active \
  openbao-snapshot.timer \
  zerobyte-database-snapshot.timer

git fetch --prune origin
git merge --ff-only origin/vm
test "$(git rev-parse HEAD)" = \
  a45c4be3091a7adb432a0313e7c4d0d258be44ae
test -z "$(git status --porcelain)"

docker compose \
  --project-directory infra/openbao \
  --file infra/openbao/compose.yaml \
  config --quiet
docker compose \
  --project-directory infra/doco-cd \
  --file infra/doco-cd/compose.yaml \
  config --quiet

sudo bootstrap/bootstrap-vm.sh
```

Acceptance: the preflight shows all four long-running containers healthy and
both timers active; both Compose renders pass; host bootstrap reports exact
Git-backed state without restarting the active runtime; the entry point does
not attempt direct recovery or request the absent recovery files; both one-shot
snapshot producers succeed; OpenBao, doco.cd, its Agent and Zerobyte remain
healthy; both timers remain active; and the script prints `VM bootstrap
passed`. Stop and report the exact phase if any guard fails.

Operator result: the first single-entry-point convergence run passed. The
reported final state shows OpenBao and Zerobyte running and healthy, both
snapshot timers active, and the exact terminal message `VM bootstrap passed;
OpenBao, Zerobyte, doco.cd and snapshot timers are converged.` Because the
script reaches that message only after both infrastructure Compose wait gates,
healthy Zerobyte, successful one-shot OpenBao and SQLite snapshots, and active
timers, the already-initialized idempotent path is accepted. The operator did
not include the separate preflight lines for doco.cd and its Agent, but their
Compose wait gate completed inside the successful entry point.

### Bootstrap UX and doco.cd webhook polish

Status: source implemented locally and a credentialed Terraform plan has
passed; no Terraform apply, Azure secret mutation, GitHub webhook mutation or
VM deployment has been performed. A saved, reviewed plan and reviewed Git
commits remain prerequisites.

The entry point now has a quiet operator interface. It collects the OpenBao
administrator password before any long-running phase when clean recovery or
credential regeneration requires it, prints short colored progress and result
lines for each meaningful phase, immediately shows the last output from a
failed phase, and retains complete command output in a root-only timestamped
file below `/var/log/polinetwork`. `--verbose` replays captured output and `NO_COLOR=1`
uses plain output. Routine APT, Docker pull, Compose and systemd output is no
longer mixed with operator decisions.

After the first healthy-host run exposed redundant `› phase` / `✓ phase`
pairs, interactive progress was refined to one terminal line per phase: the
blue pending line is replaced in place by its green result. Successful
internal Compose-model checks are log-only, while failures remain immediate
and include their diagnostic tail. Non-interactive output emits one plain
result line per phase so captured CI/operator logs remain readable.

Azure-held recovery inputs are fetched directly through the existing
`id-vm01-backup` user-assigned identity. The tracked helper obtains a Key Vault
token from IMDS, reads one validated secret name and installs its value
atomically as `root:root` mode `0600`; it never prints a token or value. The
identity's proposed Key Vault access is secret `Get` only, without `List`,
`Set` or deletion. Because `kv-polinetwork` uses legacy access policies, Azure
cannot scope `Get` to individual secret objects; fixed call sites provide the
available name allowlist. Terraform moves the existing identity from the
foundation child module to the root without replacing it, then passes its
unchanged IDs back into the VM and Blob role definitions.

The active production organization's exact `restic.pass` gains a normal
bootstrap copy at Key Vault name `zerobyte-restic-recovery-key`; the approved
off-host copy remains independent break-glass custody. This changes transport,
not the tested Restic repository password or the external recovery boundary.
Clean recovery also retrieves the Azure account key, Cloudflare token and
Zerobyte APP secret by managed identity and imports the runtime values into
restored OpenBao using the administrator session already collected at startup.
The workstation helper `bootstrap/seed-restic-recovery-key.sh` uploads the
password as a file, refuses implicit replacement, downloads the created
version to a protected temporary file and requires a byte-identical comparison
without displaying the value.

A metadata-only Key Vault inventory confirmed that the Cloudflare token,
Zerobyte APP secret and Azure account key names exist and are enabled. Neither
new name (`doco-cd-github-webhook-secret` or
`zerobyte-restic-recovery-key`) exists yet. The older enabled name
`zerobyte-restic-password` predates the accepted production-organization reset
and must not be reused or renamed implicitly; only the exact active downloaded
`restic.pass` may seed the new recovery name.

Azure Key Vault was selected for the doco.cd GitHub HMAC secret. OpenBao is a
runtime dependency of doco.cd and may itself be under recovery, so keeping the
listener's stable bootstrap credential only in OpenBao would be circular. The
root-owned file at
`/srv/polinetwork/state/doco-cd/secrets/github-webhook-secret` is mounted via
upstream-supported `WEBHOOK_SECRET_FILE`. Traefik exposes only exact path
`/v1/webhook` at `doco-cd.polinetwork.org`; no host port is published. doco.cd
performs one startup reconciliation with `run_once: true`, then relies on
GitHub push events. Both root deployment documents filter webhook references
to exact `refs/heads/vm`.

The workstation helper `bootstrap/configure-doco-webhook.sh` creates or reuses
Key Vault secret `doco-cd-github-webhook-secret` and creates or updates the
push-only GitHub repository webhook with JSON payloads and TLS verification.
It passes the secret in protected files/stdin and never prints it. Pinned
doco.cd `0.108.0` source confirms `/v1/webhook`, `WEBHOOK_SECRET_FILE`, GitHub
`X-Hub-Signature-256` HMAC-SHA256 validation, asynchronous acceptance, and
`run_once` polling semantics.

The existing remotely managed Cloudflare Tunnel wildcard maps
`*.polinetwork.org` to `http://traefik:80`, so the webhook needs no additional
public-hostname mapping. A read-only probe on 2026-08-12 reached Cloudflare and
returned HTTP 404, which is the expected Traefik response before the new router
is deployed. Do not put `doco-cd.polinetwork.org` behind Cloudflare Access:
HMAC validation in doco.cd is the authentication boundary for this
machine-to-machine endpoint.

A read-only GitHub inventory found active push-only JSON hooks for Argo CD at
`argocdwh.polinetwork.org` and the retired Komodo listener at
`komodo.polinetwork.org`. The Argo CD hook remains part of the AKS rollback
path and must not be changed. The helper intentionally leaves existing hooks
untouched and reports a legacy Komodo hook when present; only that exact hook
may be disabled after doco.cd delivery acceptance.

Local validation completed:

- every changed POSIX shell script passes `sh -n`;
- both changed YAML files parse, including the two root deployment documents;
- pinned doco.cd `0.108.0`'s own configuration package parses and validates
  the repository contract and discovers the expected five projects;
- the webhook helper's create/existing-secret paths and the Restic helper's
  guarded-replacement/byte-round-trip paths pass against local fake CLIs,
  without an external mutation or secret appearing in output;
- `git diff --check` passes;
- Terraform formatting and `terraform validate` pass on branch
  `feat/vm-bootstrap-keyvault` based on current `origin/stable`;
- after sourcing the repository `access_key.sh`, a full credentialed
  `terraform plan -lock=false -input=false` passed with exactly `0 to add, 2
  to change, 0 to destroy`: the existing `id-vm01-backup` address moves
  without replacement and its purpose tag changes in place, while
  `kv-polinetwork` gains only secret `Get` for that identity. The earlier 403
  was caused by not sourcing the repository credentials. This plan was not
  saved and no apply occurred;
- the T3 execution workstation exposes Docker CLI 29.6.2 but no Compose CLI
  plugin, while the operator confirms Docker Compose is installed on `vm01`;
  exact rendering therefore remains a VM gate, not an installation task.

Proposed rollout order after both repositories have reviewed signed commits:

1. From an authorized Terraform context, run and inspect a saved plan. It must
   show the identity address move without recreation, the intended identity
   tag update, and only secret `Get` added to its Key Vault access policy. It
   must contain no unrelated create, replacement or destroy.
2. Apply only that reviewed plan through the protected production workflow.
3. Run `bootstrap/seed-restic-recovery-key.sh` against the exact active
   `restic.pass`; require its byte-identical Key Vault round-trip to pass and
   retain the off-host copy. Then run
   `bootstrap/configure-doco-webhook.sh` from an Azure/GitHub-authenticated
   workstation. Neither operation may print a value.
4. Fast-forward the clean VM checkout to the reviewed `vm` commit, render both
   infrastructure Compose models with Docker Compose `5.4.0`, and run
   `sudo bootstrap/bootstrap-vm.sh`. On the already healthy host it must ask no
   question, fetch the webhook secret itself, avoid service interruption, and
   finish with the concise green success summary. Detailed logs must remain
   root-only.
5. Confirm the doco.cd startup log reports the webhook endpoint enabled and
   only one initial poll. Push a non-secret documentation-only commit to `vm`;
   GitHub delivery must return a successful asynchronous response and doco.cd
   must reconcile that exact commit without a later periodic poll.
6. Send or redeliver a payload with an invalid signature and confirm HTTP 401;
   push another branch and confirm the `refs/heads/vm` filters skip deployment.
   OpenBao, doco.cd, Zerobyte, all reconciled services and both timers must
   remain healthy throughout.
7. Disable the exact legacy Komodo webhook only after the preceding gates.
   Re-list repository hooks and confirm the new doco.cd hook and existing Argo
   CD hook remain active; do not delete or modify the Argo CD rollback hook.
