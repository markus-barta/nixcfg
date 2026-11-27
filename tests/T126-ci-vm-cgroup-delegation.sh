#!/usr/bin/env bash
# OPS-719: the CI guest's nix-daemon must not delegate cpuset (it would enable
# cpuset in /system.slice, which hausnetz's nightly host sampler refuses), and
# Nix must not be configured to use cgroups (which would need delegation).
# Offline text check of the provisioning script, plus must-fail mutants.
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B - "$repo/hosts/mbp2607/files/ci-vm/provision.sh" <<'PY'
import re, sys

def heredoc(text, tag):
    m = re.search(r"<<'" + tag + r"'\n(.*?)\n" + tag + r"\n", text, re.S)
    if not m:
        raise AssertionError(f"heredoc {tag} not found")
    return m.group(1)

def check(text):
    unit = [l.strip() for l in heredoc(text, "DAEMON_UNIT").splitlines() if l.strip() and not l.strip().startswith("#")]
    delegate = [l for l in unit if l.startswith("Delegate=")]
    assert delegate, "nix-daemon drop-in must set Delegate"
    assert delegate[0] == "Delegate=", "the first Delegate= must be empty (reset the stock Delegate=yes)"
    final = set(delegate[-1].split("=", 1)[1].split())
    assert final == {"cpu", "io", "memory", "pids"}, f"final Delegate controllers {sorted(final)}"
    assert all("cpuset" not in l for l in delegate), "cpuset must not be delegated"
    assert all(l.split("=", 1)[1].strip().lower() not in ("yes", "true", "1") for l in delegate), "no blanket Delegate=yes"
    nixconf = heredoc(text, "NIX_CONFIG")
    assert not re.search(r"^\s*use-cgroups\s*=\s*true", nixconf, re.M), "use-cgroups needs delegation; revisit OPS-719"
    assert not re.search(r"^\s*(extra-)?experimental-features\s*=.*\bcgroups\b", nixconf, re.M), "cgroups feature needs delegation; revisit OPS-719"

text = open(sys.argv[1]).read()
check(text)
mutants = {
    "no reset": text.replace("Delegate=\nDelegate=cpu io memory pids\n", "Delegate=cpu io memory pids\n", 1),
    "cpuset delegated": text.replace("Delegate=cpu io memory pids", "Delegate=cpu cpuset io memory pids", 1),
    "blanket yes": text.replace("Delegate=\nDelegate=cpu io memory pids\n", "Delegate=yes\n", 1),
    "drop-in removed": text.replace("Delegate=\nDelegate=cpu io memory pids\n", "", 1),
    "use-cgroups on": text.replace("sandbox = true\n", "sandbox = true\nuse-cgroups = true\n", 1),
}
for name, mutant in mutants.items():
    assert mutant != text, f"mutant {name} did not apply"
    try:
        check(mutant)
    except AssertionError:
        continue
    raise SystemExit(f"FAIL: mutant '{name}' was not caught")
print(f"T126 CI guest cgroup delegation: OK ({len(mutants)} mutants caught)")
PY
