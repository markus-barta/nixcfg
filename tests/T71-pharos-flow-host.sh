#!/usr/bin/env bash
# T71 — csb1 Pharos Flow host config contract (NIX-442 / PHAROS-257).
#
# What can actually go wrong here, and what each block therefore proves:
#
#   1. pharosd PANICS at startup when PHAROS_FLOW_CONFIG_FILE is set but the
#      config or API key is missing or has the wrong owner, mode or parent.
#      Compose env and the module's `activate` must be driven by ONE switch.
#   2. Default disabled is a no-op: no Flow env, mount, credential or binding.
#   3. An enabled synthetic document matches inspr.pharos.flow-host-config.v1
#      as accepted by crates/pharosd/src/flow_host.rs (deny_unknown_fields,
#      nonempty bindings, https origin, absolute api_key_file).
#   4. Missing bindings, unsafe origins, relative credential paths, emails
#      and wildcards are rejected at eval time.
#   5. PHAROS-206 stays inert. Flow grants no delivery/provider/Janus authority.
#   6. No credential VALUE may appear in the declarative tree, and the Flow
#      API-key path must not reuse the delivery adapter's key.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

report_failure() {
  local exit_code=$?
  local line=$1
  printf 'pharos flow host test failed at line %s (exit %s)\n' "$line" "$exit_code" >&2
}
trap 'report_failure "$LINENO"' ERR

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
stage="$repo_root/hosts/csb1/pharos-flow-host.nix"
delivery_stage="$repo_root/hosts/csb1/paimos-delivery-stage.nix"
compose="$repo_root/hosts/csb1/docker/compose-spec.nix"
host_config="$repo_root/hosts/csb1/configuration.nix"
pharos_module="$repo_root/modules/pharos-flow-host/default.nix"
pharos_eval="$repo_root/tests/pharos-flow-host-eval.nix"
delivery_module="$repo_root/modules/pharos-paimos-delivery/default.nix"
paimos_defaults="$repo_root/modules/shared/markus-defaults.nix"

for file in "$stage" "$delivery_stage" "$compose" "$host_config" "$pharos_module" "$pharos_eval"; do
  nix-instantiate --parse "$file" >/dev/null
done

eval_flow() {
  nix eval --impure --json --expr "import $pharos_eval { $* }"
}

expect_flow_rejected() {
  local expr=$1
  local message=$2
  if nix eval --impure --json --expr "$expr" >/dev/null 2>&1; then
    printf '%s\n' "$message" >&2
    exit 1
  fi
}

# --- 0. enabled synthetic document matches the released parser contract --------
enabled_document=$(eval_flow 'activate = true;')
jq -e '
  .activated == true
  and .generated.schema == "inspr.pharos.flow-host-config.v1"
  and .generated.schema_version == 1
  and .generated.enabled == true
  and .generated.host_id == "pharos-test"
  and .generated.instance_label == "Pharos test"
  and .generated.paimos_origin == "https://pm.barta.cm"
  and .generated.api_key_file == "/run/pharos/flow-host/api-key"
  and (.generated.bindings | length) == 1
  and .generated.bindings[0] == {
    project_id: 17,
    project_ref: "paimos:proj-9b2899fb59591130607952d66fcb5607",
    label: "Test project",
    hosts: ["hsb8"],
    operator_refs: ["operator-a"]
  }
  and (.generated | keys) == [
    "api_key_file",
    "bindings",
    "enabled",
    "host_id",
    "instance_label",
    "paimos_origin",
    "schema",
    "schema_version"
  ]
  and (.generated.bindings[0] | keys) == [
    "hosts",
    "label",
    "operator_refs",
    "project_id",
    "project_ref"
  ]
' <<<"$enabled_document" >/dev/null

omitted_ref=$(eval_flow 'projectRef = null;')
jq -e '
  .generated.enabled == false
  and .activated == false
  and (.generated.bindings[0] | has("project_ref") | not)
  and .generated.bindings[0].project_id == 17
' <<<"$omitted_ref" >/dev/null

disabled_live=$(eval_flow 'activate = false; bindings = [];')
jq -e '
  .activated == false
  and .generated.enabled == false
  and .generated.bindings == []
' <<<"$disabled_live" >/dev/null

expect_flow_rejected \
  "import $pharos_eval { activate = true; bindings = []; }" \
  'Flow host accepted activate=true with no project bindings'
expect_flow_rejected \
  "import $pharos_eval { paimosOrigin = \"http://pm.barta.cm\"; }" \
  'Flow host accepted a cleartext http origin'
expect_flow_rejected \
  "import $pharos_eval { paimosOrigin = \"https://user:pass@pm.barta.cm\"; }" \
  'Flow host accepted an origin with userinfo'
expect_flow_rejected \
  "import $pharos_eval { paimosOrigin = \"https://pm.barta.cm/path\"; }" \
  'Flow host accepted an origin with a path'
expect_flow_rejected \
  "import $pharos_eval { paimosOrigin = \"https://pm.barta.cm?q=1\"; }" \
  'Flow host accepted an origin with a query'
expect_flow_rejected \
  "import $pharos_eval { apiKeyFile = \"api.key\"; }" \
  'Flow host accepted a relative credential path'
expect_flow_rejected \
  "import $pharos_eval { hostId = \"1pharos\"; }" \
  'Flow host accepted a host_id that does not start with a letter'
expect_flow_rejected \
  "import $pharos_eval { operatorRefs = [ \"user@example.com\" ]; }" \
  'Flow host accepted an email-based operator_ref'
expect_flow_rejected \
  "import $pharos_eval { hosts = [ \"*\" ]; }" \
  'Flow host accepted a wildcard host allowlist'
expect_flow_rejected \
  "import $pharos_eval { projectRef = \"org:proj-x\"; }" \
  'Flow host accepted a project_ref that is not paimos:proj-'
expect_flow_rejected \
  "import $pharos_eval { projectId = 0; }" \
  'Flow host accepted project_id 0'

# --- 1. one switch, wired on both sides; delivery stays inert ---------------
grep -Fq 'import ./pharos-flow-host.nix' "$host_config"
grep -Fq 'import ../pharos-flow-host.nix' "$compose"
grep -Fq 'activate = pharosFlowHost.active;' "$host_config"
grep -Fq '../../modules/pharos-flow-host' "$host_config"
grep -Fq 'bindings = [ ];' "$host_config"
grep -Fq '  active = false;' "$stage"
grep -Fq '  active = false;' "$delivery_stage"
grep -Fq 'intents = [ ];' "$host_config"
grep -Fq 'PHAROS_FLOW_CONFIG_FILE' "$compose"
if grep -Fq 'PHAROS_FLOW_ALLOW_LOOPBACK_ORIGIN=' "$compose"; then
  printf 'PHAROS_FLOW_ALLOW_LOOPBACK_ORIGIN must not appear in production compose\n' >&2
  exit 1
fi
if grep -Fq 'csb1-paimos-pharos-owner-api-key' "$stage"; then
  printf 'Flow host must not reuse the PHAROS-206 delivery API-key path\n' >&2
  exit 1
fi
grep -Fq 'install -d -m 0700 -o' "$pharos_module"
grep -Fq 'install -m 0400 -o' "$pharos_module"

# --- 2. the compose side follows the switch, in BOTH positions ---------------
temp_root=${TMPDIR:-/tmp}
if [[ ! -d "$temp_root" ]]; then
  printf 'T71: temporary parent is not a directory: %s\n' "$temp_root" >&2
  exit 1
fi
temp_parent=$(cd -- "$temp_root" && pwd -P)
workdir="$(mktemp -d "${temp_parent}/t71-flow.XXXXXX")"
sibling="$(mktemp -d "${temp_parent}/t71-flow-sib.XXXXXX")"
printf 'keep\n' >"$sibling/marker"
remove_owned_tempdir() {
  local dir=${1:-}
  local expected=${2:-}
  [[ -n "$dir" ]] || return 0
  if [[ ! -e "$dir" && ! -L "$dir" ]]; then
    return 0
  fi
  [[ -d "$dir" ]] || {
    printf 'refusing to delete non-directory: %s\n' "$dir" >&2
    return 1
  }
  [[ -n "$expected" && "$dir" == "$expected" ]] || {
    printf 'refusing to delete unexpected path: %s\n' "$dir" >&2
    return 1
  }
  [[ "$(dirname -- "$dir")" == "$temp_parent" ]] || {
    printf 'refusing to delete path outside captured temp parent: %s\n' "$dir" >&2
    return 1
  }
  find "$dir" -mindepth 1 -delete
  rmdir "$dir"
}
trap 'remove_owned_tempdir "$workdir" "$workdir"; remove_owned_tempdir "$sibling" "$sibling"' EXIT
mkdir -p "$workdir/off/docker" "$workdir/on/docker"
sed 's/^  active = true;/  active = false;/' "$stage" >"$workdir/off/pharos-flow-host.nix"
sed 's/^  active = false;/  active = true;/' "$stage" >"$workdir/on/pharos-flow-host.nix"
cp "$delivery_stage" "$workdir/off/paimos-delivery-stage.nix"
cp "$delivery_stage" "$workdir/on/paimos-delivery-stage.nix"
cp "$compose" "$workdir/off/docker/compose-spec.nix"
cp "$compose" "$workdir/on/docker/compose-spec.nix"

grep -Fq '  active = false;' "$workdir/off/pharos-flow-host.nix" ||
  {
    printf 'forced-off fixture did not render active = false\n' >&2
    exit 1
  }
grep -Fq '  active = true;' "$workdir/on/pharos-flow-host.nix" ||
  {
    printf 'forced-on fixture did not render active = true\n' >&2
    exit 1
  }
grep -Fq '  active = false;' "$workdir/on/paimos-delivery-stage.nix" ||
  {
    printf 'flow-on fixture must leave PHAROS-206 active = false\n' >&2
    exit 1
  }

nix_import_path() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

off_compose=$(nix_import_path "$workdir/off/docker/compose-spec.nix")
on_compose=$(nix_import_path "$workdir/on/docker/compose-spec.nix")
live_compose=$(nix_import_path "$compose")
off_env="$(nix eval --impure --json --expr "(import ${off_compose}).services.pharosd.environment")"
off_volumes="$(nix eval --impure --json --expr "(import ${off_compose}).services.pharosd.volumes")"
on_env="$(nix eval --impure --json --expr "(import ${on_compose}).services.pharosd.environment")"
on_volumes="$(nix eval --impure --json --expr "(import ${on_compose}).services.pharosd.volumes")"
live_env="$(nix eval --impure --json --expr "(import ${live_compose}).services.pharosd.environment")"
live_volumes="$(nix eval --impure --json --expr "(import ${live_compose}).services.pharosd.volumes")"

PYTHONDONTWRITEBYTECODE=1 python3 - \
  "$off_env" "$off_volumes" "$on_env" "$on_volumes" "$live_env" "$live_volumes" \
  "$stage" "$paimos_defaults" "$pharos_module" "$delivery_module" <<'PY'
import json
import re
import sys

(
    off_env,
    off_volumes,
    on_env,
    on_volumes,
    live_env,
    live_volumes,
    stage_path,
    defaults_path,
    pharos_module_path,
    delivery_module_path,
) = sys.argv[1:11]
off_env, on_env, live_env = map(json.loads, (off_env, on_env, live_env))
off_volumes, on_volumes, live_volumes = map(json.loads, (off_volumes, on_volumes, live_volumes))
failures = []

VAR = "PHAROS_FLOW_CONFIG_FILE"
DELIVERY_VAR = "PHAROS_PAIMOS_DELIVERY_CONFIG_FILE"


def config_vars(env, name=VAR):
    return [entry for entry in env if entry.startswith(f"{name}=")]


# Live and forced-off must be the same no-op: no Flow env, no extra mounts.
if config_vars(off_env) or config_vars(live_env):
    failures.append(f"{VAR} is set while the stage switch is off - pharosd would panic before credentials exist")
if config_vars(off_env, DELIVERY_VAR) or config_vars(on_env, DELIVERY_VAR) or config_vars(live_env, DELIVERY_VAR):
    failures.append(f"{DELIVERY_VAR} must stay unset (NIX-381 active=false)")
if off_env != live_env:
    failures.append("forced-off pharosd environment drifted from the live compose spec")
if off_volumes != live_volumes:
    failures.append("forced-off pharosd volumes drifted from the live compose spec")
if len(off_volumes) != len(on_volumes) - 2:
    failures.append(
        f"inactive/active volume delta is {len(on_volumes) - len(off_volumes)}, expected exactly 2 "
        "(flow-host directory + API key)"
    )

active = config_vars(on_env)
if len(active) != 1:
    failures.append(f"expected exactly one {VAR} entry when active, found {len(active)}")
else:
    path = active[0].split("=", 1)[1]
    if path != "/run/pharos/flow-host/config.json":
        failures.append(f"{VAR} must point at the published config path, got {path!r}")
    if "/nix/store" in path:
        failures.append(f"{VAR} must never be a store path: {path!r}")

added = [volume for volume in on_volumes if volume not in off_volumes]
if len(added) != 2:
    failures.append(f"expected 2 added pharosd mounts when Flow is active, found {len(added)}")
for volume in added:
    if not isinstance(volume, dict):
        failures.append(f"Flow mount must be a long-form bind, got {volume!r}")
        continue
    if volume.get("type") != "bind" or not volume.get("read_only"):
        failures.append(f"Flow mount must be a read-only bind: {volume}")
    if volume.get("bind", {}).get("create_host_path") is not False:
        failures.append(f"Flow mount must not create a host path: {volume}")
    if "/nix/store" in volume.get("source", ""):
        failures.append(f"Flow mount source must never be a store path: {volume}")

sources = [volume["source"] for volume in added if isinstance(volume, dict)]
targets = [volume["target"] for volume in added if isinstance(volume, dict)]
if len(set(sources)) != len(sources):
    failures.append(f"Flow mounts share a host source: {sources}")
if len(set(targets)) != len(targets):
    failures.append(f"Flow mounts share a container target: {targets}")
if "/run/pharos/flow-host" not in sources:
    failures.append(f"active Flow must bind the uid-owned parent directory, got {sources}")
credential_sources = [source for source in sources if source != "/run/pharos/flow-host"]
if len(credential_sources) != 1:
    failures.append(f"expected 1 Flow credential mount, found {credential_sources}")
for source in credential_sources:
    if not source.startswith("/run/agenix/"):
        failures.append(f"Flow credential mount must come from agenix, got {source!r}")
    if "paimos" in source:
        failures.append(f"Flow credential mount reuses a delivery path: {source!r}")

defaults = open(defaults_path, encoding="utf-8").read()
instance = re.search(
    r"defaultInstance\s*=\s*(?:lib\.mkDefault\s*)?\"([A-Za-z0-9_-]+)\"", defaults
)
canonical = None
if not instance:
    failures.append("markus-defaults.nix declares no inspr.paimos-cli.defaultInstance")
else:
    url = re.search(
        r"instances\.%s\s*=\s*\{.*?url\s*=\s*\"([^\"]+)\"" % re.escape(instance.group(1)),
        defaults,
        re.S,
    )
    if not url:
        failures.append(
            f"markus-defaults.nix declares no url for the default Paimos instance "
            f"{instance.group(1)!r}"
        )
    else:
        canonical = url.group(1).rstrip("/")

declared = {
    stage_path: re.search(r'paimosOrigin\s*=\s*"([^"]+)"', open(stage_path, encoding="utf-8").read()),
    pharos_module_path: re.search(
        r'paimosOrigin\s*=\s*lib\.mkOption\s*\{.*?example\s*=\s*"([^"]+)"',
        open(pharos_module_path, encoding="utf-8").read(),
        re.S,
    ),
}
for path, match in declared.items():
    if not match:
        failures.append(f"{path}: no paimosOrigin value found")
        continue
    value = match.group(1)
    if not re.fullmatch(r"https://[A-Za-z0-9.-]+", value):
        failures.append(
            f"{path}: paimosOrigin must be a credential-free https origin, got {value!r}"
        )
    elif canonical is not None and value != canonical:
        failures.append(
            f"{path}: paimosOrigin is {value!r} but the canonical Paimos instance "
            f"declared in markus-defaults.nix is {canonical!r}"
        )

delivery = open(delivery_module_path, encoding="utf-8").read()
if "PHAROS_FLOW_CONFIG_FILE" in delivery:
    failures.append("pharos-paimos-delivery must not grow Flow host wiring")

if failures:
    print(f"T71: {len(failures)} compose/switch failure(s):", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    raise SystemExit(1)
PY

# --- 3. no credential values in the declarative tree ---------------------------
PYTHONDONTWRITEBYTECODE=1 python3 - "$stage" "$pharos_module" <<'PY'
import re
import sys

failures = []
patterns = (
    (re.compile(r"paimos_[A-Za-z0-9_-]{25,}"), "a literal Paimos API key"),
    (
        re.compile(r"(?<!sha256:)\b[0-9a-fA-F]{64}\b"),
        "a 64-hex literal that could be a raw secret",
    ),
)
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    for line_number, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        for pattern, description in patterns:
            if pattern.search(line):
                failures.append(f"{path}:{line_number}: {description}")

if failures:
    print(f"T71: {len(failures)} credential-shaped literal(s) in declarative config:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    raise SystemExit(1)
PY

remove_owned_tempdir "$workdir" "$workdir"
if [[ -e "$workdir" || -L "$workdir" ]]; then
  printf 'owned workdir still present after cleanup: %s\n' "$workdir" >&2
  exit 1
fi
if [[ ! -f "$sibling/marker" ]]; then
  printf 'sibling tempdir did not survive workdir cleanup: %s\n' "$sibling" >&2
  exit 1
fi

printf 'pharos_flow_host=passed\n'
