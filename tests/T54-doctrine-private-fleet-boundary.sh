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
# The source attrset is not the deployed value: hokage also defines these
# aliases. Prove our forced definitions win in both system and Home Manager
# layers, in both deployed shells, on every fleet host.
for host_name in hsb0 hsb1 hsb8 hsb9 csb0 csb1; do
  effective_json=$(
    nix eval --json --no-update-lock-file "$repo_root#nixosConfigurations.$host_name.config" \
      --apply 'c: {
        systemFish = c.programs.fish.shellAliases;
        systemBash = c.programs.bash.shellAliases;
        homeFish = c."home-manager".users.mba.programs.fish.shellAliases;
        homeBash = c."home-manager".users.mba.programs.bash.shellAliases;
      }'
  )
  for layer_name in systemFish systemBash homeFish homeBash; do
    for alias_name in gitpl gitplr gitsub; do
      expected=$(alias_value "$alias_name")
      actual=$(python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]][sys.argv[2]])' \
        "$layer_name" "$alias_name" <<<"$effective_json")
      [[ "$actual" == "$expected" ]] || fail "$host_name-$layer_name-$alias_name-effective-mismatch"
    done
  done
done

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
mkdir "$fixture_root/super/hosts"
printf 'fixture\n' >"$fixture_root/super/hosts/README"
git -C "$fixture_root/super" add hosts/README
git -C "$fixture_root/super" commit -qam 'seed consumer'

run_alias() {
  local checkout=$1 shell_name=$2 alias_name=$3 alias_text=$4
  (
    cd "$checkout/hosts"
    case "$shell_name" in
    fish)
      env GIT_ALLOW_PROTOCOL=file ALIAS_TEXT="$alias_text" \
        fish -c "alias $alias_name \"\$ALIAS_TEXT\"; type -q $alias_name; $alias_name"
      ;;
    bash)
      env GIT_ALLOW_PROTOCOL=file ALIAS_TEXT="$alias_text" \
        bash -c "shopt -s expand_aliases; alias $alias_name=\"\$ALIAS_TEXT\"; test \"\$(type -t $alias_name)\" = alias; eval $alias_name"
      ;;
    *) fail "unknown-shell-$shell_name" ;;
    esac
  )
}

# A fresh fleet checkout gets the public doctrine only. Exercise the actual
# alias renderer in both deployed shells and invoke from a repository subdir.
for shell_name in fish bash; do
  for alias_name in gitpl gitplr gitsub; do
    checkout="$fixture_root/fleet-$shell_name-$alias_name"
    git clone -q "$fixture_root/super" "$checkout"
    alias_text=$(alias_value "$alias_name")
    run_alias "$checkout" "$shell_name" "$alias_name" "$alias_text"
    [[ -e "$checkout/doctrine/.git" ]] || fail "$shell_name-$alias_name-public-not-initialized"
    [[ ! -e "$checkout/doctrine-private/.git" ]] || fail "$shell_name-$alias_name-private-initialized-on-fleet"
    [[ "$(git -C "$checkout" submodule status doctrine-private)" == -* ]] ||
      fail "$shell_name-$alias_name-private-not-left-uninitialized"
  done
done

# Create operator checkouts at the original private pin before advancing it.
for shell_name in fish bash; do
  for alias_name in gitpl gitplr gitsub; do
    checkout="$fixture_root/operator-$shell_name-$alias_name"
    git clone -q "$fixture_root/super" "$checkout"
    git -C "$checkout" -c protocol.file.allow=always submodule update -q --init \
      doctrine doctrine-private
  done
done

# Advance the private upstream and the superproject pin. Every initialized
# operator checkout must actually move to this revision; mere directory
# existence would be a vacuous assertion.
printf 'advanced\n' >>"$fixture_root/doctrine-private-src/README"
git -C "$fixture_root/doctrine-private-src" add README
git -C "$fixture_root/doctrine-private-src" commit -qm 'advance private doctrine'
new_private_rev=$(git -C "$fixture_root/doctrine-private-src" rev-parse HEAD)
git -C "$fixture_root/super/doctrine-private" fetch -q origin
git -C "$fixture_root/super/doctrine-private" checkout -q "$new_private_rev"
git -C "$fixture_root/super" add doctrine-private
git -C "$fixture_root/super" commit -qm 'advance private pin'

for shell_name in fish bash; do
  for alias_name in gitpl gitplr gitsub; do
    checkout="$fixture_root/operator-$shell_name-$alias_name"
    [[ "$alias_name" == gitsub ]] && git -C "$checkout" pull -q --ff-only
    alias_text=$(alias_value "$alias_name")
    run_alias "$checkout" "$shell_name" "$alias_name" "$alias_text"
    [[ "$(git -C "$checkout/doctrine-private" rev-parse HEAD)" == "$new_private_rev" ]] ||
      fail "$shell_name-$alias_name-operator-private-not-updated"
  done
done

# The automatically loaded repo delta is the warning surface for an agent
# session on a fleet host. The switch drift message scopes itself to the public
# pin so intentional private absence is not mislabeled as drift.
grep -Fq 'git submodule update --init doctrine' "$rules" || fail safe_refresh_not_documented
grep -Fq 'doctrine-private is intentionally absent' "$rules" || fail private_absence_not_explicit
grep -Fq 'private operator rules are not loaded' "$rules" || fail missing_rules_not_explicit
grep -Fq 'git submodule status doctrine' "$switch_recipe" || fail switch_checks_all_submodules
grep -Fq '[ -e doctrine-private/.git ]' "$switch_recipe" || fail operator_private_drift_not_checked
grep -Fq "grep -E '^[+-]'" "$switch_recipe" || fail missing_public_checkout_not_reported
[[ "$(grep -Fc 'run: nix-shell -p bash fish --run "bash tests/T54-doctrine-private-fleet-boundary.sh"' "$workflow")" == 1 ]] ||
  fail ci_wiring_count

printf 'doctrine_private_fleet_boundary=ok hosts=6 aliases=6 fleet_private=uninitialized operator_private=updated\n'
