"""CI guest boundary: only a local bundle supplies the trusted checker."""

import fcntl
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile


HOME = Path("/var/lib/ci-runners/hausnetz")
PATH = "/nix/var/nix/profiles/default/bin:/usr/bin:/bin"
SCHEMA = "hausnetz.acceptance.v1"
ADAPTER_SCHEMA = "hausnetz-cd.acceptance-adapter.v1"


def parse_json(data):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("duplicate_json_key")
            value[key] = item
        return value
    def invalid(_value):
        raise ValueError("invalid_json_constant")
    return json.loads(data, object_pairs_hook=unique, parse_constant=invalid)


def error(reason):
    return {"schema": ADAPTER_SCHEMA, "ok": False, "infra": "unavailable", "reason": reason}


def atomic(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        output.write(value)
    temporary.replace(path)


def prune(root):
    # Only this adapter's run names, never symlinks or unrelated files. Active
    # runs hold their lock; a killed wrapper leaves an inspectable directory.
    owned = sorted((p for p in root.iterdir() if re.fullmatch(r"run-[0-9a-f]{32}", p.name)
                    and p.is_dir() and not p.is_symlink()), key=lambda p: p.stat().st_mtime, reverse=True)
    for path in owned[3:]:
        lock = path / "control.lock"
        if lock.is_symlink():
            continue
        with lock.open("a") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue
            # A live checker may outlast its SSH wrapper. Do not prune it.
            if (path / "pgid").exists():
                try:
                    os.kill(int((path / "pgid").read_text()), 0)
                    continue
                except ProcessLookupError:
                    pass
            shutil.rmtree(path)


def main():
    os.environ.update(HOME=str(HOME), PATH=PATH, GIT_TERMINAL_PROMPT="0")
    os.umask(0o077)
    mode, token, *args = sys.argv[1:]
    if not re.fullmatch(r"[0-9a-f]{32}", token):
        return 75
    root = HOME / "cd-acceptance"
    if root.is_symlink():
        return 75
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    work = root / ("run-" + token)
    if mode == "kill":
        # mkdir covers cancellation before the main SSH command arrives.
        work.mkdir(mode=0o700, exist_ok=True)
        if work.is_symlink():
            return 75
        with (work / "spawn.lock").open("a") as spawn:
            fcntl.flock(spawn, fcntl.LOCK_EX)
            atomic(work / "cancelled", "yes")
            pid = work / "pgid"
            if pid.is_file() and not pid.is_symlink():
                try:
                    os.killpg(int(pid.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
        return 0
    if mode != "run" or len(args) != 5:
        return 75
    rev, url, version, caps, timeout = args
    prune(root)
    work.mkdir(mode=0o700, exist_ok=True)
    if work.is_symlink():
        return 75
    child = None
    try:
        with (work / "control.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if (work / "cancelled").exists():
                raise RuntimeError("cancelled")
            bundle = work / "trusted.bundle"
            with bundle.open("xb") as output:
                shutil.copyfileobj(sys.stdin.buffer, output)
            def git(*argv):
                return subprocess.check_output(["git", *map(str, argv)], stderr=sys.stderr,
                                               timeout=30, text=True).strip()
            heads = git("bundle", "list-heads", bundle).splitlines()
            if heads != [rev + " refs/heads/trusted"]:
                raise RuntimeError("bundle_identity")
            checkout = work / "checkout"
            git("clone", "--quiet", "--no-checkout", bundle, checkout)
            git("-C", checkout, "checkout", "--quiet", "--detach", rev)
            if git("-C", checkout, "rev-parse", "HEAD") != rev:
                raise RuntimeError("head_mismatch")
            # Serialize PID publication and cancellation, so the cancellation
            # command cannot miss a child in the spawn/publication window.
            with (work / "spawn.lock").open("a") as spawn:
                fcntl.flock(spawn, fcntl.LOCK_EX)
                if (work / "cancelled").exists():
                    raise RuntimeError("cancelled")
                child = subprocess.Popen(["nix", "develop", "-c", "just", "acceptance", url, version, caps],
                                         cwd=checkout, stdout=subprocess.PIPE, stderr=sys.stderr,
                                         start_new_session=True, text=True)
                atomic(work / "pgid", str(child.pid))
            try:
                stdout, _ = child.communicate(timeout=float(timeout))
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.communicate(timeout=1)
                print(json.dumps({"schema": ADAPTER_SCHEMA, "ok": False, "reason": "checker_timeout"}))
                return 1
            value = None
            for line in stdout.splitlines():
                try:
                    candidate = parse_json(line)
                except ValueError:
                    candidate = None
                if isinstance(candidate, dict) and candidate.get("schema") == SCHEMA:
                    if value is not None:
                        print(json.dumps(value), file=sys.stderr)
                    value = candidate
                else:
                    print(line, file=sys.stderr)
            print(json.dumps(value if value is not None else
                             {"schema": ADAPTER_SCHEMA, "ok": False, "reason": "checker_json_missing"}))
            return child.returncode if child.returncode != 0 else (0 if value is not None else 1)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        print(json.dumps(error("materialize_failed")))
        return 75
    finally:
        if child is not None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=1)
        shutil.rmtree(work)


if __name__ == "__main__":
    if sys.argv[1:2] == ["kill"]:
        raise SystemExit(main())
    # Colima collapses nonzero SSH exits to 1. A zero-exit transport envelope
    # preserves the guest/checker status without confusing it with SSH failure.
    captured = io.StringIO()
    try:
        with redirect_stdout(captured):
            status = main()
        value = parse_json(captured.getvalue())
    except Exception:
        status, value = 75, error("guest_wrapper_failed")
    status = status if status >= 0 else 128 - status
    print(json.dumps({"schema": "hausnetz-cd.acceptance-transport.v1",
                      "exit_status": status, "result": value}))
