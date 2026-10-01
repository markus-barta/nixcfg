#!/usr/bin/env bash
# NIX-603 — macOS standalone Home Manager gets a weekly dead-paths-only Nix GC
# plus a low-space guard, and only where a host opts in: exactly one account per
# Mac, the one that owns the console session (user launchd agents need a
# graphical session; the store is shared by every account on the machine).
# Eval-only: nothing is built and no garbage collection runs.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'T90 failed: %s\n' "$*" >&2
  exit 1
}

module="$repo_root/modules/uzumaki/nix-gc.nix"
home_module="$repo_root/modules/uzumaki/home-manager.nix"

grep -Fq './nix-gc.nix' "$home_module" || fail 'uzumaki home-manager.nix does not import nix-gc.nix'
grep -Fq 'nixGc.enable = true;' "$repo_root/hosts/mbp2607/home.nix" || fail 'mbp2607 does not opt in to uzumaki.nixGc'
grep -Fq 'uzumaki.nixGc.enable = true;' "$repo_root/hosts/mbp2606/home-ci.nix" || fail 'mbp2606 ci does not opt in to uzumaki.nixGc'
# mba has no graphical session on mbp2606, so its user agents could never load
# (2026-10-01: "Bootstrap failed: 125: Domain does not support specified action").
if grep -Fq 'nixGc.enable = true;' "$repo_root/hosts/mbp2606/home.nix"; then
  fail 'mba@mbp2606 must not opt in (no graphical session there; the agents would never load)'
fi

# Dead paths only: the collector must be `nix-store --gc`, never the variant
# that can delete generations.
grep -Fq 'nix-store --gc' "$module" || fail 'module does not run nix-store --gc'
if grep -Fq 'nix-collect-garbage' "$module"; then
  fail 'module must not use nix-collect-garbage (generation deletion)'
fi

nixgc_agents() {
  (cd "$repo_root" && nix eval --raw ".#homeConfigurations.\"$1\".config.launchd.agents" \
    --apply 'a: builtins.concatStringsSep "," (builtins.filter (n: builtins.match "nix-gc.*" n != null) (builtins.attrNames a))')
}

# Opted in: one account per Mac, the one that owns the console session.
for home in 'markus@mbp2607' 'ci@mbp2606'; do
  agents=$(nixgc_agents "$home")
  [ "$agents" = 'nix-gc,nix-gc-lowspace' ] || fail "$home agents are '$agents', expected nix-gc,nix-gc-lowspace"

  # shellcheck disable=SC2016 # Nix string interpolation, not shell expansion.
  weekly=$(cd "$repo_root" && nix eval --raw ".#homeConfigurations.\"$home\".config.launchd.agents.nix-gc.config.StartCalendarInterval" \
    --apply 'c: let i = builtins.head c; in "${toString i.Weekday}-${toString i.Hour}-${toString i.Minute}"')
  [ "$weekly" = '0-4-0' ] || fail "$home weekly schedule is '$weekly', expected Sunday 04:00 (0-4-0)"

  interval=$(cd "$repo_root" && nix eval --raw ".#homeConfigurations.\"$home\".config.launchd.agents.nix-gc-lowspace.config.StartInterval" \
    --apply 'i: toString i')
  [ "$interval" = 1800 ] || fail "$home low-space interval is '$interval', expected 1800"
done

# Opted out: the other accounts on mbp2606 must stay inert.
for home in 'mba@mbp2606' 'mailina@mbp2606'; do
  other=$(nixgc_agents "$home")
  [ -z "$other" ] || fail "$home unexpectedly has Nix GC agents: $other"
done

printf 'T90 ok: NIX-603 nix-gc agents on markus@mbp2607 and ci@mbp2606 only, weekly Sunday 04:00 + 30 min low-space guard\n'
