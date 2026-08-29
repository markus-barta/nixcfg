#!/usr/bin/env bash
# NIX-375 — the operator Home Manager profile must consume the public
# inspr-modules CLI module and render exactly the six non-secret fleet-routing
# values that belong to this private studio.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
defaults="$repo_root/modules/shared/markus-defaults.nix"
operator_home="$repo_root/hosts/mbp2607/home.nix"

fail() {
  printf 'T55 failed: %s\n' "$*" >&2
  exit 1
}

grep -Fq 'inputs.inspr-modules.homeManagerModules.inspr-cli' "$defaults" ||
  fail 'the personal defaults do not import homeManagerModules.inspr-cli'
grep -Fq 'inspr.cli.enable = true;' "$operator_home" ||
  fail 'the mbp2607 operator profile does not enable inspr.cli'

fleet_conf=$(
  cd "$repo_root"
  nix eval --raw '.#homeConfigurations."markus@mbp2607".config.xdg.configFile."inspr/fleet.conf".text'
)

expected_assignments='INSPR_HEADSCALE_URL="https://hs.barta.cm"
INSPR_PAIMOS_INSTANCE="ppm"
INSPR_PAIMOS_URL="https://pm.barta.cm"
INSPR_PHAROS_HOST="csb1"
INSPR_PHAROS_URL="https://pharos.barta.cm"
INSPR_TAILNET_NAME="hs.barta.cm"'
actual_assignments=$(printf '%s\n' "$fleet_conf" | sed -n '/^INSPR_[A-Z_]*=/p' | LC_ALL=C sort)

[ "$actual_assignments" = "$expected_assignments" ] ||
  fail 'rendered fleet.conf does not contain exactly the six approved public routing values'

if printf '%s\n' "$actual_assignments" | grep -Eq '(TOKEN|PASSWORD|SECRET|CREDENTIAL|API_KEY|PRIVATE_KEY)'; then
  fail 'rendered fleet.conf contains a credential-shaped variable name'
fi

printf 'T55 passed: mbp2607 renders exactly six non-secret inspr fleet values\n'
