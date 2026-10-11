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
scratch=$(mktemp -d "${TMPDIR:-/tmp}/aeon-remote-guard.XXXXXX")
cleanup() {
  # Only our fixture. CI runners may not have trash; their temp space expires.
  if command -v trash >/dev/null 2>&1 && trash "$scratch" 2>/dev/null; then
    return
  fi
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
  HOME="$guard_home" AEON_REMOTE_GUARD_LOAD="$sample" "$BASH" "$guard" \
    >"$scratch/stdout" 2>"$scratch/stderr" || rc=$?
  [[ $rc == "$expected" ]] || fail "$label: exit $rc, expected $expected"
  [[ ! -s "$scratch/stdout" ]] || fail "$label: unexpected stdout"
  if [[ $expected == 0 ]]; then
    [[ ! -s "$scratch/stderr" ]] || fail "$label: allow must be silent"
  else
    [[ $(wc -l <"$scratch/stderr") -eq 1 ]] || fail "$label: refusal must be one line"
    local error
    error=$(<"$scratch/stderr")
    [[ $error == 'remote busy'* ]] || fail "$label: missing remote busy prefix"
    [[ $error == *'retry in a few minutes or rely on PR CI' ]] || fail "$label: missing retry guidance"
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
mkdir "$guard_home/.aeon-remote-policy"
check 3 13 'non-file policy' 'malformed policy ignored'

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
printf '#!%s\nexec %q %q\n' "$BASH" "$BASH" "$guard" >"$scratch/guard"
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

# Stdin must be drained even on refusal, including more than one ref line.
set +e
for ((i = 0; i < 5000; i++)); do
  printf 'old new refs/runs/%s\n' "$i"
done |
  HOME="$guard_home" AEON_REMOTE_GUARD_LOAD=15 "$scratch/pre-receive" \
    >"$scratch/stdout" 2>"$scratch/stderr"
pipe_status=("${PIPESTATUS[@]}")
set -e
[[ ${pipe_status[0]} == 0 && ${pipe_status[1]} == 3 ]] || fail "hook did not drain stdin or exit 3: ${pipe_status[*]}"
printf 'T90 runtime ok: %s guard cases; busy/allowed local pushes through executable symlink; hook exit 3\n' "$count"

if $runtime_only; then
  printf 'T90 Nix host eval not run (--runtime-only)\n'
  exit 0
fi
nix-instantiate --parse "$repo/modules/aeon-remote-guard/default.nix" >/dev/null
evidence=$(AEON_REMOTE_GUARD_EVAL_ROOT="$repo" nix eval --impure --json \
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
