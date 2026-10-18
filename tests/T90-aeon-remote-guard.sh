#!/usr/bin/env bash
# OPS-300 — host-side refusal and the actual executable symlink Git hook.
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
for invalid in '' . .. .reservation.internal '../escape' 'bad/id' 'bad id' $'invalid-\xc3\xa9' "$long_id"; do
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
new_home
mkdir "$guard_home/actual-leases"
ln -s "$guard_home/actual-leases" "$guard_home/.aeon-remote-leases"
check 3 0 'lease directory symlink refused' 'cannot read run leases'
new_home
mkdir "$guard_home/actual-markers"
ln -s "$guard_home/actual-markers" "$guard_home/.aeon-remote-test"
check 3 0 'marker directory symlink refused' 'cannot read run markers'

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
rm -f "$guard_home/.aeon-remote-leases/fifo"

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
PATH="$scratch/fault-bin:$PATH" check 3 0 'adopt rejects another uid' 'cannot adopt run pid' adopt foreign "$$"
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
for invalid in nested/invalid "$long_id" .reservation.internal; do
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
