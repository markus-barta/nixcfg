#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
janus_root="$repo_root/hosts/csb1/docker/janus"
compose="$repo_root/hosts/csb1/docker/docker-compose.yml"
policy="$janus_root/runtime-image-policy.sh"
run_negative="$janus_root/nonprod-smoke/run-negative-smoke.sh"

grep -Fq 'JANUS_RUNTIME_UID=65532' "$policy"
grep -Fq 'JANUS_RUNTIME_GID=65532' "$policy"
grep -Fq 'alpine:3.22.5@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce' "$policy"

# The expression intentionally matches literal shell variable references.
# shellcheck disable=SC2016
if grep -ERq -- '--entrypoint (sh|cat|id|sha256sum) ("\$IMAGE"|"\$image"|\$IMAGE|\$image)' "$janus_root"; then
  printf 'Janus operational scripts still expect shell tooling in the scratch runtime image\n' >&2
  exit 1
fi
if grep -Rq 'binary = "/bin/sh"' "$janus_root"; then
  printf 'Janus managed-command policy still depends on a runtime shell\n' >&2
  exit 1
fi
grep -Fq 'APPROVED_ARGS=("--help")' "$run_negative"
# The assertions intentionally match literal shell variable references.
# shellcheck disable=SC2016
grep -Fq 'source "${SCRIPT_DIR}/../runtime-image-policy.sh"' "$run_negative"
# shellcheck disable=SC2016
grep -Fq '"$JANUS_VOLUME_HELPER_IMAGE"' "$run_negative"
# shellcheck disable=SC2016
if grep -Fq 'docker exec "$CONTAINER" sh' "$run_negative"; then
  printf 'Janus negative smoke still expects a shell in the scratch runtime image\n' >&2
  exit 1
fi

python3 - "$compose" <<'PY'
import pathlib
import re
import sys

compose = pathlib.Path(sys.argv[1]).read_text()

def block(name: str) -> str:
    match = re.search(
        rf"^  {re.escape(name)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_.-]+:\n|\Z)",
        compose,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise SystemExit(f"missing service: {name}")
    return match.group("body")

for name in ("janus", "janus-engine-staged"):
    service = block(name)
    for expected in (
        "read_only: true",
        'cap_drop: ["ALL"]',
        'security_opt: ["no-new-privileges:true"]',
        "restart: unless-stopped",
    ):
        if expected not in service:
            raise SystemExit(f"{name} missing {expected}")

engine = block("janus-engine-staged")
for expected in (
    'user: "65532:65532"',
    'network_mode: "none"',
    'entrypoint: ["/usr/local/bin/janus-warden"]',
    'test: ["CMD", "/usr/local/bin/janusd-use", "--help"]',
    "JANUS_LIFECYCLE_EVIDENCE_DIR=/var/lib/janus/secrets/.lifecycle-evidence",
):
    if expected not in engine:
        raise SystemExit(f"staged engine missing {expected}")
if "CMD-SHELL" in engine:
    raise SystemExit("staged engine healthcheck uses a shell")

for name in (
    "janus_engine_smoke_age",
    "janus_engine_smoke_secrets",
    "janus_engine_smoke_permits",
):
    volume = block(name)
    if "external: true" not in volume:
        raise SystemExit(f"staged smoke volume {name} must be externally owned")
PY

printf 'ok: Janus containers are non-root, read-only, capability-free, no-new-privileges; Rust is networkless, shell-free, and uses externally owned smoke volumes\n'
