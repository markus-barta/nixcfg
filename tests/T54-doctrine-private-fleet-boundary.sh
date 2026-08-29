#!/usr/bin/env bash
# NIX-374: fleet refreshes must never require credentials for the private
# doctrine repository, while an operator checkout that already has it may keep
# updating it. The missing private kernel must also be explicit to agents.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old; run under bash 5\n' "${0##*/}" "$BASH_VERSION" >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
config="$repo_root/modules/uzumaki/fish/config.nix"
rules="$repo_root/AGENTS-NIXCFG.md"
switch_recipe="$repo_root/justfile"
workflow="$repo_root/.github/workflows/check.yml"

fail() {
  printf 'doctrine_private_fleet_boundary=failed reason=%s\n' "$1" >&2
  exit 1
}

aliases_json=$(nix eval --impure --json --expr "(import $config).fishAliases")
alias_value() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1" <<<"$aliases_json"
}
gitpl=$(alias_value gitpl)
gitsub=$(alias_value gitsub)

fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/nix-374-doctrine.XXXXXX")
trap 'chmod -R u+w "$fixture_root"; rm -rf -- "$fixture_root"' EXIT

make_upstream() {
  local name=$1
  git init -q "$fixture_root/$name-src"
  git -C "$fixture_root/$name-src" config user.name fixture
  git -C "$fixture_root/$name-src" config user.email fixture@example.invalid
  printf '%s\n' "$name" >"$fixture_root/$name-src/README"
  git -C "$fixture_root/$name-src" add README
  git -C "$fixture_root/$name-src" commit -qm "seed $name"
}

make_upstream doctrine
make_upstream doctrine-private
git init -q "$fixture_root/super"
git -C "$fixture_root/super" config user.name fixture
git -C "$fixture_root/super" config user.email fixture@example.invalid
git -C "$fixture_root/super" -c protocol.file.allow=always submodule add -q \
  "$fixture_root/doctrine-src" doctrine
git -C "$fixture_root/super" -c protocol.file.allow=always submodule add -q \
  "$fixture_root/doctrine-private-src" doctrine-private
git -C "$fixture_root/super" commit -qam 'seed consumer'

run_alias() {
  local checkout=$1 alias_text=$2
  (
    cd "$checkout"
    env GIT_ALLOW_PROTOCOL=file fish -c "$alias_text"
  )
}

# A fresh fleet checkout gets the public doctrine only. An unconditional
# `git submodule update --init` fails this assertion by initializing private.
for alias_name in gitpl gitsub; do
  checkout="$fixture_root/fleet-$alias_name"
  git clone -q "$fixture_root/super" "$checkout"
  alias_text=$gitpl
  [[ "$alias_name" == gitsub ]] && alias_text=$gitsub
  run_alias "$checkout" "$alias_text"
  [[ -e "$checkout/doctrine/.git" ]] || fail "$alias_name-public-not-initialized"
  [[ ! -e "$checkout/doctrine-private/.git" ]] || fail "$alias_name-private-initialized-on-fleet"
  [[ "$(git -C "$checkout" submodule status doctrine-private)" == -* ]] ||
    fail "$alias_name-private-not-left-uninitialized"
done

# An operator checkout that has explicitly initialized private doctrine keeps
# both paths current; the fleet-safe default must not regress operator use.
git clone -q "$fixture_root/super" "$fixture_root/operator"
git -C "$fixture_root/operator" -c protocol.file.allow=always submodule update -q --init \
  doctrine doctrine-private
run_alias "$fixture_root/operator" "$gitpl"
run_alias "$fixture_root/operator" "$gitsub"
[[ -e "$fixture_root/operator/doctrine/.git" ]] || fail operator-public-lost
[[ -e "$fixture_root/operator/doctrine-private/.git" ]] || fail operator-private-lost

# The automatically loaded repo delta is the warning surface for an agent
# session on a fleet host. The switch drift message scopes itself to the public
# pin so intentional private absence is not mislabeled as drift.
grep -Fq 'git submodule update --init doctrine' "$rules" || fail safe_refresh_not_documented
grep -Fq 'doctrine-private is intentionally absent' "$rules" || fail private_absence_not_explicit
grep -Fq 'private operator rules are not loaded' "$rules" || fail missing_rules_not_explicit
grep -Fq 'git submodule status doctrine' "$switch_recipe" || fail switch_checks_all_submodules
grep -Fq "grep -E '^[+-]'" "$switch_recipe" || fail missing_public_checkout_not_reported
[[ "$(grep -Fc 'run: nix-shell -p bash fish --run "bash tests/T54-doctrine-private-fleet-boundary.sh"' "$workflow")" == 1 ]] ||
  fail ci_wiring_count

printf 'doctrine_private_fleet_boundary=ok aliases=2 fleet_private=uninitialized operator_private=retained\n'
