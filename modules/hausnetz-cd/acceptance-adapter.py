"""Mac adapter. Configuration and executables are immutable Nix store inputs."""

import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import uuid

from common import Manual, coordinate, digest, revision, strict_json


CONFIG_FILE = "@CONFIG@"
GUEST_FILE = "@GUEST@"
SCHEMA = "hausnetz.acceptance.v1"
ADAPTER_SCHEMA = "hausnetz-cd.acceptance-adapter.v1"


class Unavailable(Exception):
    pass


class Cancelled(BaseException):
    pass


def error(reason, infra=True):
    value = {"schema": ADAPTER_SCHEMA, "ok": False, "reason": reason}
    if infra:
        value["infra"] = "unavailable"
    return value


class Adapter:
    def __init__(self, config):
        self.config = config
        self.state = Path(config["state_dir"])
        self.token = uuid.uuid4().hex
        self.guest = Path(GUEST_FILE).read_text()
        self.remote_active = False
        self.process = None
        self.deadline = None

    def command(self, argv, *, timeout=30, stdin=None, chatter=False):
        if self.deadline is not None:
            timeout = min(timeout, self.deadline - time.monotonic())
            if timeout <= 0:
                raise Unavailable("adapter_timeout")
        # Every command has its own process group, including colima ssh.
        self.process = subprocess.Popen(argv, stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        start_new_session=True)
        process = self.process
        try:
            output, stderr = process.communicate(timeout=timeout)
            if chatter:
                sys.stderr.write(stderr.decode("utf-8", errors="replace"))
            # Tool diagnostics may include configuration/secrets. Only closed
            # reasons cross this boundary; checker chatter is handled in guest.
            return process.returncode, output.decode("utf-8", errors="replace")
        except subprocess.TimeoutExpired:
            raise Unavailable("command_timeout") from None
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=1)
            self.process = None

    def ssh(self, mode, *args):
        remote = ["sudo", "-n", "-u", "ci-hausnetz", "--", "/usr/bin/python3", "-c",
                  self.guest, mode, self.token, *args]
        return [self.config["colima"], "--profile", "ci", "ssh", "--", shlex.join(remote)]

    def markers(self):
        return [p for p in self.state.iterdir() if re.fullmatch(r"vm-[0-9a-f]{32}\.json", p.name)
                and p.is_file() and not p.is_symlink()]

    def ready(self):
        rc, status = self.command([self.config["colima"], "list", "--json"])
        try:
            profiles = [strict_json(line) for line in status.splitlines()]
            profile = next(p for p in profiles if p.get("name") == "ci")
            state = profile.get("status")
            if rc != 0 or state not in {"Running", "Stopped"}:
                raise Unavailable("vm_status_unknown")
        except (Manual, AttributeError, StopIteration):
            raise Unavailable("vm_status_unknown") from None
        rc = 0 if state == "Running" else 1
        if rc != 0:
            # Persist start intent before calling the dispatcher; release can
            # recover an interrupted start without bypassing its idle checks.
            marker = self.state / ("vm-" + self.token + ".json")
            marker.write_text(json.dumps({"run_id": self.token}))
            rc, _ = self.command([self.config["ci_vm"], "start", "--provision-only"], timeout=930)
            if rc == 75:
                marker.unlink()
                raise Unavailable("heavy_lock_busy")
            if rc != 0:
                raise Unavailable("vm_start_failed")
        probe = ("sudo -n -u ci-hausnetz -- /bin/sh -c " + shlex.quote(
            "export HOME=/var/lib/ci-runners/hausnetz; "
            "export PATH=/nix/var/nix/profiles/default/bin:/usr/bin:/bin; "
            "test -d \"$HOME\" && command -v nix >/dev/null && command -v just >/dev/null"))
        rc, _ = self.command([self.config["colima"], "--profile", "ci", "ssh", "--", probe], timeout=10)
        if rc != 0:
            raise Unavailable("guest_unavailable")

    def defer_release(self):
        subprocess.Popen([sys.executable, "-B", __file__, "--release"],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)

    def release(self):
        markers = self.markers()
        if markers:
            if self.deadline is not None and self.deadline - time.monotonic() < 205:
                self.defer_release()
                return
            rc, _ = self.command([self.config["ci_vm"], "stop"], timeout=200)
            if rc != 0:
                raise Unavailable("vm_stop_deferred")
            for marker in markers:
                marker.unlink(missing_ok=True)

    def cancel(self):
        deadline = self.deadline
        self.deadline = None
        try:
            if self.remote_active:
                try:
                    self.command(self.ssh("kill"), timeout=1)
                except (OSError, Unavailable):
                    pass
        finally:
            # Cancellation may use its own small grace, but a slow VM stop
            # must not consume the remaining stdout/exit-75 delivery budget.
            self.deadline = deadline

    def run(self, args):
        rev, url, version, caps = args
        self.deadline = time.monotonic() + self.config["budget"]
        self.ready()
        with tempfile.TemporaryDirectory(prefix="bundle-", dir=self.state) as tmp:
            tmp = Path(tmp)
            repo = tmp / "repo.git"
            def git(*argv):
                rc, output = self.command([self.config["git"], *map(str, argv)])
                if rc != 0:
                    raise Unavailable("bundle_failed")
                return output.strip()
            cache = Path(self.config["cache_dir"]) / "hausnetz"
            # Local fetch only: no missing-object fallback to a remote origin.
            git("-C", cache, "cat-file", "-e", rev + "^{commit}")
            git("init", "--quiet", "--bare", repo)
            git("-C", repo, "fetch", "--quiet", "--no-tags", cache, rev + ":refs/heads/trusted")
            bundle = tmp / "trusted.bundle"
            git("-C", repo, "bundle", "create", bundle, "refs/heads/trusted")
            if git("bundle", "list-heads", bundle) != rev + " refs/heads/trusted":
                raise Unavailable("bundle_identity")
            self.remote_active = True
            with bundle.open("rb") as data:
                rc, stdout = self.command(self.ssh("run", rev, url, version, caps,
                                                  str(self.config["timeout"])), stdin=data,
                                          timeout=self.config["timeout"] + 2, chatter=True)
        value = None
        infra = None
        guest_code = None
        if rc != 0:
            raise Unavailable("guest_unavailable")
        for line in stdout.splitlines():
            try:
                candidate = strict_json(line)
            except Manual:
                candidate = None
            if isinstance(candidate, dict) and candidate.get("schema") == "hausnetz-cd.acceptance-transport.v1":
                code = candidate.get("exit_status")
                result = candidate.get("result")
                if type(code) is not int or not 0 <= code <= 255 or not isinstance(result, dict):
                    raise Unavailable("guest_transport_invalid")
                guest_code, candidate = code, result
            if isinstance(candidate, dict) and candidate.get("schema") == SCHEMA:
                if value is not None:
                    print(json.dumps(value), file=sys.stderr)
                value = candidate
            elif isinstance(candidate, dict) and candidate.get("schema") == ADAPTER_SCHEMA:
                infra = candidate
            else:
                print(line, file=sys.stderr)
        if guest_code is None:
            raise Unavailable("guest_transport_missing")
        rc = guest_code
        if rc == 75:
            # The guest wrapper has completed its own finally cleanup. A
            # cancellation RPC here would recreate a finished run directory.
            self.remote_active = False
            raise Unavailable("guest_unavailable")
        self.remote_active = False
        if value is None:
            return 1, error("checker_json_missing", infra=False) if infra is None else infra
        # A claimed PASS with a failed process must never become PASS.
        return rc, value


def main():
    os.umask(0o077)
    config = strict_json(Path(CONFIG_FILE).read_bytes())
    args = sys.argv[1:]
    preflight = len(args) == 2 and args[0] == "--preflight"
    release = args == ["--release"]
    try:
        if preflight:
            if args[1] != config["acceptance_url"]:
                raise Manual("invalid_url")
        elif not release:
            if len(args) != 4:
                raise Manual("invalid_arguments")
            revision(args[0])
            if args[1] != config["acceptance_url"]:
                raise Manual("invalid_url")
            coordinate(args[2])
            digest(args[3])
    except Manual as exc:
        print(json.dumps(error(str(exc), infra=False)))
        return 2
    adapter = Adapter(config)
    adapter.state.mkdir(mode=0o700, parents=True, exist_ok=True)
    value = error("adapter_unavailable")
    rc = 75
    cancelled = False
    def interrupted(_signum, _frame):
        raise Cancelled()
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    with (adapter.state / "operator.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX if release else fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(json.dumps(error("adapter_busy")))
            return 75
        try:
            if release:
                adapter.release()
                rc, value = 0, {"schema": ADAPTER_SCHEMA, "ok": True}
            elif preflight:
                adapter.ready()
                rc, value = 0, {"schema": ADAPTER_SCHEMA, "ok": True}
            else:
                rc, value = adapter.run(args)
        except Cancelled:
            cancelled = True
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            adapter.cancel()
            rc, value = 75, error("cancelled")
        except (OSError, Unavailable) as exc:
            adapter.cancel()
            rc, value = 75, error(str(exc) if isinstance(exc, Unavailable) else "command_unavailable")
        finally:
            if not (preflight and rc == 0) and not release:
                if cancelled:
                    # Dispatcher drain/stop can exceed the controller's 3s
                    # grace. Hand durable lease cleanup to an isolated process.
                    adapter.defer_release()
                else:
                    try:
                        adapter.release()
                    except Cancelled:
                        signal.signal(signal.SIGTERM, signal.SIG_IGN)
                        signal.signal(signal.SIGINT, signal.SIG_IGN)
                        adapter.cancel()
                        adapter.defer_release()
                        rc, value = 75, error("cancelled")
                    except (OSError, Unavailable):
                        print("hausnetz-cd-acceptance: vm_stop_deferred", file=sys.stderr)
    print(json.dumps(value, allow_nan=False))
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
