#!/usr/bin/env bash
# OPS-226 — hsb1 Time Machine target: two-cap design + witness wiring.
#
# 2026-09-22 "Das Backup-Volume ist voll": the ZFS quota counted snapshots,
# Samba advertised the same size to Time Machine, nothing paged. This pins
# that Samba's `max size` never exceeds the refquota documented in tm-pool.nix,
# that sanoid keeps a week (not a fortnight) of tm snapshots, and that the
# tm-watch poller is wired like the other OPS-107 witnesses.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pool="${repo}/hosts/hsb1/tm-pool.nix"
samba="${repo}/hosts/hsb1/tm-samba.nix"
mod="${repo}/hosts/hsb1/tm-watch.nix"
checks="${repo}/hosts/hsb1/tm-watch.py"
conf="${repo}/hosts/hsb1/configuration.nix"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_tm_watch.py' -v
for f in "${pool}" "${samba}" "${mod}"; do
  nix-instantiate --parse "${f}" >/dev/null
done

# Two caps, documented as the imperative commands they are.
grep -Fq 'zfs set refquota=2.2T quota=3.2T tm/markus' "${pool}"
grep -Fq 'zfs set refquota=1.4T quota=2T tm/mailina' "${pool}"
# Samba's cap (GiB) must sit at or under each refquota (TiB): 2200G ≤ 2.2T, 1400G ≤ 1.4T.
grep -Fq '"fruit:time machine max size" = "2200G";' "${samba}"
grep -Fq '"fruit:time machine max size" = "1400G";' "${samba}"
if grep -Fq '2500G' "${samba}"; then
  echo "T89: the old 2500G Samba cap is back — it must equal the refquota, not the quota" >&2
  exit 1
fi
python3 - <<'PY'
# The documented pairs, checked numerically so a future edit cannot drift.
pairs = {"markus": (2200, 2.2), "mailina": (1400, 1.4)}
for user, (samba_gib, refquota_tib) in pairs.items():
    assert samba_gib * 1024**3 <= refquota_tib * 1024**4, user
print("T89: samba caps sit under their refquotas")
PY

# sanoid: a week of daily snapshots, no leaked hourly ones.
grep -Fq 'daily = 7;' "${pool}"
grep -Fq 'hourly = 0;' "${pool}"

# Witness wiring
grep -Fq './tm-watch.nix' "${conf}"
grep -Fq 'name = "tm-watch"' "${mod}"
grep -Fq 'checks = ./tm-watch.py' "${mod}"
grep -Fq 'config.age.secrets.hsb1-tailnet-watch-env.path' "${mod}"
grep -Fq 'config.boot.zfs.package' "${mod}"
grep -Fq 'DeviceAllow = [ "/dev/zfs rw" ]' "${mod}"
grep -Fq 'OnUnitActiveSec = "30m"' "${mod}"
grep -Fq 'StateDirectory = "tm-watch"' "${mod}"
grep -Fq 'SuccessExitStatus = [' "${mod}"
grep -Fq '@NOTIFICATION_ENV@' "${checks}"
grep -Fq '@ZFS_BIN@' "${checks}"
grep -Fq '@ZPOOL_BIN@' "${checks}"
grep -Fq '"/var/lib/tm-watch/state.json"' "${checks}"
grep -Fq 'WATCHTOWER_NOTIFICATION_URL' "${checks}"
echo "T89 ok"
