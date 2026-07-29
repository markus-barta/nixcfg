#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readiness="${repo}/hosts/csb1/docker/janus/managed-service-production/readiness.sh"

output=$(bash "${readiness}" self-test)
if [ "${output}" != "managed_secret_readiness_self_test=passed value_returned=false" ]; then
  printf 'unexpected readiness self-test output\n' >&2
  exit 1
fi

set +e
invalid_output=$(bash "${readiness}" unsupported 2>&1)
invalid_status=$?
set -e
if [ "${invalid_status}" -ne 2 ]; then
  printf 'invalid readiness mode did not exit 2\n' >&2
  exit 1
fi
if grep -Fq 'managed_secret_readiness=' <<<"${invalid_output}"; then
  printf 'invalid readiness mode emitted a terminal verdict\n' >&2
  exit 1
fi
if [ "${invalid_output}" != "usage: ${readiness} declarative|live|self-test" ]; then
  printf 'invalid readiness mode emitted unexpected diagnostics\n' >&2
  exit 1
fi

python3 - "${readiness}" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
for name in ("declarative", "live"):
    match = re.search(rf"^{name}\(\) \{{$(.*?)^\}}$", source, re.MULTILINE | re.DOTALL)
    if match is None:
        raise SystemExit(f"missing {name} function")
    if "managed_secret_readiness=" in match.group(1):
        raise SystemExit(f"{name} emitted an intermediate terminal verdict")

live_case = re.search(
    r'^live\)$\s+declarative\s+if \[ "\$failures" -eq 0 \]; then\s+live\s+fi',
    source,
    re.MULTILINE,
)
if live_case is None:
    raise SystemExit("live mode does not gate host checks on declarative success")

tail = source[source.rfind('case "$mode" in') :]
if tail.count('emit_terminal_verdict "$mode" "$failures"') != 1:
    raise SystemExit("requested mode does not emit exactly one terminal verdict")
PY

printf 'managed_secret_readiness_verdict=ok value_returned=false\n'
