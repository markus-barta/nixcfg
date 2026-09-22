#!/usr/bin/env bash
# OPS-223 / OPS-224 / OPS-225 — hsb1 IR bridge: witness wiring + bridge contracts.
#
# 2026-09-21: the FLIRC vanished after a reboot (bridge deaf ~4 h), then the
# TV's Sony API answered 404 until power-cycled, and nothing paged. The witness
# (ir-bridge-watch) reads unit / FLIRC node / TV API through the shared OPS-107
# engine; the bridge itself now exits on SIGTERM and never retries an HTTP verdict.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod="${repo}/hosts/hsb1/ir-bridge-watch.nix"
checks="${repo}/hosts/hsb1/ir-bridge-watch.py"
bridge_mod="${repo}/hosts/hsb1/ir-bridge.nix"
conf="${repo}/hosts/hsb1/configuration.nix"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_ir_bridge*.py' -v
nix-instantiate --parse "${mod}" >/dev/null
nix-instantiate --parse "${bridge_mod}" >/dev/null

# Wiring
grep -Fq './ir-bridge-watch.nix' "${conf}"
grep -Fq 'name = "ir-bridge-watch"' "${mod}"
grep -Fq 'checks = ./ir-bridge-watch.py' "${mod}"
# Same Telegram target as tailnet-watch; device path + TV IP read from the bridge unit.
grep -Fq 'config.age.secrets.hsb1-tailnet-watch-env.path' "${mod}"
grep -Fq 'config.systemd.services.ir-bridge.environment' "${mod}"
# The FLIRC existence check needs the real /dev, but no device may be opened.
grep -Fq 'PrivateDevices = false' "${mod}"
grep -Fq 'DevicePolicy = "closed"' "${mod}"
grep -Fq 'OnUnitActiveSec = "5m"' "${mod}"
grep -Fq 'StateDirectory = "ir-bridge-watch"' "${mod}"
# Exit contract: 2 (undeliverable) must fail the unit; 0/1 must not.
grep -Fq 'SuccessExitStatus = [' "${mod}"

# Check-file contract
grep -Fq '@NOTIFICATION_ENV@' "${checks}"
grep -Fq '@FLIRC_DEVICE@' "${checks}"
grep -Fq '@SONY_SYSTEM_URL@' "${checks}"
grep -Fq '"/var/lib/ir-bridge-watch/state.json"' "${checks}"
grep -Fq 'WATCHTOWER_NOTIFICATION_URL' "${checks}"
grep -Fq '/sys/fs/cgroup/system.slice/ir-bridge.service/cgroup.procs' "${checks}"
# OPS-225: one HTTP attempt per press — a retry can duplicate an executed command.
if grep -Eq 'retry_count|RETRY_COUNT' "${repo}/hosts/hsb1/files/ir-bridge.py"; then
  echo "T87: ir-bridge.py must not retry an IRCC press (OPS-225)" >&2
  exit 1
fi

# OPS-224: a stop must never wait out systemd's 90 s default.
grep -Fq 'TimeoutStopSec = 10;' "${bridge_mod}"
echo "T87 ok"
