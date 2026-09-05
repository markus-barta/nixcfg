#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
production="$repo_root/hosts/csb1/docker/janus/pharos-production"
smoke="$repo_root/hosts/csb1/docker/janus/pharos-retirement-smoke"
compose="$repo_root/hosts/csb1/docker/compose-spec.nix"

bash -n "$production/runtime-lib.sh"
bash -n "$production/render-sidecars.sh"
bash -n "$production/retire-host.sh"
bash -n "$smoke/run.sh"

if "$production/retire-host.sh" reconcile '../invalid' >/dev/null 2>&1; then
  printf 'retirement helper accepted an invalid host\n' >&2
  exit 1
fi

grep -Fq 'JANUS_LIFECYCLE_TOMBSTONE_DIR=/var/lib/janus/lifecycle/tombstones' \
  "$production/retire-host.sh"
grep -Fq -- '--state-dir /var/lib/janus/lifecycle/pharos-retirements' \
  "$production/retire-host.sh"
grep -Fq 'JANUS_PHAROS_METADATA_VOLUME' "$production/runtime-lib.sh"
grep -Fq 'JANUS_PHAROS_LIFECYCLE_VOLUME' "$production/runtime-lib.sh"
grep -Fq 'janus_pharos_production_identityd_start' "$production/retire-host.sh"
grep -Fq 'janus_pharos_production_identityd_stop' "$production/retire-host.sh"
# shellcheck disable=SC2016
grep -Fq '"${JANUS_PHAROS_AUTHORITY_ENV_FLAGS[@]}"' "$production/retire-host.sh"
# shellcheck disable=SC2016
grep -Fq '"${JANUS_PHAROS_AUTHORITY_VOLUME_MOUNT[@]}"' "$production/retire-host.sh"
# shellcheck disable=SC2016
grep -Fq '"${JANUS_PHAROS_AUTHORITY_MANIFEST_MOUNT[@]}"' "$production/retire-host.sh"
grep -Fq '/var/lib/janus/metadata/baseline.toml' "$production/runtime-lib.sh"
grep -Fq 'RETIREMENTS_FILE' "$production/render-sidecars.sh"
grep -Fq 'METADATA_VOLUME' "$production/render-sidecars.sh"
expected_compose_spec="COMPOSE_SPEC=\${JANUS_ENGINE_STAGED_COMPOSE_FILE:-\${COMPOSE_DIR}/compose-spec.nix}"
retired_compose_ref="\"\${COMPOSE_DIR}/docker-compose.yml\""
grep -Fq "$expected_compose_spec" "$production/render-sidecars.sh"
grep -Fq "' \"\${COMPOSE_DIR}/compose-spec.nix\"" "$production/retire-host.sh"
if grep -Fq "$retired_compose_ref" "$production/render-sidecars.sh"; then
  printf 'production renderer still resolves Janus from the retired Compose file\n' >&2
  exit 1
fi
if grep -Fq "$retired_compose_ref" "$production/retire-host.sh"; then
  printf 'retirement helper still resolves Janus from the retired Compose file\n' >&2
  exit 1
fi
# shellcheck disable=SC2016
grep -Fq 'JANUS_PHAROS_IDENTITYD_CONTAINER="$identityd_container"' \
  "$production/runtime-lib.sh"
grep -Fq 'authority_container_root}:ro"' "$production/runtime-lib.sh"
# shellcheck disable=SC2016
grep -Fq 'if [ "$FIXTURE" != 1 ]; then' "$production/retire-host.sh"
grep -Fq 'fail runtime_authority_unavailable' "$production/retire-host.sh"

# Exercise the broker wiring with an isolated authority root and a fake Docker
# transport. This proves the retirement principal is singular, the consumer
# mount is read-only, and a readiness failure remains cleanable without opening
# production custody or launching a real broker.
runtime_lib="$production/runtime-lib.sh" bash <<'BASH'
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/authority"
export JANUS_VOLUME_HELPER_IMAGE=helper:test
docker_log="$tmp/docker.log"

docker() {
  printf '%s\n' "$*" >>"$docker_log"
  case " $* " in
  *' inspect --format '*) printf 'true\n' ;;
  esac
  return 0
}

# shellcheck disable=SC1090
source "$runtime_lib"
janus_pharos_production_identityd_start \
  image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$tmp" 65532 65532 retirement-test \
  janus-pharos-retirement@csb1 inspr pharos nixcfg production \
  "$tmp/authority"

env_text=$(printf '%s\n' "${JANUS_PHAROS_AUTHORITY_ENV_FLAGS[@]}")
[ "$(grep -c '^JANUS_RELEASE_EXECUTOR=janus-pharos-retirement@csb1$' <<<"$env_text")" = 1 ]
[ "$(grep -c '^JANUS_SCOPE_ORGANIZATION=inspr$' <<<"$env_text")" = 1 ]
[ "$(grep -c '^JANUS_SCOPE_PROJECT=pharos$' <<<"$env_text")" = 1 ]
[ "$(grep -c '^JANUS_SCOPE_REPOSITORY=nixcfg$' <<<"$env_text")" = 1 ]
[ "$(grep -c '^JANUS_SCOPE_ENVIRONMENT=production$' <<<"$env_text")" = 1 ]
[ "${JANUS_PHAROS_AUTHORITY_VOLUME_MOUNT[1]}" = "$tmp/authority:/var/lib/janus/identity:ro" ]
[ "$JANUS_PHAROS_IDENTITYD_CONTAINER" = retirement-test-pharos-production-identityd ]
janus_pharos_production_identityd_stop
grep -Fq 'rm -f retirement-test-pharos-production-identityd' "$docker_log"

# A broker that never becomes ready must still publish enough lifecycle state
# for the caller's EXIT trap to remove it. Avoid a 20-second unit-test delay.
docker() {
  printf '%s\n' "$*" >>"$docker_log"
  case " $* " in
  *' --entrypoint python '*) return 1 ;;
  *' inspect --format '*) printf 'false\n' ;;
  esac
  return 0
}
sleep() { :; }
: >"$docker_log"
if (
  trap janus_pharos_production_identityd_stop EXIT
  janus_pharos_production_identityd_start \
    image@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    "$tmp" 65532 65532 failed-retirement-test \
    janus-pharos-retirement@csb1 inspr pharos nixcfg production \
    "$tmp/authority"
); then
  printf 'unready retirement broker unexpectedly passed readiness\n' >&2
  exit 1
fi
grep -Fq 'rm -f failed-retirement-test-pharos-production-identityd' "$docker_log"
BASH
grep -Fq 'fixture_uses_production_contract' "$production/retire-host.sh"
grep -Fq 'fixture_uses_production_volumes' "$production/retire-host.sh"
grep -Fq 'fixture_uses_production_scope' "$production/retire-host.sh"
grep -Fq 'pharos/csb1/nonprod-retirement-smoke' "$smoke/run.sh"

if grep -Eq -- '--(value|token|secret-ref|provider-delete|delete)([=[:space:]]|$)' \
  "$production/retire-host.sh"; then
  printf 'retirement helper exposes a forbidden value or provider control\n' >&2
  exit 1
fi
if grep -Fq '/etc/janus/metadata.toml:ro' "$production/render-sidecars.sh"; then
  printf 'production renderer still mounts immutable lifecycle metadata\n' >&2
  exit 1
fi

python3 - "$smoke" "$compose" <<'PY'
import hashlib
import json
import pathlib
import re
import subprocess
import sys

smoke = pathlib.Path(sys.argv[1])
compose = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
host = "retirementsmoke"
secret_name = "PHAROS_BEACON_RETIREMENTSMOKE_TOKEN"

canonical = b""
for component in ("janus-scope-v1", "inspr", "pharos", "nixcfg", "retirement-smoke"):
    encoded = component.encode()
    canonical += len(encoded).to_bytes(8, "big") + encoded
canonical += b"\0\0"
scope_ref = "scp_" + hashlib.sha256(canonical).hexdigest()[:40]
expected_ref = "sec_" + hashlib.sha256(
    b"janus-secret-ref-v2\0" + scope_ref.encode() + b"\0" + secret_name.encode()
).hexdigest()[:20]

def nix_from_toml(path: pathlib.Path) -> dict:
    expression = f'builtins.fromTOML (builtins.readFile "{path}")'
    completed = subprocess.run(
        ["nix", "eval", "--impure", "--json", "--expr", expression],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return json.loads(completed.stdout)

profiles = nix_from_toml(smoke / "managed-env-files.toml")["env_files"]
if len(profiles) != 1:
    raise SystemExit("retirement smoke must bind exactly one profile")
profile = profiles[0]
expected = {
    "id": "profile.PHAROS_BEACON_RETIREMENTSMOKE_TOKEN",
    "secret_ref": expected_ref,
    "destination": f"pharos-beacon-{host}",
    "env": "PHAROS_TOKEN",
    "output": f"/run/janus/env/pharos/beacons/{host}.env",
}
for key, value in expected.items():
    if profile.get(key) != value:
        raise SystemExit(f"retirement smoke profile {key} mismatch")
sidecar = profile.get("hash_sidecar", {})
if sidecar.get("subject") != host or sidecar.get("output") != f"/run/janus/env/pharos/beacon-token-hashes/{host}.json":
    raise SystemExit("retirement smoke sidecar mismatch")

secretspec = nix_from_toml(smoke / "secretspec.toml")
if secret_name not in secretspec.get("profiles", {}).get(host, {}):
    raise SystemExit("retirement smoke secret is not declared")

intent = json.loads((smoke / "retired-hosts.json").read_text(encoding="utf-8"))
if intent != {
    "retirements": [{
        "credential_retirement_required": True,
        "disposition": "destroyed",
        "host": host,
        "server_deletion": False,
        "successor": None,
    }],
    "schema": "inspr.pharos.janus-retirements.v1",
    "version": 1,
}:
    raise SystemExit("retirement smoke intent mismatch")

image_match = re.search(
    r"^\s+image = \"ghcr\.io/inspr-at/janus/janus-engine:(rust-engine-v[^@\s]+)@(sha256:[0-9a-f]{64})\";$",
    compose,
    re.MULTILINE,
)
if not image_match:
    raise SystemExit("Janus staged image is not release and digest pinned")
PY

printf 'janus_pharos_retirement_contract=passed\n'
