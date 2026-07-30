#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
module="${repo}/hosts/csb1/hausv-alerts.nix"
host="${repo}/hosts/csb1/configuration.nix"
poller="${repo}/hosts/csb1/hausv-alerts-poll.py"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  discover -s "${repo}/tests" -p 'test_hausv_alerts.py' -v
nix-instantiate --parse "${module}" >/dev/null

grep -Fq './hausv-alerts.nix' "${host}"
grep -Fq 'systemd.services.hausv-alerts =' "${module}"
grep -Fq 'systemd.services.hausv-alerts-delivery-probe =' "${module}"
grep -Fq 'systemd.timers.hausv-alerts =' "${module}"
grep -Fq 'OnUnitActiveSec = "5m";' "${module}"
grep -Fq 'StateDirectoryMode = "0700";' "${module}"
grep -Fq 'SuccessExitStatus' "${module}"
grep -Fq 'pkgs.docker' "${module}"
grep -Fq 'config.age.secrets.csb1-watchtower-env.path' "${module}"
grep -Fq '"/run/agenix/csb1-watchtower-env"' "${module}"
grep -Fq 'DEFAULT_NOTIFICATION_ENV = "/run/agenix/csb1-watchtower-env"' "${poller}"
grep -Fq 'SNAPSHOT_MAX_AGE_SECONDS = 30 * 60 * 60' "${poller}"
grep -Fq '"--tail"' "${poller}"

if grep -Fq 'EnvironmentFile' "${module}"; then
  printf 'HAUSV alert service must not inherit the complete operator env file\n' >&2
  exit 1
fi
if grep -Fq 'telegram_links' "${module}" "${poller}"; then
  printf 'HAUSV alert service must not use product-user Telegram links\n' >&2
  exit 1
fi

printf 'HAUSV alert contract: OK\n'
