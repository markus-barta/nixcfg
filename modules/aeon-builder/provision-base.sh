#!/usr/bin/env bash
# NIX-600: provision the sealed base VM that every job VM is cloned from.
# Runs once as root inside `aeon-base` (Lima docker-rootful template, no mounts).
#   provision-base.sh <runner-version> <runner-sha256> [image-to-prepull ...]
set -euo pipefail
version="$1"
sha="$2"
shift 2
export DEBIAN_FRONTEND=noninteractive

# OPS-264: job clones must never contend with automatic APT upgrades. The base
# stays sealed until OPS rebuilds it; stop boot-time APT work before using dpkg.
systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer
systemctl stop apt-daily.service apt-daily-upgrade.service
apt-get -o DPkg::Lock::Timeout=300 purge -y -q unattended-upgrades
# Mask after purging so package removal cannot undo the persistent masks.
systemctl mask unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer \
  apt-daily.service apt-daily-upgrade.service

apt-get update -q
apt-get install -y -q --no-install-recommends \
  build-essential ca-certificates curl git jq unzip zip xz-utils python3 fish zsh \
  libicu-dev libkrb5-3 zlib1g libssl3 acl cryptsetup-bin

# Runner user: Docker for service containers, passwordless sudo because
# workflows expect hosted-runner parity. The VM is thrown away after one job.
id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner
usermod -aG docker runner
echo 'runner ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/runner
chmod 0440 /etc/sudoers.d/runner

dir=/home/runner/actions-runner
tarball=/tmp/actions-runner.tar.gz
curl -fsSL -o "$tarball" "https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-arm64-${version}.tar.gz"
echo "${sha}  ${tarball}" | sha256sum -c -
rm -rf "$dir"
install -d -o runner -g runner "$dir"
tar -xzf "$tarball" -C "$dir"
chown -R runner:runner "$dir"
rm -f "$tarball"
"$dir/bin/installdependencies.sh"

# Admission hook and allowlist: root-owned, outside the runner's writable tree.
install -d -m 0755 /opt/aeon
install -m 0755 /tmp/job-started.sh /opt/aeon/job-started.sh
install -m 0755 /tmp/start-runner /opt/aeon/start-runner
install -m 0755 /tmp/cache-lock /opt/aeon/cache-lock
install -m 0644 /tmp/allowlist.json /opt/aeon/allowlist.json

cat >/opt/aeon/run-runner <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
jit=$(cat /run/aeon/jit)
rm -f /run/aeon/jit
cd /home/runner/actions-runner
exec setpriv --reuid runner --regid runner --init-groups env -i \
  HOME=/home/runner USER=runner LANG=C.UTF-8 \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/aeon/job-started.sh \
  RUNNER_TOOL_CACHE=/opt/aeon-cache/toolcache AGENT_TOOLSDIRECTORY=/opt/aeon-cache/toolcache \
  GOCACHE=/opt/aeon-cache/go-build GOMODCACHE=/opt/aeon-cache/gomod \
  npm_config_cache=/opt/aeon-cache/npm PLAYWRIGHT_BROWSERS_PATH=/opt/aeon-cache/ms-playwright \
  ./run.sh --jitconfig "$jit"
EOF
chmod 0755 /opt/aeon/run-runner

cat >/etc/systemd/system/aeon-runner.service <<'EOF'
[Unit]
Description=aeon single-job GitHub Actions runner (NIX-600)
After=docker.service network-online.target
Wants=docker.service

[Service]
Type=simple
ExecStart=/opt/aeon/run-runner
Restart=no
EOF
systemctl daemon-reload

for image in "$@"; do
  docker pull -q "$image"
done

apt-get clean
rm -f /tmp/provision-base.sh /tmp/job-started.sh /tmp/start-runner /tmp/cache-lock /tmp/allowlist.json
sync
echo "base provisioned: actions-runner ${version}"
