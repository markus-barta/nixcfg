#!/usr/bin/env bash
# NIX-603 — macOS standalone Home Manager gets a weekly dead-paths-only Nix GC
# plus a low-space guard, and only where a host opts in. Eval-only: nothing is
# built and no garbage collection runs.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'T90 failed: %s\n' "$*" >&2
  exit 1
}

module="$repo_root/modules/uzumaki/nix-gc.nix"
home_module="$repo_root/modules/uzumaki/home-manager.nix"
host_home="$repo_root/hosts/mbp2607/home.nix"

grep -Fq './nix-gc.nix' "$home_module" || fail 'uzumaki home-manager.nix does not import nix-gc.nix'
grep -Fq 'nixGc.enable = true;' "$host_home" || fail 'mbp2607 does not opt in to uzumaki.nixGc'

# Dead paths only: the collector must be `nix-store --gc`, never the variant
# that can delete generations.
grep -Fq 'nix-store --gc' "$module" || fail 'module does not run nix-store --gc'
if grep -Fq 'nix-collect-garbage' "$module"; then
  fail 'module must not use nix-collect-garbage (generation deletion)'
fi

agents=$(cd "$repo_root" && nix eval --raw '.#homeConfigurations."markus@mbp2607".config.launchd.agents' \
  --apply 'a: builtins.concatStringsSep "," (builtins.filter (n: builtins.match "nix-gc.*" n != null) (builtins.attrNames a))')
[ "$agents" = 'nix-gc,nix-gc-lowspace' ] || fail "mbp2607 agents are '$agents', expected nix-gc,nix-gc-lowspace"

# shellcheck disable=SC2016 # Nix string interpolation, not shell expansion.
weekly=$(cd "$repo_root" && nix eval --raw '.#homeConfigurations."markus@mbp2607".config.launchd.agents.nix-gc.config.StartCalendarInterval' \
  --apply 'c: let i = builtins.head c; in "${toString i.Weekday}-${toString i.Hour}-${toString i.Minute}"')
[ "$weekly" = '0-4-0' ] || fail "weekly schedule is '$weekly', expected Sunday 04:00 (0-4-0)"

interval=$(cd "$repo_root" && nix eval --raw '.#homeConfigurations."markus@mbp2607".config.launchd.agents.nix-gc-lowspace.config.StartInterval' \
  --apply 'i: toString i')
[ "$interval" = 1800 ] || fail "low-space interval is '$interval', expected 1800"

# Inert everywhere else: the store is shared per Mac, so exactly one user opts in.
for home in 'mba@mbp2606' 'mailina@mbp2606'; do
  other=$(cd "$repo_root" && nix eval --raw ".#homeConfigurations.\"$home\".config.launchd.agents" \
    --apply 'a: builtins.concatStringsSep "," (builtins.filter (n: builtins.match "nix-gc.*" n != null) (builtins.attrNames a))')
  [ -z "$other" ] || fail "$home unexpectedly has Nix GC agents: $other"
done

printf 'T90 ok: NIX-603 nix-gc agents exist on mbp2607 only, weekly Sunday 04:00 + 30 min low-space guard\n'
