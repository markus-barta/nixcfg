#!/usr/bin/env bash
# OPS-226 — hsb1 Time Machine target: two-cap design + witness wiring.
#
# 2026-09-22 "Das Backup-Volume ist voll": the ZFS quota counted snapshots,
# Samba advertised the same size to Time Machine, nothing paged. This pins
# that every number comes from tm-caps.nix, that Samba's `max size` sits under
# the refquota with margin, that sanoid keeps a week (not a fortnight) of tm
# snapshots, and that the tm-watch poller is wired like the other OPS-107
# witnesses and validates the live caps against the declared ones.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
caps="${repo}/hosts/hsb1/tm-caps.nix"
pool="${repo}/hosts/hsb1/tm-pool.nix"
samba="${repo}/hosts/hsb1/tm-samba.nix"
mod="${repo}/hosts/hsb1/tm-watch.nix"
checks="${repo}/hosts/hsb1/tm-watch.py"
conf="${repo}/hosts/hsb1/configuration.nix"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_tm_watch.py' -v
for f in "${caps}" "${pool}" "${samba}" "${mod}"; do
  nix-instantiate --parse "${f}" >/dev/null
done

# One source of numbers, consumed by all three modules.
grep -Fq 'import ./tm-caps.nix' "${pool}"
grep -Fq 'import ./tm-caps.nix' "${samba}"
grep -Fq 'import ./tm-caps.nix' "${mod}"
grep -Fq 'caps.markus.maxSizeG' "${samba}"
grep -Fq 'caps.mailina.maxSizeG' "${samba}"
if grep -Eq '"[0-9]+G"' "${samba}"; then
  echo "T89: a literal Samba max size is back in tm-samba.nix — it must come from tm-caps.nix" >&2
  exit 1
fi
# The documented imperative commands match the declared numbers, and the
# pairing holds with margin (the eval-time assertion in tm-pool.nix is the
# runtime gate; this is the same rule without a NixOS evaluation).
caps_json="$(nix-instantiate --eval --json --strict "${caps}")"
python3 - "${caps_json}" "${pool}" <<'PY'
import json
import sys

caps = json.loads(sys.argv[1])
pool = open(sys.argv[2]).read()
for user, cap in caps.items():
    assert cap["maxSizeG"] + 32 <= cap["refquotaG"] < cap["quotaG"], user
    cmd = "zfs set refquota=%dG quota=%dG %s" % (cap["refquotaG"], cap["quotaG"], cap["dataset"])
    assert cmd in pool, "tm-pool.nix must document: " + cmd
print("T89: caps pair with margin and the documented zfs set commands match")
PY

# sanoid: a week of daily snapshots (3 for the churning tm/markus), no leaked hourly ones.
grep -Fq 'daily = 7;' "${pool}"
grep -Fq 'daily = 3;' "${pool}"
grep -Fq 'useTemplate = [ "tm-daily-short" ];' "${pool}"
grep -Fq 'hourly = 0;' "${pool}"
# OPS-228 sizing rule: TM's cap ≥ 2× the Mac's data (mbp2607 ≈ 1.6T, mbp2606 ≈ 0.4T).
python3 - "${caps_json}" <<'PY'
import json, sys
caps = json.loads(sys.argv[1])
assert caps["markus"]["maxSizeG"] >= 2 * 1600, "markus: Samba cap must be >= 2x the Mac's ~1.6T"
assert caps["mailina"]["maxSizeG"] >= 2 * 400, "mailina: Samba cap must be >= 2x the Mac's ~0.4T"
assert sum(c["quotaG"] for c in caps.values()) <= 5300, "quotas exceed the 5.45TiB pool minus slop"
print("T89: caps satisfy the 2x sizing rule and fit the pool")
PY

# Witness wiring
grep -Fq './tm-watch.nix' "${conf}"
grep -Fq 'name = "tm-watch"' "${mod}"
grep -Fq 'checks = ./tm-watch.py' "${mod}"
grep -Fq 'config.age.secrets.hsb1-tailnet-watch-env.path' "${mod}"
grep -Fq 'config.boot.zfs.package' "${mod}"
grep -Fq 'CAPS_JSON = builtins.toJSON (import ./tm-caps.nix)' "${mod}"
grep -Fq 'DeviceAllow = [ "/dev/zfs rw" ]' "${mod}"
grep -Fq 'OnUnitActiveSec = "10m"' "${mod}"
grep -Fq 'StateDirectory = "tm-watch"' "${mod}"
grep -Fq 'SuccessExitStatus = [' "${mod}"
grep -Fq '@NOTIFICATION_ENV@' "${checks}"
grep -Fq '@ZFS_BIN@' "${checks}"
grep -Fq '@ZPOOL_BIN@' "${checks}"
grep -Fq '@CAPS_JSON@' "${checks}"
grep -Fq '"/var/lib/tm-watch/state.json"' "${checks}"
grep -Fq 'WATCHTOWER_NOTIFICATION_URL' "${checks}"
grep -Fq 'com.apple.TimeMachine.SnapshotHistory.plist' "${checks}"
# Pruning is restricted to sanoid's snapshots of the dataset at hand.
grep -Fq '@autosnap_' "${checks}"
echo "T89 ok"
