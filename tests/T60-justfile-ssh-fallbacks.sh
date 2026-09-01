#!/usr/bin/env bash
# T60-justfile-ssh-fallbacks.sh
# Verifies that justfile remote routing cannot fall back to dead MagicDNS or
# a retired former-employer host.
# Related PPM issue: NIX-342

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JUSTFILE="$REPO_ROOT/justfile"
OCBOTS="$REPO_ROOT/+agents/commands/ocbots.md"
MODELUPDATE="$REPO_ROOT/+agents/commands/oc-modelupdate.md"
RUNBOOK="$REPO_ROOT/hosts/hsb0/docs/OPENCLAW-RUNBOOK.md"
WORKSPACE="$REPO_ROOT/nixcfg+agents.code-workspace"

python3 - "$JUSTFILE" "$OCBOTS" "$MODELUPDATE" "$RUNBOOK" "$WORKSPACE" <<'PY'
import pathlib
import re
import sys

justfile_path = pathlib.Path(sys.argv[1])
ocbots_path = pathlib.Path(sys.argv[2])
modelupdate_path = pathlib.Path(sys.argv[3])
runbook_path = pathlib.Path(sys.argv[4])
workspace_path = pathlib.Path(sys.argv[5])
justfile = justfile_path.read_text(encoding="utf-8")
ocbots = ocbots_path.read_text(encoding="utf-8")
modelupdate = modelupdate_path.read_text(encoding="utf-8")
runbook = runbook_path.read_text(encoding="utf-8")
workspace = workspace_path.read_text(encoding="utf-8")

start_marker = "\n_oc-run host cmd:\n"
end_marker = "\n# Helper: resolve container name for a given host target"
container_start = "\n_oc-container host:\n"
container_end = "\n# Helper: resolve compose dir for a given host target"
compose_start = "\n_oc-compose-dir host:\n"
compose_end = "\n# Rebuild container from scratch"

if (
    justfile.count(start_marker) != 1
    or justfile.count(end_marker) != 1
    or justfile.count(container_start) != 1
    or justfile.count(container_end) != 1
    or justfile.count(compose_start) != 1
    or justfile.count(compose_end) != 1
):
    raise SystemExit("cannot uniquely locate the OpenClaw routing helpers")

route = justfile.split(start_marker, 1)[1].split(end_marker, 1)[0]
container = justfile.split(container_start, 1)[1].split(container_end, 1)[0]
compose = justfile.split(compose_start, 1)[1].split(compose_end, 1)[0]

dead_magicdns = sorted(set(re.findall(r"[A-Za-z0-9.-]+\.ts\.barta\.cm", justfile)))
if dead_magicdns:
    raise SystemExit(
        "justfile still contains dead MagicDNS routes: " + ", ".join(dead_magicdns)
    )

hsb0_fallback = re.compile(
    r"if ping -c1 -W3 hsb0\.lan &>/dev/null; then\s+"
    r'ssh mba@hsb0\.lan "\{\{ cmd \}\}"\s+'
    r"else\s+"
    r'ssh mba@100\.64\.0\.6 "\{\{ cmd \}\}"\s+'
    r"fi"
)
if len(hsb0_fallback.findall(route)) != 1:
    raise SystemExit(
        "hsb0 routing must use hsb0.lan first and tailnet IP 100.64.0.6 exactly once"
    )

retired_markers = [
    marker
    for marker in ("msbp", "miniserver-bp", "10.17.1.40", "openclaw-percaival", "percy-")
    if marker in justfile.lower()
]
if retired_markers:
    raise SystemExit(
        "OpenClaw recipes still expose retired miniserver-bp routing: "
        + ", ".join(retired_markers)
    )

if "Error: unknown host '${_target}'. Use: hsb0" not in route:
    raise SystemExit("unknown _oc-run targets do not fail closed with the supported host")

for helper_name, helper in (("_oc-container", container), ("_oc-compose-dir", compose)):
    if "Error: unsupported local host (${_hostname}) — specify host: hsb0" not in helper:
        raise SystemExit(f"{helper_name} does not reject unsupported local hosts")
    if "Error: unknown host '${_target}'. Use: hsb0" not in helper:
        raise SystemExit(f"{helper_name} does not reject unknown explicit hosts")

if "just percy-" in ocbots or "just oc-rebuild` or `just percy-rebuild" in ocbots:
    raise SystemExit("the live /ocbots operator guide still advertises retired Percy recipes")

if "oc-workspace-percy" in modelupdate or "both OpenClaw configs" in modelupdate:
    raise SystemExit("the live /oc-modelupdate guide still targets the retired Percy workspace")

if "../../miniserver-bp/docs/OPENCLAW-RUNBOOK.md" in runbook:
    raise SystemExit("the hsb0 runbook still links the retired miniserver-bp runbook")

workflow = runbook.split("\n## Workspace Git Workflow", 1)[1].split(
    "\n## FleetCom Observability", 1
)[0]
if "Percy" in workflow or "oc-workspace-percy" in workflow:
    raise SystemExit("the active hsb0 workspace workflow still advertises retired Percy state")

if "percy-workspace" in workspace or "oc-workspace-percy" in workspace:
    raise SystemExit("the editor workspace still opens the retired Percy repository")

print("justfile_ssh_fallbacks=passed hsb0_tailnet_ip=100.64.0.6 retired_msbp_route=absent")
PY
