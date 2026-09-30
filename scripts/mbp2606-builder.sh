#!/usr/bin/env bash
# NIX-600: switch the mbp2606 runner pool from another Mac (`just mbp2606-builder`).
#
# The pool (user ci) and the AEON workers' remote Go lane (user mba: Colima
# `default` with the aeon-dev-db container, driven by the lead's remote-test.sh)
# share the machine's memory, so they take turns:
#   on:  mark the pool on for mba (remote-test then refuses new runs), wait for
#        running remote tests to finish, stop Colima, then start the pool.
#   off: stop the pool (drain), clear the mark, start Colima again.
set -euo pipefail

HOST="${MBP2606_HOST:-mbp2606.local}"
action="${1:-status}"
shift || true
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10)

as_mba() { ssh "${ssh_opts[@]}" "mba@$HOST" bash -s -- "$@"; }
# Arguments are quoted here and expanded once on the remote side.
# shellcheck disable=SC2029
as_ci() { ssh "${ssh_opts[@]}" "ci@$HOST" "/Users/ci/.nix-profile/bin/aeon-builder $(printf '%q ' "$@")"; }

# Shared shell for the mba side; it expands remotely, not here.
# shellcheck disable=SC2016
MBA_LIB='
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
live_runs() {
  n=0
  for f in "$HOME"/.aeon-remote-test/*.pid; do
    [ -e "$f" ] || continue
    if kill -0 "$(cat "$f" 2>/dev/null)" 2>/dev/null; then n=$((n + 1)); else rm -f "$f"; fi
  done
  echo "$n"
}
'

case "$action" in
on)
  as_mba "${WAIT_MINUTES:-10}" <<EOF
set -euo pipefail
$MBA_LIB
touch "\$HOME/.aeon-builder-on"
for _ in \$(seq 1 \$((\$1 * 6))); do
  [ "\$(live_runs)" = 0 ] && break
  echo "waiting for \$(live_runs) remote test run(s) of the AEON workers..."
  sleep 10
done
if [ "\$(live_runs)" != 0 ]; then
  rm -f "\$HOME/.aeon-builder-on"
  echo "remote test runs still active after \$1 min; pool not started" >&2
  exit 1
fi
if colima status >/dev/null 2>&1; then
  echo "stopping Colima (mba) for the pool"
  colima stop >/dev/null
fi
EOF
  if ! as_ci on "$@"; then
    echo "pool did not start; releasing the remote lane" >&2
    as_mba <<EOF
$MBA_LIB
rm -f "\$HOME/.aeon-builder-on"
colima start >/dev/null 2>&1 || echo "colima start failed; start it as mba" >&2
EOF
    exit 1
  fi
  ;;
off)
  as_ci off "$@"
  as_mba <<EOF
set -euo pipefail
$MBA_LIB
rm -f "\$HOME/.aeon-builder-on"
if ! colima status >/dev/null 2>&1; then
  echo "starting Colima (mba) for the remote test lane"
  colima start >/dev/null
fi
EOF
  ;;
status)
  as_ci status
  as_mba <<EOF
$MBA_LIB
printf 'remote lane: colima %s, %s active run(s), builder mark %s\n' \
  "\$(colima status >/dev/null 2>&1 && echo running || echo stopped)" "\$(live_runs)" \
  "\$([ -e "\$HOME/.aeon-builder-on" ] && echo set || echo absent)"
EOF
  ;;
*)
  as_ci "$action" "$@"
  ;;
esac
