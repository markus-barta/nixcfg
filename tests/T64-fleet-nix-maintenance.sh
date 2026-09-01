#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

maintenance=$(nix eval --json .#nixosConfigurations --apply '
  configs:
  builtins.mapAttrs (
    _: system: {
      gcAutomatic = system.config.nix.gc.automatic;
      nhClean = system.config.programs.nh.clean;
      optimise = {
        inherit (system.config.nix.optimise) automatic dates randomizedDelaySec;
      };
    }
  ) configs
')

if ! jq -e '
  keys == ["csb0", "csb1", "hsb0", "hsb1", "hsb8", "hsb9"]
  and all(.[];
    .gcAutomatic == false
    and .nhClean == {
      "dates": "weekly",
      "enable": true,
      "extraArgs": "--keep-since 14d --keep 4"
    }
    and .optimise == {
      "automatic": true,
      "dates": ["Sun *-*-* 06:15:00"],
      "randomizedDelaySec": "45m"
    }
  )
' <<<"$maintenance" >/dev/null; then
  printf 'fleet_nix_maintenance=failed reason=unexpected_evaluated_contract\n' >&2
  jq . <<<"$maintenance" >&2
  exit 1
fi

printf 'fleet_nix_maintenance=passed hosts=6 cleaner=nh-weekly competing_gc=disabled optimise=weekly\n'
