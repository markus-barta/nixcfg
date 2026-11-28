#!/usr/bin/env python3
"""Execute the rendered guest helpers in an unprivileged filesystem fixture.

Systemd, user switching and device discovery are mocked here; the real unit,
KVM sandbox and nftables rules also require the documented live guest proof.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


root, work, module_file = map(Path, sys.argv[1:])
provision = json.loads(module_file.read_text())["colima"]["provision"][0]["script"]
control = (root / "hosts/mbp2607/files/ci-vm/control.sh").read_text()
register = (root / "hosts/mbp2607/files/ci-vm/register.sh").read_text()
bash = shutil.which("bash")
fixture_count = 0


def write(path, text, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(mode)


def fixture():
    global fixture_count
    fixture_count += 1
    base = work / f"guest-{fixture_count}"
    base.mkdir()
    bindir = base / "bin"
    bindir.mkdir()
    write(base / "etc/ci-vm-repositories.json", '[{"id":"hausnetz"}]')
    write(base / "var/lib/ci-vm/ready", "fixture-boot\n")
    write(base / "proc/sys/kernel/random/boot_id", "fixture-boot\n")
    write(base / "proc/sys/kernel/apparmor_restrict_unprivileged_userns", "0\n")
    (base / "var/lib/ci-runners/hausnetz").mkdir(parents=True)
    (base / "run").mkdir()
    stub = f"#!{sys.executable}\n" + r'''
import os, pathlib, subprocess, sys
base = pathlib.Path(os.environ["GUEST_FIXTURE"])
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (base / "calls").open("a") as stream:
    # No token/environment data is logged by any stub.
    stream.write(command + " " + " ".join(args) + "\n")
if command == "systemctl":
    if args[0] == "is-active":
        name = "FIREWALL_ACTIVE" if "ci-vm-firewall.service" in args else "RUNNER_ACTIVE"
        sys.exit(0 if os.environ.get(name, "1") == "1" else 3)
    if args[0] == "show":
        assert args[1] in {"ssh.service", "lima-guestagent.service"}
        assert args[2:] == ["--property=MainPID", "--value"]
        print(os.environ.get("CONTROL_MAINPID", "2345" if args[1] == "ssh.service" else "2346"))
    if args[0] == "freeze":
        (base / "frozen").write_text("yes")
        if os.environ.get("RACE_WORKER") == "1": (base / "worker").touch()
    if args[0] == "thaw": (base / "frozen").write_text("")
    if args[0] == "stop":
        if os.environ.get("RUNNER_ACTIVE", "1") == "1":
            assert (base / "frozen").read_text() == "yes", "listeners were not frozen before stop"
elif command == "id":
    assert args == ["-u", "ci-hausnetz"]
    print("1234")
elif command == "pgrep":
    assert args[:2] == ["-u", "1234"] and "Runner[.]Worker" in args[-1]
    sys.exit(0 if (base / "worker").exists() else int(os.environ.get("WORKER_RC", "1")))
elif command == "journalctl":
    raise AssertionError("readiness must use service state and host inventory, not immediate journal timing")
elif command == "stat":
    assert args[:2] == ["-c", "%a"]
    print(oct(pathlib.Path(args[-1]).stat().st_mode & 0o777)[2:])
elif command == "runuser":
    if args[-3:-1] == ["test", "-r"]:
        sys.exit(0 if os.environ.get("TOKEN_READABLE") == "1" else 1)
    assert args == ["--preserve-environment", "-u", "ci-hausnetz", "--", "./config.sh"]
    assert os.environ["ACTIONS_RUNNER_INPUT_TOKEN"] == "fixture-registration-value"
    assert os.environ["ACTIONS_RUNNER_INPUT_NAME"] == "mbp2607-hausnetz"
    sys.exit(subprocess.call([os.environ["FIXTURE_BASH"], "./config.sh"]))
elif command == "tar":
    (base / "extracted").touch()
elif command == "dpkg":
    assert args == ["--configure", "-a"]
    if os.environ.get("DPKG_FAIL") == "1": sys.exit(1)
    (base / "dpkg-configured").touch()
elif command == "apt-get":
    if "install" in args:
        assert (base / "dpkg-configured").exists(), "interrupted dpkg was not repaired before install"
elif command == "getent":
    assert args == ["ahostsv4", "ports.ubuntu.com"]
elif command == "sysctl":
    key = "kernel.apparmor_restrict_unprivileged_userns"
    value = base / "proc/sys/kernel/apparmor_restrict_unprivileged_userns"
    if args == ["--system"]:
        if os.environ.get("USERNS_APPLY_FAIL") == "1": sys.exit(1)
        config = base / "etc/sysctl.d/99-ci-vm-userns.conf"
        if config.exists() and os.environ.get("USERNS_APPLY_IGNORED") != "1":
            setting, configured = config.read_text().strip().split("=")
            assert setting.strip() == key
            value.write_text(configured.strip() + "\n")
    else:
        assert args == ["-n", key]
        print(value.read_text().strip())
elif command not in {"modprobe", "groupadd", "chgrp"}:
    raise AssertionError(command)
'''
    for name in ["systemctl", "id", "pgrep", "journalctl", "stat", "runuser", "tar", "modprobe", "groupadd", "chgrp", "dpkg", "apt-get", "getent", "sysctl"]:
        write(bindir / name, stub, 0o755)
    return base


def adapt(source, base):
    for prefix in ["/etc/ci-vm", "/etc/systemd/system", "/etc/sysctl.d", "/var/lib/ci-runners", "/var/lib/ci-vm", "/proc/", "/run/ci-vm-host-qos-ready", "/etc/udev", "/dev/kvm", "/nix/"]:
        source = source.replace(prefix, str(base) + prefix)
    return source.replace("/usr/sbin/runuser", str(base / "bin/runuser"))


def run(source, base, *args, **settings):
    script = base / "script.sh"
    write(script, adapt(source, base))
    environ = dict(os.environ, PATH=str(base / "bin") + os.pathsep + os.environ["PATH"],
                   GUEST_FIXTURE=str(base), FIXTURE_BASH=bash)
    environ.update(settings)
    return subprocess.run([bash, str(script), *args], env=environ, text=True, capture_output=True, timeout=10)


# A condition-skipped systemctl start returns success: readiness must still fail.
base = fixture()
assert run(control, base, "ready", "--provision-only").returncode == 0
assert not (base / "run/ci-vm-host-qos-ready").exists(), "inspection opened the activation gate"
write(base / "proc/sys/kernel/apparmor_restrict_unprivileged_userns", "1\n")
for args in [("ready",), ("ready", "--provision-only")]:
    assert run(control, base, *args).returncode != 0, "restricted user namespaces were called ready"
assert not (base / "run/ci-vm-host-qos-ready").exists(), "failed userns readiness opened the activation gate"
assert "systemctl start" not in (base / "calls").read_text(), "failed userns readiness started a runner"
write(base / "proc/sys/kernel/apparmor_restrict_unprivileged_userns", "0\n")
assert run(control, base, "ready", RUNNER_ACTIVE="0").returncode != 0, "skipped unit was called ready"
assert run(control, base, "ready", FIREWALL_ACTIVE="0").returncode != 0, "failed firewall was called ready"
assert run(control, base, "ready").returncode == 0
write(base / "var/lib/ci-runners/hausnetz/.runner", "{}")
assert run(control, base, "ready", OLD_STALE_RUNNER="1").returncode == 0, "old invocation rejected a fresh enrollment"
assert "journalctl" not in (base / "calls").read_text()
assert run(control, base, "enrolled").stdout == "CI_VM_STATUS=enrolled:hausnetz\n"
print("ok guest readiness: skipped/failed units rejected; host inventory owns stale-registration detection without journal timing")

userns = provision[provision.index("# Chromium/Playwright"):provision.index("\nprintf 'ci-vm provisioning complete")]


def userns_case(source, **settings):
    base = fixture()
    write(base / "var/lib/ci-vm/ready", "")
    write(base / "proc/sys/kernel/apparmor_restrict_unprivileged_userns", "1\n")
    result = run("set -euo pipefail\n" + source, base, **settings)
    return result, base


result, base = userns_case(userns)
assert result.returncode == 0, result.stderr
assert (base / "etc/sysctl.d/99-ci-vm-userns.conf").read_text() == "kernel.apparmor_restrict_unprivileged_userns = 0\n"
assert (base / "proc/sys/kernel/apparmor_restrict_unprivileged_userns").read_text() == "0\n"
assert (base / "var/lib/ci-vm/ready").read_text() == "fixture-boot\n"
# A subsequent boot must repair both stale persistent policy and runtime state.
write(base / "etc/sysctl.d/99-ci-vm-userns.conf", "kernel.apparmor_restrict_unprivileged_userns = 1\n")
write(base / "proc/sys/kernel/apparmor_restrict_unprivileged_userns", "1\n")
assert run("set -euo pipefail\n" + userns, base).returncode == 0
assert (base / "etc/sysctl.d/99-ci-vm-userns.conf").read_text() == "kernel.apparmor_restrict_unprivileged_userns = 0\n"
assert (base / "proc/sys/kernel/apparmor_restrict_unprivileged_userns").read_text() == "0\n"
missing_dropin = re.sub(r"cat >/etc/sysctl.d/99-ci-vm-userns.conf <<'USERNS_SYSCTL'\n.*?\nUSERNS_SYSCTL\n", "", userns, flags=re.S)
restricted_dropin = userns.replace("kernel.apparmor_restrict_unprivileged_userns = 0", "kernel.apparmor_restrict_unprivileged_userns = 1")
missing_apply = userns.replace("sysctl --system", ":")
for mutant in [missing_dropin, restricted_dropin, missing_apply]:
    assert mutant != userns
    result, base = userns_case(mutant)
    assert result.returncode != 0, "missing/restricted/unapplied userns drop-in mutant survived"
    assert not (base / "var/lib/ci-vm/ready").read_text(), "failed userns provision wrote a ready marker"
for settings in [{"USERNS_APPLY_FAIL": "1"}, {"USERNS_APPLY_IGNORED": "1"}]:
    result, base = userns_case(userns, **settings)
    assert result.returncode != 0 and not (base / "var/lib/ci-vm/ready").read_text(), "ineffective sysctl apply was called ready"
print("ok guest userns: persistent and idempotent policy, immediate apply, fail-closed boot/readiness; missing/restricted/unapplied drop-in mutants killed")

for settings, expected in [({}, "drained"), ({"WORKER_RC": "0"}, "worker-busy"), ({"RACE_WORKER": "1"}, "worker-busy"), ({"WORKER_RC": "2"}, "unknown")]:
    base = fixture()
    result = run(control, base, "drain", **settings)
    assert result.returncode == 0 and result.stdout == f"CI_VM_STATUS={expected}\n", result.stderr
    calls = (base / "calls").read_text()
    assert calls.index("systemctl freeze") < calls.index("pgrep"), "final worker check raced the listener"
    assert ("systemctl stop" in calls) == (expected == "drained"), "drain stopped a busy/unknown runner"
    assert (base / "frozen").read_text() == "", "drain left a listener frozen"
print("ok guest drain: freeze before worker check; busy, newly assigned and unknown work is retained/thawed")

for worker_rc, expected in [("0", "worker-busy"), ("1", "no-worker"), ("2", "unknown"), ("255", "unknown")]:
    base = fixture()
    result = run(control, base, "worker-active", WORKER_RC=worker_rc)
    assert result.returncode == 0 and result.stdout == f"CI_VM_STATUS={expected}\n", result.stderr
base = fixture()
assert run(control, base, "enrolled").stdout == "CI_VM_STATUS=enrolled:\n"
write(base / "etc/ci-vm-repositories.json", "malformed fixture")
for action in ["worker-active", "enrolled", "drain"]:
    result = run(control, base, action)
    assert result.returncode == 0 and result.stdout == "CI_VM_STATUS=unknown\n", (action, result.stderr)
print("ok guest protocol: busy/absent/unknown workers, empty enrollment and malformed inventory emit a single zero-exit status record")

protection = provision.split("# Protect the control path", 1)[1].split("systemctl enable --now nix-daemon.socket", 1)[0]
base = fixture()
for pid in [2345, 2346]:
    write(base / f"proc/{pid}/oom_score_adj", "0\n")
result = run("set -euo pipefail\n# Protect the control path" + protection, base)
assert result.returncode == 0, result.stderr
for unit, pid in [("ssh.service", 2345), ("lima-guestagent.service", 2346)]:
    assert (base / f"etc/systemd/system/{unit}.d/ci-vm.conf").read_text() == "[Service]\nOOMScoreAdjust=-900\n"
    assert (base / f"proc/{pid}/oom_score_adj").read_text() == "-900\n"
assert "systemctl restart" not in (base / "calls").read_text(), "control protection restarted its own transport"
assert run("set -euo pipefail\n# Protect the control path" + protection, base, CONTROL_MAINPID="0").returncode != 0
print("ok guest OOM: persistent sshd/guest-agent protection applied to running main processes without restart; missing PID refuses readiness")

unit_template = re.search(r'cat >"/etc/systemd/system/ci-runner-\$id.service" <<UNIT\n(.*?)\nUNIT', provision, re.S)[1]


def start_path_contract(template):
    base = fixture()
    directory = base / "var/lib/ci-runners/hausnetz"
    write(directory / "bin/runsvc.sh", f"#!/bin/sh\nprintf reached >'{base}/reached'\n", 0o755)
    unit = template.replace("$dir", str(directory)).replace("$user", "ci-hausnetz").replace("$id", "hausnetz")
    executable = re.search(r'^ExecStart=(.*)$', unit, re.M)[1]
    try:
        result = subprocess.run([executable], cwd=directory, capture_output=True, timeout=5)
    except FileNotFoundError:
        return False
    return result.returncode == 0 and (base / "reached").exists()


assert start_path_contract(unit_template), "unit does not execute the shipped bin/runsvc.sh path"
assert not start_path_contract(unit_template.replace("ExecStart=$dir/bin/runsvc.sh", "ExecStart=$dir/runsvc.sh")), "start-path mutant survived"
print("ok guest start: rendered ExecStart executes; root-runsvc path mutant killed")

kvm = provision.split("modprobe kvm\n", 1)[1].split("\ncat >/etc/ci-vm-repositories.json", 1)[0]


def kvm_contract(source):
    base = fixture()
    write(base / "dev/kvm", "fixture device", 0o660)
    (base / "etc/udev/rules.d").mkdir(parents=True)
    # Device availability is checked live. Here execute the actual chmod/udev
    # writes against a regular file, without changing any workstation device.
    result = run("set -e\n" + source.replace("test -c /dev/kvm", "test -f /dev/kvm"), base)
    assert result.returncode == 0, result.stderr
    return (base / "dev/kvm").stat().st_mode & 0o006 == 0o006


assert kvm_contract(kvm), "independent nixbld UIDs cannot read/write KVM"
assert not kvm_contract(kvm.replace("0666", "0660")), "nixbld KVM mutant survived"
print("ok guest KVM: execute device permissions and udev rule; supplementary-group-only mutant killed")

parent_guard = provision.split(": >/var/lib/ci-vm/ready\n", 1)[1].split("\n# Ubuntu repositories", 1)[0]


def private_parent_contract(source):
    base = fixture()
    # The fixture is unprivileged; root ownership is verified in the live guest.
    result = run("set -e\n" + source.replace("-o root -g root ", ""), base)
    assert result.returncode == 0, result.stderr
    return (base / "etc/ci-vm-private").stat().st_mode & 0o777 == 0o700


assert private_parent_contract(parent_guard), "guest mount parent permits job-user traversal"
assert not private_parent_contract(parent_guard.replace("0700", "0755")), "public mount-parent mutant survived"
print("ok guest mount: execute private parent permissions; public-parent mutant killed")


def registration_case(source, readable=False):
    base = fixture()
    write(base / "etc/ci-vm-repositories.json", json.dumps([{
        "id": "hausnetz", "repository": "inspr-at/hausnetz", "runnerName": "mbp2607-hausnetz", "labels": ["kvm"]}]))
    write(base / "etc/ci-vm-private/secrets/hausnetz.token", "fixture-registration-value\n", 0o600)
    write(base / "var/lib/ci-runners/hausnetz/config.sh", "#!/bin/bash\nset -eu\n[ \"$ACTIONS_RUNNER_INPUT_URL\" = https://github.com/inspr-at/hausnetz ]\n[ \"$ACTIONS_RUNNER_INPUT_DISABLEUPDATE\" = true ]\nprintf '{}' >.runner\n")
    result = run(source, base, "hausnetz", TOKEN_READABLE="1" if readable else "0")
    return result, base


result, base = registration_case(register)
assert result.returncode == 0, result.stderr
assert (base / "var/lib/ci-runners/hausnetz/.runner").exists()
(base / "etc/ci-vm-private/secrets/hausnetz.token").rename(base / "retired-token")
assert run(register, base, "hausnetz").returncode == 0, "configured runner reread a retired token"
result, base = registration_case(register, readable=True)
assert result.returncode != 0 and not (base / "var/lib/ci-runners/hausnetz/.runner").exists(), "readable token reached config.sh"
mutant = register.replace('if /usr/sbin/runuser -u "ci-$id" -- test -r "$secret"; then', 'if false; then')
assert mutant != register
result, _ = registration_case(mutant, readable=True)
assert result.returncode == 0, "token-isolation mutant did not exercise enrollment"
print("ok guest token lifecycle: negative user read, environment-only config, persistent enrollment; readable-token mutant killed")

result, base = registration_case(register)
assert result.returncode == 0
directory = base / "var/lib/ci-runners/hausnetz"
(base / "etc/ci-vm-private/secrets/hausnetz.token").rename(base / "consumed-token")
for name in [".credentials", ".credentials_rsaparams", "_work/keep"]:
    write(directory / name, "nonsecret fixture\n")
for settings, expected in [({"WORKER_RC": "0"}, 3), ({"WORKER_RC": "2"}, 2)]:
    result = run(control, base, "reset-enrollment", "hausnetz", **settings)
    assert result.returncode == expected and (directory / ".runner").exists(), "reset interrupted active/unknown work"
result = run(control, base, "reset-enrollment", "unknown")
assert result.returncode != 0 and (directory / ".runner").exists(), "reset accepted an unconfigured repository"
(directory / ".credentials-unexpected").mkdir()
result = run(control, base, "reset-enrollment", "hausnetz")
assert result.returncode != 0 and (directory / ".runner").exists(), "reset accepted a non-file enrollment path"
(directory / ".credentials-unexpected").rename(base / "unexpected-directory")
result = run(control, base, "reset-enrollment", "hausnetz", RUNNER_ACTIVE="0")
assert result.returncode == 0, result.stderr
assert not any((directory / name).exists() for name in [".runner", ".credentials", ".credentials_rsaparams"])
assert (directory / "_work/keep").exists(), "reset touched the workspace"
backup, = (base / "var/lib/ci-vm").glob("retired-enrollment.*")
assert backup.stat().st_mode & 0o777 == 0o700
assert {path.name for path in backup.iterdir()} == {".runner", ".credentials", ".credentials_rsaparams"}
# A fresh one-shot token now reaches config.sh rather than being skipped.
write(base / "etc/ci-vm-private/secrets/hausnetz.token", "fixture-registration-value\n", 0o600)
assert run(register, base, "hausnetz").returncode == 0
assert (directory / ".runner").exists(), "reset prevented re-enrollment"
assert run(control, base, "ready", OLD_STALE_RUNNER="1").returncode == 0, "re-enrollment lost a cycle to old journal diagnostics"
print("ok guest re-enrollment: refuses active/unknown work, privately retires only registration files, and accepts a fresh enrollment immediately")

dependencies = provision[provision.index('if [ ! -f "$cache/ubuntu-dependencies-v2" ]; then'):provision.index("\ndownload_verified()")]


def dependencies_contract(source, **settings):
    base = fixture()
    cache = base / "cache"
    cache.mkdir()
    result = run(f'set -euo pipefail\ncache="{cache}"\n' + source, base, **settings)
    return result, base


result, base = dependencies_contract(dependencies)
assert result.returncode == 0 and (base / "cache/ubuntu-dependencies-v2").exists(), result.stderr
calls = (base / "calls").read_text()
assert calls.index("dpkg --configure -a") < calls.index(" install ")
assert " git jq sudo " in calls, "required guest tools missing"
mutant = dependencies.replace("timeout 300 dpkg --configure -a", ":")
assert mutant != dependencies and dependencies_contract(mutant)[0].returncode != 0, "interrupted-dpkg mutant survived"
result, base = dependencies_contract(dependencies, DPKG_FAIL="1")
assert result.returncode != 0 and not (base / "cache/ubuntu-dependencies-v2").exists()
assert " install " not in (base / "calls").read_text(), "failed dpkg repair reached install"
print("ok guest apt: repairs interrupted dpkg before install, aborts on repair failure; omitted-repair mutant killed")

# Execute the real verification/extraction sequence with a corrupt cached Nix
# archive. A hash failure must prevent tar and the installer from running.
prefix = provision.split("download_verified() {", 1)[1].split("cat >/etc/nix/nix.conf", 1)[0]
prefix = "download_verified() {" + prefix


def extraction_contract(source):
    base = fixture()
    cache = base / "cache"
    cache.mkdir()
    write(cache / "nix-2.31.2-aarch64-linux.tar.xz", "corrupt fixture archive")
    result = run(f'set -euo pipefail\ncache="{cache}"\n' + source, base)
    return result.returncode != 0 and not (base / "extracted").exists()


assert extraction_contract(prefix), "unverified archive reached tar"
mutant = prefix.replace('  printf \'%s  %s\\n\' "$digest" "$path" | sha256sum --check --status', "  : # deliberately skip cached verification")
assert mutant != prefix and not extraction_contract(mutant), "verify-after-extract mutant survived"
print("ok guest archive: corrupt cache never reaches extraction; missing-verification mutant killed")

# A known-good cached payload also exercises the complete hash-check function.
base = fixture()
payload = base / "payload"
payload.write_bytes(b"fixture verified bytes\n")
function = prefix.split("\nnix_version=", 1)[0]
digest = hashlib.sha256(payload.read_bytes()).hexdigest()
assert run(f'set -e\n{function}\ndownload_verified https://invalid.local "{payload}" {digest}\n', base).returncode == 0
print("ci-vm guest execution test: PASS")
