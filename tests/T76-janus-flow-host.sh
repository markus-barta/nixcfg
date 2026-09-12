#!/usr/bin/env bash
# T76 — csb1 Janus Flow host config contract (NIX-481 / JANUS-458).
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s requires bash 4 or newer\n' "${0##*/}" >&2
  exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
stage="$repo_root/hosts/csb1/janus-flow-host.nix"
compose="$repo_root/hosts/csb1/docker/compose-spec.nix"
host_config="$repo_root/hosts/csb1/configuration.nix"
module="$repo_root/modules/janus-flow-host/default.nix"
eval_file="$repo_root/tests/janus-flow-host-eval.nix"

for file in "$stage" "$compose" "$host_config" "$module" "$eval_file"; do
  nix-instantiate --parse "$file" >/dev/null
done

eval_flow() {
  nix eval --impure --json --expr "import $eval_file { $* }"
}

expect_rejected() {
  local expression=$1
  local message=$2
  if nix eval --impure --json --expr "$expression" >/dev/null 2>&1; then
    printf '%s\n' "$message" >&2
    exit 1
  fi
}

# Exact released Go parser document, including optional native browser path.
enabled=$(eval_flow 'activate = true;')
jq -e '
  .activated == true
  and .composeRequires == ["janus-flow-host-config.service"]
  and .generated == {
    schema: "inspr.janus.flow-host-config.v1",
    schema_version: 1,
    enabled: true,
    host_id: "janus-test",
    paimos_origin: "https://pm.barta.cm",
    paimos_browser_url: "https://flow.example/paimos",
    api_key_file: "/run/janus/flow-host/api-key",
    instance_label: "Janus test",
    bindings: [{
      project_id: 17,
      project_ref: "paimos:proj-9b2899fb59591130607952d66fcb5607",
      label: "Test project",
      principal_refs: ["opaque-subject-a"]
    }]
  }
' <<<"$enabled" >/dev/null

disabled=$(eval_flow 'activate = false; bindings = []; paimosBrowserUrl = null;')
jq -e '
  .activated == false
  and .composeRequires == []
  and .generated.enabled == false
  and .generated.bindings == []
  and (.generated | has("paimos_browser_url") | not)
' <<<"$disabled" >/dev/null

omitted_project_ref=$(eval_flow 'projectRef = null; paimosBrowserUrl = null;')
jq -e '
  (.generated.bindings[0] | has("project_ref") | not)
  and (.generated | has("paimos_browser_url") | not)
' <<<"$omitted_project_ref" >/dev/null

expect_rejected "import $eval_file { activate = true; bindings = []; }" \
  'Janus Flow accepted activation with no bindings'
expect_rejected "import $eval_file { paimosOrigin = \"http://pm.barta.cm\"; }" \
  'Janus Flow accepted a cleartext server origin'
expect_rejected "import $eval_file { paimosOrigin = \"https://user:pass@pm.barta.cm\"; }" \
  'Janus Flow accepted server-origin userinfo'
expect_rejected "import $eval_file { paimosOrigin = \"https://pm.barta.cm/path\"; }" \
  'Janus Flow accepted a server origin path'
expect_rejected "import $eval_file { paimosBrowserUrl = \"https://flow.example/paimos/\"; }" \
  'Janus Flow accepted a noncanonical browser trailing slash'
expect_rejected "import $eval_file { paimosBrowserUrl = \"https://flow.example/../paimos\"; }" \
  'Janus Flow accepted browser dot segments'
expect_rejected "import $eval_file { apiKeyFile = \"api-key\"; }" \
  'Janus Flow accepted a relative API-key path'
expect_rejected "import $eval_file { apiKeyFile = \"/run/other/api-key\"; }" \
  'Janus Flow accepted an API key outside the private config parent'
expect_rejected "import $eval_file { hostId = \"1janus\"; }" \
  'Janus Flow accepted a host id that does not start with a letter'
expect_rejected "import $eval_file { principalRefs = [ \"user@example.com\" ]; }" \
  'Janus Flow accepted an email principal binding'
expect_rejected "import $eval_file { principalRefs = [ \"opaque subject\" ]; }" \
  'Janus Flow accepted whitespace in a principal binding'
expect_rejected "import $eval_file { principalRefs = []; }" \
  'Janus Flow accepted an empty principal binding'
expect_rejected "import $eval_file { principalRefs = [ \"opaque-a\" \"opaque-a\" ]; }" \
  'Janus Flow accepted duplicate principal bindings'
expect_rejected "import $eval_file { projectRef = \"other:proj-x\"; }" \
  'Janus Flow accepted a non-Paimos project ref'

# Module and Compose consume one switch, preserve uid 100:101, and publish the
# runtime file atomically rather than mounting its world-readable store source.
grep -Fq 'import ./janus-flow-host.nix' "$host_config"
grep -Fq 'import ../janus-flow-host.nix' "$compose"
grep -Fq '../../modules/janus-flow-host' "$host_config"
grep -Fq 'activate = janusFlowHost.active;' "$host_config"
grep -Fq 'containerUid = 100;' "$host_config"
grep -Fq 'containerGid = 101;' "$host_config"
grep -Fq '  active = false;' "$stage"
grep -Fq '  bindings = [ ];' "$stage"
grep -Fq 'install -d -m 0700 -o' "$module"
grep -Fq 'install -m 0400 -o' "$module"
# shellcheck disable=SC2016
grep -Fq 'mv -f "$temporary" "$destination"' "$module"
grep -Fq '"compose-csb1.service"' "$module"
if grep -Fq 'JANUS_FLOW_ALLOW_LOOPBACK_ORIGIN=' "$compose"; then
  printf 'production Compose must not enable the Janus loopback harness flag\n' >&2
  exit 1
fi

temp_parent=$(cd -- "${TMPDIR:-/tmp}" && pwd -P)
workdir=$(mktemp -d "${temp_parent}/t76-janus-flow.XXXXXX")
cleanup() {
  if [[ -d "$workdir" && "$(dirname -- "$workdir")" == "$temp_parent" ]]; then
    find "$workdir" -mindepth 1 -delete
    rmdir "$workdir"
  fi
}
trap cleanup EXIT
mkdir -p "$workdir/off/docker" "$workdir/on/docker"
sed 's/^  active = false;/  active = true;/' "$stage" >"$workdir/on/janus-flow-host.nix"
cp "$stage" "$workdir/off/janus-flow-host.nix"
cp "$compose" "$workdir/off/docker/compose-spec.nix"
cp "$compose" "$workdir/on/docker/compose-spec.nix"

as_nix_string() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}
off_path=$(as_nix_string "$workdir/off/docker/compose-spec.nix")
on_path=$(as_nix_string "$workdir/on/docker/compose-spec.nix")
live_path=$(as_nix_string "$compose")

off_service=$(nix eval --impure --json --expr "(import ${off_path}).services.janus")
on_service=$(nix eval --impure --json --expr "(import ${on_path}).services.janus")
live_service=$(nix eval --impure --json --expr "(import ${live_path}).services.janus")

PYTHONDONTWRITEBYTECODE=1 python3 - "$off_service" "$on_service" "$live_service" <<'PY'
import json
import sys

off, on, live = map(json.loads, sys.argv[1:4])
failures = []
var = "JANUS_FLOW_CONFIG_FILE"

def flow_vars(service):
    return [value for value in service["environment"] if value.startswith(var + "=")]

if flow_vars(off) or flow_vars(live):
    failures.append("inactive Janus carries JANUS_FLOW_CONFIG_FILE")
if off != live:
    failures.append("forced-off Janus differs from the checked-in inactive service")
if flow_vars(on) != ["JANUS_FLOW_CONFIG_FILE=/run/janus/flow-host/config.json"]:
    failures.append(f"active config variable is wrong: {flow_vars(on)!r}")
if on.get("user") != "100:101":
    failures.append(f"active Janus user drifted from 100:101: {on.get('user')!r}")

added_volumes = [value for value in on["volumes"] if value not in off["volumes"]]
if len(added_volumes) != 2:
    failures.append(f"active Janus added {len(added_volumes)} mounts, expected 2")
expected = {
    ("/run/janus/flow-host", "/run/janus/flow-host"),
    ("/run/agenix/csb1-janus-flow-api-key", "/run/janus/flow-host/api-key"),
}
actual = set()
for volume in added_volumes:
    if not isinstance(volume, dict):
        failures.append(f"Flow mount is not long-form: {volume!r}")
        continue
    if volume.get("type") != "bind" or volume.get("read_only") is not True:
        failures.append(f"Flow mount is not read-only bind: {volume!r}")
    if volume.get("bind", {}).get("create_host_path") is not False:
        failures.append(f"Flow mount may create a missing host path: {volume!r}")
    if "/nix/store" in volume.get("source", ""):
        failures.append(f"Flow mount exposes a store source: {volume!r}")
    actual.add((volume.get("source"), volume.get("target")))
if actual != expected:
    failures.append(f"Flow mount sources/targets differ: {actual!r}")

added_labels = [value for value in on["labels"] if value not in off["labels"]]
prefix = "at.inspr.janus.flow-config-revision="
if len(added_labels) != 1 or not added_labels[0].startswith(prefix):
    failures.append(f"active binding revision label is missing: {added_labels!r}")
if any(value.startswith(prefix) for value in off["labels"]):
    failures.append("inactive Janus carries a Flow deployment revision")

if failures:
    print(f"T76: {len(failures)} failure(s):", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    raise SystemExit(1)
PY

# Paths and opaque sample refs are allowed; credential-shaped literal values are not.
PYTHONDONTWRITEBYTECODE=1 python3 - "$stage" "$module" <<'PY'
import re
import sys

patterns = (
    re.compile(r"paimos_[A-Za-z0-9_-]{25,}"),
    re.compile(r"(?<!sha256:)\b[0-9a-fA-F]{64}\b"),
)
for path in sys.argv[1:]:
    for number, line in enumerate(open(path, encoding="utf-8"), start=1):
        if line.lstrip().startswith("#"):
            continue
        if any(pattern.search(line) for pattern in patterns):
            raise SystemExit(f"credential-shaped literal in {path}:{number}")
PY

cleanup
trap - EXIT
