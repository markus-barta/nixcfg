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
import copy
import json
import pathlib
import re
import subprocess
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

# NIX-574 / JANUS-471: exercise the actual deployed predicates with both
# release eras. A calendar envelope must not upgrade the engine admission.
contract = pathlib.Path(sys.argv[1]).parent
def admission_predicate(channel):
    match = re.search(
        rf"    {channel}_admission_receipt \\\n.*?\n    '(.*?)' \\\n",
        source,
        re.DOTALL,
    )
    if match is None:
        raise SystemExit(f"missing {channel} admission predicate")
    return match.group(1)

def accepted(predicate, receipt, digest):
    return subprocess.run(
        ["jq", "-e", "--arg", "digest", digest, predicate],
        input=json.dumps(receipt), text=True, capture_output=True,
    ).returncode == 0

go_receipt = json.loads((contract / "go-envelope-admission.json").read_text())
go_predicate = admission_predicate("go")
go_digest = go_receipt["artifact"]["digest"]
if not accepted(go_predicate, go_receipt, go_digest):
    raise SystemExit("calendar envelope admission rejected")
for path, value in (
    (("policy_version",), 3),
    (("artifact", "release"), None),
    (("artifact", "release", "version_scheme"), "legacy"),
    (("artifact", "release", "version"), "260229120000.0.0"),
    (("artifact", "release", "release_channel"), "stable"),
    (("artifact", "release", "release_sequence"), 2),
    (("artifact", "tag"), "go-envelope-v1.185"),
    (("source", "commit"), "0" * 40),
):
    invalid = copy.deepcopy(go_receipt)
    target = invalid
    for field in path[:-1]:
        target = target[field]
    target[path[-1]] = value
    if accepted(go_predicate, invalid, go_digest):
        raise SystemExit(f"envelope admission accepted invalid {'.'.join(path)}")
if accepted(go_predicate, go_receipt, "sha256:" + "0" * 64):
    raise SystemExit("envelope admission accepted a different runtime image")

rust_receipt = json.loads((contract / "release-admission.json").read_text())
rust_predicate = admission_predicate("rust")
rust_digest = rust_receipt["artifact"]["digest"]
if not accepted(rust_predicate, rust_receipt, rust_digest):
    raise SystemExit("retained legacy engine admission rejected")
rust_receipt["policy_version"] = 4
if accepted(rust_predicate, rust_receipt, rust_digest):
    raise SystemExit("engine admission silently upgraded to policy 4")
PY

printf 'managed_secret_readiness_verdict=ok value_returned=false\n'
