#!/usr/bin/env bash
# OPS-104 fleet alert poller contract.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module="${repo}/hosts/csb0/ops-alerts.nix"
host="${repo}/hosts/csb0/configuration.nix"
poller="${repo}/hosts/csb0/ops-alerts-poll.py"
secrets="${repo}/secrets/secrets.nix"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_ops_alerts.py' -v
nix-instantiate --parse "${module}" >/dev/null

grep -Fq './ops-alerts.nix' "${host}"
grep -Fq 'age.secrets.csb0-ops-alerts-env.file' "${host}"
grep -Fq '"csb0-ops-alerts-env.age".publicKeys' "${secrets}"
grep -Fq 'systemd.services.ops-alerts =' "${module}"
grep -Fq 'systemd.timers.ops-alerts =' "${module}"
grep -Fq 'config.age.secrets.csb0-ops-alerts-env.path' "${module}"
grep -Fq 'StateDirectory = "ops-alerts";' "${module}"

# All three instances must stay in the target list. Dropping one silently is how a
# host goes unwatched -- which is the exact failure this poller exists to catch.
for h in hsb1 hsb8 hsb9; do
  grep -Fq "name = \"${h}\";" "${module}"
done

# Targets are baked in at build time; nothing may flow from runtime data into a
# request URL (CodeQL partial-SSRF, fixed 2026-07-30).
grep -Fq '@TARGETS_JSON@' "${poller}"
grep -Fq 'builtins.replaceStrings' "${module}"
if grep -Fq 'sys.argv' "${poller}"; then
  printf 'poller must not take its target list from argv\n' >&2
  exit 1
fi

# A single bad run must never alert: the 2026-07-30 csb0 switch restarted
# tailscaled and produced a false "all three unreachable" alarm.
grep -Fq 'CONFIRM_RUNS = 2' "${poller}"

# 'unknown' is a healthy but sleeping car; only 'unavailable' means the config
# entry failed to load. Keying on the wrong one alerts forever on a parked car.
grep -Fq '"unavailable"' "${poller}"
if grep -Fq '== "unknown"' "${poller}"; then
  printf 'poller must not treat unknown as a fault (that is a sleeping car)\n' >&2
  exit 1
fi

printf 'OPS-104 fleet alert contract: OK\n'
