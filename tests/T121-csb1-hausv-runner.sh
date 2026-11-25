#!/usr/bin/env bash
# OPS-678: full-config evaluation and must-fail mutations; never build or deploy.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

python3 - <<'PY'
import json
import subprocess
import sys

command = [
    "nix", "eval", "--offline", "--no-update-lock-file", "--impure", "--json",
    ".#nixosConfigurations.csb1", "--apply",
]
gate = "import ./tests/csb1-hausv-runner-eval.nix"

def evaluate(projection):
    return subprocess.run(command + [projection], text=True, capture_output=True, timeout=300)

result = evaluate("system: " + gate + " { inherit (system) config lib; }")
if result.returncode:
    sys.stderr.write(result.stderr)
    raise SystemExit(result.returncode)
checks = json.loads(result.stdout)
failed = [name for name, passed in checks.items() if passed is not True]
if not checks or failed:
    raise SystemExit("OPS-678 preservation checks failed: " + repr(failed))
print("OPS-678 full csb1 evaluation: runner/unit absent; pull token preserved", flush=True)

# Even a disabled runner entry violates the retirement contract. Mutate the
# evaluated config in memory, without editing source files or touching a host.
mutations = [
    (
        "runner",
        "services = system.config.services // { github-runners = "
        "system.config.services.github-runners // { csb1-hausv.enable = false; }; };",
        "OPS-678: retired runner must be absent",
    ),
    (
        "unit",
        "systemd = system.config.systemd // { services = "
        "system.config.systemd.services // { github-runner-csb1-hausv = {}; }; };",
        "OPS-678: retired runner unit must be absent",
    ),
]
for name, mutation, expected in mutations:
    projection = (
        "system: " + gate + " { inherit (system) lib; "
        "config = system.config // { " + mutation + " }; }"
    )
    result = evaluate(projection)
    if result.returncode == 0 or expected not in result.stderr:
        sys.stderr.write(result.stderr)
        raise SystemExit("OPS-678 " + name + " mutant did not fail at the expected assertion")
    print("OPS-678 " + name + " mutant rejected at the expected assertion", flush=True)
PY
