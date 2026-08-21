#!/usr/bin/env bash
# OPS-187 fleet drift watch contract (csb1).
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod="${repo}/hosts/csb1/fleet-drift.nix"
checks="${repo}/hosts/csb1/fleet-drift-checks.py"
conf="${repo}/hosts/csb1/configuration.nix"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_fleet_drift_checks.py' -v
nix-instantiate --parse "${mod}" >/dev/null

grep -Fq './fleet-drift.nix' "${conf}"
grep -Fq 'name = "fleet-drift"' "${mod}"
grep -Fq './fleet-drift-checks.py' "${mod}"
grep -Fq 'csb1_pharos_data/_data/pharos.json' "${mod}"
grep -Fq 'age.secrets.csb1-watchtower-env.path' "${mod}"
grep -Fq 'ReadOnlyPaths = [ storePath ]' "${mod}"
grep -Fq 'OnUnitActiveSec = "1h"' "${mod}"
grep -Fq 'StateDirectory = "fleet-drift"' "${mod}"
grep -Fq 'SuccessExitStatus = [' "${mod}"
for ph in '@STORE_PATH@' '@NIXCFG_CHECKOUT@' '@GIT_BIN@' '@NOTIFICATION_ENV@'; do
  grep -Fq "${ph}" "${checks}"
done
grep -Fq 'STALE_SECONDS' "${checks}"
grep -Fq '"/var/lib/fleet-drift/state.json"' "${checks}"
echo "T46 ok"
