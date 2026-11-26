#!/usr/bin/env python3
"""PATH fakes for T125; refuses any unrecognized operation (no network)."""

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
    script = script.replace("/var/lib/hausnetz-cd", config["state_dir"])
    script = script.replace("/etc/pharos-deployment/evidence.json", config["evidence_file"])
    script = script.replace("/run/current-system/sw/bin/hausnetz-cd-execute", config["executor"])
    result = subprocess.run(["bash", "-s", "--", *call[3:]], input=script.encode(), check=False)
    raise SystemExit(result.returncode)
elif command == "systemd-run":
    position = args.index(config["executor"])
    event("start", args=args)
    with (root / "executor.log").open("ab") as output:
        process = subprocess.Popen(args[position:], stdout=output, stderr=output, start_new_session=True)
    (root / "executor.pid").write_text(str(process.pid))
elif command == "systemctl":
    assert args[0] == "show"
    print("active" if (root / "executor.pid").exists() else "inactive")
elif command == "nix":
    event("nix", args=args)
    if args[0] == "build":
        if scenario.get("build_fail"):
            raise SystemExit(1)
        print(config["new_system"])
    elif args[:2] == ["store", "diff-closures"]:
        if scenario.get("closures") is not None:
            print(scenario["closures"])
        else:
            print("hausnetz: old → new")
            print("etc: +12.6 KiB")
            print("pharos-deployment-evidence: old → new")
            if scenario.get("extra_closure"):
                print("  openssh: old → new")
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
            print("would start the following units: hausnetz.service, polkit.service")
            print("would reload the following units: dbus-broker.service")
        if scenario.get("extra_unit"):
            # Must also capture/reject an extra unit emitted only on stderr.
            print("would restart the following units: sshd.service", file=sys.stderr)
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
        elif url.endswith("/version"):
            active = str(Path(config["current_system"]).resolve())
            is_new = active == config["new_system"]
            if is_new and scenario.get("bare_200"):
                print("{}")
            else:
                rev = config["new_hnet"] if is_new else config["old_hnet"]
                if is_new and scenario.get("health_fail"):
                    rev = config["old_hnet"]
                if not is_new and scenario.get("rollback_health_fail") and (root / "rolled-back").exists():
                    rev = config["new_hnet"]
                print(json.dumps({"revision": rev}))
        elif url.endswith("/healthz"):
            if scenario.get("healthz_fail") and str(Path(config["current_system"]).resolve()) == config["new_system"]:
                raise SystemExit(1)
            print('{"ok":true}')
        else:
            raise AssertionError(url)
        assert "--write-out" in args
        sys.stdout.flush()
        sys.stdout.write("\n" + str(scenario.get("http_status", 200)))
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
