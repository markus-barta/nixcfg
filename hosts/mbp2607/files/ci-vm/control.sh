#!/bin/bash
# Root-only guest controls. No API/token access, including the idle signal.
set -euo pipefail
repositories=/etc/ci-vm-repositories.json
runners=/var/lib/ci-runners
status() { printf 'CI_VM_STATUS=%s\n' "$1"; }

worker_active() {
  local users
  users=$(jq -er '.[].id | "ci-" + .' "$repositories") || return 2
  local user uid rc
  for user in $users; do
    uid=$(id -u "$user") || return 2
    if pgrep -u "$uid" -f '(^|/)Runner[.]Worker([[:space:]]|$)' >/dev/null; then
      return 0
    else
      rc=$?
      [ "$rc" -eq 1 ] || return 2
    fi
  done
  return 1
}

case "${1:-}" in
worker-active)
  if worker_active; then status worker-busy; else
    rc=$?
    if [ "$rc" -eq 1 ]; then status no-worker; else status unknown; fi
  fi
  ;;
enrolled)
  ids=$(jq -er '.[].id' "$repositories") || {
    status unknown
    exit 0
  }
  enrolled=()
  while IFS= read -r id; do
    if [ -f "$runners/$id/.runner" ]; then enrolled+=("$id"); fi
  done <<<"$ids"
  status "enrolled:$(
    IFS=,
    printf '%s' "${enrolled[*]}"
  )"
  ;;
ready)
  # Colima can report READY even if provision failed. Require this boot's marker.
  test "$(cat /var/lib/ci-vm/ready)" = "$(cat /proc/sys/kernel/random/boot_id)"
  test "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns)" = 0
  systemctl is-active --quiet ci-vm-firewall.service
  if [ "${2:-}" = --provision-only ]; then exit 0; fi
  # This gate is never opened by the provision-only inspection path.
  touch /run/ci-vm-host-qos-ready
  while IFS= read -r id; do
    unit="ci-runner-$id.service"
    systemctl start "$unit"
    if ! systemctl is-active --quiet "$unit"; then
      printf 'ci-vm: %s is not active; check enrollment, runner pin and unit health\n' "$unit" >&2
      exit 1
    fi
    # Inventory on the host detects deleted registrations. An immediate journal
    # scan cannot reliably observe the listener's first failure/restart.
  done < <(jq -r '.[].id' "$repositories")
  ;;
drain)
  ids=$(jq -er '.[].id' "$repositories") || {
    status unknown
    exit 0
  }
  units=()
  while IFS= read -r id; do
    unit="ci-runner-$id.service"
    if systemctl is-active --quiet "$unit"; then units+=("$unit"); fi
  done <<<"$ids"
  # Freeze the listeners AND descendants before the final worker check. They
  # cannot pick up a job between that check and systemd stopping the units.
  if [ "${#units[@]}" -gt 0 ]; then
    trap 'systemctl thaw "${units[@]}" >/dev/null 2>&1 || true' EXIT
    systemctl freeze "${units[@]}" || {
      status unknown
      exit 0
    }
  fi
  if worker_active; then
    status worker-busy
    exit 0
  else rc=$?; fi
  [ "$rc" -eq 1 ] || {
    status unknown
    exit 0
  }
  if [ "${#units[@]}" -gt 0 ]; then
    systemctl stop "${units[@]}" || {
      status unknown
      exit 0
    }
  fi
  # Also catch any worker outside the stopped service cgroups.
  if worker_active; then
    status worker-busy
    exit 0
  else rc=$?; fi
  [ "$rc" -eq 1 ] || {
    status unknown
    exit 0
  }
  status drained
  ;;
reset-enrollment)
  id=${2:?repository id required}
  jq -e --arg id "$id" 'any(.[]; .id == $id)' "$repositories" >/dev/null
  unit="ci-runner-$id.service"
  if systemctl is-active --quiet "$unit"; then
    systemctl freeze "$unit"
    trap 'systemctl thaw "$unit" >/dev/null 2>&1 || true' EXIT
  fi
  if worker_active; then
    printf 'ci-vm: refusing to reset enrollment while a worker is active\n' >&2
    exit 3
  else rc=$?; fi
  [ "$rc" -eq 1 ] || exit 2
  systemctl stop "$unit"
  # Move only the known enrollment files out of the runner directory before
  # a new token is minted. Keep a root-only rollback copy; never print them.
  shopt -s nullglob
  files=("$runners/$id/.runner" "$runners/$id"/.credentials*)
  for file in "${files[@]}"; do
    if [ -e "$file" ] || [ -L "$file" ]; then
      if [ ! -f "$file" ] || [ -L "$file" ]; then
        printf 'ci-vm: refusing an unsafe enrollment file path for %s\n' "$id" >&2
        exit 1
      fi
    fi
  done
  backup=$(mktemp -d /var/lib/ci-vm/retired-enrollment.XXXXXXXX)
  chmod 0700 "$backup"
  for file in "${files[@]}"; do
    if [ -f "$file" ]; then mv "$file" "$backup/"; fi
  done
  systemctl reset-failed "$unit"
  printf 'ci-vm: %s enrollment reset; retired files retained in %s\n' "$id" "$backup"
  ;;
*) exit 2 ;;
esac
