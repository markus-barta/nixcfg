#!/usr/bin/env bash
# OPS-181 / OPS-185 tailnet witness contract (csb1 + hsb1).
#
# After the 2026-08-21 empty-DERP-map outage went unpaged for ~57 minutes,
# csb1 (netcup) and hsb1 (home, different failure domain) each run a tiny
# OPS-107 poller that reads their own tailscale view — one shared check file,
# per-host substitutions. This pins the wiring nothing else catches at build time.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checks="${repo}/modules/shared/fleet-alerts/tailnet-watch-checks.py"
secrets="${repo}/secrets/secrets.nix"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_tailnet_watch_checks.py' -v
for host in csb1 hsb1; do
  mod="${repo}/hosts/${host}/tailnet-watch.nix"
  conf="${repo}/hosts/${host}/configuration.nix"
  nix-instantiate --parse "${mod}" >/dev/null
  # Wiring
  grep -Fq './tailnet-watch.nix' "${conf}"
  grep -Fq 'name = "tailnet-watch"' "${mod}"
  grep -Fq '../../modules/shared/fleet-alerts/tailnet-watch-checks.py' "${mod}"
  grep -Fq "HOSTNAME = \"${host}\"" "${mod}"
  grep -Fq 'config.services.tailscale.package' "${mod}"
  grep -Fq '"AF_UNIX"' "${mod}"
  grep -Fq 'ReadWritePaths = [ "/run/tailscale" ]' "${mod}"
  grep -Fq 'OnUnitActiveSec = "10m"' "${mod}"
  grep -Fq 'StateDirectory = "tailnet-watch"' "${mod}"
  # Exit contract: 2 (undeliverable) must fail the unit; 0/1 must not.
  grep -Fq 'SuccessExitStatus = [' "${mod}"
done
# Per-host notification env: csb1 reuses its watchtower env, hsb1 has its own agenix secret.
grep -Fq 'age.secrets.csb1-watchtower-env.path' "${repo}/hosts/csb1/tailnet-watch.nix"
grep -Fq 'age.secrets.hsb1-tailnet-watch-env.path' "${repo}/hosts/hsb1/tailnet-watch.nix"
grep -Fq '../../secrets/hsb1-tailnet-watch-env.age' "${repo}/hosts/hsb1/tailnet-watch.nix"
grep -Fq '"hsb1-tailnet-watch-env.age".publicKeys = markus ++ hsb1;' "${secrets}"

# Check-file contract
grep -Fq '@TAILSCALE_BIN@' "${checks}"
grep -Fq '@NOTIFICATION_ENV@' "${checks}"
grep -Fq '"/var/lib/tailnet-watch/state.json"' "${checks}"
grep -Fq 'WATCHTOWER_NOTIFICATION_URL' "${checks}"
grep -Fq 'SUPPRESSED_HEALTH' "${checks}"
grep -Fq '@HOSTNAME@' "${checks}"
grep -Fq '"debug", "derp-map"' "${checks}"
echo "T44 ok"
