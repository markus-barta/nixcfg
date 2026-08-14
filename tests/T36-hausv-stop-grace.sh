#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="${repo}/hosts/csb1/configuration.nix"
runbook="${repo}/hosts/csb1/docs/RUNBOOK.md"
poller="${repo}/hosts/csb1/hausv-alerts-poll.py"

grep -Fq 'hausvComposeDir = "/home/mba/Code/hausv-jhw22";' "${host}"
grep -Fq '/run/lock/compose-hausv.lock' "${host}"
grep -Fq '"f /run/lock/compose-hausv.lock 0660 root users -"' "${host}"
# The following single-quoted values are literal Nix and Markdown contracts.
# shellcheck disable=SC2016
grep -Fq '${hausvCompose} stop -t 30 hausv-org' "${host}"
# shellcheck disable=SC2016
grep -Fq '${hausvCompose} start hausv-org' "${host}"
# shellcheck disable=SC2016
grep -Fq 'The private `hausv-jhw22` Compose service declares `stop_grace_period: 30s`.' "${runbook}"
grep -Fq "The expected stop timeout is \`30\`." "${runbook}"
grep -Fq '"magic link delivery shutdown deadline reached",' "${poller}"

printf 'HAUSV graceful-stop budget: OK\n'
