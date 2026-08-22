#!/usr/bin/env bash
# T48 — csb1 Paimos v1 external-stage adapter contract (NIX-381 / PAI-810).
#
# What can actually go wrong here, and what each block therefore proves:
#
#   1. pharosd v0.1.83 PANICS at startup when PHAROS_PAIMOS_DELIVERY_CONFIG_FILE
#      is set but the config/API key/handoff secret is missing or has the wrong
#      owner or mode. So the compose env var and the module's `activate` must be
#      driven by ONE switch. A drift between them does not degrade the fleet
#      dashboard, it crash-loops it.
#   2. Both adapters refuse a shared credential inode, so the API key and every
#      32-byte handoff secret must be distinct files.
#   3. Neither published file may be a /nix/store path: both binaries require
#      mode & 0o077 == 0, an exact owner uid, and nlink == 1.
#   4. The Janus reporter reads exactly one hard-coded path and takes no
#      arguments; a unit that passes one is dead on arrival.
#   5. No credential VALUE may appear anywhere in the declarative tree.
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s: bash %s is too old -- set -e does not abort on a failing [[ ]], so this test would FALSELY PASS. Run under bash 5: nix run nixpkgs#bash -- %s\n' \
    "${0##*/}" "$BASH_VERSION" "$0" >&2
  exit 2
fi

report_failure() {
  local exit_code=$?
  local line=$1
  printf 'paimos delivery stage test failed at line %s (exit %s)\n' "$line" "$exit_code" >&2
}
trap 'report_failure "$LINENO"' ERR

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
stage="$repo_root/hosts/csb1/paimos-delivery-stage.nix"
compose="$repo_root/hosts/csb1/docker/compose-spec.nix"
host_config="$repo_root/hosts/csb1/configuration.nix"
pharos_module="$repo_root/modules/pharos-paimos-delivery/default.nix"
janus_module="$repo_root/modules/janus-paimos-dependency-reporter/default.nix"
# The one place this repo already declares the canonical Paimos instances.
paimos_defaults="$repo_root/modules/shared/markus-defaults.nix"

for file in "$stage" "$compose" "$host_config" "$pharos_module" "$janus_module"; do
  nix-instantiate --parse "$file" >/dev/null
done

# --- 1. one switch, wired on both sides -------------------------------------
grep -Fq 'import ./paimos-delivery-stage.nix' "$host_config"
grep -Fq 'import ../paimos-delivery-stage.nix' "$compose"
grep -Fq 'activate = paimosDeliveryStage.active;' "$host_config"
grep -Fq '../../modules/pharos-paimos-delivery' "$host_config"
grep -Fq '../../modules/janus-paimos-dependency-reporter' "$host_config"

# --- 2. the compose side follows the switch, in BOTH positions ---------------
# Rendered with the real file (whatever `active` currently is) and with a
# forced-active copy, so this test keeps biting after the operator flips it.
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
mkdir -p "$workdir/off/docker" "$workdir/on/docker"
sed 's/^  active = true;/  active = false;/' "$stage" >"$workdir/off/paimos-delivery-stage.nix"
sed 's/^  active = false;/  active = true;/' "$stage" >"$workdir/on/paimos-delivery-stage.nix"
cp "$compose" "$workdir/off/docker/compose-spec.nix"
cp "$compose" "$workdir/on/docker/compose-spec.nix"

grep -Fq '  active = false;' "$workdir/off/paimos-delivery-stage.nix" ||
  {
    printf 'forced-off fixture did not render active = false\n' >&2
    exit 1
  }
grep -Fq '  active = true;' "$workdir/on/paimos-delivery-stage.nix" ||
  {
    printf 'forced-on fixture did not render active = true\n' >&2
    exit 1
  }

off_env="$(nix eval --impure --json --expr "(import $workdir/off/docker/compose-spec.nix).services.pharosd.environment")"
off_volumes="$(nix eval --impure --json --expr "(import $workdir/off/docker/compose-spec.nix).services.pharosd.volumes")"
on_env="$(nix eval --impure --json --expr "(import $workdir/on/docker/compose-spec.nix).services.pharosd.environment")"
on_volumes="$(nix eval --impure --json --expr "(import $workdir/on/docker/compose-spec.nix).services.pharosd.volumes")"

PYTHONDONTWRITEBYTECODE=1 python3 - \
  "$off_env" "$off_volumes" "$on_env" "$on_volumes" "$stage" \
  "$paimos_defaults" "$pharos_module" "$janus_module" <<'PY'
import json
import re
import sys

(
    off_env,
    off_volumes,
    on_env,
    on_volumes,
    stage_path,
    defaults_path,
    pharos_module_path,
    janus_module_path,
) = sys.argv[1:9]
off_env, on_env = json.loads(off_env), json.loads(on_env)
off_volumes, on_volumes = json.loads(off_volumes), json.loads(on_volumes)
stage = open(stage_path, encoding="utf-8").read()
failures = []

VAR = "PHAROS_PAIMOS_DELIVERY_CONFIG_FILE"


def config_vars(env):
    return [entry for entry in env if entry.startswith(f"{VAR}=")]


# Inactive: pharosd must be byte-for-byte the pre-NIX-381 service.
if config_vars(off_env):
    failures.append(f"{VAR} is set while the stage switch is off - pharosd would panic before credentials exist")
if len(off_volumes) != len(on_volumes) - 4:
    failures.append(
        f"inactive/active volume delta is {len(on_volumes) - len(off_volumes)}, expected exactly 4 "
        "(config + API key + deployment secret + verification secret)"
    )

# Active: exactly one env var, pointing at the published config path.
active = config_vars(on_env)
if len(active) != 1:
    failures.append(f"expected exactly one {VAR} entry when active, found {len(active)}")
else:
    path = active[0].split("=", 1)[1]
    if not path.startswith("/run/"):
        failures.append(f"{VAR} must point at a runtime-published path, got {path!r}")
    if "/nix/store" in path:
        failures.append(f"{VAR} must never be a store path (mode 0444, possibly hardlinked): {path!r}")

added = [volume for volume in on_volumes if volume not in off_volumes]
if len(added) != 4:
    failures.append(f"expected 4 added pharosd mounts when active, found {len(added)}")
for volume in added:
    if not isinstance(volume, dict):
        failures.append(f"adapter mount must be a long-form bind, got {volume!r}")
        continue
    if volume.get("type") != "bind" or not volume.get("read_only"):
        failures.append(f"adapter mount must be a read-only bind: {volume}")
    if volume.get("bind", {}).get("create_host_path") is not False:
        failures.append(f"adapter mount must not create a host path: {volume}")
    if "/nix/store" in volume.get("source", ""):
        failures.append(f"adapter mount source must never be a store path: {volume}")

# Distinct inodes: no source and no target may be reused.
sources = [volume["source"] for volume in added if isinstance(volume, dict)]
targets = [volume["target"] for volume in added if isinstance(volume, dict)]
if len(set(sources)) != len(sources):
    failures.append(f"adapter mounts share a host source - both adapters refuse a shared credential inode: {sources}")
if len(set(targets)) != len(targets):
    failures.append(f"adapter mounts share a container target: {targets}")

# The three credential mounts must come from agenix, not from the closure.
credential_sources = [source for source in sources if "paimos-delivery" not in source]
if len(credential_sources) != 3:
    failures.append(f"expected 3 credential mounts, found {credential_sources}")
for source in credential_sources:
    if not source.startswith("/run/agenix/"):
        failures.append(f"credential mount must come from agenix, got {source!r}")

# --- the origin is the EXACT canonical instance, not merely https-shaped ----
# 🔴 A plausible-but-wrong origin (a subdomain that does not resolve, or the
# other-trust-context instance) is invisible to a shape check and only shows up
# as `paimos_reporter_*`/`contract_refused` after activation. So the canonical
# value is DERIVED from the single place this repo already declares it —
# modules/shared/markus-defaults.nix, `inspr.paimos-cli` — and every copy in the
# adapter tree must equal it. Moving the instance therefore moves this test.
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

if canonical is not None and not re.fullmatch(r"https://[A-Za-z0-9.-]+", canonical):
    failures.append(f"canonical Paimos instance url is not a bare https origin: {canonical!r}")

declared = {
    stage_path: re.search(r'paimosOrigin\s*=\s*"([^"]+)"', stage),
    # The module `example =` values are what the next author copies. A stale one
    # is how a dead origin gets reintroduced, so they are checked, not ignored.
    pharos_module_path: re.search(
        r'paimosOrigin\s*=\s*lib\.mkOption\s*\{.*?example\s*=\s*"([^"]+)"',
        open(pharos_module_path, encoding="utf-8").read(),
        re.S,
    ),
    janus_module_path: re.search(
        r'paimosOrigin\s*=\s*lib\.mkOption\s*\{.*?example\s*=\s*"([^"]+)"',
        open(janus_module_path, encoding="utf-8").read(),
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
            f"{path}: paimosOrigin must be a credential-free https origin with no path, "
            f"query or fragment, got {value!r}"
        )
    elif canonical is not None and value != canonical:
        failures.append(
            f"{path}: paimosOrigin is {value!r} but the canonical Paimos instance "
            f"declared in markus-defaults.nix is {canonical!r}"
        )

if failures:
    print(f"T48: {len(failures)} compose/switch failure(s):", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    raise SystemExit(1)
PY

# --- 3. the modules publish private files, never store paths -----------------
grep -Fq 'install -m 0400 -o' "$pharos_module"
grep -Fq 'install -m 0600 -o root -g root' "$janus_module"
# Fixed by the binary; must not become an option.
grep -Fq 'configFile = "/run/janus-paimos-dependency-reporter/config.json";' "$janus_module"
# Durable journal, and the exact mode the reporter demands.
grep -Fq '0700 root root' "$janus_module"
grep -Fq '/var/lib/janus-paimos-dependency-reporter/journal' "$stage"
# Skip, do not fail, before activation.
grep -Fq 'unitConfig.ConditionPathExists = configFile;' "$janus_module"
# 🔴 The reporter refuses to start when argc != 1, so ExecStart must be the
# bare binary path and nothing else.
exec_start="$(grep -E '^\s*ExecStart\s*=' "$janus_module" | grep -F 'janus-paimos-dependency-reporter')"
# The braces below are Nix interpolation in the file under test, not a shell
# expansion, so they must stay inside single quotes.
# shellcheck disable=SC2016
grep -Fqx '        ExecStart = "${cfg.package}/bin/janus-paimos-dependency-reporter";' <<<"$exec_start" ||
  {
    printf 'reporter ExecStart is not the bare binary (argc != 1 exits 1): %s\n' "$exec_start" >&2
    exit 1
  }

# --- 4. operator authority over UpdateRestart is not delegated ---------------
# The adapter may only OBSERVE an existing, operator-confirmed host action.
# Nothing in this repository may confirm, create or auto-approve one.
if grep -Eq 'PHAROS_[A-Z_]*AUTO[A-Z_]*(CONFIRM|APPROVE)' "$compose"; then
  printf 'an auto-confirm Pharos setting appeared; UpdateRestart must stay attended\n' >&2
  exit 1
fi

# --- 5. no credential values anywhere in the declarative tree ----------------
PYTHONDONTWRITEBYTECODE=1 python3 - "$stage" "$pharos_module" "$janus_module" <<'PY'
import re
import sys

failures = []
# A Paimos API key is `paimos_` + >=25 more chars; a raw handoff secret is 32
# bytes, i.e. 64 hex. Neither may ever appear literally — the config names
# FILES, never values. `sha256:`-prefixed hex is excluded: artifact, plan,
# predecessor and context digests are part of the contract and carry no secret.
patterns = (
    (re.compile(r"paimos_[A-Za-z0-9_-]{25,}"), "a literal Paimos API key"),
    (
        re.compile(r"(?<!sha256:)\b[0-9a-fA-F]{64}\b"),
        "a 64-hex literal that could be a raw handoff secret",
    ),
)
for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    for line_number, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue  # prose and examples in comments are not configuration
        for pattern, description in patterns:
            if pattern.search(line):
                failures.append(f"{path}:{line_number}: {description}")

if failures:
    print(f"T48: {len(failures)} credential-shaped literal(s) in declarative config:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    raise SystemExit(1)
PY

printf 'paimos_delivery_stage=passed\n'
