#!/usr/bin/env bash
#
# T09: systemd EnvironmentFile secrets are shell-safe (NIX-572)
# Every agenix file a systemd unit consumes via EnvironmentFile= is also what
# the ops doctrine sources on the host (`( set -a; . FILE; cmd; set +a )`).
# systemd's parser tolerates unquoted special characters; bash does not. So
# each such file must source in a bash subshell without error. The set of
# files is taken from the running systemd, not guessed from names (other
# hsb1-*-env secrets are Samba/compose material with their own parsers).
# Values are never printed: only unit names, paths and exit codes leave the
# subshell.
#
# Can run locally on hsb1 OR remotely via SSH. Remote commands are sent to
# `bash -s` on stdin because hsb1's login shell is fish.
#

set -euo pipefail

TARGET_HOST="hsb1"
HOST="${HSB1_HOST:-192.168.1.101}"
SSH_USER="${HSB1_USER:-mba}"

if [[ "$(hostname)" == "$TARGET_HOST" ]]; then
  run_script() { bash -s; }
else
  run_script() { ssh "$SSH_USER@$HOST" bash -s 2>/dev/null; }
fi

# "unit<TAB>/run/agenix/<file>" for every service whose EnvironmentFile= is an agenix path
pairs=$(
  run_script <<'EOS'
for u in $(systemctl list-units --type=service --all --plain --no-legend | awk '{print $1}'); do
  systemctl show "$u" -p EnvironmentFiles --value 2>/dev/null | grep -o '/run/agenix/[^ ]*' | sed "s#^#$u\t#"
done | sort -u
EOS
)
if [[ -z "$pairs" ]]; then
  echo "  ⚠️  no systemd unit on $TARGET_HOST consumes an agenix EnvironmentFile — nothing to check"
  exit 0
fi

pass=0
fail=0
while IFS=$'\t' read -r unit file; do
  [[ -n "$file" ]] || continue
  # Source in a throwaway subshell; discard all output; keep only the status.
  if run_script <<EOS; then
sudo -n bash -c 'set -euo pipefail; set -a; . $file; set +a' >/dev/null 2>&1
EOS
    echo "  ✅ PASS: $file ($unit) sources cleanly in bash"
    pass=$((pass + 1))
  else
    echo "  ❌ FAIL: $file ($unit) is not shell-safe — quote its values (NIX-572)"
    fail=$((fail + 1))
  fi
done <<<"$pairs"
echo
echo "  Passed: $pass  Failed: $fail"
[[ $fail -eq 0 ]]
