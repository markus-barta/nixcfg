#!/usr/bin/env bash
# T19-janus-role-deployment.sh
# Description: Keep the deployed Janus role projection exact and explicit.
# Related PPM issues: JANUS-267, JANUS-297, JANUS-308, JANUS-309, JANUS-298,
# JANUS-416, NIX-345

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose="${repo_root}/hosts/csb1/docker/compose-spec.nix"
nonprod_renderer="${repo_root}/hosts/csb1/docker/janus/pharos-nonprod/run-sidecar-smoke.sh"
production_renderer="${repo_root}/hosts/csb1/docker/janus/pharos-production/render-sidecars.sh"
provider_renderer="${repo_root}/hosts/csb1/docker/janus/pharos-production/render-hetzner-provider.sh"
retirement_executor="${repo_root}/hosts/csb1/docker/janus/pharos-production/retire-host.sh"
provisioning_executor="${repo_root}/modules/pharos-provisioning-executor/janus-credential.sh"
role_runtime="${repo_root}/hosts/csb1/docker/janus/pharos-production/runtime-role-authorization.sh"
role_bootstrap="${repo_root}/hosts/csb1/docker/janus/role-authorization/bootstrap.sh"
configuration="${repo_root}/hosts/csb1/configuration.nix"

python3 - \
  "${compose}" \
  "${nonprod_renderer}" \
  "${production_renderer}" \
  "${provider_renderer}" \
  "${retirement_executor}" \
  "${provisioning_executor}" \
  "${role_runtime}" \
  "${role_bootstrap}" \
  "${configuration}" <<'PY'
import pathlib
import re
import sys

compose = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
nonprod_renderer = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
production_renderers = {
    "production renderer": (pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"), 3),
    "provider renderer": (pathlib.Path(sys.argv[4]).read_text(encoding="utf-8"), 3),
    "retirement executor": (pathlib.Path(sys.argv[5]).read_text(encoding="utf-8"), 1),
    "provisioning executor": (pathlib.Path(sys.argv[6]).read_text(encoding="utf-8"), 4),
}
role_runtime = pathlib.Path(sys.argv[7]).read_text(encoding="utf-8")
role_bootstrap = pathlib.Path(sys.argv[8]).read_text(encoding="utf-8")
configuration = pathlib.Path(sys.argv[9]).read_text(encoding="utf-8")

def service_block(name: str) -> str:
    match = re.search(
        rf"^    {re.escape(name)} = \{{\n(?P<body>.*?)^    \}};$",
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
    "JANUS_VIEWER_GROUPS": "janus:viewer",
    "JANUS_OWNER_GROUPS": "janus:admin",
    "JANUS_APPROVER_GROUPS": "janus:approver",
    "JANUS_AUDITOR_GROUPS": "janus:auditor",
    "JANUS_OPERATOR_GROUPS": "janus:operator",
    "JANUS_SECURITY_ADMIN_GROUPS": "janus:security_admin",
    "JANUS_BREAK_GLASS_ADMIN_GROUPS": "janus:break_glass_admin",
    "JANUS_SERVICE_ADMIN_GROUPS": "janus:service_admin",
    "JANUS_WORKLOAD_ADMIN_GROUPS": "janus:workload_admin",
    "OIDC_PROJECT_ID": "375139131258306571",
}
values = []
for key, value in expected.items():
    line = f'"{key}={value}"'
    if go_service.count(line) != 1:
        raise SystemExit(f"expected exactly one reviewed Janus role mapping: {key}")
    values.append(value)
if len(values) != len(set(values)):
    raise SystemExit("Janus role mappings must use unique exact group values")

if '"JANUS_PRODUCT_MODE=self_hosted"' not in engine_service:
    raise SystemExit("staged Janus engine lacks explicit self-hosted posture")
for requirement in (
    '"JANUS_ROLE_AUTHORIZATION_MODE=enforced"',
    '"JANUS_ROLE_BINDINGS_ROOT=/var/lib/janus/role-authorization/bindings"',
    '"JANUS_ROLE_AUDIT_FILE=/var/lib/janus/role-authorization/audit.jsonl"',
    '"JANUS_WARDEN_AUDIT_FILE=/var/lib/janus/role-authorization/warden-audit.jsonl"',
    'source = "/var/lib/janus-role-authorization-csb1/staged";',
    'target = "/var/lib/janus/role-authorization";',
    "create_host_path = false;",
):
    if requirement not in engine_service:
        raise SystemExit(f"staged Janus engine role posture drift: {requirement}")
if "JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev" in engine_service:
    raise SystemExit("continuously running staged Janus engine still disables authorization")

for service, block in [("janus", go_service), ("janus-engine-staged", engine_service)]:
    for requirement in (
        "read_only = true;",
        '"ALL"',
        '"no-new-privileges:true"',
    ):
        if requirement not in block:
            raise SystemExit(f"{service} lacks container hardening: {requirement}")
if 'user = "65532:65532";' not in engine_service:
    raise SystemExit("staged Janus engine lacks exact non-root uid/gid")
if 'network_mode = "none";' not in engine_service:
    raise SystemExit("staged Janus engine must remain networkless")
if '"/usr/local/bin/janus-warden"' not in engine_service:
    raise SystemExit("staged Janus engine entrypoint must be absolute and shell-free")
if '"/usr/local/bin/janusd-use"' not in engine_service:
    raise SystemExit("staged Janus engine lacks an exec-form healthcheck")
if "CMD-SHELL" in engine_service:
    raise SystemExit("staged Janus engine healthcheck reintroduced a shell")

if nonprod_renderer.count("-e JANUS_PRODUCT_MODE=self_hosted") != 3:
    raise SystemExit("non-production renderer lacks explicit self-hosted posture")
if nonprod_renderer.count("-e JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev") != 3:
    raise SystemExit("non-production renderer must retain its isolated unsafe fixture")

for name, (script, launch_count) in production_renderers.items():
    if script.count("-e JANUS_PRODUCT_MODE=self_hosted") != launch_count:
        raise SystemExit(f"{name} lacks explicit self-hosted posture on each privileged launch")
    if "JANUS_ROLE_AUTHORIZATION_MODE=unsafe_disabled_dev" in script:
        raise SystemExit(f"{name} still disables production role authorization")
    if script.count('${JANUS_ROLE_AUTHORIZATION_ARGS[@]}') != launch_count:
        raise SystemExit(f"{name} does not apply enforced role state to every privileged launch")
    if "runtime-role-authorization.sh" not in script:
        raise SystemExit(f"{name} does not load the shared production role contract")

for requirement in (
    "JANUS_ROLE_AUTHORIZATION_MODE=enforced",
    "JANUS_ROLE_BINDINGS_ROOT=",
    "JANUS_ROLE_AUDIT_FILE=",
    "JANUS_WARDEN_AUDIT_FILE=",
    "/var/lib/janus-role-authorization-csb1",
):
    if requirement not in role_runtime:
        raise SystemExit(f"shared production role contract drift: {requirement}")

for requirement in (
    "JANUS_ROLE_BOOTSTRAP_ACK=bootstrap-role-authorization",
    "--role security_admin",
    "registry_not_empty",
    "unsafe_bootstrap",
    "local_reviewed",
    "unauthorized_actor_allowed",
    "--network none",
    "--cap-drop ALL",
    "--security-opt no-new-privileges",
):
    if requirement not in role_bootstrap:
        raise SystemExit(f"role bootstrap guard drift: {requirement}")

for requirement in (
    '"d /var/lib/janus-role-authorization-csb1/production 0700 65532 65532 -"',
    '"d /var/lib/janus-role-authorization-csb1/production/bindings 0700 65532 65532 -"',
    '"f /var/lib/janus-role-authorization-csb1/production/audit.jsonl 0600 65532 65532 -"',
    '"f /var/lib/janus-role-authorization-csb1/production/warden-audit.jsonl 0600 65532 65532 -"',
    '"d /var/lib/janus-role-authorization-csb1/staged 0700 65532 65532 -"',
    '"d /var/lib/janus-role-authorization-csb1/staged/bindings 0700 65532 65532 -"',
    '"f /var/lib/janus-role-authorization-csb1/staged/audit.jsonl 0600 65532 65532 -"',
    '"f /var/lib/janus-role-authorization-csb1/staged/warden-audit.jsonl 0600 65532 65532 -"',
):
    if configuration.count(requirement) != 1:
        raise SystemExit(f"declarative role state drift: {requirement}")

for service, image, prefix, block in [
    (
        "janus",
        r"ghcr\.io/inspr-at/janus/janus-envelope",
        "go-envelope-v",
        go_service,
    ),
    (
        "janus-engine-staged",
        r"ghcr\.io/inspr-at/janus/janus-engine",
        "rust-engine-v",
        engine_service,
    ),
]:
    pattern = rf"^      image = \"{image}:{prefix}[^@\s]+@sha256:[0-9a-f]{{64}}\";$"
    if not re.search(pattern, block, re.MULTILINE):
        raise SystemExit(f"{service} is not pinned to an immutable Janus release digest")

print("ok: Janus deployment uses exact shared role mappings and explicit runtime posture")
PY
