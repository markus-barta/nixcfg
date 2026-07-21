#!/usr/bin/env bash
# T19-janus-role-deployment.sh
# Description: Keep the deployed Janus role projection exact and explicit.
# Related PPM issues: JANUS-297, JANUS-308, JANUS-309, JANUS-298

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose="${repo_root}/hosts/csb1/docker/docker-compose.yml"

python3 - "${compose}" <<'PY'
import pathlib
import re
import sys

compose = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")

def service_block(name: str) -> str:
    match = re.search(
        rf"^  {re.escape(name)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_.-]+:\n|\Z)",
        compose,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise SystemExit(f"missing compose service: {name}")
    return match.group("body")

go_service = service_block("janus")
engine_service = service_block("janus-engine-staged")

legacy = [
    "JANUS_ADMIN_SUBJECTS",
    "JANUS_ADMIN_GROUPS",
    "JANUS_BOOTSTRAP_OWNER",
]
for key in legacy:
    if key in go_service:
        raise SystemExit(f"legacy Janus authorization lane remains: {key}")

expected = {
    "JANUS_OWNER_GROUPS": "janus:admin",
    "JANUS_APPROVER_GROUPS": "janus:approver",
    "JANUS_AUDITOR_GROUPS": "janus:auditor",
    "JANUS_OPERATOR_GROUPS": "janus:operator",
    "JANUS_SECURITY_ADMIN_GROUPS": "janus:security_admin",
    "JANUS_BREAK_GLASS_ADMIN_GROUPS": "janus:break_glass_admin",
    "JANUS_SERVICE_ADMIN_GROUPS": "janus:service_admin",
    "JANUS_WORKLOAD_ADMIN_GROUPS": "janus:workload_admin",
}
values = []
for key, value in expected.items():
    line = f"- {key}={value}"
    if go_service.count(line) != 1:
        raise SystemExit(f"expected exactly one reviewed Janus role mapping: {key}")
    values.append(value)
if len(values) != len(set(values)):
    raise SystemExit("Janus role mappings must use unique exact group values")

if "- JANUS_PRODUCT_MODE=self_hosted" not in engine_service:
    raise SystemExit("staged Janus engine lacks explicit self-hosted posture")
if "- JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev" not in engine_service:
    raise SystemExit("staged Janus engine lacks explicit unsafe development posture")

for service, prefix, block in [
    ("janus", "go-envelope-v", go_service),
    ("janus-engine-staged", "rust-engine-v", engine_service),
]:
    pattern = rf"^    image: ghcr\.io/markus-barta/janus/[^\s]+:{prefix}[^@\s]+@sha256:[0-9a-f]{{64}}$"
    if not re.search(pattern, block, re.MULTILINE):
        raise SystemExit(f"{service} is not pinned to an immutable Janus release digest")

print("ok: Janus deployment uses exact shared role mappings and explicit staged posture")
PY
