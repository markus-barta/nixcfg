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
shared_flow="$repo_root/hosts/csb1/shared-flow.nix"
host_config="$repo_root/hosts/csb1/configuration.nix"
module="$repo_root/modules/janus-flow-host/default.nix"
eval_file="$repo_root/tests/janus-flow-host-eval.nix"

for file in "$stage" "$compose" "$shared_flow" "$host_config" "$module" "$eval_file"; do
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
expect_rejected "import $eval_file { principalRefs = [ \"opaque-a\" \" opaque-a \" ]; }" \
  'Janus Flow accepted duplicate principal bindings after normalization'
expect_rejected "import $eval_file { principalRefs = [ \"*\" ]; }" \
  'Janus Flow accepted a wildcard principal binding'
expect_rejected "import $eval_file { principalRefs = [ \"opaque-*\" ]; }" \
  'Janus Flow accepted a partial wildcard principal binding'
expect_rejected "import $eval_file { projectRef = \"other:proj-x\"; }" \
  'Janus Flow accepted a non-Paimos project ref'
expect_rejected "import $eval_file { bindings = [ { projectId = 17; projectRef = null; label = \"A\"; principalRefs = [ \"opaque-a\" ]; } { projectId = 17; projectRef = null; label = \"B\"; principalRefs = [ \"opaque-b\" ]; } ]; }" \
  'Janus Flow accepted duplicate project ids'
expect_rejected "import $eval_file { bindings = [ { projectId = 17; projectRef = \"paimos:proj-shared\"; label = \"A\"; principalRefs = [ \"opaque-a\" ]; } { projectId = 18; projectRef = \"paimos:proj-shared\"; label = \"B\"; principalRefs = [ \"opaque-b\" ]; } ]; }" \
  'Janus Flow accepted duplicate explicit project refs'

# Module and Compose consume one switch, preserve uid 100:101, and publish the
# runtime file atomically rather than mounting its world-readable store source.
grep -Fq 'import ./janus-flow-host.nix' "$host_config"
grep -Fq 'import ../janus-flow-host.nix' "$compose"
grep -Fq '../../modules/janus-flow-host' "$host_config"
grep -Fq 'activate = janusFlowHost.active;' "$host_config"
grep -Fq 'containerUid = 100;' "$host_config"
grep -Fq 'containerGid = 101;' "$host_config"
grep -Fq '  active = false;' "$stage"
nix eval --impure --json --expr "import $stage" | jq -e '
  .active == false
  and .hostApiKeyFile == "/run/janus-flow-credential/api-key"
  and (.credentialRevision == null or (.credentialRevision | test("^[0-9a-f]{64}$")))
  and .bindings == [{projectId:33,projectRef:null,label:"UXQA sandbox",principalRefs:["391779593318563851"]}]
' >/dev/null
# shellcheck disable=SC2016
grep -Fq '${./private_files.py} placeholder' "$module"
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
mkdir -p "$workdir/off/docker" "$workdir/on/docker" "$workdir/missing/docker" "$workdir/rotated/docker"
# Synthetic revision metadata is not a credential or an encrypted artifact.
for fixture in off on missing rotated; do
  active=true
  revision='"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
  [[ "$fixture" != off ]] || active=false
  [[ "$fixture" != missing ]] || revision=null
  [[ "$fixture" != rotated ]] || revision='"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
  printf '(import %s) // { active = %s; credentialRevision = %s; }\n' "$stage" "$active" "$revision" >"$workdir/$fixture/janus-flow-host.nix"
  cp "$compose" "$workdir/$fixture/docker/compose-spec.nix"
  sed 's/^  active = true;/  active = false;/' "$shared_flow" >"$workdir/$fixture/shared-flow.nix"
done
expect_rejected "(import $workdir/missing/docker/compose-spec.nix).services.janus" \
  'Janus Flow accepted activation without ciphertext revision'
rotated_service=$(nix eval --impure --json --expr "(import $workdir/rotated/docker/compose-spec.nix).services.janus")
for fixture in off on; do
  grep -Fq '  active = false;' "$workdir/$fixture/shared-flow.nix" || {
    printf 'Janus fixture must leave shared Flow inactive: %s\n' "$fixture" >&2
    exit 1
  }
done

as_nix_string() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}
off_path=$(as_nix_string "$workdir/off/docker/compose-spec.nix")
on_path=$(as_nix_string "$workdir/on/docker/compose-spec.nix")
live_path=$(as_nix_string "$compose")

off_service=$(nix eval --impure --json --expr "(import ${off_path}).services.janus")
on_service=$(nix eval --impure --json --expr "(import ${on_path}).services.janus")
live_service=$(nix eval --impure --json --expr "(import ${live_path}).services.janus")

PYTHONDONTWRITEBYTECODE=1 python3 - "$off_service" "$on_service" "$live_service" "$rotated_service" <<'PY'
import json
import sys

off, on, live, rotated = map(json.loads, sys.argv[1:5])
failures = []
var = "JANUS_FLOW_CONFIG_FILE"

def flow_vars(service):
    return [value for value in service["environment"] if value.startswith(var + "=")]

if flow_vars(off) or flow_vars(live):
    failures.append("inactive Janus carries JANUS_FLOW_CONFIG_FILE")
# Normalize only the separately tested active shared-origin changes, then
# preserve the full-service equality check for the disabled delivery adapter.
public_keys = {"JANUS_PUBLIC_URL", "JANUS_PUBLIC_BASE_PATH"}
if {entry for entry in live["environment"] if entry.split("=", 1)[0] in public_keys} != {
    "JANUS_PUBLIC_URL=https://flow.inspr.at", "JANUS_PUBLIC_BASE_PATH=/janus",
}:
    failures.append("live Janus shared-origin settings are wrong")
if live.get("networks") != {"traefik": None, "shared-flow": {"ipv4_address": "10.253.253.3"}}:
    failures.append("live Janus shared network is wrong")
if live.get("extra_hosts") != ["pharos.barta.cm:10.253.253.2"]:
    failures.append("live Janus private Pharos resolution is wrong")
expected_health = {
    "test": ["CMD-SHELL", "wget -qO- http://127.0.0.1:8080/janus/readyz | grep -q '\"ready\":true' || exit 1"],
    "interval": "30s", "timeout": "3s", "start_period": "10s", "retries": 3,
}
if live.get("healthcheck") != expected_health:
    failures.append("live Janus healthcheck does not preserve ready:true at its native prefix")
if "healthcheck" in off:
    failures.append("inactive shared origin must retain the image healthcheck")
normalized_live = dict(live)
normalized_live["environment"] = [entry for entry in live["environment"] if entry.split("=", 1)[0] not in public_keys] + ["JANUS_PUBLIC_URL=https://vault.barta.cm"]
normalized_live["networks"] = ["traefik"]
normalized_live.pop("extra_hosts", None)
normalized_live.pop("healthcheck", None)
if normalized_live != off:
    failures.append("forced-off Janus differs beyond the reviewed shared-origin changes")
if flow_vars(on) != ["JANUS_FLOW_CONFIG_FILE=/run/janus/flow-host/config.json"]:
    failures.append(f"active config variable is wrong: {flow_vars(on)!r}")
if on.get("user") != "100:101":
    failures.append(f"active Janus user drifted from 100:101: {on.get('user')!r}")

added_volumes = [value for value in on["volumes"] if value not in off["volumes"]]
if len(added_volumes) != 2:
    failures.append(f"active Janus added {len(added_volumes)} mounts, expected 2")
expected = {
    ("/run/janus/flow-host", "/run/janus/flow-host"),
    ("/run/janus-flow-credential/api-key", "/run/janus/flow-host/api-key"),
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

# Recover the entire original service after removing exactly Flow's additions.
stripped = dict(on)
stripped["environment"] = [value for value in on["environment"] if not value.startswith(var + "=")]
stripped["volumes"] = [value for value in on["volumes"] if value not in added_volumes]
stripped["labels"] = [value for value in on["labels"] if value not in added_labels]
if stripped != off:
    failures.append("Flow activation changes unrelated Janus service settings")
if rotated["labels"] == on["labels"]:
    failures.append("ciphertext rotation does not change the Compose revision")
if dict(rotated, labels=on["labels"]) != on:
    failures.append("ciphertext rotation changes more than the revision label")

if failures:
    print(f"T76: {len(failures)} failure(s):", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    raise SystemExit(1)
PY

# The projection depends on agenix's activation anchor, not a phantom unit.
PYTHONDONTWRITEBYTECODE=1 python3 - "$host_config" <<'PY'
import pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text()
activation = re.search(r'system\.activationScripts\.janusFlowCredential = lib\.mkIf janusFlowHost\.active \{(.*?)\n  \};', source, re.S)
assert activation, "missing gated credential projection"
assert 'deps = [ "agenix" ];' in activation[1]
assert 'private_files.py} credential' in activation[1]
assert '--source ${lib.escapeShellArg config.age.secrets.csb1-janus-flow-api-key.path}' in activation[1]
assert '--uid 100 --gid 101' in activation[1]
secret = re.search(r'age\.secrets\.csb1-janus-flow-api-key = lib\.mkIf janusFlowHost\.active \{(.*?)\n  \};', source, re.S)
assert secret, "missing gated agenix declaration"
for required in ('owner = "root";', 'group = "root";', 'mode = "0400";'):
    assert required in secret[1], "unsafe agenix metadata"
assert 'path =' not in secret[1] and 'symlink =' not in secret[1], "must keep default agenix publication"
extra_after = re.search(r'extraAfter = (.*?);', source, re.S)
assert extra_after and 'agenix.service' not in extra_after[1], "phantom Compose agenix service"
assert 'config.age.secrets.csb1-janus-flow-api-key.file' in source, "missing ciphertext reconcile trigger"
PY

PYTHONDONTWRITEBYTECODE=1 python3 "$repo_root/tests/test_janus_flow_private_files.py"

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
