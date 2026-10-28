#!/usr/bin/env bash
# OPS-485 fleet backup watch contract (csb1).
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod="${repo}/hosts/csb1/fleet-backup-watch.nix"
checks="${repo}/hosts/csb1/fleet-backup-watch-checks.py"
conf="${repo}/hosts/csb1/configuration.nix"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_fleet_backup_watch_checks.py' -v
nix-instantiate --parse "${mod}" >/dev/null

grep -Fq './fleet-backup-watch.nix' "${conf}"
grep -Fq 'name = "fleet-backup-watch"' "${mod}"
grep -Fq './fleet-backup-watch-checks.py' "${mod}"
grep -Fq 'csb1_pharos_data/_data/pharos.json' "${mod}"
grep -Fq 'age.secrets.csb1-watchtower-env.path' "${mod}"
grep -Fq 'ReadOnlyPaths = [ storePath ]' "${mod}"
grep -Fq 'OnUnitActiveSec = "1h"' "${mod}"
grep -Fq 'StateDirectory = "fleet-backup-watch"' "${mod}"
grep -Fq 'SuccessExitStatus = [' "${mod}"
for ph in '@STORE_PATH@' '@NOTIFICATION_ENV@'; do
  grep -Fq "${ph}" "${checks}"
done
grep -Fq 'PAGED_BY_PHAROS' "${checks}"
grep -Fq '"/var/lib/fleet-backup-watch/state.json"' "${checks}"
echo "T114 ok"
