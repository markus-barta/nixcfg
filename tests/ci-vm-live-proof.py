#!/usr/bin/env python3
"""Explicit, token-free OPS-669 guest proof; always stops only the ci profile.

Usage: python3 tests/ci-vm-live-proof.py /nix/store/...-ci-vm/bin/ci-vm EVIDENCE_DIR
EVIDENCE_DIR must be below /Users/markus/.local/share/ops-qa.
Never runs Home Manager activation, registration, token minting, or a browser.
"""

import json
import os
from pathlib import Path
import re
import shlex
import socketserver
import subprocess
import sys
import threading
import uuid


EVIDENCE_ROOT = "/Users/markus/.local/share/ops-qa"


def installed_command(value):
    # Select only installed ci-vm outputs from the immutable store. argv is a
    # lookup key; subprocess receives the allowlist value from this fixed root.
    with os.scandir("/nix/store") as entries:
        commands = {
            entry.path + "/bin/ci-vm": entry.path + "/bin/ci-vm"
            for entry in entries
            if re.fullmatch(r"[0-9a-df-np-sv-z]{32}-ci-vm", entry.name)
            and entry.is_dir(follow_symlinks=False)
        }
    try:
        return commands[os.path.realpath(value)]
    except KeyError:
        raise ValueError("expected an installed /nix/store/...-ci-vm/bin/ci-vm") from None


def evidence_path(value):
    path = os.path.realpath(value)
    if not path.startswith(EVIDENCE_ROOT + os.sep):
        raise ValueError("evidence must stay below " + EVIDENCE_ROOT)
    return Path(path)


command = installed_command(sys.argv[1])
evidence = evidence_path(sys.argv[2])
home = Path.home()
legacy = home / ".colima"
secrets = home / ".local/state/ci-vm/secrets"
assert not legacy.exists() and not legacy.is_symlink(), "legacy Colima home exists"
assert not (secrets / "hausnetz.token").exists(), "registration token unexpectedly present"
environ = dict(os.environ, COLIMA_HOME=str(home / ".config/colima"), LIMA_HOME=str(home / ".config/colima/_lima"))
evidence.mkdir(parents=True, exist_ok=True)


def metadata():
    result = {}
    colima = Path(environ["COLIMA_HOME"])
    for name in ("default", "funk", "hnetcap", "hnetprobe"):
        for directory in (colima / name, colima / "_lima" / ("colima-" + name)):
            for path in (directory, directory / "colima.yaml", directory / "lima.yaml", directory / "disk", directory / "diffdisk"):
                try:
                    st = path.lstat()
                    result[str(path)] = [st.st_mode, st.st_size, st.st_mtime_ns, st.st_ctime_ns]
                except FileNotFoundError:
                    result[str(path)] = None
    return result


class LocalhostProof(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.recv(1024)
        self.request.sendall(b"OPS-669-localhost-proof\n")


probe = secrets / ".ci-read-probe-r3"
assert not probe.exists() and not probe.is_symlink()
before = metadata()
evidence_path(str(evidence / "profiles-before-r3.json")).write_text(json.dumps(before, indent=2) + "\n")
nix_expression = (Path(__file__).parent / "ci-vm-kvm-proof.nix").read_text()

with evidence_path(str(evidence / "live-proof-r3.log")).open("w") as log:
    def checked(args, **kwargs):
        return subprocess.run(args, env=environ, stdout=log, stderr=subprocess.STDOUT,
                              check=True, timeout=kwargs.pop("timeout", 180), **kwargs)

    try:
        checked([str(command), "start", "--provision-only"], timeout=1000)
        secrets.mkdir(parents=True, exist_ok=True)
        with probe.open("x") as stream:
            probe.chmod(0o600)
            stream.write("nonsecret permission proof\n")
        with socketserver.TCPServer(("127.0.0.1", 0), LocalhostProof) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            port = server.server_address[1]
            network_probe = r'''
import os, socket, sys
port, expected = int(sys.argv[1]), sys.argv[2]
assert {entry[4][0] for entry in socket.getaddrinfo("host.lima.internal", port, socket.AF_INET)} == {"192.168.5.2"}
try:
    with socket.create_connection(("192.168.5.2", port), timeout=3) as stream:
        stream.sendall(b"probe\n")
        assert stream.recv(128) == b"OPS-669-localhost-proof\n"
    reached = True
except OSError:
    reached = False
assert reached == (expected == "allowed"), "localhost isolation/positive control failed"
print(f"uid={os.geteuid()} Mac localhost={expected}", flush=True)
assert socket.getaddrinfo("cache.nixos.org", 443, socket.AF_INET), "guest DNS is blocked"
print(f"uid={os.geteuid()} DNS=working via configured guest resolver", flush=True)
'''
            script = r'''
set -euo pipefail
test ! -e /var/lib/ci-runners/hausnetz/.runner
test ! -e /etc/ci-vm-private/secrets/hausnetz.token
test ! -e /run/ci-vm-host-qos-ready
printf 'No registration, token or runner activation gate exists\n'
tar -tzf /var/cache/ci-vm/actions-runner-linux-arm64-2.338.2.tar.gz | grep -E '(^|/)runsvc.sh$'
test -x /var/lib/ci-runners/hausnetz/bin/runsvc.sh
runuser -u ci-hausnetz -- test -x /var/lib/ci-runners/hausnetz/bin/runsvc.sh
systemd-analyze verify /etc/systemd/system/ci-runner-hausnetz.service /etc/systemd/system/ci-vm-firewall.service /etc/systemd/system/nix-daemon.service
printf 'Shipped executable and systemd-analyze verify: PASS\n'
systemctl show ci-runner-hausnetz.service -p Type -p ExecStart -p User -p NoNewPrivileges -p ProtectSystem -p ProtectHome -p PrivateTmp -p RestrictSUIDSGID -p TasksMax -p MemoryMax
systemctl show nix-daemon.service -p MemoryMax -p TasksMax -p Nice -p CPUWeight -p IOWeight
systemd-analyze security --no-pager ci-runner-hausnetz.service nix-daemon.service
stat -c '/dev/kvm permissions=%a owner=%U:%G' /dev/kvm
bash_store=$(find /nix/store -maxdepth 1 -type d -name '*-bash-[0-9]*' -print -quit)
test -x "$bash_store/bin/bash"
'''
            # A distinct derivation name forces a fresh sandbox on every proof.
            proof_name = "ci-vm-nixbld-kvm-proof-" + uuid.uuid4().hex[:12]
            script += "\noutput=$(runuser -u ci-hausnetz -- /nix/var/nix/profiles/default/bin/nix-build --no-out-link --expr " + shlex.quote(nix_expression) + ' --argstr bashStore "$bash_store" --argstr proofName ' + shlex.quote(proof_name) + ')\n'
            script += r'''
cat "$output"
build_uid=$(sed -n 's/^host_uid=//p' "$output")
build_user=$(getent passwd "$build_uid" | cut -d: -f1)
case "$build_user" in nixbld[0-9]*) ;; *) exit 1 ;; esac
printf 'Sandboxed requiredSystemFeatures=kvm derivation: PASS (%s)\n' "$build_user"
test "$(stat -c %a /etc/ci-vm-private)" = 700
test "$(stat -c %U /etc/ci-vm-private)" = root
test "$(findmnt -rn -t virtiofs -o TARGET)" = /etc/ci-vm-private/secrets
test -r /etc/ci-vm-private/secrets/.ci-read-probe-r3
if runuser -u ci-hausnetz -- test -r /etc/ci-vm-private/secrets/.ci-read-probe-r3; then
  printf 'runner can read the mounted 0600 proof file\n' >&2
  exit 1
fi
printf 'Mounted 0600 negative read as ci-hausnetz: PASS\n'
runuser -u ci-hausnetz -- python3 -c 'import os,sys
try:
    fd=os.open(sys.argv[1],os.O_RDONLY)
except PermissionError:
    sys.exit(0)
os.close(fd)
sys.exit(1)' /etc/ci-vm-private/secrets/.ci-read-probe-r3
printf 'Mounted file negative open as ci-hausnetz: PASS\n'
'''
            for user, expected in [("root", "allowed"), ("ci-hausnetz", "blocked"), ("nixbld1", "blocked")]:
                script += "\nrunuser -u " + shlex.quote(user) + " -- python3 -c " + shlex.quote(network_probe) + " " + str(port) + " " + expected + "\n"
            script += r'''
nft list table inet ci_vm
systemctl is-active ci-vm-firewall.service
systemctl start ci-runner-hausnetz.service
if systemctl is-active --quiet ci-runner-hausnetz.service; then exit 1; fi
test ! -e /var/lib/ci-runners/hausnetz/.runner
test ! -e /etc/ci-vm-private/secrets/hausnetz.token
test ! -e /run/ci-vm-host-qos-ready
printf 'Unenrolled runner remains inactive; no registration performed\n'
'''
            try:
                checked(["colima", "--profile", "ci", "ssh", "--", "sudo", "bash", "-s"], input=script, text=True, timeout=300)
            finally:
                server.shutdown()
    finally:
        if probe.exists():
            subprocess.run(["/usr/bin/trash", str(probe)], check=True)
        # The packaged stop drains workers before addressing ONLY ci.
        checked([str(command), "stop"], timeout=200)
        stopped = subprocess.run(["colima", "status", "ci", "--json"], env=environ,
                                 capture_output=True, text=True, timeout=25)
        assert stopped.returncode != 0 and "not running" in stopped.stderr + stopped.stdout
        after = metadata()
        evidence_path(str(evidence / "profiles-after-r3.json")).write_text(json.dumps(after, indent=2) + "\n")
        assert before == after, "protected profile metadata changed during proof"
        assert not legacy.exists() and not legacy.is_symlink()
        assert not (secrets / "hausnetz.token").exists()
        log.write("ci stopped; legacy home absent; protected profile metadata unchanged\n")
print("ci-vm live guest proof: PASS; ci stopped")
