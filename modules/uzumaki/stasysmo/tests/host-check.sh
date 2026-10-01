#!/usr/bin/env bash
# Read-only live host assertions; used by hsb0, hsb1 and hsb8 test suites.
set -euo pipefail
systemctl is-active --quiet stasysmo-daemon
systemctl is-enabled --quiet stasysmo-daemon
python3 - <<'PY'
import os, re, stat, time
path = '/run/stasysmo/snapshot'
directory = os.lstat('/run/stasysmo')
assert stat.S_ISDIR(directory.st_mode) and directory.st_mode & 0o777 == 0o755
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
try:
    info = os.fstat(fd)
    assert stat.S_ISREG(info.st_mode) and info.st_mode & 0o777 == 0o644
    assert info.st_uid == directory.st_uid, 'snapshot must be owned by the service'
    record = os.read(fd, 129).decode('ascii')
finally:
    os.close(fd)
pattern = r'v1 ([1-9][0-9]{8,10}) (100|[1-9]?[0-9]) (100|[1-9]?[0-9]) (100|[1-9]?[0-9]) ((?:0|[1-9][0-9]{0,3})\.[0-9]{2}) ([1-9][0-9]{0,3})\n'
match = re.fullmatch(pattern, record)
assert match, 'invalid snapshot'
assert 0 <= time.time() - int(match[1]) <= 15, 'stale or future snapshot'
print('PASS: service-owned snapshot, validated fields and fresh timestamp')
PY
# Exercise the installed compositor definitions, not a custom Starship subprocess.
fish -i -c 'functions -q __stasysmo_compose; and functions -q __stasysmo_read'
grep -q '\[git_commit\]' "$HOME/.config/starship.toml"
if grep -q '\[custom.stasysmo\]' "$HOME/.config/starship.toml"; then
  printf 'FAIL: old custom metrics module remains\n' >&2
  exit 1
fi
printf 'PASS: StaSysMo v2 service and fish compositor\n'
