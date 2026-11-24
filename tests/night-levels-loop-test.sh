#!/usr/bin/env bash
# OPS-595: one cycle of the night-levels loop against stubs (no network, no real LEAD files).
# Usage: bash tests/night-levels-loop-test.sh
# Cases:
#   retired  NL_RETIRED=mbp2606 -> zero ssh calls, no WARN, heartbeat mbp2606=RED.
#   control  NL_RETIRED unset   -> the loop does ssh to mbp2606 and prints the policy-write WARN
#            (proves the stub sees ssh, so "zero calls" in the retired case means something).
#   mutant   the retired switch disabled in a copy of the script -> the retired expectations must FAIL.
set -euo pipefail
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
loop="$root/hosts/mbp2607/files/night-levels/night-levels.sh"
mkdir -p "$root/.tmp"
work=$(mktemp -d "$root/.tmp/night-levels-loop-test.XXXXXXXX")
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# Stubs. ssh records every call and behaves like an unreachable host.
mkdir -p "$work/bin"
cat >"$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NL_TEST_SSH_LOG"
cat >/dev/null 2>&1 || true
exit 255
STUB
cat >"$work/mac-health.sh" <<'STUB'
#!/usr/bin/env bash
echo 'mbp2607 cores=18 data_free_gb=500 mem_free_pct=80 swap_used_mb=0 load="2.0 2.0 2.0" cpu_speed_limit=100 swapouts=0'
STUB
: >"$work/unguarded.sh"
chmod +x "$work/bin/ssh" "$work/mac-health.sh"

# Runs one cycle of $1 (script path) with NL_RETIRED=$2; leaves results in $case_dir.
run_cycle() {
  local script=$1 retired=$2
  case_dir=$(mktemp -d "$work/case.XXXXXX")
  mkdir -p "$case_dir/home" "$case_dir/lead"
  printf 'mbp2607 GREEN\nmbp2606 RED\n' >"$case_dir/lead/HOST-LEVEL"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/hl.log"\n' "$case_dir" >"$case_dir/lead/host-level.sh"
  chmod +x "$case_dir/lead/host-level.sh"
  : >"$case_dir/ssh.log"
  env -i PATH="$work/bin:/usr/bin:/bin:/usr/sbin:/sbin:${NL_TEST_EXTRA_PATH:-}" \
    HOME="$case_dir/home" NL_LEAD_DIR="$case_dir/lead" NL_ONCE=1 \
    NL_MAC_HEALTH="$work/mac-health.sh" NL_UNGUARDED="$work/unguarded.sh" \
    NL_RETIRED="$retired" NL_TEST_SSH_LOG="$case_dir/ssh.log" RED_LOAD=28 \
    bash "$script" >"$case_dir/out.log" 2>&1 || fail "loop exited non-zero: $(cat "$case_dir/out.log")"
}

ssh_calls() { wc -l <"$case_dir/ssh.log" | tr -d ' '; }
heartbeat() { cat "$case_dir/lead/HOST-LEVEL.heartbeat" 2>/dev/null || true; }

# Returns 0 when the cycle behaved as "mbp2606 retired".
retired_ok() {
  [ "$(ssh_calls)" -eq 0 ] || return 1
  ! grep -q WARN "$case_dir/out.log" || return 1
  [[ "$(heartbeat)" == *"mbp2607=GREEN mbp2606=RED"* ]] || return 1
  [ ! -e "$case_dir/hl.log" ] || return 1 # no level change -> host-level.sh not called
}

# 1. retired
run_cycle "$loop" mbp2606
retired_ok || fail "retired: ssh=$(ssh_calls) heartbeat='$(heartbeat)' out='$(cat "$case_dir/out.log")'"
echo "ok retired: 0 ssh calls, no WARN, heartbeat '$(heartbeat)'"

# 2. control: not retired -> real probes (stubbed ssh) and the policy-write WARN
run_cycle "$loop" ""
[ "$(ssh_calls)" -gt 0 ] || fail "control: expected ssh calls to mbp2606, got 0"
grep -q 'WARN policy write to mbp2606 failed' "$case_dir/out.log" || fail "control: expected the policy-write WARN"
[[ "$(heartbeat)" == *"mbp2606=RED"* ]] || fail "control: unreachable mbp2606 must read RED, got '$(heartbeat)'"
echo "ok control: $(ssh_calls) ssh calls, WARN present"

# 3. mutant: the switch disabled must fail the retired expectations
mutant="$work/night-levels-mutant.sh"
sed 's/\*" mbp2606 "\*) retired6=1 ;;/*" mbp2606 "*) retired6=0 ;;/' "$loop" >"$mutant"
! cmp -s "$loop" "$mutant" || fail "mutant: sed did not change the retired switch"
run_cycle "$mutant" mbp2606
if retired_ok; then fail "mutant: retired expectations passed with the switch disabled"; fi
echo "ok mutant: switch disabled -> $(ssh_calls) ssh calls, retired expectations fail as they must"

echo "night-levels loop test: PASS"
