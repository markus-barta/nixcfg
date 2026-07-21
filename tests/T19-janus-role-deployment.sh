#!/usr/bin/env bash
# T19-janus-role-deployment.sh
# Description: Keep the deployed Janus role projection exact and explicit.
# Related PPM issues: JANUS-297, JANUS-308, JANUS-309, JANUS-298

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose="${repo_root}/hosts/csb1/docker/docker-compose.yml"
nonprod_renderer="${repo_root}/hosts/csb1/docker/janus/pharos-nonprod/run-sidecar-smoke.sh"
production_renderer="${repo_root}/hosts/csb1/docker/janus/pharos-production/render-sidecars.sh"
provider_renderer="${repo_root}/hosts/csb1/docker/janus/pharos-production/render-hetzner-provider.sh"
retirement_executor="${repo_root}/hosts/csb1/docker/janus/pharos-production/retire-host.sh"

python3 - \
  "${compose}" \
  "${nonprod_renderer}" \
  "${production_renderer}" \
  "${provider_renderer}" \
  "${retirement_executor}" <<'PY'
import pathlib
import re
import sys

compose = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
renderers = {
    "non-production renderer": (pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"), 3),
    "production renderer": (pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"), 3),
    "provider renderer": (pathlib.Path(sys.argv[4]).read_text(encoding="utf-8"), 3),
    "retirement executor": (pathlib.Path(sys.argv[5]).read_text(encoding="utf-8"), 1),
}

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

for name, (script, launch_count) in renderers.items():
    if script.count("-e JANUS_PRODUCT_MODE=self_hosted") != launch_count:
        raise SystemExit(f"{name} lacks explicit self-hosted posture on each privileged launch")
    if script.count("-e JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev") != launch_count:
        raise SystemExit(f"{name} lacks explicit unsafe development posture on each privileged launch")

for service, prefix, block in [
    ("janus", "go-envelope-v", go_service),
    ("janus-engine-staged", "rust-engine-v", engine_service),
]:
    pattern = rf"^    image: ghcr\.io/markus-barta/janus/[^\s]+:{prefix}[^@\s]+@sha256:[0-9a-f]{{64}}$"
    if not re.search(pattern, block, re.MULTILINE):
        raise SystemExit(f"{service} is not pinned to an immutable Janus release digest")

print("ok: Janus deployment uses exact shared role mappings and explicit runtime posture")
PY
