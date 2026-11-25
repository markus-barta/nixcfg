#!/bin/bash
# Executed as root by Lima on EVERY boot. Inputs are substituted by ci-vm.nix.
set +x
set -euo pipefail
umask 022
export DEBIAN_FRONTEND=noninteractive
cache=/var/cache/ci-vm
install -d -m 0755 "$cache" /usr/local/libexec/ci-vm /etc/nix /var/lib/ci-runners /var/lib/ci-vm
: >/var/lib/ci-vm/ready

# Ubuntu repositories only. Avoid repeating apt work on every on-demand boot.
if [ ! -f "$cache/ubuntu-dependencies-v1" ]; then
  apt-get update -qq
  apt-get install -y --no-install-recommends ca-certificates curl xz-utils git jq sudo \
    libicu-dev libkrb5-3 zlib1g libssl-dev
  touch "$cache/ubuntu-dependencies-v1"
fi

download_verified() {
  local url=$1 path=$2 digest=$3
  if [ ! -f "$path" ]; then
    curl --fail --silent --show-error --location --proto '=https' --retry 3 \
      --output "$path.partial" "$url"
    printf '%s  %s\n' "$digest" "$path.partial" | sha256sum --check --status
    mv "$path.partial" "$path"
  fi
  printf '%s  %s\n' "$digest" "$path" | sha256sum --check --status
}

nix_version=@nixVersion@
nix_archive="$cache/nix-$nix_version-aarch64-linux.tar.xz"
download_verified "https://releases.nixos.org/nix/nix-$nix_version/nix-$nix_version-aarch64-linux.tar.xz" \
  "$nix_archive" @nixSha256@
if [ ! -x /nix/var/nix/profiles/default/bin/nix ]; then
  tar -xJf "$nix_archive" -C "$cache"
  HOME=/root "$cache/nix-$nix_version-aarch64-linux/install" --daemon --yes --no-channel-add
fi
test "$(/nix/var/nix/profiles/default/bin/nix --version)" = "nix (Nix) $nix_version"
cat >/etc/nix/nix.conf <<'NIX_CONFIG'
experimental-features = nix-command flakes
system-features = nixos-test benchmark big-parallel kvm
max-jobs = 2
cores = 3
build-users-group = nixbld
sandbox = true
extra-sandbox-paths = /dev/kvm
trusted-users = root
allowed-users = *
NIX_CONFIG
systemctl enable --now nix-daemon.socket
systemctl restart nix-daemon.service

modprobe kvm
test -c /dev/kvm
groupadd -f kvm
chgrp kvm /dev/kvm
chmod 0660 /dev/kvm
printf '%s\n' 'KERNEL=="kvm", GROUP="kvm", MODE="0660"' >/etc/udev/rules.d/70-ci-vm-kvm.rules

cat >/etc/ci-vm-repositories.json <<'REPOSITORIES'
@repositories@
REPOSITORIES
cat >/usr/local/libexec/ci-vm/register <<'REGISTER_SCRIPT'
@register@
REGISTER_SCRIPT
chmod 0755 /usr/local/libexec/ci-vm/register
cat >/usr/local/libexec/ci-vm/host-ready <<'HOST_READY'
#!/bin/bash
set -euo pipefail
# Colima can report READY even if a provision failed. Require this boot's marker.
test "$(cat /var/lib/ci-vm/ready)" = "$(cat /proc/sys/kernel/random/boot_id)"
# No runner (including enrollment) may start before the host verifies both QoS
# policies. /run is cleared at reboot and this file is root-owned.
touch /run/ci-vm-host-qos-ready
while IFS= read -r id; do
  systemctl start "ci-runner-$id.service"
done < <(jq -r '.[].id' /etc/ci-vm-repositories.json)
HOST_READY
chmod 0755 /usr/local/libexec/ci-vm/host-ready

runner_version=@runnerVersion@
runner_digest=@runnerSha256@
runner_archive="$cache/actions-runner-linux-arm64-$runner_version.tar.gz"
download_verified "https://github.com/actions/runner/releases/download/v$runner_version/actions-runner-linux-arm64-$runner_version.tar.gz" \
  "$runner_archive" "$runner_digest"

while IFS= read -r id; do
  user="ci-$id"
  dir="/var/lib/ci-runners/$id"
  if ! id "$user" >/dev/null 2>&1; then
    useradd --create-home --home-dir "$dir" --shell /bin/bash "$user"
  fi
  usermod -aG kvm "$user"
  install -d -o "$user" -g "$user" -m 0700 "$dir"
  # Version changes require a deliberate stop/re-provision, retaining enrollment.
  if [ ! -f "$cache/$id-$runner_version.installed" ]; then
    systemctl stop "ci-runner-$id.service" 2>/dev/null || true
    tar -xzf "$runner_archive" --no-same-owner -C "$dir"
    touch "$cache/$id-$runner_version.installed"
  fi
  test -x "$dir/bin/Runner.Listener"
  # runsvc.sh/config.sh load .path; no host paths or agent tokens enter it.
  printf '%s\n' '/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin' >"$dir/.path"
  chown "$user:$user" "$dir/.path"
  cat >"/etc/systemd/system/ci-runner-$id.service" <<UNIT
[Unit]
Description=GitHub Actions runner $id (OPS-669)
Wants=network-online.target nix-daemon.socket
After=network-online.target nix-daemon.socket
# Skip enrollment and execution entirely until configuration or a token exists.
ConditionPathExists=/run/ci-vm-host-qos-ready
ConditionPathExists=|$dir/.runner
ConditionPathExists=|/etc/ci-vm-secrets/$id.token

[Service]
User=$user
Group=$user
SupplementaryGroups=kvm
WorkingDirectory=$dir
Environment=HOME=$dir
Environment=PATH=/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin
ExecStartPre=+/usr/local/libexec/ci-vm/register $id
ExecStart=$dir/runsvc.sh
Restart=on-failure
RestartSec=60
TimeoutStopSec=120
KillMode=control-group
UMask=0077
Nice=10
CPUWeight=10
IOWeight=10

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable "ci-runner-$id.service"
done < <(jq -r '.[].id' /etc/ci-vm-repositories.json)
cat /proc/sys/kernel/random/boot_id >/var/lib/ci-vm/ready
printf 'ci-vm provisioning complete: Nix %s; runner %s sha256 verified; KVM ready\n' "$nix_version" "$runner_version"
