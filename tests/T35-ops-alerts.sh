#!/usr/bin/env bash
# OPS-104 / OPS-107 fleet alert contract.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="${repo}/modules/shared/fleet-alerts/engine.py"
heartbeat="${repo}/modules/shared/fleet-alerts/heartbeat.nix"
fleetlib="${repo}/modules/shared/fleet-alerts/lib.nix"
csb0mod="${repo}/hosts/csb0/ops-alerts.nix"
csb0checks="${repo}/hosts/csb0/ops-alerts-checks.py"
csb1mod="${repo}/hosts/csb1/peer-watch.nix"
csb1checks="${repo}/hosts/csb1/peer-watch-checks.py"
secrets="${repo}/secrets/secrets.nix"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_fleet_alerts_engine.py' -v
# OPS-115: the smart-home link check that would have caught the two-day
# access-gate outage. Discovered separately so a rename of either file is a
# loud failure rather than a silently skipped suite.
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_ops_alerts_smarthome_link.py' -v
for module in "${heartbeat}" "${fleetlib}" "${csb0mod}" "${csb1mod}"; do
  nix-instantiate --parse "${module}" >/dev/null
done

# OPS-115 wiring: the heartbeat probe must stay pointed at loopback, and the
# broker credential must reach the unit. Both are easy to lose in a refactor and
# neither fails loudly at build time.
grep -Fq 'SMARTHOME_LINKS_JSON' "${csb0mod}"
grep -Fq 'SMARTHOME_LINKS_JSON' "${csb0checks}"
grep -Fq 'check_smarthome_link' "${csb0checks}"
grep -Fq 'paho-mqtt' "${csb0mod}"
grep -Fq 'age.secrets.mqtt-csb0.path' "${csb0mod}"
grep -Fq '127.0.0.1:1883:1883' "${repo}/hosts/csb0/docker/compose-spec.nix"

# Wiring
grep -Fq './ops-alerts.nix' "${repo}/hosts/csb0/configuration.nix"
grep -Fq 'fleet-alerts/heartbeat.nix' "${repo}/hosts/csb0/configuration.nix"
grep -Fq './peer-watch.nix' "${repo}/hosts/csb1/configuration.nix"
grep -Fq 'fleet-alerts/heartbeat.nix' "${repo}/hosts/csb1/configuration.nix"
grep -Fq '"csb0-ops-alerts-env.age".publicKeys' "${secrets}"
grep -Fq 'config.age.secrets.csb0-ops-alerts-env.path' "${csb0mod}"

# All three HA instances must stay watched. Dropping one silently is how a host
# goes unmonitored -- the exact failure this poller exists to catch.
for host in hsb1 hsb8 hsb9; do
  grep -Fq "name = \"${host}\";" "${csb0mod}"
done

# OPS-107: the two pollers must watch EACH OTHER. A host cannot detect its own
# death, so neither side may be the only watcher.
grep -Fq 'name = "csb1";' "${csb0mod}"
grep -Fq 'name = "csb0";' "${csb1mod}"
grep -Fq 'nixcfg.fleetAlerts.heartbeat' "${csb0mod}"
grep -Fq 'nixcfg.fleetAlerts.heartbeat' "${csb1mod}"
# Heartbeat must never be exposed on the public interface -- both are internet-facing.
grep -Fq 'networking.firewall.interfaces."tailscale0".allowedTCPPorts' "${heartbeat}"
if grep -Fq 'networking.firewall.allowedTCPPorts' "${heartbeat}"; then
  printf 'heartbeat must not open a port on the public interface\n' >&2
  exit 1
fi

# Durability contract (adopted from hausv-alerts, NIX-332). An alert that cannot
# be delivered must be retried, not dropped, and must fail the unit.
grep -Fq 'EXIT_UNDELIVERED = 2' "${engine}"
grep -Fq 'atomic_write_state' "${engine}"
grep -Fq '"pending"' "${engine}"
grep -Fq 'CONFIRM_RUNS = 2' "${engine}"
for module in "${csb0mod}" "${csb1mod}"; do
  grep -Fq 'SuccessExitStatus' "${module}"
  grep -Fq 'StateDirectoryMode = "0700";' "${module}"
done

# Targets are baked in at build time; nothing may flow from runtime data into a
# request URL (CodeQL partial-SSRF, fixed 2026-07-30).
grep -Fq '@TARGETS_JSON@' "${csb0checks}"
grep -Fq 'builtins.replaceStrings' "${fleetlib}"
for checks in "${csb0checks}" "${csb1checks}"; do
  if grep -Fq 'sys.argv' "${checks}"; then
    printf 'poller must not take its configuration from argv\n' >&2
    exit 1
  fi
done

# 'unknown' is a healthy but SLEEPING car; only 'unavailable' means the config
# entry failed to load. Keying on the wrong one alerts forever on a parked car.
grep -Fq '"unavailable"' "${csb0checks}"
if grep -Fq '== "unknown"' "${csb0checks}"; then
  printf 'poller must not treat unknown as a fault (that is a sleeping car)\n' >&2
  exit 1
fi

# csb1's peer watch must not inherit the whole operator environment -- same rule
# tests/T34-hausv-alerts.sh enforces for hausv-alerts.
if grep -Eq '^[^#]*EnvironmentFile[[:space:]]*=' "${csb1mod}"; then
  printf 'peer watch must not inherit the complete operator env file\n' >&2
  exit 1
fi

printf 'OPS-104/OPS-107 fleet alert contract: OK\n'
