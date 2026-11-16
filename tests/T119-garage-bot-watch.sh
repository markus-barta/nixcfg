#!/usr/bin/env bash
# OPS-604 garage Telegram bot watch contract (csb1).
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mod="${repo}/hosts/csb1/garage-bot-watch.nix"
checks="${repo}/hosts/csb1/garage-bot-watch-checks.py"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_garage_bot_watch_checks.py' -v
nix-instantiate --parse "${mod}" >/dev/null

grep -Fq './garage-bot-watch.nix' "${repo}/hosts/csb1/configuration.nix"
grep -Fq 'name = "garage-bot-watch"' "${mod}"
grep -Fq './garage-bot-watch-checks.py' "${mod}"
grep -Fq 'age.secrets.csb1-watchtower-env.path' "${mod}"
grep -Fq 'OnUnitActiveSec = "5m"' "${mod}"
grep -Fq 'StateDirectory = "garage-bot-watch"' "${mod}"
grep -Fq '"/var/lib/garage-bot-watch/state.json"' "${checks}"
grep -Fq '@NOTIFICATION_ENV@' "${checks}"
if grep -Eq '^[[:space:]]*EnvironmentFile[[:space:]]*=' "${mod}"; then
  echo "T119: poller must read only its notification key" >&2
  exit 1
fi
echo "T119 ok"
