#!/usr/bin/env bash
# OPS-300 / OPS-385 / OPS-393 — host-side refusal and the actual executable symlink Git hook.
set -euo pipefail
if [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
  printf '%s requires bash 5 (running %s)\n' "${0##*/}" "$BASH_VERSION" >&2
  exit 2
fi
runtime_only=false
case "${1:-}" in
'') ;;
--runtime-only) runtime_only=true ;;
*)
  printf 'usage: %s [--runtime-only]\n' "$0" >&2
  exit 2
  ;;
esac

# The production wrapper puts pkgs.gawk on PATH. Refuse a different awk so
# macOS /usr/bin/awk cannot hide incompatibilities with GNU awk builtins.
if ! awk_version=$(awk --version 2>/dev/null) || [[ $awk_version != 'GNU Awk '* ]]; then
  printf '%s requires GNU awk on PATH (matching the Nix wrapper)\n' "${0##*/}" >&2
  exit 2
fi
printf 'T90 tools: bash %s; %s\n' "$BASH_VERSION" "${awk_version%%$'\n'*}"

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="$repo/modules/aeon-remote-guard/guard.sh"
mkdir -p "$repo/tests/.tmp"
scratch=$(mktemp -d "$repo/tests/.tmp/aeon-remote-guard.XXXXXX")
cleanup() {
  # Keep evidence local; neither touch client state nor write outside tests/.tmp.
  printf 'T90 fixture retained: %s\n' "$scratch" >&2
}
trap cleanup EXIT
fail() {
  printf 'T90 failed: %s\n' "$*" >&2
  exit 1
}
new_home() { guard_home=$(mktemp -d "$scratch/home.XXXXXX"); }
count=0
check() {
  local expected=$1 sample=$2 label=$3 needle=${4:-} rc=0
  if (($# >= 4)); then shift 4; else shift 3; fi
  local caller_home=${test_caller_home:-$guard_home}
  HOME="$caller_home" guard_home="$guard_home" AEON_REMOTE_GUARD_LOAD="$sample" "$BASH" "$guard" "$@" \
    >"$scratch/stdout" 2>"$scratch/stderr" || rc=$?
  [[ $rc == "$expected" ]] || fail "$label: exit $rc, expected $expected"
  [[ ! -s "$scratch/stdout" ]] || fail "$label: unexpected stdout"
  if [[ $expected == 0 ]]; then
    [[ ! -s "$scratch/stderr" ]] || fail "$label: allow must be silent"
  else
    [[ $(wc -l <"$scratch/stderr") -eq 1 ]] || fail "$label: refusal must be one line"
    local error
    error=$(<"$scratch/stderr")
    [[ $error == 'remote busy:'* || $error == 'remote paused:'* ]] || fail "$label: missing refusal prefix"
    [[ $error == *'retry in a few minutes or rely on PR CI' || $error == *'retry later or rely on PR CI' ]] || fail "$label: missing retry guidance"
    [[ $error == *"$needle"* ]] || fail "$label: missing reason $needle"
  fi
  count=$((count + 1))
}
policy() { printf '%s\n' "$1" >"$guard_home/.aeon-remote-policy"; }
now=$(date +%s)
# Legacy maxruns fixtures intentionally reach eight units. Isolate those gates
# with high joint limits; OPS-393 cases below restore the pinned defaults.
export guard_units_total=99 guard_units_new_max=99 guard_units_finishing_reserve=99
export guard_aeon_new_max=99 guard_ait_new_max=99 guard_ops_new_max=99
export guard_browser_max=99 guard_units_new_max_during_browser=99
export guard_yellow_units_new_max=99 guard_yellow_browser_max=99 guard_red_units_new_max=99

new_home
check 0 1 'allow without policy'
check 0 12 'threshold equality'
check 0 12.0 'decimal threshold equality'
check 3 12.01 'default maximum' 'exceeds maxload 12'
check 0 9.5 'decimal below default maximum'
check 0 0.0 'decimal zero load'
check 0 '{ 1.25 30.00 40.00 }' 'Darwin sample uses 1-minute load'
check 3 '{ 12.25 0.00 0.00 }' 'Darwin high sample' 'exceeds maxload 12'
check 3 '' 'empty load' 'cannot read 1-minute load'
check 3 'unavailable' 'invalid load' 'cannot read 1-minute load'

new_home
touch "$guard_home/.hold-mbp2606"
check 3 0 'hold' 'hold file exists'
check 3 20 'combined reasons' 'hold file exists; 1-minute load'
new_home
ln -s "$scratch/absent-hold-target" "$guard_home/.hold-mbp2606"
check 3 0 'dangling hold symlink' 'hold file exists'
guard_home="$scratch/missing-home"
check 3 0 'uncheckable hold' 'cannot check hold file'
new_home
blocked_home=$guard_home
chmod 000 "$blocked_home"
if [[ ! -x "$blocked_home" ]]; then
  check 3 0 'inaccessible hold parent' 'cannot check hold file'
fi
chmod 700 "$blocked_home"

new_home
policy "block=1 maxload=50 level=RED epoch=$now"
check 3 0 'fresh block' 'fresh policy block=1'
policy "block=1 maxload=1 level=RED epoch=$((now - 901))"
check 0 5 'stale block and threshold ignored'
check 3 13 'stale policy uses default maximum' 'exceeds maxload 12'
policy "block=1 maxload=1 level=RED epoch=$((now + 3600))"
check 0 5 'future policy ignored'
# Freeze the clock for exact skew boundaries and inject clock failures without
# changing the production guard. Only these checks put the date stub on PATH.
mkdir "$scratch/clock-bin"
cat >"$scratch/clock-bin/date" <<'SH'
#!/usr/bin/env bash
case "$AEON_REMOTE_GUARD_TEST_CLOCK" in
fail) exit 1 ;;
invalid) printf 'unavailable\n' ;;
*) printf '%s\n' "$AEON_REMOTE_GUARD_TEST_CLOCK" ;;
esac
SH
chmod +x "$scratch/clock-bin/date"
policy "block=1 maxload=20 level=RED epoch=$((now + 60))"
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
  check 3 0 '60-second future skew accepted' 'fresh policy block=1'
policy "block=0 maxload=20 level=GREEN epoch=$((now + 60))"
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
  check 0 15 '60-second future threshold accepted'
policy "block=1 maxload=1 level=RED epoch=$((now + 61))"
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
  check 0 5 '61-second future block and threshold ignored'
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
  check 3 13 '61-second future policy uses default maximum' 'exceeds maxload 12'
policy "block=0 maxload=50 level=GREEN epoch=$now"
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK=fail \
  check 3 0 'failed policy clock' 'cannot read policy clock'
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK=invalid \
  check 3 0 'invalid policy clock' 'cannot read policy clock'
policy "block=0 maxload=20.5 level=YELLOW epoch=$now"
check 0 15 'fresh policy raises maximum'
check 0 20.5 'fresh threshold equality'
check 3 20.51 'fresh policy maximum' 'exceeds maxload 20.5'
policy "block=0 maxload=12.0 level=GREEN epoch=$now"
check 0 12 'integer equals decimal maximum'
check 0 12.0 'matching decimal maximum'
check 3 12.01 'decimal exceeds decimal maximum' 'exceeds maxload 12.0'
policy "block=0 maxload=28 level=GREEN epoch=$now"
check 3 100 'numeric integer ordering' 'exceeds maxload 28'
policy "block=0 maxload=2.5 level=GREEN epoch=$now"
check 3 3 'fresh policy lowers maximum' 'exceeds maxload 2.5'
policy "block=0 maxload=0 level=GREEN epoch=$now"
check 0 0 'zero maximum equality'
check 3 0.1 'zero maximum refusal' 'exceeds maxload 0'

for bad in \
  'not a policy' \
  "block=2 maxload=100 level=RED epoch=$now" \
  "block=1 maxload=NaN level=RED epoch=$now" \
  "block=1 maxload=100 level=PURPLE epoch=$now" \
  'block=1 maxload=100 level=RED epoch=999999999999999999999999' \
  "block=1 maxload=100 level=RED epoch=$now trailing=data" \
  "block=1 maxload=100 level=RED epoch=$now"$'\nsecond line' \
  ''; do
  policy "$bad"
  check 0 1 'malformed policy falls back silently'
  check 3 13 'malformed policy refusal' 'malformed policy ignored'
done
new_home
policy "block=1 maxload=1 level=RED epoch=$now"
chmod 000 "$guard_home/.aeon-remote-policy"
if ((EUID == 0)); then
  printf 'T90 skip: unreadable policy checks (running as root)\n'
else
  check 0 5 'unreadable policy block and threshold ignored'
  check 3 13 'unreadable policy uses default maximum' 'malformed policy ignored'
fi
chmod 600 "$guard_home/.aeon-remote-policy"
new_home
mkdir "$guard_home/.aeon-remote-policy"
check 3 13 'non-file policy' 'malformed policy ignored'
new_home
policy "block=0 maxload=50 level=GREEN epoch=$now maxruns=9"
check 3 13 'policy still requires exactly four fields' 'malformed policy ignored'

# OPS-385 — strict budget input, fallback, own reservations and all run sources.
budget() { printf '%s\n' "$1" >"$guard_home/.aeon-remote-maxruns"; }
lease() {
  mkdir -p "$guard_home/.aeon-remote-leases"
  printf '%s\n' "$2" >"$guard_home/.aeon-remote-leases/$1"
}
new_home
check 0 0 'reserve first fallback run' '' reserve own
[[ $(<"$guard_home/.aeon-remote-leases/own") == "reserved="* ]] || fail 'missing reservation'
python3 - "$guard_home/.aeon-remote-leases/own" <<'PY'
import os
import sys
assert os.stat(sys.argv[1]).st_mode & 0o777 == 0o600, 'reservation mode must be 0600'
PY
check 0 0 'bare call with own reservation at default cap'
check 0 0 'same id refreshes reservation' '' reserve own
check 3 0 'new id blocked at default cap' '1/1 runs active (OPS budget)' reserve other
lease extra "reserved=$now"
check 3 0 'bare call with extra reservation' '2/1 runs active (OPS budget)'
check 3 0 'same id excludes only itself' '1/1 runs active (OPS budget)' reserve own
new_home
lease adopted "reserved=$((now - 1000))"$'\n'"pid=$$"
check 0 0 'adopted id can refresh' '' reserve adopted
grep -qx "pid=$$" "$guard_home/.aeon-remote-leases/adopted" || fail 're-push dropped live lease pid'
check 0 0 'refreshed adopted lease passes bare call'
check 3 0 'refreshed adopted lease still counts' '1/1 runs active (OPS budget)' reserve other

new_home
policy "block=0 maxload=20 level=YELLOW epoch=$now"
budget "maxruns=0 epoch=$now"
check 3 0 'paused bare' 'remote paused: OPS budget is 0 (level YELLOW); retry later or rely on PR CI'
check 3 0 'paused reservation' 'remote paused: OPS budget is 0 (level YELLOW); retry later or rely on PR CI' reserve paused
[[ ! -e $guard_home/.aeon-remote-leases/paused ]] || fail 'paused reservation written'
touch "$guard_home/.hold-mbp2606"
check 3 30 'paused combines hold and load' 'hold file exists; 1-minute load 30 exceeds maxload 20'
new_home
budget "maxruns=0 epoch=$now"
check 3 0 'paused without policy level' 'level UNKNOWN'
policy "block=1 maxload=50 level=RED epoch=$now"
check 3 0 'paused combines policy block' 'fresh policy block=1'

# The command substitution is deliberately literal, untrusted budget text.
# shellcheck disable=SC2016
for bad in \
  "maxruns=9 epoch=$((now - 901))" \
  "maxruns=0 epoch=$((now + 61))" \
  'maxruns=0 epoch=999999999999999999999999' \
  "maxruns=10 epoch=$now" \
  "maxruns=-1 epoch=$now" \
  "maxruns=01 epoch=$now" \
  "maxruns=1.0 epoch=$now" \
  "maxruns=0 epoch=$now trailing=data" \
  "maxruns=0 epoch=$now"$'\nsecond line' \
  "epoch=$now maxruns=0" \
  '$(touch SHOULD-NOT-EXIST)' \
  ''; do
  new_home
  budget "$bad"
  lease first "reserved=$now"
  PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
    check 0 0 'invalid budget falls back to one (bare)'
  PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
    check 3 0 'invalid budget falls back to one (reserve)' '1/1 runs active (OPS budget)' reserve second
done
new_home
budget "maxruns=2 epoch=$((now + 60))"
lease first "reserved=$now"
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
  check 0 0 'budget accepts 60s future skew' '' reserve second
new_home
budget "maxruns=2 epoch=$((now - 900))"
lease first "reserved=$now"
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
  check 0 0 'budget accepts stale boundary' '' reserve second
new_home
budget "maxruns=2 epoch=000$now"
lease first "reserved=$now"
check 3 0 'oversized padded epoch falls back' '1/1 runs active (OPS budget)' reserve second
new_home
budget "maxruns=2 epoch=$now"
chmod 000 "$guard_home/.aeon-remote-maxruns"
if ((EUID != 0)); then
  lease first "reserved=$now"
  check 3 0 'unreadable budget uses fallback' '1/1 runs active (OPS budget)' reserve second
fi
chmod 600 "$guard_home/.aeon-remote-maxruns"
new_home
mkdir "$guard_home/.aeon-remote-maxruns"
lease first "reserved=$now"
check 3 0 'non-file budget uses fallback' '1/1 runs active (OPS budget)' reserve second

# Every source counts; multiple markers for the same id count once. Old slots
# and markers with invalid ids or dead/invalid pids are neither counted nor deleted.
new_home
budget "maxruns=5 epoch=$now"
mkdir -p "$guard_home/.aeon-remote-test" "$guard_home/ci.noindex/aeon-runs/shared" \
  "$guard_home/aeon-ui-runs/shared" "$guard_home/aeon-ui-runs/ui" \
  "$guard_home/ci.noindex/slots/s1"
lease shared "reserved=$((now - 1000))"$'\n'"pid=$$"
lease reserved "reserved=$now"
printf '%s\n' "$$" >"$guard_home/.aeon-remote-test/shared.pid"
printf '%s\n' "$$" >"$guard_home/.aeon-remote-test/legacy.pid"
printf '%s\n' "$$" >"$guard_home/aeon-ui-runs/shared/supervisor.pid"
printf '%s\n' "$$" >"$guard_home/aeon-ui-runs/ui/supervisor.pid"
mkdir "$guard_home/ci.noindex/aeon-runs/worktree"
check 0 0 'five deduplicated live runs at cap'
check 3 0 'all four sources count' '5/5 runs active (OPS budget)' reserve sixth
check 0 0 'reserve excludes all own markers' '' reserve shared
check 0 0 'bare after shared reservation refresh'
dead_pid=2147483647
if kill -0 "$dead_pid" 2>/dev/null; then fail 'dead pid fixture is alive'; fi
lease dead "reserved=$now"$'\n'"pid=$dead_pid"
lease expired "reserved=$((now - 120))"
python3 - "$guard_home/.aeon-remote-leases" "$((now - 120))" <<'PYTIME'
import os, sys
for name in ('dead', 'expired'):
    os.utime(os.path.join(sys.argv[1], name), (int(sys.argv[2]), int(sys.argv[2])))
PYTIME
lease boundary "reserved=$((now - 119))"
lease 'bad id' "reserved=$now"
lease $'invalid-\xc3\xa9' "reserved=$now"
long_id=$(printf '%065d' 1)
lease "$long_id" "reserved=$now"
lease malformed $'reserved=invalid\npid=1'
lease malformed_pid "reserved=$now"$'\npid=0'
printf '%s\n' "$dead_pid" >"$guard_home/.aeon-remote-test/dead.pid"
printf '%s\n' 0 >"$guard_home/.aeon-remote-test/zero.pid"
printf '%s\n' '-1' >"$guard_home/.aeon-remote-test/negative.pid"
printf '%s\n' "$$" >"$guard_home/.aeon-remote-test/bad id.pid"
mkdir -p "$guard_home/ci.noindex/aeon-runs/bad id" \
  "$guard_home/aeon-ui-runs/bad id" "$guard_home/aeon-ui-runs/dead"
printf '%s\n' "$$" >"$guard_home/aeon-ui-runs/bad id/supervisor.pid"
printf '%s\n' "$dead_pid" >"$guard_home/aeon-ui-runs/dead/supervisor.pid"
budget "maxruns=8 epoch=$now"
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
  check 0 0 'fresh malformed leases also count; eight deduplicated runs'
[[ ! -e $guard_home/.aeon-remote-leases/dead && ! -e $guard_home/.aeon-remote-leases/expired ]] || fail 'dead/expired leases not collected'
[[ -f $guard_home/.aeon-remote-leases/boundary && -f $guard_home/.aeon-remote-leases/'bad id' && -f $guard_home/.aeon-remote-leases/$long_id && -f $guard_home/.aeon-remote-leases/malformed && -f $guard_home/.aeon-remote-leases/malformed_pid ]] || fail 'GC touched non-expired or malformed leases'
[[ -f $guard_home/.aeon-remote-test/dead.pid && -d $guard_home/ci.noindex/aeon-runs/'bad id' && -f $guard_home/aeon-ui-runs/dead/supervisor.pid ]] || fail 'GC touched client state'
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
  check 3 0 'GC count remains deduplicated' '8/8 runs active (OPS budget)' reserve ninth

new_home
check 0 0 'dot-prefixed id allowed' '' reserve .hidden
check 3 0 'hidden lease counted' '1/1 runs active (OPS budget)' reserve other
check 0 0 'hidden id reservation can refresh' '' reserve .hidden
for invalid in '' . .. .recent-rounds .reservation.internal '../escape' 'bad/id' 'bad id' $'invalid-\xc3\xa9' "$long_id"; do
  rc=0
  HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=0 "$BASH" "$guard" reserve "$invalid" \
    >"$scratch/stdout" 2>"$scratch/stderr" || rc=$?
  [[ $rc == 2 ]] || fail "invalid reserve id accepted: $invalid"
done
new_home
check 0 0 'lock-like id can reserve safely' '' reserve .lock
check 3 0 'lock-like id is counted without replacing host lock' '1/1 runs active (OPS budget)' reserve other
new_home
max_id=$(printf '%064d' 1)
check 0 0 'maximum-length id allowed' '' reserve "$max_id"
check 3 0 'maximum-length id counted' '1/1 runs active (OPS budget)' reserve other
new_home
mkdir -p "$guard_home/.aeon-remote-leases/directory"
check 3 0 'unexpected lease directory preserved' 'cannot write run reservation' reserve directory
[[ -d $guard_home/.aeon-remote-leases/directory ]] || fail 'unexpected lease directory removed'
entries=("$guard_home/.aeon-remote-leases/directory/"*)
[[ ! -e ${entries[0]} ]] || fail 'reservation moved inside unexpected directory'
new_home
mkdir "$guard_home/.aeon-remote-leases.lock"
check 3 0 'lock failure refuses safely' 'cannot lock run budget' reserve denied
[[ ! -e $guard_home/.aeon-remote-leases/denied ]] || fail 'unlocked reservation written'

# Round 2: permissions, malformed leases, adoption, path pinning and failures.
new_home
lease hidden "reserved=$now"
for mode in 000 100 300 500; do
  chmod "$mode" "$guard_home/.aeon-remote-leases"
  if [[ ! -r $guard_home/.aeon-remote-leases || ! -w $guard_home/.aeon-remote-leases || ! -x $guard_home/.aeon-remote-leases ]]; then
    check 3 0 "lease directory mode $mode refuses bare" 'cannot read run leases'
    check 3 0 "lease directory mode $mode refuses reserve" 'cannot read run leases' reserve denied
  fi
  chmod 700 "$guard_home/.aeon-remote-leases"
done
for marker in .aeon-remote-test ci.noindex/aeon-runs aeon-ui-runs; do
  new_home
  mkdir -p "$guard_home/$marker"
  for mode in 000 100 300 400; do
    chmod "$mode" "$guard_home/$marker"
    if [[ ! -r $guard_home/$marker || ! -x $guard_home/$marker ]]; then
      check 3 0 "marker $marker mode $mode refuses" 'cannot read run markers' reserve denied
    fi
    chmod 700 "$guard_home/$marker"
  done
done
# Round 3: individual unreadable markers refuse just like their parent dirs.
new_home
mkdir -p "$guard_home/aeon-ui-runs/unreadable"
printf '%s\n' "$$" >"$guard_home/aeon-ui-runs/unreadable/supervisor.pid"
for mode in 000 100 400; do
  chmod "$mode" "$guard_home/aeon-ui-runs/unreadable"
  if [[ ! -r $guard_home/aeon-ui-runs/unreadable || ! -x $guard_home/aeon-ui-runs/unreadable ]]; then
    check 3 0 "unreadable UI run mode $mode refuses bare" 'cannot read run markers'
    check 3 0 "unreadable UI run mode $mode refuses reserve" 'cannot read run markers' reserve denied
  fi
  chmod 700 "$guard_home/aeon-ui-runs/unreadable"
done
new_home
mkdir "$guard_home/.aeon-remote-test"
printf '%s\n' "$$" >"$guard_home/.aeon-remote-test/unreadable.pid"
chmod 000 "$guard_home/.aeon-remote-test/unreadable.pid"
if ((EUID != 0)); then
  check 3 0 'unreadable legacy pid refuses bare' 'cannot read run markers'
  check 3 0 'unreadable legacy pid refuses reserve' 'cannot read run markers' reserve denied
fi
chmod 600 "$guard_home/.aeon-remote-test/unreadable.pid"
[[ $(<"$guard_home/.aeon-remote-test/unreadable.pid") == "$$" ]] || fail 'guard changed unreadable client marker'
new_home
mkdir "$guard_home/actual-leases"
ln -s "$guard_home/actual-leases" "$guard_home/.aeon-remote-leases"
check 3 0 'lease directory symlink refused' 'cannot read run leases'
new_home
mkdir "$guard_home/actual-markers"
ln -s "$guard_home/actual-markers" "$guard_home/.aeon-remote-test"
check 3 0 'marker directory symlink refused' 'cannot read run markers'
for target in present absent; do
  new_home
  if [[ $target == present ]]; then printf 'untouched\n' >"$guard_home/lock-target"; fi
  ln -s "$guard_home/lock-target" "$guard_home/.aeon-remote-leases.lock"
  check 3 0 "lock $target symlink refused" 'cannot lock run budget' reserve denied
  [[ ! -e $guard_home/.aeon-remote-leases/denied ]] || fail 'reservation written through lock symlink'
  if [[ $target == present ]]; then
    [[ $(<"$guard_home/lock-target") == untouched ]] || fail 'lock target changed'
  else
    [[ ! -e $guard_home/lock-target ]] || fail 'lock target created'
  fi
done

for contents in "reserved=$now"$'\npid=0' "pid=$$" "reserved=$now"$'\npid=0\npid=0' '' "reserved=$((now + 61))"; do
  new_home
  lease malformed "$contents"
  check 3 0 'fresh malformed regular lease counts' '1/1 runs active (OPS budget)' reserve other
done
new_home
lease unreadable 'invalid'
chmod 000 "$guard_home/.aeon-remote-leases/unreadable"
check 3 0 'fresh unreadable lease counts' '1/1 runs active (OPS budget)' reserve other
chmod 600 "$guard_home/.aeon-remote-leases/unreadable"
new_home
lease multiple "reserved=$((now - 1000))"$'\npid='"$dead_pid"$'\npid='"$$"
lease malformed "garbage"$'\npid='"$$"$'\nextra'
python3 - "$guard_home/.aeon-remote-leases" "$((now - 1000))" <<'PYTIME'
import os, sys
for name in ('multiple', 'malformed'):
    os.utime(os.path.join(sys.argv[1], name), (int(sys.argv[2]), int(sys.argv[2])))
PYTIME
budget "maxruns=2 epoch=$now"
check 3 0 'any live pid counts even in old malformed leases' '2/2 runs active (OPS budget)' reserve other
new_home
lease stale-malformed 'garbage'
lease future "reserved=$((now + 61))"
lease .reservation.stale ''
lease .reservation.fresh "reserved=$now"
python3 - "$guard_home/.aeon-remote-leases" "$((now - 1000))" <<'PYTIME'
import os, sys
for name in ('stale-malformed', 'future', '.reservation.stale'):
    os.utime(os.path.join(sys.argv[1], name), (int(sys.argv[2]), int(sys.argv[2])))
PYTIME
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
  check 0 0 'stale malformed and internal temp files do not count' '' reserve own
[[ -f $guard_home/.aeon-remote-leases/stale-malformed && -f $guard_home/.aeon-remote-leases/future ]] || fail 'GC collected malformed lease'
[[ ! -e $guard_home/.aeon-remote-leases/.reservation.stale && -f $guard_home/.aeon-remote-leases/.reservation.fresh ]] || fail 'temp GC did not respect mtime'
new_home
mkdir -p "$guard_home/.aeon-remote-leases/directory"
mkfifo "$guard_home/.aeon-remote-leases/fifo"
printf 'pid=%s\n' "$$" >"$guard_home/external"
ln -s "$guard_home/external" "$guard_home/.aeon-remote-leases/link"
lease visible "reserved=$now"
check 3 0 'non-regular entries do not hide regular lease' '1/1 runs active (OPS budget)' reserve other
[[ -L $guard_home/.aeon-remote-leases/link && -p $guard_home/.aeon-remote-leases/fifo ]] || fail 'GC touched non-regular entries'
# The module eval below copies the source tree (tests/.tmp included); Nix cannot copy a FIFO.
unlink "$guard_home/.aeon-remote-leases/fifo"

new_home
check 0 0 'adopt recreates collected reservation' '' adopt adopted "$$"
grep -qx "pid=$$" "$guard_home/.aeon-remote-leases/adopted" || fail 'adopt did not record pid'
check 3 0 'adopted lease counts' '1/1 runs active (OPS budget)' reserve other
check 0 0 'repeated adoption preserves live pid' '' adopt adopted "$$"
check 0 0 'reserve preserves all live pids' '' reserve adopted
check 3 0 'adopt dead pid refused' 'cannot adopt run pid' adopt dead "$dead_pid"
check 3 0 'adopt invalid pid refused' 'cannot adopt run pid' adopt invalid 0
check 3 0 'adopt negative pid refused' 'cannot adopt run pid' adopt invalid -1
budget "maxruns=0 epoch=$now"
touch "$guard_home/.hold-mbp2606"
check 0 20 'adopt records admitted run even after pause/hold' '' adopt paused "$$"
new_home
mkdir -p "$guard_home/.aeon-remote-leases/dir"
check 3 0 'adopt never writes inside a directory' 'guard error' adopt dir "$$"
ln -s "$guard_home/external" "$guard_home/.aeon-remote-leases/link"
check 3 0 'adopt never follows a symlink' 'guard error' adopt link "$$"
[[ ! -e $guard_home/external ]] || fail 'adopt followed symlink'

# Round 4: run directories only cover the start window (reservation TTL and the
# same future skew). Leaked directories of killed runs never block the budget
# and are never deleted; an adopted lease keeps the run counted once afterwards.
run_dir_age() {
  python3 - "$guard_home/ci.noindex/aeon-runs" "$1" "${@:2}" <<'PYTIME'
import os, sys
for name in sys.argv[3:]:
    os.utime(os.path.join(sys.argv[1], name), (int(sys.argv[2]), int(sys.argv[2])))
PYTIME
}
new_home
mkdir -p "$guard_home/ci.noindex/aeon-runs/old"
run_dir_age "$((now - 1000))" old
check 0 0 'old run dir without lease does not count' '' reserve other
check 0 0 'old run dir without lease passes bare call'
[[ -d $guard_home/ci.noindex/aeon-runs/old ]] || fail 'guard removed old run dir'
new_home
mkdir -p "$guard_home/ci.noindex/aeon-runs/fresh"
check 3 0 'fresh run dir counts' '1/1 runs active (OPS budget)' reserve other
check 0 0 'fresh run dir excludes itself' '' reserve fresh
new_home
mkdir -p "$guard_home/ci.noindex/aeon-runs/boundary"
run_dir_age "$((now - 119))" boundary
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
  check 3 0 'run dir inside start window counts' '1/1 runs active (OPS budget)' reserve other
run_dir_age "$((now - 120))" boundary
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
  check 0 0 'run dir at TTL boundary does not count' '' reserve other
unlink "$guard_home/.aeon-remote-leases/other"
run_dir_age "$((now + 60))" boundary
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
  check 3 0 '60-second future run dir counts' '1/1 runs active (OPS budget)' reserve other
run_dir_age "$((now + 61))" boundary
PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
  check 0 0 'run dir beyond future skew does not count' '' reserve other
[[ -d $guard_home/ci.noindex/aeon-runs/boundary ]] || fail 'guard removed boundary run dir'
new_home
mkdir -p "$guard_home/ci.noindex/aeon-runs/adopted"
run_dir_age "$((now - 1000))" adopted
check 0 0 'adopt keeps an old run dir counted' '' adopt adopted "$$"
check 3 0 'old run dir with live adopted lease counts once' '1/1 runs active (OPS budget)' reserve other
check 0 0 'old run dir with live adopted lease passes bare call'
check 0 0 'adopted run with old run dir can refresh' '' reserve adopted
grep -qx "pid=$$" "$guard_home/.aeon-remote-leases/adopted" || fail 'refresh dropped adopted pid'
new_home
leaked=()
for i in 1 2 3 4 5 6 7 8; do leaked+=("leaked-$i"); done
mkdir -p "${leaked[@]/#/$guard_home/ci.noindex/aeon-runs/}"
run_dir_age "$((now - 1000))" "${leaked[@]}"
check 0 0 'eight leaked run dirs still admit a reserve at maxruns=1' '' reserve admitted
check 0 0 'eight leaked run dirs pass the bare call'
check 3 0 'admitted run still counts beside leaked dirs' '1/1 runs active (OPS budget)' reserve other
for i in "${leaked[@]}"; do
  [[ -d $guard_home/ci.noindex/aeon-runs/$i ]] || fail "guard removed leaked run dir $i"
done
new_home
mkdir "$guard_home/.aeon-remote-test"
printf '%s\n' "$$" >"$guard_home/.aeon-remote-test/pinned.pid"
test_caller_home="$scratch/unrelated-home" check 3 0 'marker home pinned independently of HOME' '1/1 runs active (OPS budget)' reserve other

# Remove a marker exactly between its existence check and read. DEBUG runs in
# the test shell only; the production script has no race-injection switches.
cat >"$scratch/marker-race.bash" <<'SH'
trap 'if [[ $BASH_COMMAND == pid=\$\(* && -n ${entry:-} ]]; then if [[ -d $entry ]]; then unlink -- "$entry/supervisor.pid" 2>/dev/null || true; else unlink -- "$entry" 2>/dev/null || true; fi; fi' DEBUG
SH
for source in legacy ui; do
  new_home
  if [[ $source == legacy ]]; then
    mkdir "$guard_home/.aeon-remote-test"
    race_marker="$guard_home/.aeon-remote-test/vanishing.pid"
  else
    mkdir -p "$guard_home/aeon-ui-runs/vanishing"
    race_marker="$guard_home/aeon-ui-runs/vanishing/supervisor.pid"
  fi
  printf '%s\n' "$$" >"$race_marker"
  BASH_ENV="$scratch/marker-race.bash" check 0 0 "vanishing $source marker read is tolerated"
  [[ ! -e $race_marker ]] || fail 'marker race fixture did not remove marker'
done

# Remove a lease after its regular-file check but before stat. A genuine stat
# failure on an entry that still exists is covered by fault injection below.
cat >"$scratch/lease-race.bash" <<'SH'
trap 'if [[ $BASH_COMMAND == mtime=\$\(* && ${entry:-} == */vanishing ]]; then unlink -- "$entry"; fi' DEBUG
SH
for action in check reserve; do
  new_home
  lease vanishing "reserved=$now"
  if [[ $action == check ]]; then
    BASH_ENV="$scratch/lease-race.bash" check 0 0 'vanishing lease stat tolerated by bare check'
  else
    BASH_ENV="$scratch/lease-race.bash" check 0 0 'vanishing lease stat tolerated by reserve' '' reserve own
    [[ -f $guard_home/.aeon-remote-leases/own ]] || fail 'vanished lease prevented reservation'
  fi
  [[ ! -e $guard_home/.aeon-remote-leases/vanishing ]] || fail 'lease race fixture did not remove lease'
done

# Fault injection checks the one-line protocol, including raw stderr suppression.
mkdir "$scratch/fault-bin"
for tool in mktemp mv chmod stat dirname; do
  printf '#!%s\nprintf "raw injected failure\\n" >&2\nexit 1\n' "$BASH" >"$scratch/fault-bin/$tool"
  chmod +x "$scratch/fault-bin/$tool"
  new_home
  if [[ $tool == stat ]]; then lease first "reserved=$now"; fi
  PATH="$scratch/fault-bin:$PATH" check 3 0 "$tool failure exits busy 3" 'guard error' reserve denied
  unlink "$scratch/fault-bin/$tool"
done
printf '#!%s\nprintf "%%s\\n" "%s"\n' "$BASH" "$((EUID + 1))" >"$scratch/fault-bin/ps"
chmod +x "$scratch/fault-bin/ps"
new_home
if ((EUID != 0)); then
  PATH="$scratch/fault-bin:$PATH" check 0 0 'non-root adoption ignores unpinned ps' '' adopt own "$$"
  if ! kill -0 1 2>/dev/null; then
    check 3 0 'adopt rejects a pid not signalable by this user' 'cannot adopt run pid' adopt foreign 1
  fi
fi
unlink "$scratch/fault-bin/ps"
printf '#!%s\nprintf "raw unlink failure\\n" >&2\nexit 1\n' "$BASH" >"$scratch/fault-bin/unlink"
chmod +x "$scratch/fault-bin/unlink"
new_home
lease expired "reserved=$((now - 1000))"
python3 - "$guard_home/.aeon-remote-leases/expired" "$((now - 1000))" <<'PYTIME'
import os, sys
os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))
PYTIME
PATH="$scratch/fault-bin:$PATH" check 0 0 'unlink failure tolerated silently' '' reserve own
[[ -f $guard_home/.aeon-remote-leases/expired ]] || fail 'unlink stub not exercised'
unlink "$scratch/fault-bin/unlink"

# Real lock contention must time out, rather than hanging a client indefinitely.
new_home
mkdir "$guard_home/.aeon-remote-leases"
perl -e 'open my $f, ">>", $ARGV[0] or die; flock($f, 2) or die; open my $r, ">", $ARGV[1] or die; close $r; sleep 45' \
  "$guard_home/.aeon-remote-leases.lock" "$scratch/lock-ready" &
lock_holder=$!
for ((i = 0; i < 500; i++)); do
  [[ ! -f $scratch/lock-ready ]] || break
  sleep 0.01
done
[[ -f $scratch/lock-ready ]] || fail 'lock fixture did not start'
lock_started=$SECONDS
check 3 0 'lock wait bounded at thirty seconds' 'cannot lock run budget' reserve denied
((SECONDS - lock_started >= 29 && SECONDS - lock_started < 40)) || fail 'lock wait outside expected bound'
kill "$lock_holder"
wait "$lock_holder" 2>/dev/null || true

# Tests run serially; each contention round intentionally starts ten guard
# processes together to prove count + reserve is one host-locked transaction.
for round in 1 2 3 4 5; do
  new_home
  budget "maxruns=2 epoch=$(date +%s)"
  pids=()
  for i in {1..10}; do
    HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=0 "$BASH" "$guard" reserve "race-$i" \
      >"$scratch/race-$i.out" 2>"$scratch/race-$i.err" &
    pids+=("$!")
  done
  admitted=0
  for i in {1..10}; do
    rc=0
    wait "${pids[i - 1]}" || rc=$?
    [[ ! -s $scratch/race-$i.out ]] || fail 'race produced stdout'
    case $rc in
    0)
      admitted=$((admitted + 1))
      [[ ! -s $scratch/race-$i.err ]] || fail 'admission produced stderr'
      ;;
    3) grep -qx 'remote busy: 2/2 runs active (OPS budget); retry in a few minutes or rely on PR CI' "$scratch/race-$i.err" || fail 'unexpected race refusal' ;;
    *) fail "race exited $rc" ;;
    esac
  done
  [[ $admitted == 2 ]] || fail "round $round admitted $admitted of ten (expected two)"
  leases=("$guard_home/.aeon-remote-leases/"race-*)
  [[ ${#leases[@]} == 2 ]] || fail 'race did not leave exactly two reservations'
done
printf 'T90 atomic contention ok: five rounds, ten contenders, exactly two admitted per round\n'

# Real local push, no host or network. As with HM's source + executable file,
# only pre-receive is a symlink; the existing hooks directory stays real.
new_home
git init -q --bare "$guard_home/aeon-remote.git"
git init -q "$scratch/work"
tree=$(git -C "$scratch/work" mktree </dev/null)
# Reuse existing commit attribution without hardcoding personal data or
# inventing an operator identity. commit-tree invokes no development hooks.
author_name=$(git -C "$repo" log -1 --format=%an)
author_email=$(git -C "$repo" log -1 --format=%ae)
commit=$(GIT_AUTHOR_NAME="$author_name" GIT_AUTHOR_EMAIL="$author_email" \
  GIT_COMMITTER_NAME="$author_name" GIT_COMMITTER_EMAIL="$author_email" \
  git -C "$scratch/work" commit-tree "$tree" <<<'OPS-300 hook fixture')
git -C "$scratch/work" update-ref refs/heads/main "$commit"
printf '#!%s\nexec %q %q "$@"\n' "$BASH" "$BASH" "$guard" >"$scratch/guard"
{
  printf '#!%s\n' "$BASH"
  sed "s|@guard@|$scratch/guard|g" "$repo/modules/aeon-remote-guard/pre-receive.sh"
} >"$scratch/pre-receive"
chmod +x "$scratch/guard" "$scratch/pre-receive"
ln -s "$scratch/pre-receive" "$guard_home/aeon-remote.git/hooks/pre-receive"
[[ -d "$guard_home/aeon-remote.git/hooks" && ! -L "$guard_home/aeon-remote.git/hooks" ]] || fail 'hooks directory replaced'
[[ -L "$guard_home/aeon-remote.git/hooks/pre-receive" && -x "$guard_home/aeon-remote.git/hooks/pre-receive" ]] || fail 'hook is not an executable symlink'

ref=refs/runs/ops-300-fixture
if HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=15 git -C "$scratch/work" push \
  "$guard_home/aeon-remote.git" "refs/heads/main:$ref" >"$scratch/push-output" 2>&1; then
  fail 'busy push was accepted'
fi
grep -q '^remote: remote busy' "$scratch/push-output" || fail 'push did not relay guard refusal'
grep -q 'pre-receive hook declined' "$scratch/push-output" || fail 'push did not fail through hook'
if git --git-dir="$guard_home/aeon-remote.git" show-ref --verify --quiet "$ref"; then
  fail 'busy push updated the ref'
fi
HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=1 git -C "$scratch/work" push \
  "$guard_home/aeon-remote.git" "refs/heads/main:$ref" >"$scratch/push-output" 2>&1 || fail 'allowed push rejected'
[[ $(git --git-dir="$guard_home/aeon-remote.git" rev-parse "$ref") == "$commit" ]] || fail 'allowed push did not update ref'
[[ -f $guard_home/.aeon-remote-leases/ops-300-fixture ]] || fail 'hook did not reserve single run ref'
check 0 0 'bare call after push reservation'
if HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=0 git -C "$scratch/work" push \
  "$guard_home/aeon-remote.git" 'refs/heads/main:refs/runs/over-budget' \
  >"$scratch/push-output" 2>&1; then
  fail 'over-budget single-ref push admitted'
fi
grep -q '1/1 runs active (OPS budget)' "$scratch/push-output" || fail 'hook did not relay budget refusal'
HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=0 git -C "$scratch/work" push \
  "$guard_home/aeon-remote.git" 'refs/heads/main:refs/heads/non-run' \
  >"$scratch/push-output" 2>&1 || fail 'non-run ref did not use bare check'
[[ ! -e $guard_home/.aeon-remote-leases/non-run ]] || fail 'non-run ref reserved'
if HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=0 git -C "$scratch/work" push \
  "$guard_home/aeon-remote.git" 'refs/heads/main:refs/runs/batch-a' 'refs/heads/main:refs/runs/batch-b' \
  >"$scratch/push-output" 2>&1; then
  fail 'multi-run push admitted'
fi
grep -q 'more than one run ref in one push' "$scratch/push-output" || fail 'multi-run refusal missing'
[[ ! -e $guard_home/.aeon-remote-leases/batch-a && ! -e $guard_home/.aeon-remote-leases/batch-b ]] || fail 'multi-run push reserved'
budget "maxruns=2 epoch=$(date +%s)"
HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=0 git -C "$scratch/work" push \
  "$guard_home/aeon-remote.git" 'refs/heads/main:refs/heads/main' 'refs/heads/main:refs/tags/fixture' 'refs/heads/main:refs/runs/batch' \
  >"$scratch/push-output" 2>&1 || fail 'run plus main/tags push refused'
[[ -f $guard_home/.aeon-remote-leases/batch ]] || fail 'run plus main/tags push did not reserve'
for invalid in nested/invalid "$long_id" .reservation.internal .recent-rounds; do
  rc=0
  printf 'old new refs/runs/%s\n' "$invalid" |
    HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=0 "$scratch/pre-receive" \
      >"$scratch/stdout" 2>"$scratch/stderr" || rc=$?
  [[ $rc == 3 ]] || fail 'invalid run ref did not exit 3'
  grep -q 'remote busy: invalid run id' "$scratch/stderr" || fail 'invalid run refusal missing'
done
# Deletion of an invalid legacy id is still allowed.
printf 'old 0000 refs/runs/nested/invalid\n' |
  HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=99 "$scratch/pre-receive" \
    >"$scratch/stdout" 2>"$scratch/stderr" || fail 'invalid legacy deletion refused'

# A mixed deletion/update must still be refused, preserving both refs.
if HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=15 git -C "$scratch/work" push \
  "$guard_home/aeon-remote.git" ":$ref" 'refs/heads/main:refs/runs/new' \
  >"$scratch/push-output" 2>&1; then
  fail 'busy mixed deletion/update push was accepted'
fi
grep -q '^remote: remote busy' "$scratch/push-output" || fail 'mixed push did not relay guard refusal'
[[ $(git --git-dir="$guard_home/aeon-remote.git" rev-parse "$ref") == "$commit" ]] || fail 'mixed push deleted the ref'
if git --git-dir="$guard_home/aeon-remote.git" show-ref --verify --quiet refs/runs/new; then
  fail 'mixed push created a ref'
fi
HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=15 git -C "$scratch/work" push \
  "$guard_home/aeon-remote.git" ":$ref" >"$scratch/push-output" 2>&1 || fail 'busy deletion push rejected'
if git --git-dir="$guard_home/aeon-remote.git" show-ref --verify --quiet "$ref"; then
  fail 'busy deletion push did not delete ref'
fi

# Stdin must be drained even on refusal, including more than one ref line.
set +e
for ((i = 0; i < 5000; i++)); do
  if ((i == 4999)); then
    printf 'old new refs/runs/%s\n' "$i"
  else
    printf 'old 0000000000000000000000000000000000000000 refs/runs/%s\n' "$i"
  fi
done |
  HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=15 "$scratch/pre-receive" \
    >"$scratch/stdout" 2>"$scratch/stderr"
pipe_status=("${PIPESTATUS[@]}")
set -e
[[ ${pipe_status[0]} == 0 && ${pipe_status[1]} == 3 ]] || fail "hook did not drain stdin or exit 3: ${pipe_status[*]}"
# OPS-393 — production joint defaults, independent of the legacy maxruns suite.
unset guard_units_total guard_units_new_max guard_units_finishing_reserve
unset guard_aeon_new_max guard_ait_new_max guard_ops_new_max
unset guard_browser_max guard_units_new_max_during_browser
unset guard_yellow_units_new_max guard_yellow_browser_max guard_red_units_new_max
legacy_count=$count
joint_home() {
  new_home
  budget "maxruns=9 epoch=$(date +%s)"
}
request() {
  local expected=$1 reason=$2 id=$3 lane=$4 kind=$5 round=$6
  shift 6
  check "$expected" 0 "joint $id" "$reason" reserve "$id" "lane=$lane" "kind=$kind" "round=$round" "$@"
}
# Global new cap, total cap, exactly one finishing unit, and per-lane caps.
joint_home
request 0 '' a aeon test shared
request 0 '' b aeon test shared
request 3 'lane new cap' c aeon test shared
request 0 '' d ait test shared
request 3 'joint new cap' e ops test shared
request 3 'new cap during browser' finishing-browser ops browser shared phase=finish
request 0 '' f ops test shared phase=finish
request 3 'joint total cap' g ops test shared phase=finish
check 0 0 'bare check at total/new equality'
check 0 0 'refresh at total equality' '' reserve f
check 0 0 'adoption preserves lane and finish' '' adopt f "$$"
for field in lane=ops kind=test round=shared phase=finish; do
  grep -qx "$field" "$guard_home/.aeon-remote-leases/f" || fail 'adoption lost joint metadata'
done
check 3 0 'metadata cannot downgrade on refresh' 'run metadata mismatch' reserve f lane=ops kind=test round=shared
joint_home
request 0 '' a ait test r
request 3 'lane new cap' b ait test r
joint_home
request 0 '' a ops test r
request 3 'lane new cap' b ops test r
# Browser caps and coupling apply in either admission order and to finishers.
joint_home
request 0 '' a aeon browser shared
request 3 'browser cap' b ait browser shared
request 0 '' c ait test shared
request 3 'new cap during browser' d ops test shared
request 3 'browser cap' e ops browser shared phase=finish
request 0 '' f ops test shared phase=finish
request 3 'finishing reserve cap' g ops test shared phase=finish
joint_home
request 0 '' a aeon test shared
request 0 '' b ait test shared
request 3 'new cap during browser' c ops browser shared
# Missing lane bypasses only the lane cap, including kind=browser requests.
joint_home
for id in a b c; do check 0 0 'legacy new unit' '' reserve "$id"; done
check 3 0 'legacy global new cap' 'joint new cap' reserve d
joint_home
check 0 0 'unknown browser classified' '' reserve a kind=browser round=r
check 3 0 'unknown browser cap' 'browser cap' reserve b kind=browser round=r
check 0 0 'unknown browser refresh preserves kind' '' reserve a
check 0 0 'unknown browser adoption preserves kind' '' adopt a "$$"
grep -qx kind=browser "$guard_home/.aeon-remote-leases/a" || fail 'legacy refresh lost browser kind'
guard_allow_unknown_lane=false check 3 0 'legacy disabled' 'lane required' reserve c
guard_allow_unknown_lane=false check 3 0 'legacy bare disabled' 'lane required'
guard_allow_unknown_lane=false check 3 0 'legacy adoption disabled' 'lane required' adopt a "$$"
guard_allow_unknown_lane=false request 0 '' known aeon test r
guard_allow_unknown_lane=false check 0 0 'known refresh without repeated args' '' reserve known
# Strict value-free client validation; nothing from untrusted values is echoed.
joint_home
for parameter in lane=invalid lane=unknown lane=AEON kind=invalid kind=Browser round= round=bad/id round=bad\ value "round=$long_id" phase=new phase=invalid; do
  check 3 0 'malformed client parameter' 'invalid' reserve invalid "$parameter"
  error=$(<"$scratch/stderr")
  [[ $error != *"$parameter"* ]] || fail 'client parameter leaked into refusal'
done
for parameter in 'lane=aeon lane=ait' 'kind=test kind=browser' 'round=a round=b' 'phase=finish phase=finish'; do
  read -r -a duplicate <<<"$parameter"
  check 3 0 'duplicate client field' 'duplicate client parameter' reserve invalid "${duplicate[@]}"
done
check 3 0 'unknown parameter' 'invalid client parameters' reserve invalid secret=value
check 3 0 'lane requires kind and round' 'incomplete client parameters' reserve invalid lane=aeon
check 3 0 'kind requires round' 'incomplete client parameters' reserve invalid kind=test
request 0 '' valid aeon test "$max_id"
# Finishing needs proof of this round, live or within 30 minutes.
joint_home
request 3 'finish round not recent' first aeon test never phase=finish
request 0 '' live aeon test matching
request 3 'finish round not recent' other ait test different phase=finish
request 0 '' finish ait test matching phase=finish
touch "$guard_home/.hold-mbp2606"
budget "maxruns=0 epoch=$(date +%s)"
check 0 0 'release while held/paused' '' release finish
check 0 0 'release round' '' release live
[[ ! -e $guard_home/.aeon-remote-leases/live ]] || fail 'release kept a unit'
unlink "$guard_home/.hold-mbp2606"
budget "maxruns=9 epoch=$(date +%s)"
request 0 '' recent ops test matching phase=finish
check 0 0 'release idempotent' '' release live
# Deterministic timestamps include both sides of the exact window boundary.
now=$(date +%s)
for age in 1799 1800 1801; do
  joint_home
  mkdir -p "$guard_home/.aeon-remote-leases"
  printf '%s matching\n' "$((now - age))" >"$guard_home/.aeon-remote-leases/.recent-rounds"
  expected=0 reason=''
  if ((age > 1800)); then expected=3 reason='finish round not recent'; fi
  PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
    request "$expected" "$reason" finishing aeon test matching phase=finish
done
# Marker liveness must keep the round eligible even after lease TTL expiry.
joint_home
request 0 '' marker aeon test marker-round
mkdir -p "$guard_home/.aeon-remote-test"
printf '%s\n' "$$" >"$guard_home/.aeon-remote-test/marker.pid"
python3 - "$guard_home/.aeon-remote-leases/marker" <<'PYTIME'
import os, sys, time
stamp = int(time.time()) - 2000
os.utime(sys.argv[1], (stamp, stamp))
PYTIME
: >"$guard_home/.aeon-remote-leases/.recent-rounds"
request 0 '' marker-finish ait test marker-round phase=finish
# Browser metadata must survive collection on repeated checks while a legacy
# pid marker remains live; collecting it would admit a second browser later.
joint_home
request 0 '' marked-browser aeon browser browser-round
mkdir -p "$guard_home/.aeon-remote-test"
printf '%s\n' "$$" >"$guard_home/.aeon-remote-test/marked-browser.pid"
python3 - "$guard_home/.aeon-remote-leases/marked-browser" <<'PYTIME'
import os, sys, time
stamp = int(time.time()) - 2000
os.utime(sys.argv[1], (stamp, stamp))
PYTIME
request 3 'browser cap' second-browser ait browser browser-round
request 3 'browser cap' third-browser ops browser browser-round
[[ -f $guard_home/.aeon-remote-leases/marked-browser ]] || fail 'GC lost live marker metadata'
unlink "$guard_home/.aeon-remote-test/marked-browser.pid"
request 0 '' after-cleanup ait browser browser-round
[[ ! -e $guard_home/.aeon-remote-leases/marked-browser ]] || fail 'dead marked lease not collected'
# External cleanup also leaves bounded proof; GC releases units and keeps rounds.
joint_home
request 0 '' old aeon test collected
python3 - "$guard_home/.aeon-remote-leases/old" "$((now - 121))" <<'PYTIME'
import os, sys
os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))
PYTIME
request 0 '' finish ait test collected phase=finish
[[ ! -e $guard_home/.aeon-remote-leases/old ]] || fail 'joint GC did not release unit'
check 0 0 'finish cleanup' '' release finish
request 0 '' start aeon test unlinked
unlink "$guard_home/.aeon-remote-leases/start"
request 0 '' end ait test unlinked phase=finish
joint_home
for i in 1 2 3 4 5 6; do
  guard_recent_round_limit=3 request 0 '' "r$i" aeon test "round-$i"
  guard_recent_round_limit=3 check 0 0 'bounded history release' '' release "r$i"
done
[[ $(wc -l <"$guard_home/.aeon-remote-leases/.recent-rounds") -eq 3 ]] || fail 'round history unbounded'
# Policy coupling: all gates intersect, and stale/missing policy keeps defaults.
joint_home
request 0 '' seed aeon test shared
policy "block=0 maxload=12 level=YELLOW epoch=$(date +%s)"
request 3 'joint new cap' yellow ait test shared
request 3 'browser cap' yellow-browser ait browser shared
request 0 '' finishing ait test shared phase=finish
policy "block=0 maxload=12 level=RED epoch=$(date +%s)"
check 0 0 'release under RED' '' release seed
check 0 0 'release finisher under RED' '' release finishing
request 3 'joint new cap' red aeon test shared
request 0 '' finishing-red ait test shared phase=finish
check 0 0 'release under RED again' '' release finishing-red
request 3 'finish round not recent' new-round ops test different phase=finish
policy "block=0 maxload=12 level=RED epoch=$((now - 901))"
request 0 '' stale-policy aeon test fresh
joint_home
policy "block=0 maxload=12 level=YELLOW epoch=$(date +%s)"
request 0 '' yellow-first aeon test shared
# A policy reduction must preserve finishing admission while earlier new work
# is still live above the reduced ceiling.
joint_home
request 0 '' active-a aeon test shared
request 0 '' active-b ait test shared
policy "block=0 maxload=12 level=RED epoch=$(date +%s)"
request 0 '' red-finish ops test shared phase=finish
check 0 0 'release RED finisher' '' release red-finish
policy "block=0 maxload=12 level=YELLOW epoch=$(date +%s)"
request 0 '' yellow-finish ops test shared phase=finish
joint_home
policy "block=0 maxload=12 level=YELLOW epoch=$(date +%s)"
request 0 '' yellow-first aeon test shared
# Existing maxruns and load remain additional ceilings, even for a finisher.
budget "maxruns=1 epoch=$(date +%s)"
request 3 '1/1 runs active (OPS budget)' maximum ait test shared phase=finish
budget "maxruns=9 epoch=$(date +%s)"
check 3 13 'finish obeys load gate' 'exceeds maxload' reserve loaded lane=ait kind=test round=shared phase=finish
# Strict, transactional override input; missing fields retain pinned defaults.
joint_home
printf 'epoch=%s units_new_max=1\n' "$(date +%s)" >"$guard_home/.aeon-remote-budget"
request 0 '' a aeon test shared
request 3 'joint new cap' b ait test shared
# Deliberately literal untrusted shell text must never be sourced.
# shellcheck disable=SC2016
for bad in \
  "units_new_max=1 epoch=$((now - 901))" \
  "units_new_max=1 epoch=$((now + 3600))" \
  "units_new_max=1 epoch=$now garbage=1" \
  "units_new_max=1 epoch=$now epoch=$now" \
  "units_new_max=1 units_new_max=2 epoch=$now" \
  "units_new_max=1 epoch=$now"$'\nsecond line' \
  "units_new_max=-1 epoch=$now" "units_new_max=01 epoch=$now" \
  "units_new_max=1000 epoch=$now" "units_new_max=1 epoch=9999999999999" \
  "units_new_max=1 epoch=$now trailing" 'units_new_max=1' \
  "epoch=$now" '$(touch SHOULD-NOT-EXIST)' ''; do
  joint_home
  printf '%s\n' "$bad" >"$guard_home/.aeon-remote-budget"
  request 0 '' a aeon test shared
  request 0 '' b ait test shared
  request 0 '' c ops test shared
  request 3 'joint new cap' d aeon test shared
done
now=$(date +%s)
for epoch in "$((now - 900))" "$((now + 60))"; do
  joint_home
  printf 'units_new_max=0 epoch=%s\n' "$epoch" >"$guard_home/.aeon-remote-budget"
  PATH="$scratch/clock-bin:$PATH" AEON_REMOTE_GUARD_TEST_CLOCK="$now" \
    request 3 'joint new cap' zero aeon test shared
done
joint_home
printf 'units_total=1 epoch=%s\n' "$(date +%s)" >"$guard_home/.aeon-remote-budget"
request 0 '' a aeon test shared
request 3 'joint total cap' b ait test shared phase=finish
joint_home
printf 'aeon_new_max=0 browser_max=0 epoch=%s\n' "$(date +%s)" >"$guard_home/.aeon-remote-budget"
request 3 'lane new cap' a aeon test shared
request 3 'browser cap' b ait browser shared
# Parallel clients exercise the whole transaction, including finishing history.
# Leases stay live until inspection; each successful exit must have one lease.
parallel_clients=0
for mode in unknown lanes browser-finish; do
  for _iteration in 1 2 3 4; do
    joint_home
    if [[ $mode == browser-finish ]]; then
      request 0 '' seed aeon test shared
      check 0 0 'parallel seed cleanup' '' release seed
    fi
    jobs=()
    for ((i = 0; i < 24; i++)); do
      args=(reserve "parallel-$i")
      if [[ $mode != unknown ]]; then
        lanes=(aeon ait ops)
        args+=("lane=${lanes[i % 3]}" kind=test round=shared)
        if [[ $mode == browser-finish && $((i % 4)) == 0 ]]; then args[3]=kind=browser; fi
        if [[ $mode == browser-finish && $((i % 5)) == 0 ]]; then args+=(phase=finish); fi
      fi
      (
        rc=0
        HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=0 "$BASH" "$guard" "${args[@]}" \
          >"$scratch/parallel-$i.out" 2>"$scratch/parallel-$i.err" || rc=$?
        printf '%s\n' "$rc" >"$scratch/parallel-$i.rc"
      ) &
      jobs+=("$!")
      parallel_clients=$((parallel_clients + 1))
    done
    for job in "${jobs[@]}"; do wait "$job"; done
    python3 - "$guard_home/.aeon-remote-leases" "$scratch" "$mode" <<'PY'
from pathlib import Path
import sys
leases, scratch, mode = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
records = []
for i in range(24):
    rc = int((scratch / f'parallel-{i}.rc').read_text())
    assert rc in (0, 3), rc
    p = leases / f'parallel-{i}'
    assert p.exists() == (rc == 0), (i, rc)
    assert not (scratch / f'parallel-{i}.out').read_text()
    if rc == 0:
        assert not (scratch / f'parallel-{i}.err').read_text()
        records.append(dict(line.split('=', 1) for line in p.read_text().splitlines()))
    else:
        error = (scratch / f'parallel-{i}.err').read_text()
        assert error.startswith('remote busy: ') and len(error.splitlines()) == 1
assert 1 <= len(records) <= 4
new = [r for r in records if r['phase'] != 'finish']
assert len(new) <= 3
assert sum(r['phase'] == 'finish' for r in records) <= 1
browsers = sum(r['kind'] == 'browser' for r in records)
assert browsers <= 1
assert not browsers or len(new) <= 2
for lane, cap in [('aeon', 2), ('ait', 1), ('ops', 1)]:
    assert sum(r['lane'] == lane for r in new) <= cap
if mode in ('unknown', 'lanes'):
    assert len(records) == 3, records
PY
    count=$((count + 1))
  done
done
joint_count=$((count - legacy_count))
printf 'T90 joint budget ok: %s cases; %s parallel clients in 12 batches\n' "$joint_count" "$parallel_clients"

printf 'T90 runtime ok: %s guard cases; busy/allowed/mixed/deletion local pushes through executable symlink; 5000 stdin lines drained; hook exit 3\n' "$count"

if $runtime_only; then
  printf 'T90 Nix host eval not run (--runtime-only)\n'
  exit 0
fi
nix-instantiate --parse "$repo/modules/aeon-remote-guard/default.nix" >/dev/null
evidence=$(AEON_REMOTE_GUARD_EVAL_ROOT="$repo" nix eval --offline --impure --json \
  --file "$repo/tests/aeon-remote-guard-eval.nix" \
  --apply 'f: f { root = builtins.getEnv "AEON_REMOTE_GUARD_EVAL_ROOT"; }')
python3 - "$evidence" <<'PY'
import json
import sys

evidence = json.loads(sys.argv[1])
failed = [name for name, passed in evidence["checks"].items() if passed is not True]
assert not failed, "mbp2606 mba Home Manager checks failed: " + ", ".join(failed)
print("T90 Nix host eval ok: %d checks; hook %s" % (len(evidence["checks"]), evidence["hookSource"]))
PY
