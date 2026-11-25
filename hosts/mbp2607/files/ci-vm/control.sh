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
    systemctl start "$unit"
    if ! systemctl is-active --quiet "$unit"; then
      printf 'ci-vm: %s is not active; check enrollment, runner pin and unit health\n' "$unit" >&2
      exit 1
    fi
    # A deleted registration can briefly reach active before Listener exits.
    # Use only this invocation so old diagnostics cannot reject re-enrollment.
    if [ -f "$runners/$id/.runner" ]; then
      invocation=$(systemctl show "$unit" --property=InvocationID --value)
      [[ "$invocation" =~ ^[a-f0-9]{32}$ ]] || exit 1
      if journalctl -b -u "$unit" "_SYSTEMD_INVOCATION_ID=$invocation" --no-pager -o cat |
        grep -Ei 'runner registration (has been |was )?(deleted|removed)|runner (.* )?not found|needs re-enrollment' >/dev/null; then
        printf 'ci-vm: %s needs re-enrollment; GitHub registration is stale\n' "$id" >&2
        exit 1
      fi
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
