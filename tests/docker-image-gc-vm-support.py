"""OPS-327 isolated NixOS VM helpers; never install on a fleet host.

Real dockerd, registry, switch-to-configuration, systemd budgets and old images.
The only external traffic is loopback inside the VM. Each outcome is recorded.
The stand-in units preserve the production lock paths, acquisition counts,
timeouts, restart policy, trap shape and publish order; their payload is tiny.
"""

from __future__ import annotations

from contextlib import contextmanager
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import tarfile
import threading
import time
import types

ROOT = Path("/var/lib/ops327")
SETTINGS = Path("/run/ops327-settings.json")
COMPOSE = "/run/lock/compose-csb1.lock"
HAUSV = "/run/lock/compose-hausv.lock"
PROXY = "/run/ops327-engine.sock"
DOCKER_SOCKET = "/run/ops327-docker.sock"
GC_SINCE = None


def require_test_vm():
    # Both the CLI and direct socket entry points fail closed on a workstation
    # or fleet host. Only docker-image-gc-vm.nix installs this fixture marker
    # and starts a disposable daemon on this non-production socket.
    marker = Path("/etc/ops327/vm-only")
    if sys.platform != "linux" or not marker.is_file() or marker.read_text() != "OPS-327 disposable VM\n":
        raise RuntimeError("OPS-327 helper requires its isolated test VM")


def settings():
    try: return json.loads(SETTINGS.read_text())
    except FileNotFoundError: return {}


def configure(**kw):
    tmp = SETTINGS.with_suffix(".tmp")
    tmp.write_text(json.dumps(kw)); tmp.replace(SETTINGS)


def record(name, **data):
    ROOT.mkdir(parents=True, exist_ok=True)
    with (ROOT / "events.jsonl").open("a") as output:
        output.write(json.dumps({"event": name, "at": time.monotonic(), **data}) + "\n")


def command(*argv, check=True, timeout=None, pass_fds=()):
    if argv[0] == "docker":
        require_test_vm()
        argv = ("docker", "--host", "unix://" + DOCKER_SOCKET, *argv[1:])
    result = subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, pass_fds=pass_fds)
    if check and result.returncode:
        raise AssertionError((argv, result.returncode, result.stdout, result.stderr))
    return result


def set_system_profile(target, profiles="/nix/var/nix/profiles"):
    """Mirror nix-env generation links without opening the read-only store."""
    target = os.path.realpath(target)
    assert target.startswith("/nix/store/"), ("system target outside store", target)
    assert (Path(target) / "bin/switch-to-configuration").is_file(), target
    profiles = Path(profiles)
    profiles.mkdir(parents=True, exist_ok=True)
    generations = {int(match[1]): path for path in profiles.iterdir()
                   if (match := re.fullmatch(r"system-(\d+)-link", path.name))}
    number = max(generations, default=0)
    updates = []
    if not generations or os.path.realpath(generations[number]) != target:
        number += 1
        generation = profiles / f"system-{number}-link"
        updates.append((generation, target))
    else:
        generation = generations[number]
    updates.append((profiles / "system", generation.name))
    for link, destination in updates:
        temporary = profiles / f".{link.name}-{os.getpid()}-{time.monotonic_ns()}"
        temporary.symlink_to(destination)
        try:
            os.replace(temporary, link)
        finally:
            temporary.unlink(missing_ok=True)
    return generation


def rollback_system_profile(profiles="/nix/var/nix/profiles"):
    """Select the preceding generation, then run its real switch activation."""
    profiles = Path(profiles)
    current = os.readlink(profiles / "system")
    match = re.fullmatch(r"system-(\d+)-link", Path(current).name)
    assert match is not None, ("invalid system profile generation", current)
    number = int(match[1])
    generations = {int(match[1]): path for path in profiles.iterdir()
                   if (match := re.fullmatch(r"system-(\d+)-link", path.name))
                   and int(match[1]) < number}
    assert generations, ("no lower system generation", number)
    generation = generations[max(generations)]
    temporary = profiles / f".system-{os.getpid()}-{time.monotonic_ns()}"
    temporary.symlink_to(generation.name)
    try:
        os.replace(temporary, profiles / "system")
    finally:
        temporary.unlink(missing_ok=True)
    command(str(profiles / "system/bin/switch-to-configuration"), "switch", timeout=650)
    return generation


def wait_for(predicate, seconds=60, name="condition"):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if result := predicate(): return result
        time.sleep(0.05)
    raise AssertionError(f"watchdog waiting for {name}")


class UnixConnection(http.client.HTTPConnection):
    def connect(self):
        require_test_vm()
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(DOCKER_SOCKET)


def engine(method, path):
    conn = UnixConnection("localhost", timeout=650)
    try:
        conn.request(method, path)
        response = conn.getresponse()
        return response.status, response.read(), response.getheaders()
    finally: conn.close()


def listing(path):
    status, body, _ = engine("GET", path)
    assert status == 200
    return json.loads(body)


def events():
    try: return [json.loads(line) for line in (ROOT / "events.jsonl").read_text().splitlines()]
    except FileNotFoundError: return []


class EngineProxy(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class EngineHandler(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline().decode()
        if not line: return
        method, path, _ = line.split()
        while self.rfile.readline() not in (b"\r\n", b"\n", b""): pass
        cfg = settings()
        if method in ("DELETE", "POST"):
            previous = [e for e in events() if e["event"] == "destructive" and e.get("epoch") == cfg.get("epoch")]
            index = len(previous)
            record("destructive", method=method, path=path, epoch=cfg.get("epoch"), index=index)
            delays = cfg.get("delays", [0])
            delay = delays[min(index, len(delays) - 1)]
            time.sleep(delay)
        status, body, headers = engine(method, path)
        if method in ("DELETE", "POST"):
            record("executed", method=method, path=path, status=status, removed=(b'"Deleted"' in body), epoch=cfg.get("epoch"))
        try:
            self.wfile.write(f"HTTP/1.1 {status} answer\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body)
        except (BrokenPipeError, ConnectionResetError): pass


class RegistryHandler(BaseHTTPRequestHandler):
    def do_GET(self): self.forward()
    def do_HEAD(self): self.forward()
    def log_message(self, *_): pass
    def forward(self):
        path = self.path
        # A pull needs only discovery, manifests and content-addressed blobs.
        # Full matching excludes URLs, query strings, escapes and extra segments.
        if not re.fullmatch(
            r"/v2/(?:[a-z0-9][a-z0-9_-]{0,63}(?:/[a-z0-9][a-z0-9_-]{0,63}){0,3}/"
            r"(?:manifests/(?:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|sha256:[0-9a-f]{64})"
            r"|blobs/sha256:[0-9a-f]{64}))?", path
        ):
            record("registry-rejected", method=self.command, path=path)
            self.send_error(400, "unsupported registry request path")
            return
        cfg = settings()
        marker = ROOT / ("registry-delay-" + str(cfg.get("epoch")))
        # Delay exactly one manifest GET, keeping the work inside a real pull.
        marker = marker.with_name(marker.name + '-' + str(cfg.get('pull_index', 0)))
        delayed = self.command == "GET" and "/manifests/" in path and cfg.get("pull_delay") and not marker.exists()
        if delayed:
            marker.touch(); record("registry-wait", epoch=cfg.get("epoch"))
        conn = http.client.HTTPConnection("127.0.0.1", 5000, timeout=650)
        try:
            conn.request(self.command, path, headers=dict(self.headers))
            response = conn.getresponse(); body = response.read()
            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() not in ("transfer-encoding", "connection", "content-length"):
                    self.send_header(key, value)
            self.send_header("Content-Length", response.getheader('Content-Length', str(len(body))) if self.command == 'HEAD' else str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                if delayed:
                    # Headers immediately; body progress at <=5 s intervals avoids
                    # dockerd's response-header/inactivity watchdogs.
                    slices = max(1, int(cfg['pull_delay'] / 5))
                    for n in range(slices):
                        a, b = n * len(body) // slices, (n + 1) * len(body) // slices
                        time.sleep(cfg['pull_delay'] / slices)
                        self.wfile.write(body[a:b]); self.wfile.flush()
                else:
                    self.wfile.write(body)
        finally: conn.close()


def proxy():
    path = Path(PROXY)
    if path.exists(): path.unlink()  # this test's own stopped proxy socket
    registry = ThreadingHTTPServer(("127.0.0.1", 5001), RegistryHandler)
    threading.Thread(target=registry.serve_forever, daemon=True).start()
    with EngineProxy(PROXY, EngineHandler) as server:
        server.serve_forever()


def load_gc(*, mutants=True):
    require_test_vm()
    source = Path("/etc/ops327/gc.py").read_text()
    cfg = settings() if mutants else {}
    if cfg.get("mutant_hold"):
        assert source.count("BATCH_S = 10\n") == 1
        source = source.replace("BATCH_S = 10\n", "BATCH_S = 60\n")
    for flag, anchor in (
        ('mutant_device', '            if info.st_dev != expected:\n'),
        ('mutant_regular', '            if not stat.S_ISREG(info.st_mode):\n'),
    ):
        if cfg.get(flag):
            assert source.count(anchor) == 1, (flag, 'missing mutation anchor')
            source = source.replace(anchor, '            if False:\n')
    spec = importlib.util.spec_from_file_location("vm_gc_harness", Path(__file__).with_name("harness.py"))
    harness = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(harness)
    # The disposable NixOS guest's entire filesystem is this fixture. Its
    # hypervisor boundary, read-only store, marker and private Docker socket
    # are required above; an offline workstation fixture may never use '/'.
    module = harness.execute_source(source, root="/")
    module.SOCKET_PATH = PROXY
    return module


def gc_run():
    gc = load_gc()
    cfg = settings()
    original_locks = gc.deploy_locks
    @contextmanager
    def locks(paths):
        with original_locks(paths):
            record('batch-held', epoch=cfg.get('epoch'))
            yield
    gc.deploy_locks = locks
    batch_budget = None
    if cfg.get('late_decision'):
        original_snapshot = gc.snapshot
        def snapshot(api, budget):
            nonlocal batch_budget
            batch_budget = budget
            return original_snapshot(api, budget)
        gc.snapshot = snapshot
    original_api = gc.docker_api
    paused = False
    late_paused = False
    slow = False
    def api(method, path, timeout, limit):
        nonlocal paused, late_paused, slow
        if cfg.get('late_decision') and method == 'DELETE' and not late_paused:
            late_paused = True
            assert batch_budget is not None, 'missing late-decision batch budget'
            # Final activation/budget/age checks have passed. The request's
            # separate 30 s deadline starts only inside original_api below.
            record('late-decision-held', path=path, epoch=cfg.get('epoch'))
            time.sleep(max(0, batch_budget.left() - 0.1))
        if cfg.get('pause_after_fence') and method == 'DELETE' and not paused:
            paused = True
            record('after-fence', path=path, epoch=cfg.get('epoch'))
            wait_for(lambda: (ROOT / 'send-go').exists(), 20, 'accepted-race publication')
        answer = original_api(method, path, timeout, limit)
        if cfg.get('slow_snapshot') and method == 'GET' and path.startswith('/containers/') and not slow:
            slow = True
            record('snapshot-first', epoch=cfg.get('epoch'))
            time.sleep(1.5)
        return answer
    # Keep the production constants. A hold scenario stops by SIGTERM or budget.
    signal.signal(signal.SIGTERM, gc.STOP.set)
    os.environ["INVOCATION_ID"] = "vm-gc"
    return gc.main(api=api)


@contextmanager
def locked(path, wait=570):
    # The util-linux child locks this inherited open-file description. The
    # parent keeps the same description open through the whole work step, so
    # flock's exit does not release it. This exercises real blocking flock -w.
    fd = os.open(path, os.O_RDONLY | os.O_CREAT, 0o600)
    start = time.monotonic()
    try:
        command("flock", "-w", str(wait), str(fd), pass_fds=(fd,))
        record("acquisition", lock=path, waited=time.monotonic() - start)
        yield
    finally: os.close(fd)


def compose():
    cfg = settings()
    if cfg.get("fail_start"):
        record("intentional-start-failure", epoch=cfg.get("epoch"))
        return 1
    for n in range(cfg.get("acquisitions", 3)):
        (ROOT / f"compose-ready-{n}").touch()
        if cfg.get('ready_gates'):
            wait_for(lambda: (ROOT / f'compose-go-{n}').exists(), 650, 'paced compose acquisition')
        with locked(COMPOSE):
            if n == 0 or cfg.get('split_work'):
                if cfg.get('split_work'):
                    updated = settings(); updated['pull_index'] = n; configure(**updated)
                ref = cfg.get("pull_ref", "localhost:5001/fixture:r8")
                command("docker", "pull", ref)
                if cfg.get("race"):
                    record("pull-attached")
                    wait_for(lambda: any(e["event"] == "executed" and e.get("epoch") == cfg["epoch"] for e in events()), 60, "delayed DELETE effect")
                # Mirror docker-compose's pull-then-API-create sequence: create never pulls.
                result = command("docker", "create", "--pull=never", "--name", f"compose-fixture-{time.monotonic_ns()}", "-v", "ops327-data:/data", ref, check=False)
                if result.returncode:
                    record("creation-failed", epoch=cfg.get("epoch")); return 1
            # Extra acquisitions mirror the two postRecreate operations.
            else:
                time.sleep(cfg.get("extra_work", 0))
    return 0


def canary(start):
    if start:
        with locked(COMPOSE, 300):
            command("docker", "container", "rm", "-f", "canary", check=False)
            code = "trap '' TERM; while :; do sleep 1; done" if settings().get("ignore_term") else "trap 'exit 0' TERM; while :; do sleep 1; done"
            command("docker", "run", "-d", "--name", "canary", "localhost:5000/fixture:r1", "/bin/sh", "-c", code)
    else:
        with locked(COMPOSE, 300): command("docker", "stop", "-t", "10", "canary")


def hausv():
    # The shell, not Python signal handlers, implements TERM + EXIT semantics.
    script = r'''set -eu
stopped=0
start_hausv() {
  if [ "$stopped" = 1 ]; then
    ops327-vm hausv-start
  fi
}
trap start_hausv EXIT HUP INT TERM
ops327-vm hausv-stop
stopped=1
ops327-vm hausv-work
ops327-vm hausv-start
stopped=0
'''
    return command("bash", "-c", script, check=False).returncode


def hausv_step(step):
    if step in ("start", "stop"):
        with locked(HAUSV, 300):
            command("docker", step, "hausv-org")
        return
    cfg = settings()
    publish = ROOT / "snapshot"
    previous = ROOT / ".previous"
    staging = ROOT / ".staging"
    if staging.exists(): shutil.rmtree(staging)
    staging.mkdir(); (staging / "checked").write_text("new-integrity-ok")
    (ROOT / "hausv-working").touch()
    time.sleep(cfg.get("snapshot_work", 0))
    if previous.exists(): shutil.rmtree(previous)
    if publish.exists(): publish.rename(previous)
    (ROOT / "between-renames").touch()
    time.sleep(cfg.get("rename_pause", 0))
    staging.rename(publish)
    if previous.exists(): shutil.rmtree(previous)
    (ROOT / "published").touch()


def dangling(ref, name):
    saved = ROOT / (name + ".tar")
    command("docker", "save", "-o", str(saved), ref)
    clean = ROOT / (name + "-untagged.tar")
    with tarfile.open(saved) as source, tarfile.open(clean, "w") as target:
        for member in source:
            stream = source.extractfile(member) if member.isfile() else None
            if member.name == "manifest.json":
                manifests = json.load(stream)
                for entry in manifests: entry["RepoTags"] = None
                data = json.dumps(manifests).encode(); member.size = len(data); stream = io.BytesIO(data)
            elif member.name == "index.json":
                index = json.load(stream)
                for entry in index["manifests"]:
                    annotations = entry.get("annotations", {})
                    for key in ("io.containerd.image.name", "org.opencontainers.image.ref.name"):
                        annotations.pop(key, None)
                # distribution.source.* describes blob provenance, not an image
                # name. Keep it and all content-addressed blobs unchanged.
                data = json.dumps(index).encode(); member.size = len(data); stream = io.BytesIO(data)
            target.addfile(member, stream)
    command("docker", "image", "rm", ref)
    command("docker", "load", "-i", str(clean))
    return clean


def require_candidates(phase):
    """Check the real Engine view and GC plan without locks or mutation."""
    candidates = json.loads((ROOT / "candidate-refs.json").read_text())
    expected = set(candidates)
    required_refs = {f"localhost:5000/fixture:r{n}" for n in (2, 3)}
    images = listing("/images/json")
    by_id = {image["Id"]: image for image in images}
    # A previous scenario may have left mutant flags in settings. Preconditions
    # always use the unmodified production reader, planner and budget.
    gc = load_gc(mutants=False)
    # Preconditions read the private daemon without proxy delays or faults.
    gc.SOCKET_PATH = DOCKER_SOCKET
    def read_only_api(method, path, timeout, limit):
        assert method == "GET", (phase, "fixture precondition attempted mutation", method, path)
        return gc.docker_api(method, path, timeout=timeout, limit=limit)
    budget = gc.Budget(gc.BATCH_S)
    snap = gc.snapshot(read_only_api, budget)
    planned = gc.plan(snap, time.time(), budget)
    index = gc.Index(images, gc.validate(snap.containers, images))
    declared = set(gc.DECLARED_REFS) | {ref for _, spec in snap.systems for ref in spec.values()}
    resolved = {ref: sorted(index.resolve(ref) & expected) for ref in declared}
    resolved = {ref: ids for ref, ids in resolved.items() if ids}
    actual = {image["Id"] for image in planned.candidates}
    deletable = {image["Id"] for image in planned.deletable}
    details = {"phase": phase, "expected": sorted(expected), "candidates": sorted(actual),
               "deletable": sorted(deletable), "baseline": planned.baseline, "reasons": planned.reasons,
               "declared_candidate_refs": sorted(declared & required_refs), "resolved": resolved,
               "images": {image_id: {key: by_id[image_id].get(key) for key in ("RepoTags", "RepoDigests")}
                          for image_id in expected if image_id in by_id}}
    diagnostic = json.dumps(details, sort_keys=True)
    assert len(expected) == 2 and set(candidates.values()) == required_refs, ("invalid fixture candidate mapping", diagnostic)
    assert expected <= by_id.keys(), ("fixture candidate ID missing after load", diagnostic)
    assert all(tag.startswith("<none>") for image_id in expected
               for tag in by_id[image_id].get("RepoTags") or []), ("fixture candidate is still tagged", diagnostic)
    # RepoDigests may remain after pulls; let the real planner judge protection.
    assert required_refs <= declared, ("fixture candidate system declarations missing", diagnostic)
    assert not resolved, ("declared system ref resolves to a fixture candidate", diagnostic)
    assert actual == deletable == expected and planned.baseline is None, ("unexpected real GC fixture plan", diagnostic)
    record("candidate-preconditions", **details)
    print("fixture candidate preconditions:", diagnostic, flush=True)


def prepare():
    info = json.loads(command("docker", "info", "--format", "{{json .}}", timeout=10).stdout)
    store = {key: info[key] for key in ("Driver", "DriverStatus")}
    record("docker-store", **store)
    print("docker store:", json.dumps(store, sort_keys=True), flush=True)
    assert store["Driver"] == "overlay2", ("unexpected Docker storage driver", store)
    assert ["driver-type", "io.containerd.snapshotter.v1"] not in (store["DriverStatus"] or []), ("unexpected Docker containerd image store", store)
    ROOT.mkdir(parents=True, exist_ok=True)
    wait_for(lambda: command("curl", "-fsS", "http://127.0.0.1:5000/v2/", check=False).returncode == 0)
    for image in json.loads(Path("/etc/ops327/images.json").read_text()):
        command("docker", "load", "-i", image)
    for n in range(1, 9): command("docker", "push", f"localhost:5000/fixture:r{n}")
    command("docker", "tag", "localhost:5000/fixture:r1", "ghcr.io/inspr-at/aeon:live")
    command("docker", "run", "-d", "--name", "aeon", "ghcr.io/inspr-at/aeon:live")
    command("docker", "volume", "create", "ops327-data")
    command("docker", "run", "--name", "volume-sentinel", "-v", "ops327-data:/data", "localhost:5000/fixture:r1", "/bin/sh", "-c", "echo untouched >/data/sentinel")
    command("docker", "run", "-d", "--name", "hausv-org", "localhost:5000/fixture:r1")
    keep = Path("/var/lib/docker-image-gc/keep.d"); keep.mkdir(parents=True, exist_ok=True)
    images = listing("/images/json")
    # Capture Engine IDs (classic-store config digests) independently of the
    # registry manifest digests in RepoDigests.
    candidates = {i['Id']: tag for i in images for tag in i['RepoTags'] or [] if tag in ('localhost:5000/fixture:r2', 'localhost:5000/fixture:r3')}
    (ROOT / 'candidate-refs.json').write_text(json.dumps(candidates))
    live = next(i for i in images if "ghcr.io/inspr-at/aeon:live" in (i["RepoTags"] or []))
    (keep / "aeon-live.refs").write_text(live["RepoDigests"][0] + "\n")
    (keep / "aeon-previous.refs").write_text("ghcr.io/inspr-at/aeon@sha256:" + "f" * 64 + "\n")
    kept = [ref for i in images for ref in i["RepoDigests"] or [] if not any(tag in (i["RepoTags"] or []) for tag in ("localhost:5000/fixture:r2", "localhost:5000/fixture:r3"))]
    (keep / "fixture.refs").write_text("\n".join(kept) + "\n")
    archives = [str(dangling(f"localhost:5000/fixture:r{n}", f"candidate-{n}")) for n in (2, 3)]
    (ROOT / "candidates.json").write_text(json.dumps(archives))
    (ROOT / "base-system").write_text(os.path.realpath("/run/current-system"))
    Path("/run/ops327-ready").touch()
    configure(epoch="init")
    start_unit("ops327-proxy")
    set_system_profile(os.path.realpath("/run/current-system"))
    require_candidates("prepare")


def restore(reset_compose=True):
    stop_unit("ops327-gc")
    stop_unit("compose-csb1")
    fixtures = command("docker", "container", "ls", "-a", "--filter", "name=compose-fixture-", "-q").stdout.split()
    for container in fixtures: command("docker", "container", "rm", container)
    command("systemctl", "reset-failed", "ops327-gc", "hausv-backup-snapshot", "janus-managed-canary", check=False)
    if reset_compose: command("systemctl", "reset-failed", "compose-csb1", check=False)
    # Earlier pulls may attach tags and RepoDigests to these Engine IDs.
    # Remove real tags before reload; require_candidates checks any digests left.
    candidate_ids = json.loads((ROOT / 'candidate-refs.json').read_text())
    for image in listing('/images/json'):
        if image['Id'] in candidate_ids:
            for tag in image['RepoTags'] or []:
                if not tag.startswith('<none>'): command('docker', 'image', 'rm', tag)
    for archive in json.loads((ROOT / "candidates.json").read_text()): command("docker", "load", "-i", archive)
    require_candidates("restore")
    for pattern in ("compose-ready-*", "compose-go-*", "send-go", "hausv-working", "between-renames", "published"):
        for path in ROOT.glob(pattern): path.unlink()


def run_gc(epoch, delays, *, wait_held=False, wait_event=None, preserve_start_limit=False, **kw):
    global GC_SINCE
    restore(reset_compose=not preserve_start_limit); configure(epoch=epoch, delays=delays, **kw)
    GC_SINCE = time.time()
    command("systemctl", "start", "--no-block", "ops327-gc")
    event = wait_event or ('late-decision-held' if kw.get('late_decision') else
                           'batch-held' if wait_held else 'destructive')
    return wait_for(lambda: next((e for e in events() if e["event"] == event and e.get("epoch") == epoch), None), 60, "GC request/hold")


def journal_since(unit, since):
    # Flush journald before every read, including gc_done. Bound both commands
    # so a stuck journal is a setup failure instead of an unbounded fixture.
    command("journalctl", "--sync", timeout=10)
    return command("journalctl", "--unit", unit, "--since", f"@{since:.6f}",
                   "--output=cat", "--no-pager", timeout=10).stdout


def unit_value(unit, property_name):
    return command("systemctl", "show", unit, "-p", property_name, "--value").stdout.strip()


def require_state(unit, states, substates=None):
    active = unit_value(unit, "ActiveState")
    assert active in states, (unit, "unexpected ActiveState", active)
    if substates is not None:
        sub = unit_value(unit, "SubState")
        assert sub in substates, (unit, "unexpected SubState", sub)


def start_unit(unit, *, verb="start"):
    command("systemctl", verb, unit)
    require_state(unit, ("active",))
    require_outcome(unit)


def stop_unit(unit):
    # Cleanup can retain a preceding scenario's Result. Here only quiescence
    # matters; scenario outcome assertions happen before this cleanup.
    command("systemctl", "stop", unit, check=False)
    require_state(unit, ("inactive", "failed"), ("dead", "failed"))


def require_outcome(unit, since=None, *, allowed=("success",), phase="start"):
    result = unit_value(unit, "Result")
    assert result in allowed, (unit, "unexpected Result", result, allowed)
    if result == "timeout":
        assert since is not None, "missing timeout invocation timestamp"
        require_timeout(unit, since, phase)
    return result


def require_timeout(unit, since, phase="start"):
    assert phase in ("start", "stop"), phase
    assert unit_value(unit, "Result") == "timeout", (unit, "expected Result=timeout")
    log = journal_since(unit, since)
    # service_dispatch_timer: SERVICE_START uses the state name "start";
    # SERVICE_STOP uses a different, capitalized sentence. See systemd service.c.
    message = "Stopping timed out" if phase == "stop" else "start operation timed out"
    assert message in log, (unit, "expected unit timeout", message, log)


def assert_no_registry_rejections():
    rejected = [event for event in events() if event["event"] == "registry-rejected"]
    assert not rejected, ("registry-rejected", rejected)


def require_start_limit():
    result = unit_value("compose-csb1", "Result")
    assert result == "start-limit-hit", ("unexpected start-limit failure", result)


def gc_done(expected=2, seconds=50, *, reason="not answered in 30 s", since=None):
    wait_for(lambda: unit_value("ops327-gc", "ActiveState") in ("inactive", "failed"), seconds, "GC exit")
    require_outcome("ops327-gc", allowed=("success",) if expected == 0 else ("exit-code",))
    code = unit_value("ops327-gc", "ExecMainStatus")
    assert int(code) == expected, code
    if expected == 2:
        since = GC_SINCE if since is None else since
        assert since is not None, "missing GC invocation timestamp"
        log = journal_since("ops327-gc", since)
        assert reason in log, ("unexpected GC failure", reason, log)


def switch_async(target):
    return subprocess.Popen([target + "/bin/switch-to-configuration", "test"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def switch_failed_units(out, err):
    # switch-to-configuration-ng main.rs:2669-2683: summary, then systemctl status.
    return {unit for stream in (out, err) for line in stream.splitlines()
            if (match := re.fullmatch(r"warning: the following units failed: (.+)", line))
            for unit in match[1].split(", ")}


def full_unit_outcomes(results):
    # Every scenario runs with and without GC holds. A loopback registry proxy
    # keeps reconcile work inside Docker's real pull, instead of sleeping a unit.
    for work in (540, 580):
        for with_gc in (False, True):
            epoch = f"compose-{work}-{with_gc}"
            actual_work = 595 if with_gc and work == 580 else work
            if with_gc: run_gc(epoch, [29], pull_delay=actual_work, acquisitions=1, late_decision=True, wait_held=True)
            else: restore(); configure(epoch=epoch, delays=[0], pull_delay=actual_work, acquisitions=1)
            stop_unit("compose-csb1")
            begin_events = len(events())
            record("compose-work", epoch=epoch, work=actual_work)
            started = time.monotonic()
            base = (ROOT / 'base-system').read_text()
            target = base + '/specialisation/changed' if os.path.realpath('/run/current-system') == base else base
            since = time.time()
            switch = switch_async(target)
            out, err = switch.communicate(timeout=650)
            result = types.SimpleNamespace(returncode=switch.returncode, stdout=out, stderr=err)
            expected = not (with_gc and work == 580)
            acquisitions = [e for e in events()[begin_events:] if e["event"] == "acquisition" and e["lock"] == COMPOSE]
            if not expected:
                assert acquisitions and acquisitions[0]["waited"] >= 20, (epoch, "insufficient fixture overlap", actual_work, acquisitions)
            # main.rs:2578-2588: the compose start job's timeout forces exit 4.
            assert result.returncode == (0 if expected else 4), (epoch, result)
            if expected:
                assert switch_failed_units(out, err) == set(), (epoch, result)
            else:
                assert switch_failed_units(out, err) <= {"compose-csb1.service"}, (epoch, result)
            if expected:
                require_outcome("compose-csb1", since)
                require_state("compose-csb1", ("active",), ("exited",))
            else:
                # A retry can recover during ng's settling loop; retain the
                # original job's timeout evidence independently of current Result.
                log = journal_since("compose-csb1", since)
                assert "start operation timed out" in log, (epoch, "expected original start timeout", log)
            results.append({"case": epoch, "work": actual_work, "acquisitions": acquisitions,
                            "exit": result.returncode, "elapsed": time.monotonic() - started})
            stop_unit("compose-csb1")
            if with_gc: gc_done(0, 5)
    # The hold mutant must push 540 s past the 600 s unit budget.
    run_gc("mutant-hold", [29], pull_delay=540, acquisitions=1, mutant_hold=True, late_decision=True, wait_held=True)
    since = time.time()
    result = command("systemctl", "start", "compose-csb1", check=False, timeout=650)
    require_outcome("compose-csb1", since, allowed=("timeout",))
    results.append({"case": "hold-above-45-mutant", "exit": result.returncode})
    stop_unit("compose-csb1")
    # Canary stop with quick and ignoring containers, both actual Docker states.
    for ignored in (False, True):
        for with_gc in (False, True):
            restore(); configure(epoch=f"canary-{ignored}-{with_gc}", ignore_term=ignored)
            start_unit("janus-managed-canary")
            holder = subprocess.Popen(["flock", COMPOSE, "sleep", "25"]) if with_gc else None
            if holder: time.sleep(0.1)
            since = time.time()
            stopped = command("systemctl", "stop", "janus-managed-canary", check=False, timeout=40)
            outcome = require_outcome("janus-managed-canary", since, allowed=("success", "timeout"), phase="stop")
            require_state("janus-managed-canary", ("inactive", "failed"), ("dead", "failed"))
            state = command("docker", "ps", "-a", "--filter", "name=^/canary$", "--format", "{{.State}}").stdout.strip()
            assert state in ("running", "exited"), state
            results.append({"case": "canary-stop", "ignores-term": ignored, "gc": with_gc, "exit": stopped.returncode, "Result": outcome, "container": state})
            if holder: assert holder.wait(timeout=30) == 0
            command("systemctl", "reset-failed", "janus-managed-canary", check=False)
    # Publish order and a killed unit's actual EXIT/TERM traps.
    for position in ("before", "after", "between"):
        for with_gc in (False, True):
            # Held "between": 39 + 130 = ~169 s to first rename, then a
            # 50 s gap (~169-219 s) around the 180 s start timeout.
            restore(); configure(epoch=f"hausv-{position}-{with_gc}",
                                 snapshot_work=181 if position == "before" else 130 if position == "between" and with_gc else 140,
                                 rename_pause=50 if position == "between" else 0)
            for name in ("snapshot", ".previous", ".staging"):
                path = ROOT / name
                if path.exists(): shutil.rmtree(path)
            (ROOT / "snapshot").mkdir(); (ROOT / "snapshot/checked").write_text("previous")
            command("docker", "start", "hausv-org")
            begin_events = len(events())
            holder = subprocess.Popen(["flock", HAUSV, "sleep", "39"]) if with_gc else None
            if holder: time.sleep(0.1)
            since = time.time()
            command("systemctl", "start", "--no-block", "hausv-backup-snapshot")
            if with_gc and position == "after":
                wait_for(lambda: (ROOT / "hausv-working").exists(), 50)
                # Main start and handlers can each meet further holds.
                time.sleep(120)
                extra = subprocess.Popen(["flock", HAUSV, "sleep", "39"])
            else: extra = None
            wait_for(lambda: unit_value("hausv-backup-snapshot", "ActiveState") in ("inactive", "failed"), 290)
            outcome = require_outcome("hausv-backup-snapshot", since, allowed=("success", "timeout"))
            state = command("docker", "ps", "-a", "--filter", "name=^/hausv-org$", "--format", "{{.State}}").stdout.strip()
            snapshots = {name: (ROOT / name / "checked").read_text() for name in ("snapshot", ".previous") if (ROOT / name / "checked").exists()}
            acquisitions = [e for e in events()[begin_events:] if e["event"] == "acquisition" and e["lock"] == HAUSV]
            assert len(acquisitions) <= 4 and all(e["waited"] <= 45 for e in acquisitions)
            assert state in ("running", "exited")
            assert snapshots and all(v in ("previous", "new-integrity-ok") for v in snapshots.values())
            if position == "before": assert snapshots.get("snapshot") == "previous"
            if position == "between": assert snapshots.get(".previous") == "previous" and "snapshot" not in snapshots
            results.append({"case": f"hausv-{position}", "gc": with_gc, "Result": outcome, "container": state, "snapshots": snapshots, "acquisitions": acquisitions})
            if holder: assert holder.wait(timeout=45) == 0
            if extra: assert extra.wait(timeout=45) == 0
    # Three acquisitions in one real 600 s unit, 440 fits and 480 fails.
    for work in (440, 480):
        for with_gc in (False, True):
            restore(); configure(epoch=f"three-{work}-{with_gc}", pull_delay=work / 3, acquisitions=3, split_work=True, ready_gates=with_gc)
            stop_unit("compose-csb1")
            thread_errors = []
            def paced_holds():
                for n in range(3):
                    # For later acquisitions hold before unblocking the previous
                    # phase; marker is written before the actual lock attempt.
                    wait_for(lambda n=n: (ROOT / f"compose-ready-{n}").exists(), 650)
                    with locked(COMPOSE):
                        (ROOT / f'compose-go-{n}').touch()
                        time.sleep(44)
            if with_gc:
                # Hold before the unit's first attempt, then work/readiness hooks
                # provide the next two opportunities (assert the measured waits).
                def checked_holds():
                    try: paced_holds()
                    except Exception as exc: thread_errors.append(exc)
                thread = threading.Thread(target=checked_holds, daemon=True); thread.start()
            since = time.time()
            result = command("systemctl", "start", "compose-csb1", check=False, timeout=650)
            if with_gc:
                thread.join(timeout=5)
                assert not thread.is_alive(), "paced hold fixture did not finish"
                if thread_errors: raise RuntimeError("paced hold fixture failed") from thread_errors[0]
            results.append({"case": f"three-acquisitions-{work}", "gc": with_gc, "exit": result.returncode})
            expected = not with_gc or work == 440
            require_outcome("compose-csb1", since, allowed=("success",) if expected else ("timeout",))
            if expected: require_state("compose-csb1", ("active",), ("exited",))
            stop_unit("compose-csb1")


def checks():
    outcomes, results = [], []
    base = os.path.realpath("/run/current-system")
    changed = base + "/specialisation/changed"
    # A real switch while DELETE is delayed for 600 seconds: 30 s GC error,
    # then the compose lock is available and the switch completes.
    request = run_gc("switch-held", [600])
    proc = switch_async(changed)
    # Match the actual kernel token, with switch ng holding its tmpfs lock.
    gc = load_gc()
    assert wait_for(lambda: gc.switch_lock_used(gc.Budget(5)), 10, "real switch token")
    gc_done(2)
    out, err = proc.communicate(timeout=650)
    assert proc.returncode == 4, (out, err)
    assert switch_failed_units(out, err) == {"ops327-gc.service"}, (out, err)
    require_state("compose-csb1", ("active",), ("exited",))
    require_outcome("compose-csb1")
    results.append({"case": "switch-held-delete-and-real-proc-token", "switch": proc.returncode})
    start_unit("ops327-proxy", verb="restart")  # cancel the never-forwarded 600 s request
    # Drive profiles with symlinks: Nix commands open the store DB, which cannot
    # be initialized on this VM's read-only store. Activation still switches.
    set_system_profile(base)
    set_system_profile(os.path.realpath(changed))
    run_gc("snapshot-switch", [1], slow_snapshot=True, wait_event="snapshot-first")
    rollback_system_profile()
    gc_done(0, 100)
    results.append({"case": "switch-never-blocked-by-gc-switch-lock"})
    # The accepted post-snapshot race: a tag appears only after the fence.
    # The actual old specialisation declares that tag, ng retargets and waits
    # on the compose lock, then the ID delete removes it; reconcile re-pulls.
    fence = run_gc('accepted-publication', [0], pause_after_fence=True, wait_event='after-fence')
    victim = fence['path'].split('/images/', 1)[1].split('?', 1)[0]
    ref = json.loads((ROOT / 'candidate-refs.json').read_text())[victim]
    old_number = ref.rsplit('r', 1)[1]
    command('docker', 'tag', victim, ref)
    cfg = settings(); cfg['pull_ref'] = ref; cfg['acquisitions'] = 1; configure(**cfg)
    old_target = base + '/specialisation/old' + old_number
    switch = switch_async(old_target)
    wait_for(lambda: os.path.realpath('/run/current-system') == os.path.realpath(old_target), 10, 'late old system retarget')
    (ROOT / 'send-go').touch()
    out, err = switch.communicate(timeout=650)
    assert switch.returncode == 0, (out, err)
    removal = wait_for(lambda: next((e for e in events() if e['event'] == 'executed' and e.get('epoch') == 'accepted-publication' and e['method'] == 'DELETE'), None), 10)
    assert removal['status'] == 200 and removal['removed'], removal
    gc_done(0, 110)
    results.append({'case': 'old-system-after-snapshot-accepted-race', 'switch': switch.returncode, 'delete': removal})
    # Real delayed effect: the victim's tag is absent, its Engine ID exists
    # dangling. The registry pull reattaches its tag while DELETE waits 40 s.
    request = run_gc("delayed-effect", [40], race=True, pull_ref="localhost:5000/fixture:r2", acquisitions=1)
    victim = request['path'].split('/images/', 1)[1].split('?', 1)[0]
    pull_ref = json.loads((ROOT / 'candidate-refs.json').read_text())[victim]
    cfg = settings(); cfg['pull_ref'] = pull_ref; configure(**cfg)
    stop_unit("compose-csb1")
    switch = switch_async(changed if os.path.realpath("/run/current-system") == base else base)
    command("systemctl", "start", "--no-block", "compose-csb1")
    gc_done(2)
    wait_for(lambda: any(e["event"] == "creation-failed" and e.get("epoch") == "delayed-effect" for e in events()), 20)
    # Prevent the second start from waiting on the first call's event semantics.
    configure(epoch="retry", race=False, pull_ref=pull_ref, acquisitions=1)
    wait_for(lambda: unit_value("compose-csb1", "ActiveState") == "active", 45)
    require_outcome("compose-csb1")
    assert int(unit_value("compose-csb1", "NRestarts")) >= 1, "missing automatic recovery restart"
    switch_out, switch_err = switch.communicate(timeout=650)
    assert switch.returncode in (0, 4), (switch_out, switch_err)
    # GC failure and compose retry race with ng's failed-unit scan.
    assert switch_failed_units(switch_out, switch_err) <= {"compose-csb1.service", "ops327-gc.service"}, (switch_out, switch_err)
    sentinel = command("docker", "run", "--name", "sentinel-check", "-v", "ops327-data:/data", "localhost:5000/fixture:r1", "/bin/cat", "/data/sentinel").stdout.strip()
    assert sentinel == "untouched"
    results.append({"case": "delayed-delete-real-effect", "switch": switch.returncode, "volume": sentinel})
    # Exhaust the actual start limit; the third failure is an actual raced pull.
    stop_unit("compose-csb1")
    command('systemctl', 'reset-failed', 'compose-csb1')
    for n in range(2):
        stop_unit("compose-csb1")
        epoch = f"fail-{n}"
        configure(epoch=epoch, fail_start=True)
        command("systemctl", "start", "compose-csb1", check=False)
        require_outcome("compose-csb1", allowed=("exit-code",))
        assert any(e["event"] == "intentional-start-failure" and e.get("epoch") == epoch for e in events())
    # Keep automatic retries from burning the third slot before the race.
    stop_unit("compose-csb1")
    request = run_gc("start-limit-race", [40], race=True, pull_ref="localhost:5000/fixture:r2", acquisitions=1, preserve_start_limit=True)
    victim = request['path'].split('/images/', 1)[1].split('?', 1)[0]
    pull_ref = json.loads((ROOT / 'candidate-refs.json').read_text())[victim]
    cfg = settings(); cfg['pull_ref'] = pull_ref; configure(**cfg)
    command("systemctl", "start", "--no-block", "compose-csb1")
    gc_done(2)
    wait_for(lambda: any(e["event"] == "creation-failed" and e.get("epoch") == "start-limit-race" for e in events()), 20)
    configure(epoch="limit-retry", pull_ref=pull_ref, acquisitions=1)
    time.sleep(35)
    require_state("compose-csb1", ("failed",), ("failed",))
    require_start_limit()
    command("systemctl", "reset-failed", "compose-csb1")
    start_unit("compose-csb1")
    results.append({"case": "exhausted-start-limit-and-manual-recovery"})
    # Filesystem identity and device nodes: both are rejected before reading.
    keep = Path("/var/lib/docker-image-gc/keep.d")
    for kind in ("bind", "device"):
        restore(); configure(epoch=kind)
        path = keep / "bad.refs"
        if kind == "bind":
            path.touch()
            command("mkdir", "-p", "/run/ops327-other")
            command("mount", "-t", "tmpfs", "tmpfs", "/run/ops327-other")
            Path("/run/ops327-other/refs").write_text("")
            command("mount", "--bind", "/run/ops327-other/refs", str(path))
        else: os.mknod(path, 0o020600, os.makedev(1, 3))
        since = time.time()
        command("systemctl", "start", "ops327-gc", check=False, timeout=60)
        gc_done(2, 5, reason="unexpected file system" if kind == "bind" else "not a regular file", since=since)
        # Re-run exactly the same fixture with its single check removed.
        # The behavioural test must reject the mutant (it no longer exits 2).
        command('systemctl', 'reset-failed', 'ops327-gc')
        configure(epoch=kind + '-mutant', **{'mutant_device' if kind == 'bind' else 'mutant_regular': True})
        command('systemctl', 'start', 'ops327-gc', check=False, timeout=65)
        gc_done(0, 5)
        results.append({'case': f'keep-{kind}-mutant-killed', 'mutant': 'no device check' if kind == 'bind' else 'no S_ISREG check'})
        if kind == "bind":
            command("umount", str(path)); command("umount", "/run/ops327-other")
        path.unlink()
        results.append({"case": f"keep-{kind}-rejected"})
    full_unit_outcomes(outcomes)
    assert_no_registry_rejections()
    (ROOT / "results.json").write_text(json.dumps(results, indent=2))
    (ROOT / "unit-outcomes.json").write_text(json.dumps(outcomes, indent=2))
    for result in results + outcomes: print("ok", result["case"], json.dumps(result))


if __name__ == "__main__":
    require_test_vm()
    action = sys.argv[1]
    if action == "proxy": proxy()
    elif action == "gc": sys.exit(gc_run())
    elif action == "prepare": prepare()
    elif action == "checks": checks()
    elif action == "compose": sys.exit(compose())
    elif action.startswith("canary-"): canary(action.endswith("start"))
    elif action == "hausv": sys.exit(hausv())
    elif action.startswith("hausv-"): hausv_step(action.split("-", 1)[1])
    else: raise ValueError(action)
