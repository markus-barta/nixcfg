#!/bin/bash
# Root-only guest controls. No API/token access, including the idle signal.
set -euo pipefail
repositories=/etc/ci-vm-repositories.json
runners=/var/lib/ci-runners

worker_active() {
  local users
  users=$(jq -r '.[].id | "ci-" + .' "$repositories") || return 2
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
worker-active) worker_active ;;
enrolled)
  while IFS= read -r id; do
    if [ -f "$runners/$id/.runner" ]; then printf '%s\n' "$id"; fi
  done < <(jq -r '.[].id' "$repositories")
  ;;
ready)
  # Colima can report READY even if provision failed. Require this boot's marker.
  test "$(cat /var/lib/ci-vm/ready)" = "$(cat /proc/sys/kernel/random/boot_id)"
  systemctl is-active --quiet ci-vm-firewall.service
  if [ "${2:-}" = --provision-only ]; then exit 0; fi
  # This gate is never opened by the provision-only inspection path.
  touch /run/ci-vm-host-qos-ready
  while IFS= read -r id; do
    unit="ci-runner-$id.service"
    # A deleted registration can briefly reach active before Listener exits.
    # Check only for known diagnostics; never print the runner's journal.
    if [ -f "$runners/$id/.runner" ] &&
      journalctl -b -u "$unit" --no-pager -o cat |
      grep -Ei 'runner registration (has been |was )?(deleted|removed)|runner (.* )?not found|needs re-enrollment' >/dev/null; then
      printf 'ci-vm: %s needs re-enrollment; GitHub registration is stale\n' "$id" >&2
      exit 1
    fi
    systemctl start "$unit"
    if ! systemctl is-active --quiet "$unit"; then
      printf 'ci-vm: %s is not active; check enrollment, runner pin and unit health\n' "$unit" >&2
      exit 1
    fi
  done < <(jq -r '.[].id' "$repositories")
  ;;
drain)
  units=()
  while IFS= read -r id; do
    unit="ci-runner-$id.service"
    if systemctl is-active --quiet "$unit"; then units+=("$unit"); fi
  done < <(jq -r '.[].id' "$repositories")
  # Freeze the listeners AND descendants before the final worker check. They
  # cannot pick up a job between that check and systemd stopping the units.
  if [ "${#units[@]}" -gt 0 ]; then
    systemctl freeze "${units[@]}" || exit 2
    trap 'systemctl thaw "${units[@]}" >/dev/null 2>&1 || true' EXIT
  fi
  if worker_active; then exit 3; else rc=$?; fi
  [ "$rc" -eq 1 ] || exit 2
  if [ "${#units[@]}" -gt 0 ]; then systemctl stop "${units[@]}"; fi
  # Also catch any worker outside the stopped service cgroups.
  if worker_active; then exit 3; else rc=$?; fi
  [ "$rc" -eq 1 ] || exit 2
  ;;
*) exit 2 ;;
esac
