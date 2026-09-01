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

python3 - "$JUSTFILE" "$OCBOTS" <<'PY'
import pathlib
import re
import sys

justfile_path = pathlib.Path(sys.argv[1])
ocbots_path = pathlib.Path(sys.argv[2])
justfile = justfile_path.read_text(encoding="utf-8")
ocbots = ocbots_path.read_text(encoding="utf-8")

start_marker = "\n_oc-run host cmd:\n"
end_marker = "\n# Helper: resolve container name for a given host target"
surface_start = "\n# OpenClaw — Unified host-aware commands"
surface_end = "\n# Get the reverse dependencies of a nix store path"

if (
    justfile.count(start_marker) != 1
    or justfile.count(end_marker) != 1
    or justfile.count(surface_start) != 1
    or justfile.count(surface_end) != 1
):
    raise SystemExit("cannot uniquely locate the _oc-run routing helper")

route = justfile.split(start_marker, 1)[1].split(end_marker, 1)[0]
surface = justfile.split(surface_start, 1)[1].split(surface_end, 1)[0]

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
    if marker in surface.lower()
]
if retired_markers:
    raise SystemExit(
        "OpenClaw recipes still expose retired miniserver-bp routing: "
        + ", ".join(retired_markers)
    )

if "Error: unknown host '${_target}'. Use: hsb0" not in route:
    raise SystemExit("unknown _oc-run targets do not fail closed with the supported host")

if "just percy-" in ocbots or "just oc-rebuild` or `just percy-rebuild" in ocbots:
    raise SystemExit("the live /ocbots operator guide still advertises retired Percy recipes")

print("justfile_ssh_fallbacks=passed hsb0_tailnet_ip=100.64.0.6 retired_msbp_route=absent")
PY
