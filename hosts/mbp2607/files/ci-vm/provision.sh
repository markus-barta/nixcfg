#!/bin/bash
# Executed as root by Lima on EVERY boot. Inputs are substituted by ci-vm.nix.
set +x
set -euo pipefail
umask 022
export DEBIAN_FRONTEND=noninteractive
cache=/var/cache/ci-vm
install -d -m 0755 "$cache" /usr/local/libexec/ci-vm /etc/nix /var/lib/ci-runners /var/lib/ci-vm
: >/var/lib/ci-vm/ready
# VZ virtiofs can report host-owned 0600 files readable to guest users. Put
# the mount beneath a root-only directory on the GUEST filesystem as well.
test ! -L /etc/ci-vm-private
install -d -o root -g root -m 0700 /etc/ci-vm-private

# Ubuntu repositories only. Avoid repeating apt work on every on-demand boot.
if [ ! -f "$cache/ubuntu-dependencies-v2" ]; then
  # DNS can lag the guest agent on a cold VZ boot. Bound both DNS and apt.
  for attempt in $(seq 1 12); do
    if timeout 5 getent ahostsv4 ports.ubuntu.com >/dev/null; then break; fi
    printf 'ci-vm: waiting for Ubuntu DNS (%s/12)\n' "$attempt" >&2
    sleep 5
  done
  timeout 5 getent ahostsv4 ports.ubuntu.com >/dev/null
  apt_options=(-o Acquire::Retries=3 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20)
  timeout 300 apt-get "${apt_options[@]}" -o APT::Update::Error-Mode=any update -qq
  timeout 300 dpkg --configure -a
  timeout 300 apt-get "${apt_options[@]}" install -y --no-install-recommends ca-certificates curl xz-utils git jq sudo \
    nftables procps python3 libicu-dev libkrb5-3 zlib1g libssl-dev
  touch "$cache/ubuntu-dependencies-v2"
fi

download_verified() {
  local url=$1 path=$2 digest=$3
  if [ ! -f "$path" ]; then
    curl --fail --silent --show-error --location --proto '=https' --retry 3 \
      --connect-timeout 10 --max-time 180 --retry-max-time 300 \
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
  if [ -e /nix/var/nix/db/db.sqlite ]; then
    printf 'ci-vm: partial Nix installation needs operator repair; refusing to overwrite it\n' >&2
    exit 1
  fi
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
min-free = 5368709120
max-free = 10737418240
NIX_CONFIG
install -d -m 0755 /etc/systemd/system/nix-daemon.service.d
cat >/etc/systemd/system/nix-daemon.service.d/ci-vm.conf <<'DAEMON_UNIT'
[Service]
# OPS-719: Nix's stock unit sets Delegate=yes, which also delegates cpuset and
# makes systemd enable cpuset in /system.slice; hausnetz's nightly host sampler
# (HNET-433) refuses that layout. This daemon does not use cgroups (no
# use-cgroups), so reset the list and keep only the accounting controllers.
Delegate=
Delegate=cpu io memory pids
MemoryHigh=8G
MemoryMax=9G
TasksMax=4096
Nice=10
CPUWeight=10
IOWeight=10
DAEMON_UNIT
# Protect the control path during a guest-wide OOM. Apply to existing main
# processes too: restarting the guest agent here would interrupt provisioning.
for unit in ssh.service lima-guestagent.service; do
  install -d -m 0755 "/etc/systemd/system/$unit.d"
  cat >"/etc/systemd/system/$unit.d/ci-vm.conf" <<'CONTROL_UNIT'
[Service]
OOMScoreAdjust=-900
CONTROL_UNIT
done
systemctl daemon-reload
for unit in ssh.service lima-guestagent.service; do
  pid=$(systemctl show "$unit" --property=MainPID --value)
  [[ "$pid" =~ ^[1-9][0-9]*$ ]]
  printf '%s\n' -900 >"/proc/$pid/oom_score_adj"
done
systemctl enable --now nix-daemon.socket
systemctl restart nix-daemon.service

modprobe kvm
test -c /dev/kvm
groupadd -f kvm
chgrp kvm /dev/kvm
# As on NixOS, sandboxed nixbld users need access without supplementary groups.
chmod 0666 /dev/kvm
printf '%s\n' 'KERNEL=="kvm", GROUP="kvm", MODE="0666"' >/etc/udev/rules.d/70-ci-vm-kvm.rules

cat >/etc/ci-vm-repositories.json <<'REPOSITORIES'
@repositories@
REPOSITORIES
cat >/usr/local/libexec/ci-vm/register <<'REGISTER_SCRIPT'
@register@
REGISTER_SCRIPT
chmod 0755 /usr/local/libexec/ci-vm/register
cat >/usr/local/libexec/ci-vm/control <<'CONTROL_SCRIPT'
@control@
CONTROL_SCRIPT
chmod 0755 /usr/local/libexec/ci-vm/control
cat >/usr/local/libexec/ci-vm/host-ready <<'HOST_READY'
#!/bin/bash
exec /usr/local/libexec/ci-vm/control ready "$@"
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
  test -x "$dir/bin/runsvc.sh"
  # runsvc.sh/config.sh load .path; no host paths or agent tokens enter it.
  printf '%s\n' '/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin' >"$dir/.path"
  chown "$user:$user" "$dir/.path"
  cat >"/etc/systemd/system/ci-runner-$id.service" <<UNIT
[Unit]
Description=GitHub Actions runner $id (OPS-669)
Wants=network-online.target nix-daemon.socket
Requires=ci-vm-firewall.service
After=network-online.target nix-daemon.socket ci-vm-firewall.service
# Skip enrollment and execution entirely until configuration or a token exists.
ConditionPathExists=/run/ci-vm-host-qos-ready
ConditionPathExists=|$dir/.runner
ConditionPathExists=|/etc/ci-vm-private/secrets/$id.token

[Service]
Type=exec
User=$user
Group=$user
SupplementaryGroups=kvm
WorkingDirectory=$dir
Environment=HOME=$dir
Environment=PATH=/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin
ExecStartPre=+/usr/local/libexec/ci-vm/register $id
ExecStart=$dir/bin/runsvc.sh
Restart=on-failure
RestartSec=60
TimeoutStopSec=120
KillMode=control-group
UMask=0077
Nice=10
CPUWeight=10
IOWeight=10
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=$dir
ProtectHome=true
PrivateTmp=true
RestrictSUIDSGID=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
LockPersonality=true
CapabilityBoundingSet=
MemoryHigh=5G
MemoryMax=6G
TasksMax=2048

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable "ci-runner-$id.service"
done < <(jq -r '.[].id' /etc/ci-vm-repositories.json)

# Lima's .2 alias exposes Mac localhost, including other profiles' services.
# Block job/build UIDs only; leave the .3 DNS forwarder and root guest agent.
uids=$(getent passwd | awk -F: '$1 ~ /^ci-/ || $1 ~ /^nixbld[0-9]+$/ {print $3}' | paste -sd, -)
test -n "$uids"
install -d -m 0755 /etc/nftables.d
cat >/etc/nftables.d/ci-vm.nft <<NFTABLES
add table inet ci_vm
delete table inet ci_vm
table inet ci_vm {
  chain output {
    type filter hook output priority -10; policy accept;
    meta skuid { $uids } ip daddr 192.168.5.2 counter reject
  }
}
NFTABLES
cat >/etc/systemd/system/ci-vm-firewall.service <<'FIREWALL_UNIT'
[Unit]
Description=Block CI job access to Mac localhost (OPS-669)
[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/nftables.d/ci-vm.nft
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
FIREWALL_UNIT
systemctl daemon-reload
systemctl enable ci-vm-firewall.service
systemctl restart ci-vm-firewall.service
# Chromium/Playwright needs its unprivileged user-namespace sandbox in this
# capped CI guest. Persist and reapply the policy on every provisioned boot.
install -d -m 0755 /etc/sysctl.d
cat >/etc/sysctl.d/99-ci-vm-userns.conf <<'USERNS_SYSCTL'
kernel.apparmor_restrict_unprivileged_userns = 0
USERNS_SYSCTL
sysctl --system
test "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns)" = 0
cat /proc/sys/kernel/random/boot_id >/var/lib/ci-vm/ready
printf 'ci-vm provisioning complete: Nix %s; runner %s sha256 verified; KVM ready\n' "$nix_version" "$runner_version"
