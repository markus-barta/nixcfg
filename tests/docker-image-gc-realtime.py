#!/usr/bin/env python3
"""OPS-327 Linux real-time lane: non-root, Python 3, bash 5, util-linux flock.

No Docker, systemd, network or privileged paths. All fixture paths stay in this checkout.
Baseline: approximately 70–100 minutes; --mutants adds approximately 2–4 hours.
--case selects checks (repeatable); --list lists them without running anything.
Every check prints ok/FAIL; any failed baseline, missing mutation anchor or
surviving mutant exits nonzero. Watchdogs kill only this harness's children.

Example:
  python3 tests/docker-image-gc-realtime.py --root "$PWD/lane-example" \
    --compose-lock-dir "$PWD/lane-example/locks" --instance-lock "$PWD/lane-example/instance" \
    --switch-lock "$PWD/lane-example/switch" --keep-dir "$PWD/lane-example/keep" \
    --store "$PWD/lane-example/store" --engine-socket "$PWD/lane-example/engine.sock" --mutants
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
from contextlib import contextmanager

HERE = Path(__file__).resolve().parent
REPO = os.path.realpath(HERE.parent)
spec = importlib.util.spec_from_file_location("harness", HERE / "docker-image-gc-harness.py")
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)


def repo_path(value, *, directory=False):
    """Resolve symlinks and traversal before allowing a path inside this checkout."""
    path = os.path.realpath(value)
    if path.startswith(REPO + os.sep):
        return path
    if directory and path == REPO:
        return REPO
    print(f"path must stay inside checkout {REPO}: {value!r}", file=sys.stderr)
    raise SystemExit(2)


def unique_keys(pairs):
    data = {}
    for key, value in pairs:
        if key in data:
            raise ValueError(f"duplicate manifest key: {key}")
        data[key] = value
    return data


def checked_paths(source, paths):
    h.check_path_contract(source, paths)
    checked = {}
    for key, value in paths.items():
        if key in ("PROC", "PROC_LOCKS"):
            if value != {"PROC": "/proc", "PROC_LOCKS": "/proc/locks"}[key]:
                raise ValueError(f"{key} must name the read-only kernel table")
            checked[key] = value
        elif key == "LOCK_PATHS":
            if not isinstance(value, (tuple, list)) or len(value) != 3:
                raise ValueError("LOCK_PATHS must contain three fixture paths")
            checked[key] = tuple(repo_path(path) for path in value)
        else:
            checked[key] = repo_path(value)
    return checked


def prepare_worker(manifest):
    """Validate the entire closed manifest before loading or creating anything."""
    data = json.loads(Path(repo_path(manifest)).read_text(), object_pairs_hook=unique_keys)
    if not isinstance(data, dict) or set(data) != {"source", "paths", "events", "constants"}:
        raise ValueError("top-level keys must be source, paths, events, constants")
    source = Path(repo_path(data["source"])).read_text()
    events = repo_path(data["events"])
    paths = checked_paths(source, data["paths"])
    constants = data["constants"]
    if not isinstance(constants, dict) or not set(constants) <= {"RUN_BUDGET_S"}:
        raise ValueError("constants keys may only contain RUN_BUDGET_S")
    for value in constants.values():
        if type(value) is not int:
            raise ValueError("RUN_BUDGET_S must be an int, not bool")
        if not 1 <= value <= 3000:
            raise ValueError("RUN_BUDGET_S must be within 1..3000 seconds")
    gc = h.load(source, paths)
    for name, value in constants.items():
        setattr(gc, name, value)
    actual = {name: getattr(gc, name) for name in h.path_constants(source)}
    if checked_paths(source, actual) != paths:
        raise ValueError("loaded path constants differ from the manifest")
    h.check_socket(gc.SOCKET_PATH)
    return gc, events


def worker(manifest):
    try:
        gc, events = prepare_worker(manifest)
    except h.FixtureViolation as exc:
        print("fixture audit violation: " + json.dumps(exc.recorded), file=sys.stderr)
        return 2
    except (ValueError, TypeError, KeyError, AttributeError, OSError, SyntaxError) as exc:
        print("invalid worker manifest: " + str(exc).replace("\n", " "), file=sys.stderr)
        return 2
    holds, attempts = [], []
    original = gc.deploy_locks
    @contextmanager
    def tracked(paths):
        attempts.append(time.monotonic())
        with original(paths):
            started = time.monotonic()
            try:
                yield
            finally:
                holds.append((started, time.monotonic()))
    gc.deploy_locks = tracked
    os.environ["INVOCATION_ID"] = "ops327-offline-fixture"
    os.environ["DOCKER_IMAGE_GC_DRY_RUN"] = "0"
    signal.signal(signal.SIGTERM, gc.STOP.set)
    try:
        rc = gc.main()
    except h.FixtureViolation as exc:
        print("fixture audit violation: " + json.dumps(exc.recorded), file=sys.stderr)
        rc = 2
    finally:
        Path(events).write_text(json.dumps({"holds": holds, "attempts": attempts,
                                           "violations": gc.__ops327_fixture_guard__.violations}))
    return rc


class CaseFailure(AssertionError):
    """Only an assertion of the case's observed GC behaviour can kill a mutant."""


def require(condition, message="case assertion failed"):
    if not condition:
        raise CaseFailure(message)


def wait_for(predicate, seconds, label):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        result = predicate()
        if result:
            return result
        time.sleep(0.01)
    raise CaseFailure(f"watchdog: {label} ({seconds:g} s)")


class Lane:
    def __init__(self, args, name, source):
        self.root = Path(repo_path(os.path.join(args.root, name)))
        if self.root.exists():
            raise AssertionError(f"fixture directory already exists; use a fresh --root: {self.root}")
        self.root.mkdir(parents=True)
        def nested(value, directory=False):
            base = repo_path(value, directory=directory)
            return repo_path(os.path.join(base, name) if directory else
                             os.path.join(os.path.dirname(base), name, os.path.basename(base)))
        overrides = {"KEEP_DIR": nested(args.keep_dir, True), "STORE_DIR": nested(args.store, True),
                     "INSTANCE_LOCK": nested(args.instance_lock), "SWITCH_LOCK": nested(args.switch_lock),
                     "SOCKET_PATH": nested(args.engine_socket),
                     "LOCK_PATHS": tuple(str(Path(nested(args.compose_lock_dir, True)) / f"compose-{n}.lock") for n in range(3))}
        self.paths, self.images, self.containers, self.spec = h.fixture(self.root, **overrides)
        self.source = self.root / "gc-source.py"
        self.source.write_text(source)
        self.processes = []
        self.engines = []
        self.sequence = 0

    def engine(self, **kw):
        server = h.Engine(self.paths["SOCKET_PATH"], self.images, self.containers, **kw)
        self.engines.append(server)
        return server

    def start(self, constants=None):
        self.sequence += 1
        manifest = self.root / f"worker-{self.sequence}.json"
        events = self.root / f"events-{self.sequence}.json"
        manifest.write_text(json.dumps({"source": str(self.source), "paths": self.paths,
                                        "events": str(events), "constants": constants or {}}))
        process = subprocess.Popen([sys.executable, "-B", str(Path(__file__).resolve()), "--worker", str(manifest)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        process.events = events
        self.processes.append(process)
        return process

    def finish(self, process, timeout=100, expected=0):
        try:
            out, err = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill(); out, err = process.communicate()
            raise CaseFailure(f"GC watchdog after {timeout}s: {out} {err}") from None
        if not process.events.exists():
            raise RuntimeError(f"worker startup failed: {process.returncode}: {err}")
        require(process.returncode == expected, (process.returncode, out, err))
        return json.loads(process.events.read_text()), out + err

    def contender(self, lock=0, hold=0, prefix="contender"):
        # The actual util-linux waiter is the process receiving STOP/CONT.
        acquired = self.root / (prefix + ".acquired")
        proc = subprocess.Popen(["flock", "-x", "-w", "570", self.paths["LOCK_PATHS"][lock],
                                 sys.executable, "-c",
                                 "import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text(str(time.monotonic())); time.sleep(float(sys.argv[2]))",
                                 str(acquired), str(hold)])
        proc.acquired = acquired
        self.processes.append(proc)
        return proc

    def check_workers(self):
        for proc in self.processes:
            if hasattr(proc, "events") and proc.poll() is not None and proc.returncode >= 0 and not proc.events.exists():
                out, err = proc.communicate()
                raise RuntimeError(f"worker startup failed: {proc.returncode}: {out} {err}")

    def close(self):
        for proc in self.processes:
            if proc.poll() is None:
                # A stopped waiter must be continued so termination can run.
                if getattr(proc, "owned_group", False):
                    os.killpg(proc.pid, signal.SIGCONT)
                    os.killpg(proc.pid, signal.SIGKILL)
                else:
                    proc.send_signal(signal.SIGCONT)
                    proc.kill()
            proc.wait(timeout=5)
            for pipe in (getattr(proc, "stdout", None), getattr(proc, "stderr", None)):
                if pipe: pipe.close()
        for server in self.engines:
            server.close()


def deadline(lane, *, method="DELETE", phase=None, delay=600):
    if method == "POST":
        lane.images[:] = lane.images[:2]
    engine = lane.engine(delay=delay, phase=phase)
    proc = lane.start()
    require(engine.sent.wait(55), "no destructive call after initial cooldown")
    sent = engine.destructive[0][2]
    contender = lane.contender()
    acquired = float(wait_for(lambda: contender.acquired.read_text() if contender.acquired.exists() else None,
                              31 if phase else 45, "deadline contender"))
    require(acquired - sent <= (31 if phase else 45), acquired - sent)
    events, output = lane.finish(proc, 5, 2)
    require("not answered in 30 s" in output, output)
    require(events["holds"][-1][1] - sent <= 31)
    require(len(engine.destructive) == 1, engine.destructive)
    require(contender.wait(timeout=5) == 0)


def maximal(lane, *, r34=False):
    # A 5 s first call leaves 5 s to admit the next decision inside BATCH_S.
    # A 24 s answer leaves >=4 s below the deadline after offset/jitter.
    # The real hold is ~29 s; BATCH_S=60 admits four calls and holds ~77 s.
    # r34 strict-bound exception (in addition to <=31 and >=45): [9,29,29]
    # sends the second decision at 8.9..10.1 s, with ~38..39 s total hold
    # against <=45. Its internal 10 s batch/30 s call limits leave ~1 s
    # headroom, not 2 s. Keep the design's numbers; Linux measures overhead.
    engine = lane.engine(delay=[9, 29, 29] if r34 else [5, 24, 24])
    proc = lane.start({"RUN_BUDGET_S": 55})
    require(engine.sent.wait(55))
    contender = lane.contender()
    wait_for(lambda: contender.acquired.exists(), 45, "maximal hold")
    events, _ = lane.finish(proc, 50)
    require(max(end - start for start, end in events["holds"]) <= 45, events)
    require(float(contender.acquired.read_text()) - events["holds"][0][0] <= 45)
    require(len(engine.destructive) >= 2, engine.destructive)
    decision = engine.destructive[1][2] - events["holds"][0][0]
    require((8.9 <= decision <= 10.1) if r34 else (3 <= decision <= 10), decision)


def between(lane):
    engine = lane.engine(delay=[11, 0])
    proc = lane.start({"RUN_BUDGET_S": 110})
    require(engine.sent.wait(55))
    contender = lane.contender(hold=3)
    wait_for(lambda: contender.acquired.exists(), 45, "between-batch waiter")
    events, _ = lane.finish(proc, 100)
    require(len(events["holds"]) >= 2, events)
    require(events["holds"][1][0] - events["holds"][0][1] >= 45, events)
    require(float(contender.acquired.read_text()) < events["holds"][1][0])


def backlog(lane):
    # Fake listings remain in-process; the destructive connection alone meets
    # the full real AF_UNIX accept queue. No request can have been sent.
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    clients = []
    server.bind(lane.paths["SOCKET_PATH"]); server.listen(1)
    try:
        for _ in range(16):
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.setblocking(False)
            try:
                client.connect(lane.paths["SOCKET_PATH"])
                clients.append(client)
            except BlockingIOError:
                client.close()
                break
        require(len(clients) >= 1)
        gc = h.load(lane.source.read_text(), lane.paths)
        # Exercise the real main()/compose finally path, not just a connect.
        real = gc.docker_api
        def api(method, path, timeout, limit):
            if method == "GET":
                return 200, json.dumps(lane.containers if path.startswith("/containers/") else lane.images).encode()
            (lane.root / "backlog.started").write_text(str(time.monotonic()))
            return real(method, path, timeout, limit)
        # A watchdog child bounds no-deadline mutants, even if connect hangs.
        pid = os.fork()
        if pid == 0:
            try:
                os.environ["INVOCATION_ID"] = "ops327-backlog"
                os.environ["DOCKER_IMAGE_GC_DRY_RUN"] = "0"
                signal.signal(signal.SIGTERM, gc.STOP.set)
                rc = gc.main(api)
                Path(lane.root / "backlog.result").write_text(str(rc))
            except Exception as exc:
                Path(lane.root / "backlog.error").write_text(f"{type(exc).__name__}: {exc}")
                os._exit(2)
            os._exit(rc)
        try:
            # Observe the actual destructive connect, rather than guessing
            # that a 46 s sleep outlasted cooldown plus worker scheduling.
            def started():
                if (lane.root / "backlog.error").exists():
                    raise RuntimeError((lane.root / "backlog.error").read_text())
                return (lane.root / "backlog.started").exists()
            wait_for(started, 55, "backlog destructive connect starts")
            contender = lane.contender()
            began = time.monotonic()
            wait_for(lambda: contender.acquired.exists(), 31, "full accept queue contender")
            require(float(contender.acquired.read_text()) - began <= 31)
            wait_for(lambda: (lane.root / "backlog.result").exists(), 3, "backlog GC exit")
            require((lane.root / "backlog.result").read_text() == "2")
            # The only queued connections were the prefill: no HTTP request.
            server.settimeout(1)
            for _ in clients:
                conn, _ = server.accept()
                conn.setblocking(False)
                try:
                    require(not conn.recv(100), "destructive request reached prefill socket")
                except BlockingIOError:
                    pass
                conn.close()
        finally:
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
            os.waitpid(pid, 0)
            if (lane.root / "backlog.error").exists():
                raise RuntimeError((lane.root / "backlog.error").read_text())
    finally:
        for client in clients: client.close()
        server.close()


def fifo(lane, where):
    path = lane.spec if where == "spec" else Path(lane.paths["KEEP_DIR"]) / ("aeon-live.refs" if where == "role" else "stuck.refs")
    if path.exists(): path.unlink()  # only a fixture file created by this case
    os.mkfifo(path)
    engine = lane.engine()
    proc = lane.start()
    wait_for(lambda: engine.calls, 55, "FIFO snapshot starts")
    began = engine.calls[0][2]
    contender = lane.contender()
    wait_for(lambda: contender.acquired.exists(), 5, "FIFO contender")
    _, output = lane.finish(proc, 5, 2)
    require(time.monotonic() - began < 5)
    require("not a regular file" in output, output)


def never_switch_lock(lane):
    Path(lane.paths["SWITCH_LOCK"]).touch()
    engine = lane.engine(delay=5)
    proc = lane.start({"RUN_BUDGET_S": 55})
    require(engine.sent.wait(55))
    for _ in range(25):
        result = subprocess.run(["flock", "-n", lane.paths["SWITCH_LOCK"], "true"], check=False)
        require(result.returncode == 0, "GC locked the switch lock")
        time.sleep(0.02)
    lane.finish(proc, 50)


def instance(lane):
    engine = lane.engine(delay=600)
    first = lane.start()
    require(engine.sent.wait(55))
    second = lane.start()
    events, output = lane.finish(second, 5)
    require("another run is in progress" in output)
    require(not events["attempts"])
    first.kill(); first.wait(timeout=5)
    restarted_at = time.monotonic()
    third = lane.start()
    # Busy instance has gone, but third must still cool down after SIGKILL.
    time.sleep(40)
    require(len(engine.destructive) == 1)
    wait_for(lambda: len(engine.destructive) > 1, 10, "post-SIGKILL first attempt")
    require(engine.destructive[1][2] - restarted_at >= 45)


def schedules(lane, *, extra=False, across=False, adversarial=False, r34=False):
    engine = lane.engine(delay=[9, 29, 9, 29] if r34 else [5, 24, 5, 24])
    # r29-adversarial: COOLDOWN_S=45, BATCH_S=10, CALL_DEADLINE_S=30.
    # Hold 1: ~45..74 (5+24); B: ~74..124; busy attempt: ~119;
    # next cooldown ends ~164; hold 2: ~164..193; then A and SIGTERM.
    # r30-adversarial adds C at ~124..124.5, before the ~164 attempt.
    # Both need >193 s: 180 exits 0 on release before the bound is checked.
    # 300 leaves room for SIGTERM (rc 1) and the measured W/G assertion.
    first = lane.start({"RUN_BUDGET_S": 55 if across else 300 if adversarial else 180})
    require(engine.sent.wait(55))
    # Hold 1 lasts about 29 s. B wins by stopping A before the release.
    b = lane.contender(hold=50 if adversarial else 7 if r34 else 5, prefix="B")
    a = lane.contender(prefix="A")
    a.send_signal(signal.SIGSTOP)
    wait_for(lambda: b.acquired.exists(), 45, "B wins first release")
    if across:
        first_events, _ = lane.finish(first, 5)
    b.wait(timeout=60)
    if extra:
        # C lives between former sample points; A remains stopped at C's release.
        c = lane.contender(hold=0.5, prefix="C")
        wait_for(lambda: c.acquired.exists(), 3, "C's intervening hold")
        c.wait(timeout=3)
    if across:
        next_run = lane.start({"RUN_BUDGET_S": 90})
    # Let the adversarial variant admit a second GC hold inside A's wait.
    # Otherwise 8 s spans the mutant's 2 s retry plus scheduling tolerance,
    # while the real rule's 45 s cooldown remains far away.
    if adversarial:
        wait_for(lambda: len(engine.destructive) >= 3, 100, 'next GC hold inside A wait')
    else:
        time.sleep(8)
    a.send_signal(signal.SIGCONT)
    wait_for(lambda: a.acquired.exists(), 50, "A after B/C")
    acquired = float(a.acquired.read_text())
    a.wait(timeout=5)
    if across:
        later_events, _ = lane.finish(next_run, 140)
        holds = first_events["holds"] + later_events["holds"]
        require(later_events["attempts"][0] - first_events["holds"][-1][1] >= 45)
    else:
        if adversarial:
            require(first.poll() is None, "GC exited before adversarial SIGTERM")
        first.send_signal(signal.SIGTERM)
        events, _ = lane.finish(first, 40, 1)
        holds = events["holds"]
    if adversarial:
        require(len(holds) >= 2, ("adversarial bound needs two GC holds", holds))
    if r34:
        require(8.9 <= engine.destructive[1][2] - holds[0][0] <= 10.1)
        require(all(end - start <= 45 for start, end in holds), holds)
    began = engine.destructive[0][2]
    w = acquired - began
    g = sum(max(0, min(end, acquired) - max(start, began)) for start, end in holds)
    require(g <= 45 + (w - g) + 0.2, {"W": w, "G": g, "holds": holds})
    if adversarial:
        print(f"adversarial bound checked: W={w:.3f} G={g:.3f} holds={len(holds)}", flush=True)
    if not adversarial:
        require(acquired < holds[1][0] if len(holds) > 1 else True)


def four_acquisitions(lane, *, r34=False):
    # HAUSV-shaped real bash traps. GC holds are spaced >45 s apart. Each of
    # main-stop, interrupted main-start, TERM-start, EXIT-start is counted.
    script = lane.root / "hausv-user.sh"
    script.write_text('''#!/usr/bin/env bash
set -eu
stopped=1
acquire() {
  n=$(cat "$1/count"); n=$((n+1)); echo "$n" > "$1/count"
  echo "$n" > "$1/ready"
  while [ ! -f "$1/go-$n" ]; do sleep 0.02; done
  flock -w 570 "$2" python3 -c 'import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text(str(time.monotonic()))' "$1/got-$n"
}
restart() { if [ "$stopped" = 1 ]; then acquire "$1" "$2"; fi; }
trap 'restart "$1" "$2"' EXIT HUP INT TERM
acquire "$1" "$2"
acquire "$1" "$2"
stopped=0
''')
    (lane.root / "count").write_text("0")
    user = subprocess.Popen(["bash", str(script), str(lane.root), lane.paths["LOCK_PATHS"][0]], start_new_session=True)
    user.owned_group = True
    lane.processes.append(user)
    last_release = None
    for n in range(1, 5):
        wait_for(lambda: (lane.root / "ready").read_text().strip() == str(n) if (lane.root / "ready").exists() else False, 10, f"acquisition {n} ready")
        if last_release is not None:
            time.sleep(max(0, last_release + 45 - time.monotonic()))
        # Drive an actual GC batch for this acquisition, through the same worker.
        # Unique sockets allow independent server lifetimes without unlinking.
        lane.paths["SOCKET_PATH"] = str(lane.root / f"engine-{n}.sock")
        engine = lane.engine(delay=[9, 29, 29] if r34 else [5, 24, 24])
        proc = lane.start({"RUN_BUDGET_S": 55})
        require(engine.sent.wait(55))
        began = time.monotonic()
        (lane.root / f"go-{n}").touch()
        if n == 2:
            time.sleep(0.1)
            # As systemd does, signal the shell and its waiting flock child.
            # The interrupted attempt ends at SIGTERM; TERM and EXIT each
            # make a subsequent, separately bounded acquisition.
            os.killpg(user.pid, signal.SIGTERM)
            require(time.monotonic() - began <= 45)
        else:
            got = lane.root / f"got-{n}"
            wait_for(lambda: got.exists(), 45, f"handler acquisition {n}")
            require(float(got.read_text()) - began <= 45)
        events, _ = lane.finish(proc, 45 if n == 2 else 10)
        if r34:
            require(8.9 <= engine.destructive[1][2] - events["holds"][0][0] <= 10.1)
            require(all(end - start <= 45 for start, end in events["holds"]), events)
        last_release = events["holds"][-1][1]
    user.wait(timeout=10)
    require((lane.root / "count").read_text().strip() == "4")


CASES = {"delete-hold-bound": lambda l: deadline(l), "prune-hold-bound": lambda l: deadline(l, method="POST"),
         "maximal-hold": maximal, "between-batches": between, "full-accept-queue": backlog,
         "fifo-keep": lambda l: fifo(l, "keep"), "fifo-spec": lambda l: fifo(l, "spec"),
         "fifo-role": lambda l: fifo(l, "role"), "never-switch-lock": never_switch_lock,
         "instance-and-sigkill": instance,
         "r29": lambda l: schedules(l), "r30": lambda l: schedules(l, extra=True),
         "r29-adversarial": lambda l: schedules(l, adversarial=True),
         "r30-adversarial": lambda l: schedules(l, extra=True, adversarial=True),
         "across-runs": lambda l: schedules(l, across=True), "four-acquisitions": four_acquisitions}
CASES.update({"maximal-hold-r34": lambda l: maximal(l, r34=True),
              "r29-r34": lambda l: schedules(l, r34=True),
              "r30-r34": lambda l: schedules(l, extra=True, r34=True),
              "r29-adversarial-r34": lambda l: schedules(l, adversarial=True, r34=True),
              "r30-adversarial-r34": lambda l: schedules(l, extra=True, adversarial=True, r34=True),
              "across-runs-r34": lambda l: schedules(l, across=True, r34=True),
              "four-acquisitions-r34": lambda l: four_acquisitions(l, r34=True)})
for method in ("DELETE", "POST"):
    for phase in ("status", "header", "chunk-size", "chunk-data", "body", "stream"):
        CASES[f"trickle-{method.lower()}-{phase}"] = lambda l, m=method, p=phase: deadline(l, method=m, phase=p)


REAL_MUTANTS = {
    "BatchOver sleeps 12 s": ["maximal-hold-r34"],
    "BATCH_S 60": ["maximal-hold"], "deadline 120": ["delete-hold-bound", "prune-hold-bound"],
    "no deadline": ["trickle-delete-body"], "a per-receive timeout only": ["trickle-delete-stream"],
    "the locks kept after the deadline": ["delete-hold-bound"],
    "exit 0 instead of 2 after the deadline": ["delete-hold-bound"],
    "re-take the locks without the sleep": ["between-batches"],
    "cooldown 2 s": ["r29"],
    "no wait before the first attempt": ["across-runs"], "no instance lock": ["instance-and-sigkill"],
    "the instance lock released before the run's last compose release": ["instance-and-sigkill"],
    "plain blocking open": ["fifo-keep", "fifo-spec", "fifo-role"], "no `S_ISREG` check": ["fifo-keep"],
    "the GC takes the lock": ["never-switch-lock"], "hold above 45 s": ["four-acquisitions"],
    "the timeout update dropped from `connect`": ["full-accept-queue"],
    "the wrapper bypassed for connection setup": ["full-accept-queue"],
    "the timeout update dropped from `recv_into`": ["trickle-delete-header"],
    "a fresh 30 s socket timeout before each receive": ["trickle-delete-body", "trickle-post-body"],
    "a parser that reads through its own unwrapped socket": ["trickle-delete-header"],
    "a fresh 30 s socket timeout confined to the status line": ["trickle-delete-status"],
    "a fresh 30 s socket timeout confined to the header lines": ["trickle-delete-header"],
    "a fresh 30 s socket timeout confined to the chunked reader": ["trickle-delete-chunk-size", "trickle-delete-chunk-data"],
    "a fresh 30 s socket timeout confined to the body": ["trickle-delete-body"],
}
# A 5 s over-hold still fits ~38+5 <=45. Observe it without promising a kill
# or weakening the bound. --mutants includes this diagnostic probe separately.
REAL_PROBES = {"BatchOver sleeps 5 s": ["maximal-hold-r34"]}


def validate_mutant_table(mutants):
    for mutant, names in {**REAL_MUTANTS, **REAL_PROBES}.items():
        if mutant not in mutants:
            raise ValueError(f"unknown mutant {mutant!r}")
        if not names:
            raise ValueError(f"mutant {mutant!r} has no cases")
        for name in names:
            if name not in CASES:
                raise ValueError(f"unknown case {name!r} for {mutant!r}")


def socket_paths(args, checks):
    """All bind sites: Lane.engine, backlog and four_acquisitions' four sockets."""
    for index, (name, _, _) in enumerate(checks):
        directory = f"{index:03d}-{name}"
        yield os.path.join(os.path.dirname(args.engine_socket), directory, os.path.basename(args.engine_socket))
        if name in ("four-acquisitions", "four-acquisitions-r34"):
            for n in range(1, 5):
                yield os.path.join(args.root, directory, f"engine-{n}.sock")


def preflight_sockets(args, checks):
    longest = max(socket_paths(args, checks), key=lambda path: len(os.fsencode(path)), default="")
    size = len(os.fsencode(longest))
    if size > 107:
        print(f"FAIL socket path too long: {longest} ({size} bytes; shorten --root)")
        return False
    return True


def classify_case(name, mutant, baseline_passed, error, *, setup=False):
    label = name + (f" [mutant: {mutant}]" if mutant else "")
    if error is not None and (setup or not isinstance(error, CaseFailure)):
        return False, f"FAIL {label} (setup: {error})"
    if mutant and not baseline_passed:
        return False, f"FAIL {label} (baseline did not pass in this run)"
    passed = isinstance(error, CaseFailure) if mutant else error is None
    detail = f": {error}" if error and not mutant else ""
    return passed, f"{'ok' if passed else 'FAIL'} {label}{detail}"


def run_checks(args, checks):
    failed, baselines = 0, {}
    for index, (name, mutant, candidate) in enumerate(checks):
        lane, error, setup = None, None, True
        try:
            case = CASES[name]
            lane = Lane(args, f"{index:03d}-{name}", candidate)
            setup = False
            case(lane)
        except Exception as exc:
            error = exc
        finally:
            if lane:
                try:
                    lane.check_workers()
                except Exception as exc:
                    error, setup = exc, True
                try:
                    lane.close()
                except Exception as exc:
                    error, setup = exc, True
        passed, message = classify_case(name, mutant, baselines.get(name, False), error, setup=setup)
        if mutant in REAL_PROBES and baselines.get(name, False) and not setup and (error is None or isinstance(error, CaseFailure)):
            passed = True
            message = f"{'SURVIVED' if error is None else 'KILLED'} probe {name} [{mutant}]" + (f": {error}" if error else "")
        if mutant is None:
            baselines[name] = passed
        failed += not passed
        print(message, flush=True)
    print(f"{len(checks) - failed}/{len(checks)} checks passed; {failed} failed")
    return int(bool(failed))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--worker", help=argparse.SUPPRESS)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--mutants", action="store_true")
    parser.add_argument("--source", default=str(HERE.parent / "hosts/csb1/docker-image-gc.py"))
    for name in ("root", "compose-lock-dir", "instance-lock", "switch-lock", "keep-dir", "store", "engine-socket"):
        parser.add_argument("--" + name)
    args = parser.parse_args()
    # Check every supplied path before worker dispatch, --list or the Linux gate.
    for name, directory in (
        ("worker", False),
        ("root", True),
        ("compose_lock_dir", True),
        ("instance_lock", False),
        ("switch_lock", False),
        ("keep_dir", True),
        ("store", True),
        ("engine_socket", False),
        ("source", False),
    ):
        value = getattr(args, name)
        if value is not None:
            setattr(args, name, repo_path(value, directory=directory))
    if args.worker:
        return worker(args.worker)
    sys.path.insert(0, str(HERE))
    import test_docker_image_gc as unit
    try:
        validate_mutant_table(unit.MUTANTS)
    except ValueError as exc:
        print(f"FAIL mutant table: {exc}")
        return 1
    if args.list:
        for name in CASES: print(name)
        for mutant, names in REAL_MUTANTS.items(): print(f"mutant: {mutant} -> {', '.join(names)}")
        for mutant, names in REAL_PROBES.items(): print(f"probe: {mutant} -> {', '.join(names)}")
        return 0
    for name in ("root", "compose_lock_dir", "instance_lock", "switch_lock", "keep_dir", "store", "engine_socket"):
        if not getattr(args, name): parser.error("missing --" + name.replace("_", "-"))
    source = Path(repo_path(args.source)).read_text()
    checks = [(name, None, source) for name in (args.case or CASES)]
    if args.mutants:
        for mutant, names in {**REAL_MUTANTS, **REAL_PROBES}.items():
            override = unit.MUTANTS[mutant][0]
            for before, _ in override[1].pairs:
                if source.count(before) != 1:
                    print(f"FAIL mutant anchor: {mutant}")
                    return 1
            changed = override[1](source)
            checks += [(name, mutant, changed) for name in names if not args.case or name in args.case]
    if not preflight_sockets(args, checks):
        return 2
    if sys.platform != "linux":
        print("SKIP: real-time lane requires Linux and util-linux flock", file=sys.stderr)
        return 77
    subprocess.run(["flock", "--version"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["bash", "-c", 'test "${BASH_VERSINFO[0]}" -ge 5'], check=True)
    return run_checks(args, checks)


if __name__ == "__main__":
    sys.exit(main())
