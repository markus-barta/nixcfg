#!/usr/bin/env python3
"""PATH fakes for T125; refuses any unrecognized operation (no network)."""

import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
import urllib.parse
import zipfile


root = Path(os.environ["CD_FIXTURE"])
config = json.loads((root / "fixture.json").read_text())
scenario = json.loads((root / "scenario.json").read_text())
command = Path(sys.argv[0]).name
args = sys.argv[1:]


def event(kind, **fields):
    with (root / "events").open("a") as output:
        output.write(json.dumps({"kind": kind, **fields}) + "\n")


def link(path, target):
    path = Path(path)
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
    os.execvp(args[0], args)
elif command == "ssh":
    script = sys.stdin.read()
    call = shlex.split(args[-1])
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
        path = Path(config["state_dir"]) / "results" / (token + ".json")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({
            "schema": "inspr.pharos.guarded-deploy-result.v1", "nixcfg_rev": args[position + 1],
            "hausnetz_rev": args[position + 2], "mode": args[position + 3], "run_id": token,
            "status": "running", "phase": "build"}))
    else:
        with (root / "executor.log").open("ab") as output:
            process = subprocess.Popen(args[position:], stdout=output, stderr=output, start_new_session=True)
        (root / "executor.pid").write_text(str(process.pid))
elif command == "systemctl":
    assert args[0] == "show"
    if args[1] == "hausnetz.service":
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
        print(os.readlink(args[0]))
elif command == "nix":
    if args[0] == "run":
        event("prepare", args=args)
        assert args[1].endswith("#cd-prepare") and args[2:4] == ["--", "--rev"]
        assert args[5] == "--running"
        repo = args[1].split("#")[0]
        assert subprocess.check_output(["git", "-C", repo, "rev-parse", "--is-shallow-repository"], text=True).strip() == "false"
        if scenario.get("prepare_missing"):
            raise SystemExit(1)
        def manifest(rev):
            result = subprocess.run(["git", "-C", repo, "show", rev + ":capabilities.json"],
                                    capture_output=True, check=False)
            return result.stdout if result.returncode == 0 else b""
        before, after = manifest(args[6]), manifest(args[4])
        value = {"rev": args[4], "narHash": config["nar_hash"], "version": config["new_version"],
                 "persisted_ok": True, "manifest_changed": before != after,
                 "manifest_sha256": hashlib.sha256(after).hexdigest(),
                 "running_manifest_sha256": hashlib.sha256(before).hexdigest(),
                 "problems": [] if before and after else ["manifest_missing"]}
        value.update(scenario.get("prepare", {}))
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
elif command == "nix-env":
    assert args[:2] == ["--profile", config["system_profile"]] and args[2] == "--set"
    target = args[3]
    generation = "system-2-link" if target == config["new_system"] else "system-3-link"
    link(root / generation, target)
    link(config["system_profile"], root / generation)
    event("profile", target=target)
elif command == "switch-to-configuration":
    target = str(Path(sys.argv[0]).parent.parent)
    if args == ["dry-activate"]:
        event("dry-activate")
        if scenario.get("activation") is not None:
            print(scenario["activation"])
        else:
            print("would stop the following units: hausnetz.service, polkit.service")
            print("would activate the configuration...")
            print("would reload the following units: dbus-broker.service")
            print("would start the following units: hausnetz.service, polkit.service")
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
        rev = config["old_rev"] if target == config["old_system"] else config["new_rev"]
        if not scenario.get("stale_evidence"):
            Path(config["evidence_file"]).write_text(json.dumps({
                "schema": "inspr.pharos.nix-deployment-evidence.v1", "source_revision": rev}))
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
                print(json.dumps({"version": version}))
        elif url.endswith("/readyz"):
            if active_new() and scenario.get("readyz_missing"):
                status = 404
            if active_new() and scenario.get("readyz_503"):
                status = 503
            bad = (active_new() and scenario.get("readyz_false")) or (
                not active_new() and scenario.get("rollback_readyz_false") and (root / "rolled-back").exists())
            print(json.dumps({"ok": not bad}))
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
elif command in {"alarm", "secondary-telegram"}:
    event(command, text=args[-1])
else:
    raise AssertionError((command, args))
