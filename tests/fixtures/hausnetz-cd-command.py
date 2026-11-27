#!/usr/bin/env python3
"""PATH fakes for T125; refuses any unrecognized operation (no network)."""

import hashlib
import io
import json
import os
import re
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import urllib.parse
import zipfile


# Value-free hsb0 r67 capture (2026-11-26); older fixture releases substitute
# only their version. The capability body below remains synthetic test data.
CAPTURED_READYZ = b'{"ok":true,"version":"261126165633.0.0","checks":{"instance":true,"engine":true,"site":true,"ui":true}}'
CAPTURED_META_SHA_PREFIX = "782631fc5c0bb9e9"


# Each fake is copied into its private fixture bin directory.
root = Path(__file__).resolve().parent.parent
config = json.loads((root / "fixture.json").read_text())
scenario = json.loads((root / "scenario.json").read_text())
command = Path(sys.argv[0]).name
args = sys.argv[1:]


def event(kind, **fields):
    with (root / "events").open("a") as output:
        output.write(json.dumps({"kind": kind, **fields}) + "\n")


def link(path, target):
    destinations = {str(root / name): root / name for name in (
        "current-system", "profile", "system-2-link", "system-3-link",
        "remote-state/old-system", "remote-state/new-system")}
    path = destinations[str(path)]
    resolved = os.path.realpath(target)
    if not resolved.startswith(str(root) + os.sep):
        raise ValueError("unsafe fixture target")
    if path.is_symlink():
        path.unlink()
    path.symlink_to(target)


def occurrence(name):
    path = root / ("count-" + name)
    count = int(path.read_text()) + 1 if path.exists() else 1
    path.write_text(str(count))
    return count


def active_new():
    return str(Path(config["current_system"]).resolve()) == config["new_system"]


if command == "sudo":
    assert args.pop(0) == "-n"
    if scenario.get("sudo_fail"):
        raise SystemExit(1)
    commands = {name: str(root / "bin" / name) for name in
                ("systemd-run", "systemctl", "readlink", "cat", "test", "tee", "chmod")}
    # Only fixed local fixture programs or system utilities are executable.
    commands.update({name: shutil.which(name) for name in ("cat", "test", "tee", "chmod", "install", "mktemp", "mv")})
    if args[:2] == ["mv", "-fT"]:
        args[1] = "-f"  # BSD fixture host; both paths are regular fixture files.
    os.execv(commands[args[0]], args)
elif command == "ssh":
    script = sys.stdin.read()
    call = shlex.split(args[-1])
    if call[:3] == ["PATH=$HOME/.local/bin:$PATH", "mbx", "send"]:
        call = call[1:]
        assert args[-2] == "agents@fixture-agents" and args[-4:-2] == ["-p", "2222"]
        assert args[:6] == ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o"]
        assert call[2] in {"mac-lead", "lead"}
        assert call[3:5] == ["-f", "mac-ops"] and call[-2:] == ["-m", "-"]
        ticket_args = call[5:-2]
        assert ticket_args == [] or (len(ticket_args) == 2 and ticket_args[0] == "-t")
        event("mailbox", recipient=call[2], ticket=ticket_args[1] if ticket_args else None, text=script)
        if scenario.get("mailbox_fail") == call[2]:
            raise SystemExit(1)
        raise SystemExit(0)
    assert call[:3] == ["bash", "-s", "--"], call
    assert args[-2] == "mba@hsb0.lan"
    action = call[3]
    event("ssh", action=action)
    if scenario.get("ssh_fail") == action:
        raise SystemExit(1)
    if action == "status":
        count = occurrence("status")
        if count <= scenario.get("ssh_status_failures", 0):
            raise SystemExit(1)
        if scenario.get("stale_status") and count == 1:
            mode = json.loads((root / "orchestrate.json").read_text())["mode"]
            print(json.dumps({"unit_state": "active", "result": {
                "schema": "inspr.pharos.guarded-deploy-result.v1", "nixcfg_rev": call[4],
                "hausnetz_rev": config["new_hnet"], "mode": mode, "run_id": "0" * 32,
                "status": "skipped", "phase": "lock", "completed_at": "stale"}}))
            raise SystemExit(0)
    script = script.replace("/var/lib/hausnetz-cd", config["state_dir"])
    script = script.replace("/etc/pharos-deployment/evidence.json", config["evidence_file"])
    script = script.replace("/nix/var/nix/profiles/system", config["system_profile"])
    script = script.replace("/run/current-system/sw/bin/hausnetz-cd-execute", config["executor"])
    result = subprocess.run(["bash", "-s", "--", *call[3:]], input=script.encode(), check=False)
    if action == "ack" and scenario.get("change_at_ack"):
        link(config["current_system"], config["new_system"])
    if action == "start" and scenario.get("drop_start_response"):
        raise SystemExit(1)
    raise SystemExit(result.returncode)
elif command == "systemd-run":
    position = args.index(config["executor"])
    event("start", args=args)
    if scenario.get("crash"):
        token = args[-1]
        if not re.fullmatch(r"[0-9a-f]{32}", token):
            raise ValueError("invalid fixture run ID")
        path = os.path.realpath(root / "remote-state/results" / (token + ".json"))
        if not path.startswith(str(root) + os.sep):
            raise ValueError("unsafe fixture result")
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({
            "schema": "inspr.pharos.guarded-deploy-result.v1", "nixcfg_rev": args[position + 1],
            "hausnetz_rev": args[position + 2], "mode": args[position + 3], "run_id": token,
            "status": "running", "phase": "build"}))
    else:
        with (root / "executor.log").open("ab") as output:
            process = subprocess.Popen([config["executor"], *args[position + 1:]], stdout=output, stderr=output, start_new_session=True)
        (root / "executor.pid").write_text(str(process.pid))
elif command == "systemctl":
    if args[0] == "--failed":
        event("failed-units")
        failed = scenario.get("failed_units", "")
        if scenario.get("failed_units_on_recheck") and occurrence("failed-units") > 1:
            failed = "broken.service loaded failed failed Broken unit"
        if scenario.get("failed_units_after_switch") and (active_new() or (root / "rolled-back").exists()):
            failed = "broken.service loaded failed failed Broken unit"
        print(failed)
        raise SystemExit(0)
    assert args[0] == "show"
    if "--property=MemoryPeak" in args:
        event("memory-peak", unit=args[1])
        print(scenario.get("memory_peak", "536870912"))
    elif args[1] == "hausnetz.service":
        if "--property=InvocationID" in args:
            print("b" * 32 if scenario.get("rehearsal_restart") and (root / "rolled-back").exists() else "a" * 32)
        else:
            assert "--property=MainPID" in args
            print("0" if scenario.get("pid_missing") and active_new() else "123")
    else:
        assert "--property=ActiveState" in args
        print(scenario.get("unit_state", "active" if (root / "executor.pid").exists() else "inactive"))
elif command == "readlink":
    if args[0] == "/proc/123/exe":
        if active_new() and scenario.get("exe_unreadable"):
            raise SystemExit(1)
        exe = config["new_exe"] if active_new() else config["old_exe"]
        if active_new() and scenario.get("exe_mismatch"):
            exe = config["old_exe"]
        if not active_new() and scenario.get("rollback_exe_mismatch") and (root / "rolled-back").exists():
            exe = config["new_exe"]
        print(exe)
    else:
        assert args == [config["system_profile"]]
        print(os.readlink(config["system_profile"]))
elif command == "nix":
    if args[0] == "run":
        assert args[1] == "--offline"
        assert args[2] == "--no-write-lock-file"
        checker = urllib.parse.urlsplit(args[3])
        repo = urllib.parse.unquote(checker.path)
        assert checker.scheme == "git+file" and checker.fragment == "cd-prepare"
        checker_rev = urllib.parse.parse_qs(checker.query)["rev"][0]
        event("prepare", args=args,
              checker_rev=subprocess.check_output(["git", "-C", repo, "rev-parse", "HEAD"], text=True).strip())
        assert args[4:6] == ["--", "--repo"] and args[6] == repo
        assert args[7] == "--rev" and args[9] == "--running"
        assert checker_rev == args[10]
        assert subprocess.check_output(["git", "-C", repo, "rev-parse", "--is-shallow-repository"], text=True).strip() == "false"
        if scenario.get("prepare_missing"):
            raise SystemExit(1)
        def manifest(rev):
            result = subprocess.run(["git", "-C", repo, "show", rev + ":capabilities.json"],
                                    capture_output=True, check=False)
            return result.stdout if result.returncode == 0 else b""
        before, after = manifest(args[10]), manifest(args[8])
        value = {"rev": args[8], "narHash": config["nar_hash"], "version": config["new_version"],
                 "persisted_ok": True, "manifest_changed": before != after,
                 "manifest_sha256": hashlib.sha256(after).hexdigest(),
                 "running_manifest_sha256": hashlib.sha256(before).hexdigest(),
                 "changed_paths": [], "changed_paths_total": 0, "checker_rev": checker_rev,
                 "problems": [] if before and after else ["manifest_missing"]}
        value.update(scenario.get("prepare", {}))
        for field in scenario.get("prepare_omit", []):
            value.pop(field)
        if scenario.get("prepare_json") is not None:
            print(scenario["prepare_json"])
        else:
            print(json.dumps(value))
            if scenario.get("prepare_extra_output"):
                print('{"extra":"object"}')
        raise SystemExit(scenario.get("prepare_exit", 0))
    event("nix", args=args)
    if args[0] == "build":
        if scenario.get("build_fail"):
            raise SystemExit(1)
        if "--out-link" in args:
            link(args[args.index("--out-link") + 1], config["new_system"])
        print(config["new_system"])
    elif args[:2] == ["store", "diff-closures"]:
        if scenario.get("closures") is not None:
            print(scenario["closures"])
        else:
            print("hausnetz: 261123075451.0.0 → 261126120508.0.0, 453.0 KiB")
            print("etc: +12.6 KiB")
            print("pharos-deployment-evidence: old → new")
            if scenario.get("extra_closure"):
                print("hsb0-hausnetz-ha-token.age: ∅ → ε")
    else:
        raise AssertionError(args)
elif command == "nix-store":
    assert args[:1] == ["--add-root"] and args[2:4] == ["--indirect", "--realise"]
    link(args[1], args[4])
    event("gc-root", path=args[1], target=args[4])
    print(args[4])
elif command == "nix-env":
    if args == ["--profile", config["system_profile"], "--list-generations"]:
        print("1 fixture generation" + ("\n2 changed" if scenario.get("rehearsal_generation") and (root / "rolled-back").exists() else ""))
        raise SystemExit(0)
    assert args[:2] == ["--profile", config["system_profile"]] and args[2] == "--set"
    target = args[3]
    generation = "system-2-link" if target == config["new_system"] else "system-3-link"
    link(root / generation, target)
    link(config["system_profile"], root / generation)
    event("profile", target=target)
elif command == "switch-to-configuration":
    target = str(Path(sys.argv[0]).parent.parent)
    if args == ["dry-activate"]:
        event("dry-activate", roots={name: str((Path(config["state_dir"]) / name).resolve())
                                    for name in ("old-system", "new-system")
                                    if (Path(config["state_dir"]) / name).is_symlink()})
        if scenario.get("activation") is not None:
            print(scenario["activation"])
        else:
            print("would stop the following units: hausnetz.service, polkit.service")
            print("would activate the configuration...")
            print("would reload the following units: dbus-broker.service")
            print("would start the following units: hausnetz.service, polkit.service")
        if scenario.get("rehearsal_rollback_units") and (root / "rolled-back").exists():
            print("would restart the following units: hausnetz.service")
        if scenario.get("extra_unit"):
            print("would restart the following units: sshd.service", file=sys.stderr)
        if scenario.get("change_during_g3"):
            link(config["current_system"], config["new_system"])
    elif args == ["switch"]:
        event("switch", target=target)
        if target == config["old_system"]:
            time.sleep(scenario.get("rollback_delay", 0))
        if target == config["old_system"] and scenario.get("rollback_fail"):
            raise SystemExit(1)
        link(config["current_system"], target)
        if target == config["old_system"]:
            (root / "rolled-back").touch()
            if scenario.get("rehearsal_boot_change"):
                (root / "boot/grub/grubenv").write_text("changed default")
            if "boot_after_switch" in scenario:
                (root / "boot/grub/grub.cfg").write_text(scenario["boot_after_switch"])
        rev = config["old_rev"] if target == config["old_system"] else config["new_rev"]
        if not scenario.get("stale_evidence"):
            Path(config["evidence_file"]).write_text(json.dumps({
                "schema": "inspr.pharos.nix-deployment-evidence.v1", "source_revision": rev}))
        if target == config["old_system"] and scenario.get("rollback_exit4"):
            raise SystemExit(4)  # activation completed, systemd reports failed units
        if target == config["new_system"] and scenario.get("partial_switch_fail"):
            raise SystemExit(1)
    else:
        raise AssertionError(args)
elif command == "curl":
    if any("fixture_token" in arg for arg in args):
        event("credential-in-argv")
        raise SystemExit(1)
    event("curl-argv", args=args)
    if "--config" in args:
        data = sys.stdin.read()
        encoded = data.split('data = "', 1)[1].split('"', 1)[0]
        event("telegram", text=urllib.parse.parse_qs(encoded)["text"][0])
        if scenario.get("telegram_fail"):
            raise SystemExit(1)
    else:
        url = args[-1]
        event("http", url=url)
        assert url.startswith("http://127.0.0.1:8377/"), url
        status = scenario.get("http_status", 200)
        if url.endswith("/api/export"):
            if scenario.get("bad_export"):
                sys.stdout.write("not a backup")
            elif scenario.get("zip_export"):
                buffer = io.BytesIO()
                with zipfile.ZipFile(buffer, "w") as archive:
                    archive.writestr("state.json", '{"devices":[]}')
                sys.stdout.buffer.write(buffer.getvalue())
            else:
                sys.stdout.write('{"devices":[]}')
        elif url.endswith("/api/meta"):
            if active_new() and scenario.get("bare_200"):
                print("{}")
            else:
                version = config["new_version"] if active_new() else config["old_version"]
                if active_new() and scenario.get("health_fail"):
                    version = config["old_version"]
                if not active_new() and scenario.get("rollback_health_fail") and (root / "rolled-back").exists():
                    version = config["new_version"]
                metadata = {"version": version, "capabilities_sha256": config["manifest_sha"]}
                if active_new():
                    if scenario.get("meta_manifest_missing"):
                        metadata.pop("capabilities_sha256")
                    if scenario.get("meta_manifest_mismatch"):
                        # Only the captured prefix is known; this suffix is
                        # deliberately synthetic and must not pass the proof.
                        metadata["capabilities_sha256"] = CAPTURED_META_SHA_PREFIX + "0" * 48
                elif scenario.get("rollback_manifest_mismatch") and (root / "rolled-back").exists():
                    metadata["capabilities_sha256"] = "0" * 64
                print(json.dumps(metadata))
        elif url.endswith("/api/host-capabilities"):
            body = b'{"connections":[],"secrets":[],"writes":[]}\n'
            if active_new() and scenario.get("capabilities_mismatch"):
                body += b" "
            if active_new() and scenario.get("capabilities_missing"):
                status = 404
            if not active_new() and scenario.get("rollback_capabilities_mismatch") and (root / "rolled-back").exists():
                body += b" "
            sys.stdout.buffer.write(body)
            sys.stdout.buffer.flush()
        elif url.endswith("/readyz"):
            if active_new() and scenario.get("readyz_missing"):
                status = 404
            if active_new() and scenario.get("readyz_503"):
                status = 503
            bad = (active_new() and scenario.get("readyz_false")) or (
                not active_new() and scenario.get("rollback_readyz_false") and (root / "rolled-back").exists())
            version = config["new_version"] if active_new() else config["old_version"]
            ready = json.loads(CAPTURED_READYZ)
            ready.update(ok=not bad, version=version)
            if active_new():
                ready.update(scenario.get("readyz", {}))
            print(json.dumps(ready))
        else:
            raise AssertionError(url)
        assert "--write-out" in args
        sys.stdout.flush()
        sys.stdout.write("\n" + str(status))
elif command == "paimos":
    assert args[:4] == ["--instance", "ppm", "issue", "comment"]
    assert args[5] == "--body"
    event("ticket", ticket=args[4], text=args[6])
    if scenario.get("ticket_fail"):
        raise SystemExit(1)
elif command == "mbx":
    assert args[:1] == ["send"] and args[1] in {"mac-lead", "lead"}
    assert args[2:4] == ["-f", "mac-ops"] and args[-2:] == ["-m", "-"]
    ticket_args = args[4:-2]
    assert ticket_args == [] or (len(ticket_args) == 2 and ticket_args[0] == "-t")
    event("local-mailbox", recipient=args[1], ticket=ticket_args[1] if ticket_args else None, text=sys.stdin.read())
    if scenario.get("local_mailbox_fail") == args[1]:
        raise SystemExit(1)
elif command in {"alarm", "secondary-telegram"}:
    assert args == []
    event(command, text=sys.stdin.read())
    if scenario.get("secondary_telegram_fail") and command == "secondary-telegram":
        raise SystemExit(1)
elif command == "bootctl":
    assert args == ["--json=short", "list"]
    print(json.dumps([{"id": "nixos-generation-1.conf", "isDefault": True}]))
elif command == "acceptance":
    event("acceptance", args=args)
    assert len(args) == 6 and args[1:3] == ["just", "acceptance"]
    assert args[0] == config["old_hnet"] and args[0] != config["new_hnet"]
    assert args[3:] == ["http://fixture.invalid", config["new_version"], config["manifest_sha"]]
    if scenario.get("acceptance_orphan"):
        subprocess.Popen([sys.executable, "-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(12)"])
        time.sleep(12)
    if scenario.get("acceptance_hang"):
        time.sleep(10)
    if scenario.get("acceptance_missing"):
        raise SystemExit(127)
    print(scenario.get("acceptance_output", '{"ok":true}'))
    raise SystemExit(scenario.get("acceptance_exit", 0))
elif command == "gh":
    event("vm-test", args=args)
    assert args == ["api", "--method", "GET",
                    "repos/inspr-at/hausnetz/actions/workflows/vm-test.yml/runs?head_sha="
                    + config["new_hnet"] + "&per_page=100"]
    if scenario.get("vm_test_error"):
        raise SystemExit(1)
    print(json.dumps(scenario.get("vm_test_response", {"workflow_runs": [
        {"id": 1, "head_sha": config["new_hnet"], "status": "completed", "conclusion": "success"}]})))
else:
    raise AssertionError((command, args))
