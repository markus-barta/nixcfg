#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose="${repo}/hosts/csb1/docker/docker-compose.yml"
runbook="${repo}/hosts/csb1/docs/RUNBOOK.md"
poller="${repo}/hosts/csb1/hausv-alerts-poll.py"

python3 - "${compose}" <<'PY'
import pathlib
import re
import sys

compose = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(
    r"(?ms)^  hausv-org:\n(?P<body>.*?)(?=^  [a-zA-Z0-9_-]+:\n)",
    compose,
)
if match is None:
    raise SystemExit("missing hausv-org compose service")
body = match.group("body")
if body.count("stop_grace_period: 30s") != 1:
    raise SystemExit("hausv-org must declare exactly one 30s stop grace period")
for explanation in (
    "15s for HTTP",
    "5s for queued login mail",
    "1s for transport",
    "9s margin",
):
    if explanation not in body:
        raise SystemExit(f"missing shutdown-budget explanation: {explanation}")
PY

grep -Fq "The HAUSV Compose service declares \`stop_grace_period: 30s\`." "${runbook}"
grep -Fq "The expected stop timeout is \`30\`." "${runbook}"
grep -Fq '"magic link delivery shutdown deadline reached",' "${poller}"

printf 'HAUSV graceful-stop budget: OK\n'
