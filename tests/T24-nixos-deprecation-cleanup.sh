#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if grep -ERq '\bpkgs\.system\b' "$repo_root/hosts" "$repo_root/modules"; then
  printf 'deprecated pkgs.system remains in a host or module\n' >&2
  exit 1
fi
if grep -ERq '\bxorg\.xset\b' "$repo_root/hosts" "$repo_root/modules"; then
  printf 'deprecated xorg.xset package path remains\n' >&2
  exit 1
fi
if grep -ERq 'boot\.initrd\.systemd\.enable[[:space:]]*=[[:space:]]*lib\.mkForce false|boot\.initrd\.network\.postCommands' \
  "$repo_root/hosts"; then
  printf 'deprecated scripted initrd configuration remains\n' >&2
  exit 1
fi

for host in csb0 csb1; do
  config="$repo_root/hosts/$host/configuration.nix"
  grep -Fq "boot.initrd.systemd.services.${host}-zpool-import-after-network" "$config"
  grep -Fq 'wants = [ "network-online.target" ];' "$config"
  grep -Fq 'before = [ "sysroot.mount" ];' "$config"
  # The expression intentionally verifies the literal Nix interpolation.
  # shellcheck disable=SC2016
  grep -Fq 'ExecStart = "${pkgs.zfs}/bin/zpool import -a";' "$config"
done

printf 'ok: host-platform and systemd-initrd migrations are explicit\n'
