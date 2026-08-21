#!/usr/bin/env bash
# OPS-181 tailnet witness contract (csb1).
#
# After the 2026-08-21 empty-DERP-map outage went unpaged for ~57 minutes,
# csb1 runs a second tiny OPS-107 poller that reads its own tailscale view.
# This pins the wiring that nothing else would catch at build time.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod="${repo}/hosts/csb1/tailnet-watch.nix"
checks="${repo}/hosts/csb1/tailnet-watch-checks.py"
conf="${repo}/hosts/csb1/configuration.nix"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_tailnet_watch_checks.py' -v
nix-instantiate --parse "${mod}" >/dev/null

# Wiring
grep -Fq './tailnet-watch.nix' "${conf}"
grep -Fq 'name = "tailnet-watch"' "${mod}"
grep -Fq './tailnet-watch-checks.py' "${mod}"
grep -Fq 'config.services.tailscale.package' "${mod}"
grep -Fq 'age.secrets.csb1-watchtower-env.path' "${mod}"
grep -Fq '"AF_UNIX"' "${mod}"
grep -Fq 'ReadWritePaths = [ "/run/tailscale" ]' "${mod}"
grep -Fq 'OnUnitActiveSec = "10m"' "${mod}"
grep -Fq 'StateDirectory = "tailnet-watch"' "${mod}"

# Check-file contract
grep -Fq '@TAILSCALE_BIN@' "${checks}"
grep -Fq '@NOTIFICATION_ENV@' "${checks}"
grep -Fq '"/var/lib/tailnet-watch/state.json"' "${checks}"
grep -Fq 'WATCHTOWER_NOTIFICATION_URL' "${checks}"
grep -Fq 'SUPPRESSED_HEALTH' "${checks}"
grep -Fq '"debug", "derp-map"' "${checks}"
# Exit contract: 2 (undeliverable) must fail the unit; 0/1 must not.
grep -Fq 'SuccessExitStatus = [' "${mod}"
echo "T44 ok"
