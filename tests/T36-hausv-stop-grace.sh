#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host="${repo}/hosts/csb1/configuration.nix"
runbook="${repo}/hosts/csb1/docs/RUNBOOK.md"
poller="${repo}/hosts/csb1/hausv-alerts-poll.py"

grep -Fq '/run/lock/compose-hausv.lock' "${host}"
grep -Fq '"f /run/lock/compose-hausv.lock 0660 root users -"' "${host}"
# HAUSV-918 retired the nightly stop/start script. The operator's final stop
# retains the private project and its graceful-stop budget.
grep -Fq 'docker compose -p hausv-jhw22 -f compose.yml stop -t 30 hausv-org' "${runbook}"
grep -Fq 'docker compose -p hausv-jhw22 -f compose.yml start hausv-org' "${runbook}"
# shellcheck disable=SC2016
grep -Fq 'The private `hausv-jhw22` Compose service declares `stop_grace_period: 30s`.' "${runbook}"
grep -Fq "The expected stop timeout is \`30\`." "${runbook}"
grep -Fq '"magic link delivery shutdown deadline reached",' "${poller}"

printf 'HAUSV graceful-stop budget: OK\n'
