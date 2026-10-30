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
import hashlib
import select
import threading
import uuid
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
from contextlib import contextmanager, nullcontext

HERE = Path(__file__).resolve().parent
REPO = os.path.realpath(HERE.parent)
TIMING_INSTRUMENTATION_MAX_S = 0.250
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


class EvidenceError(RuntimeError):
    """Incomplete or inconsistent setup evidence can never kill a mutant."""


class EvidenceState:
    """Streaming schema/state validator; errors are sticky through SIGKILL."""

    def __init__(self, identity, pid):
        self.identity, self.pid = identity, pid
        self.records, self.pending, self.phases = [], {}, set()
        self.ready, self.end, self.fatal = False, None, []

    def accept(self, record):
        common = {"identity", "pid", "seq", "kind"}
        fields = {"START": set(), "READY": set(), "GUARD_BEGIN": {"id"},
                  "ALLOW": {"id"}, "SETUP_BEGIN": {"id"}, "SETUP_END": {"id"},
                  "DENY": {"event", "path"}, "SETUP_ERROR": {"error"},
                  "RUNTIME_ERROR": {"error"}, "PHASE": {"label"},
                  "END": {"rc", "violations", "setup_error"}}
        if not isinstance(record, dict) or record.get("kind") not in fields:
            raise EvidenceError("malformed evidence record")
        kind = record["kind"]
        if (set(record) != common | fields[kind] or record["identity"] != self.identity
                or type(record["pid"]) is not int or record["pid"] != self.pid
                or type(record["seq"]) is not int or record["seq"] != len(self.records) + 1):
            raise EvidenceError("wrong evidence identity, digest, pid, sequence or schema")
        if self.end is not None or (not self.records and kind != "START") or (self.records and kind == "START"):
            raise EvidenceError("missing START, duplicate START/END or records after END")
        if kind.endswith("_BEGIN"):
            if not isinstance(record["id"], str) or record["id"] in self.pending:
                raise EvidenceError("invalid evidence transaction")
            self.pending[record["id"]] = kind
        elif kind in ("ALLOW", "SETUP_END"):
            if self.pending.pop(record["id"], None) != ("GUARD_BEGIN" if kind == "ALLOW" else "SETUP_BEGIN"):
                raise EvidenceError("unmatched evidence transaction")
        elif kind == "READY":
            if self.ready or self.pending or self.fatal:
                raise EvidenceError("READY before completed setup")
            self.ready = True
        elif kind == "PHASE":
            if not self.ready or not isinstance(record["label"], str):
                raise EvidenceError("phase before READY")
            self.phases.add(record["label"])
        elif kind in ("DENY", "SETUP_ERROR", "RUNTIME_ERROR"):
            if any(not isinstance(record[key], str) for key in fields[kind]):
                raise EvidenceError("invalid error evidence")
            self.fatal.append(record)
        elif kind == "END":
            if type(record["rc"]) is not int or record["rc"] < 0 or record["violations"] != [] or record["setup_error"] is not None:
                raise EvidenceError("invalid END or END contains violations/setup_error")
            self.end = record
        self.records.append(record)

    def validate(self, rc, summary, stop):
        # Existing summaries and ENDs are checked BEFORE the stop exception.
        if summary is not None:
            if (not isinstance(summary, dict) or summary.get("identity") != self.identity
                    or summary.get("pid") != self.pid or type(summary.get("last_seq")) is not int
                    or summary["last_seq"] != len(self.records) or summary.get("violations") != []
                    or summary.get("setup_error") is not None or type(summary.get("rc")) is not int
                    or summary["rc"] < 0 or summary["rc"] != rc):
                raise EvidenceError("malformed, stale or contradictory final summary")
        if self.end is not None and (self.end["rc"] != rc or summary is None or summary["rc"] != self.end["rc"]):
            raise EvidenceError("END contradicts observation/summary")
        if not self.records or not self.ready or self.pending or self.fatal:
            raise EvidenceError("missing START/READY, pending transaction or sticky error")
        if rc >= 0:
            if self.end is None or summary is None:
                raise EvidenceError("natural exit requires END and final summary")
        elif rc != -signal.SIGKILL or stop is None:
            raise EvidenceError("unexpected death or unplanned cleanup kill")
        elif (stop.get("identity") != self.identity or not stop.get("case") or not stop.get("site")
              or not stop.get("required") or not set(stop["required"]) <= self.phases):
            raise EvidenceError("declared stop lacks mandatory phase witness")


class EvidencePublisher:
    def __init__(self, send, ack, identity):
        self.send_fd, self.ack_fd, self.identity = send, ack, identity
        self.sequence, self.transaction_id = 0, 0
        self.ack_count, self.ack_total_s, self.ack_max_s = 0, 0.0, 0.0
        self.timing_windows = []
        self.active_window = None
        self.lock = threading.RLock()

    def send(self, kind, **fields):
        with self.lock:
            began = time.monotonic()
            self.sequence += 1
            record = dict(identity=self.identity, pid=os.getpid(), seq=self.sequence, kind=kind, **fields)
            timed = self.identity.get("case", "").endswith("-r34")
            if timed:
                # All processes share the host monotonic clock. The parent
                # bounds this timestamp by its receipt clock, then measures
                # through receipt of our acknowledgement confirmation. This
                # includes send/queue/append/ack latency even without a report.
                record["_timing"] = dict(started=began, window=(
                    self.active_window["start"] if self.active_window is not None else None))
            payload = json.dumps(record, separators=(",", ":")).encode() + b"\n"
            if len(payload) > 4096:
                raise EvidenceError("evidence record exceeds atomic pipe frame")
            if not select.select([], [self.send_fd], [], 5)[1] or os.write(self.send_fd, payload) != len(payload):
                raise EvidenceError("broken or stalled evidence collector")
            if not select.select([self.ack_fd], [], [], 5)[0] or os.read(self.ack_fd, 1) != b"+":
                raise EvidenceError("missing appended evidence acknowledgement")
            elapsed = time.monotonic() - began
            if timed:
                confirmation = json.dumps({"acknowledged": self.sequence}).encode() + b"\n"
                if os.write(self.send_fd, confirmation) != len(confirmation):
                    raise EvidenceError("broken evidence acknowledgement confirmation")
            self.ack_count += 1
            self.ack_total_s += elapsed
            self.ack_max_s = max(self.ack_max_s, elapsed)
            if self.active_window is not None:
                window = self.active_window
                window["round_trips"].append((began, began + elapsed))
                window["instrumentation_s"] += elapsed
                if (self.identity.get("case", "").endswith("-r34")
                        and window["instrumentation_s"] > TIMING_INSTRUMENTATION_MAX_S
                        and kind != "RUNTIME_ERROR"):
                    self.send("RUNTIME_ERROR", error="timed-window instrumentation exceeds 250 ms")
                    raise EvidenceError("timed-window instrumentation exceeds 250 ms")

    def begin_timed_window(self, started):
        if self.active_window is not None:
            raise EvidenceError("overlapping timed windows")
        window = dict(start=started, end=None, instrumentation_s=0.0, round_trips=[])
        self.timing_windows.append(window)
        self.active_window = window

    def end_timed_window(self):
        if self.active_window is not None:
            self.active_window["end"] = time.monotonic()
            self.active_window = None

    @contextmanager
    def transaction(self, kind):
        with self.lock:
            self.transaction_id += 1
            token = str(self.transaction_id)
        self.send(kind + "_BEGIN", id=token)
        try:
            yield
        except BaseException as exc:
            # No successful END/ALLOW: an interrupted callback remains pending.
            if kind == "SETUP":
                self.send("SETUP_ERROR", error=type(exc).__name__)
            raise
        else:
            self.send("ALLOW" if kind == "GUARD" else "SETUP_END", id=token)

    def close(self):
        os.close(self.send_fd)
        os.close(self.ack_fd)


class WorkerEvidence:
    """Parent owns the journal, collector, launch identity and stop certificate."""

    def __init__(self, root, worker, source_digest, manifest_digest, case):
        self.identity = dict(worker=worker, token=uuid.uuid4().hex, source=source_digest, manifest=manifest_digest, case=case)
        self.case = case
        self.journal = Path(root) / (worker + ".journal.jsonl")
        self.read, self.send_fd = os.pipe()
        self.ack_fd, self.ack_write = os.pipe()
        self.stop = None
        self.window_started = None
        self.errors = []
        self.eof = threading.Event()
        self.abort = threading.Event()
        self.lock = threading.RLock()
        self.thread = None
        self.state = None
        self.journal_synced = False
        self.timing_pending = None
        self.timing_confirmed = 0
        self.timing_windows = {}

    def attach(self, pid):
        self.state = EvidenceState(self.identity, pid)
        os.close(self.send_fd)
        os.close(self.ack_fd)
        self.thread = threading.Thread(target=self.collect, name="ops327-evidence", daemon=True)
        self.thread.start()

    def collect(self):
        buffer = b""
        try:
            with self.journal.open("xb", buffering=0) as journal:
                while not self.abort.is_set():
                    if not select.select([self.read], [], [], .1)[0]:
                        continue
                    data = os.read(self.read, 8192)
                    if not data:
                        if buffer:
                            raise EvidenceError("truncated evidence frame at EOF")
                        self.eof.set()
                        return
                    buffer += data
                    if len(buffer) > 65536:
                        raise EvidenceError("oversize evidence frame")
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        record = json.loads(line, object_pairs_hook=unique_keys)
                        with self.lock:
                            if self.case.endswith("-r34"):
                                if self.timing_pending is not None:
                                    if record != {"acknowledged": self.timing_pending["seq"]}:
                                        raise EvidenceError("missing evidence acknowledgement confirmation")
                                    certificate = dict(self.timing_pending, confirmed=time.monotonic())
                                    payload = json.dumps({"timing_certificate": certificate}).encode() + b"\n"
                                    if journal.write(payload) != len(payload):
                                        raise EvidenceError("short timing certificate append")
                                    window = certificate["window"]
                                    if window is not None:
                                        self.timing_windows.setdefault(window, []).append(
                                            (certificate["started"], certificate["confirmed"]))
                                    self.timing_confirmed += 1
                                    self.timing_pending = None
                                    continue
                                metadata = record.pop("_timing", None) if isinstance(record, dict) else None
                                received = time.monotonic()
                                if (not isinstance(metadata, dict) or set(metadata) != {"started", "window"}
                                        or type(metadata["started"]) not in (int, float)
                                        or not 0 <= metadata["started"] <= received
                                        or (metadata["window"] is not None and (
                                            type(metadata["window"]) not in (int, float)
                                            or not 0 <= metadata["window"] <= metadata["started"]))):
                                    raise EvidenceError("missing or invalid parent timing metadata")
                                self.timing_pending = dict(metadata, seq=record.get("seq"), received=received)
                            self.state.accept(record)
                            payload = line + b"\n"
                            if journal.write(payload) != len(payload):
                                raise EvidenceError("short evidence journal append")
                            os.write(self.ack_write, b"+")
                raise EvidenceError("evidence drain timeout")
        except BaseException as exc:
            self.errors.append(f"{type(exc).__name__}: {exc}")
        finally:
            os.close(self.read)
            os.close(self.ack_write)

    def open_window(self):
        with self.lock:
            if self.errors or not self.state.ready or "main-entered" not in self.state.phases:
                raise EvidenceError("observation window before acknowledged READY/main-entry")
            self.window_started = time.monotonic()
            with self.journal.with_suffix(".window.json").open("x") as output:
                json.dump(dict(identity=self.identity, case=self.case, seq=len(self.state.records),
                               opened=self.window_started), output)
                output.flush()
                os.fsync(output.fileno())

    def arm(self, site, required):
        with self.lock:
            if self.errors or self.window_started is None or not self.state.ready or not set(required) <= self.state.phases:
                raise EvidenceError(f"stop {site} lacks mandatory witnesses {required}")
            if self.state.pending or self.state.fatal:
                raise EvidenceError("cannot authorize stop with pending admission or sticky error")
            certificate = dict(identity=self.identity, case=self.case, site=site, required=list(required),
                               window_started=self.window_started)
            # Parent persistence precedes signal delivery; cleanup cannot invent it.
            with self.journal.with_suffix(".stop.json").open("x") as output:
                json.dump(certificate, output)
                output.flush()
                os.fsync(output.fileno())
            self.stop = certificate

    def validate(self, process):
        if process.poll() is None:
            raise EvidenceError("worker not reaped")
        self.thread.join(5)
        if self.thread.is_alive():
            self.abort.set()
            self.thread.join(1)
        summary = worker_events(process.events) if process.events.exists() else None
        if self.errors or not self.eof.is_set():
            raise EvidenceError("worker evidence not drained through EOF: " + "; ".join(self.errors))
        with self.lock:
            self.state.validate(process.returncode, summary, self.stop)
        return summary

    def persist(self):
        # Only the worker is threatened by SIGKILL. The surviving parent has
        # already appended every acknowledged record in order. Durability is
        # required once, after ALL case windows, before any outcome is scored.
        # Invalid streams still need the final durability attempt. Do not let
        # schema, append, acknowledgement or EOF errors bypass that attempt.
        # Cleanup/validation may itself have failed before draining a live
        # collector. Stop it independently so it cannot append after fsync.
        if self.thread.is_alive():
            self.thread.join(5)
            if self.thread.is_alive():
                self.abort.set()
                self.thread.join(1)
        if not self.journal_synced:
            with self.journal.open("rb") as journal:
                os.fsync(journal.fileno())
            self.journal_synced = not self.thread.is_alive()
        if self.thread.is_alive() or self.errors or not self.eof.is_set():
            raise EvidenceError("cannot persist an incomplete evidence journal: " + "; ".join(self.errors))

    def certify_timing(self):
        """Parent-held, journalled certification is mandatory even after SIGKILL.

        A completed confirmation conservatively bounds the worker's full RTT.
        A kill before confirmation leaves it pending, never a zero-cost RTT.
        No observed hold/admission (e.g. a startup stop) certifies zero windows.
        """
        with self.lock:
            if (self.thread.is_alive() or self.errors or not self.eof.is_set()
                    or self.timing_pending is not None or not self.state.records
                    or self.timing_confirmed != len(self.state.records)):
                raise EvidenceError("missing parent timing certification")
            totals = []
            for window, intervals in self.timing_windows.items():
                total = sum(end - start for start, end in intervals)
                if total > TIMING_INSTRUMENTATION_MAX_S:
                    raise EvidenceError("parent timed-window instrumentation exceeds 250 ms")
                totals.append(dict(start=window, instrumentation_s=total, round_trips=len(intervals)))
            return totals


def digest(data):
    return hashlib.sha256(data).hexdigest()


def prepare_worker(manifest, *, report=None):
    """Validate the entire closed manifest before loading or creating anything."""
    raw_manifest = Path(repo_path(manifest)).read_bytes()
    data = json.loads(raw_manifest, object_pairs_hook=unique_keys)
    if not isinstance(data, dict) or set(data) != {"source", "paths", "events", "constants"}:
        raise ValueError("top-level keys must be source, paths, events, constants")
    source_bytes = Path(repo_path(data["source"])).read_bytes()
    publisher = getattr(h._EVIDENCE, "current", None)
    if publisher is not None and (digest(raw_manifest) != publisher.identity["manifest"] or
                                  digest(source_bytes) != publisher.identity["source"]):
        raise EvidenceError("launch manifest/source digest changed")
    source = source_bytes.decode()
    events = repo_path(data["events"])
    try:
        paths = checked_paths(source, data["paths"])
    except h.FixtureViolation:
        # The inventory itself executes copied source. A guarded top-level
        # operation must report to the already validated destination too.
        if report is not None:
            report["events"] = events
        raise
    constants = data["constants"]
    if not isinstance(constants, dict) or not set(constants) <= {"RUN_BUDGET_S"}:
        raise ValueError("constants keys may only contain RUN_BUDGET_S")
    for value in constants.values():
        if type(value) is not int:
            raise ValueError("RUN_BUDGET_S must be an int, not bool")
        if not 1 <= value <= 3000:
            raise ValueError("RUN_BUDGET_S must be within 1..3000 seconds")
    # Apart from reporting an inventory guard violation above, invalid
    # manifests create nothing. Normal reports need complete validation.
    if report is not None:
        report["events"] = events
    gc = h.load(source, paths)
    for name, value in constants.items():
        setattr(gc, name, value)
    actual = {name: getattr(gc, name) for name in h.path_constants(source)}
    if checked_paths(source, actual) != paths:
        raise ValueError("loaded path constants differ from the manifest")
    h.check_socket(gc.SOCKET_PATH)
    return gc, events


def instrument_worker(gc, report, publisher):
    original = gc.deploy_locks
    calls_in_hold = 0
    @contextmanager
    def tracked(paths):
        nonlocal calls_in_hold
        report["attempts"].append(time.monotonic())
        with original(paths):
            started = time.monotonic()
            calls_in_hold = 0
            if publisher is not None:
                publisher.begin_timed_window(started)
            try:
                yield
            finally:
                if publisher is not None:
                    publisher.end_timed_window()
                report["holds"].append((started, time.monotonic()))
    gc.deploy_locks = tracked
    if publisher is not None:
        instance = gc.instance_lock
        @contextmanager
        def instance_attempt():
            publisher.send("PHASE", label="instance-attempt")
            with instance():
                yield
        gc.instance_lock = instance_attempt
        destructive = gc.destructive_call
        def destructive_phase(*args, **kwargs):
            nonlocal calls_in_hold
            publisher.send("PHASE", label="destructive-phase")
            calls_in_hold += 1
            try:
                return destructive(*args, **kwargs)
            finally:
                # Through completion of call two is a conservative envelope
                # of hold-entry -> engine receipt of DELETE two. No production
                # clock or deadline is changed; socket waiting adds no RTTs.
                if calls_in_hold == 2:
                    publisher.end_timed_window()
        gc.destructive_call = destructive_phase
    os.environ["INVOCATION_ID"] = "ops327-offline-fixture"
    os.environ["DOCKER_IMAGE_GC_DRY_RUN"] = "0"
    signal.signal(signal.SIGTERM, gc.STOP.set)


def run_worker_main(gc, publisher, api=None):
    if publisher is None:
        return gc.main() if api is None else gc.main(api)
    publisher.send("READY")
    publisher.send("PHASE", label="main-entered")
    def sleep(seconds):
        publisher.send("PHASE", label="cooldown")
        time.sleep(seconds)
    return gc.main(sleep=sleep) if api is None else gc.main(api, sleep=sleep)


def finish_worker_report(events, report, publisher, rc):
    if publisher is not None:
        with publisher.transaction("SETUP"):
            report.update(identity=publisher.identity, pid=os.getpid(), last_seq=publisher.sequence + 2, rc=rc,
                          evidence_transport=dict(count=publisher.ack_count, total_s=publisher.ack_total_s, max_s=publisher.ack_max_s),
                          timing_windows=publisher.timing_windows)
            publish_events(events, report)
        publisher.send("END", rc=rc, violations=report["violations"], setup_error=report.get("setup_error"))
    else:
        publish_events(events, report)


def worker(manifest, publisher=None, api_factory=None):
    report = {"events": None, "holds": [], "attempts": [], "violations": []}
    rc = 2
    if publisher is not None:
        publisher.send("START")
    try:
        with h.evidence_scope(publisher):
            try:
                with publisher.transaction("SETUP") if publisher is not None else nullcontext():
                    gc, events = prepare_worker(manifest, report=report)
                    report["events"] = events
                    report["violations"] = gc.__ops327_fixture_guard__.violations
                    instrument_worker(gc, report, publisher)
                    api = api_factory(gc) if api_factory is not None else None
            except h.FixtureViolation as exc:
                report["violations"] = exc.recorded
                print("fixture audit violation: " + json.dumps(exc.recorded), file=sys.stderr)
                return 2
            except (ValueError, TypeError, KeyError, AttributeError, OSError, SyntaxError, EvidenceError) as exc:
                report["setup_error"] = str(exc).replace("\n", " ")
                print("invalid worker manifest: " + report["setup_error"], file=sys.stderr)
                return 2
            try:
                rc = run_worker_main(gc, publisher, api)
                return rc
            except h.FixtureViolation as exc:
                print("fixture audit violation: " + json.dumps(exc.recorded), file=sys.stderr)
                return 2
    except BaseException as exc:
        report["setup_error"] = f"{type(exc).__name__}: {exc}"
        if publisher is not None:
            publisher.send("RUNTIME_ERROR", error=type(exc).__name__)
        raise
    finally:
        events = report.pop("events")
        try:
            if events is not None:
                finish_worker_report(events, report, publisher, rc)
        finally:
            if publisher is not None:
                publisher.close()


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


def publish_events(path, report):
    # check_workers can observe a still-running worker. Publish a complete
    # report atomically so an empty/partial JSON write cannot look like setup.
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(report))
    temporary.replace(path)


def worker_events(path):
    """A missing/invalid report or guard violation is setup failure, never a kill."""
    try:
        events = json.loads(Path(path).read_text())
        violations = events["violations"]
        if not isinstance(violations, list) or any(
                not isinstance(item, dict) or not all(isinstance(item.get(key), str) for key in ("event", "path"))
                for item in violations):
            raise ValueError("violations must be a list of event/path records")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise RuntimeError(f"worker startup failed: invalid events {path}: {exc}") from exc
    if violations:
        raise RuntimeError("worker fixture audit violation: " + "; ".join(
            f"{item['event']}: {item['path']}" for item in violations))
    if events.get("setup_error") is not None:
        raise RuntimeError(f"worker setup failed: {events['setup_error']}")
    return events


def check_timing_windows(events):
    """Validate worker-monotonic RTT sums, including incomplete decisions.

    Each measured envelope starts at hold entry and ends at completion of the
    second destructive call (or release if fewer). It contains the entire r34
    decision window, including both snapshots and all socket admissions.
    """
    windows = events.get('timing_windows')
    holds = events.get('holds')
    if not isinstance(windows, list) or not isinstance(holds, list) or len(windows) != len(holds):
        raise EvidenceError('missing timed-window instrumentation')
    for window, hold in zip(windows, holds):
        if (not isinstance(window, dict) or set(window) != {'start', 'end', 'instrumentation_s', 'round_trips'}
                or not isinstance(window['round_trips'], list)):
            raise EvidenceError('malformed timed-window instrumentation')
        numbers = [window['start'], window['end'], window['instrumentation_s'], *hold]
        if (len(hold) != 2 or any(type(value) not in (int, float) or not 0 <= value < float('inf') for value in numbers)
                or window['start'] != hold[0] or not hold[0] <= window['end'] <= hold[1]):
            raise EvidenceError('invalid timed-window bounds')
        total, previous = 0.0, window['start']
        for interval in window['round_trips']:
            if (not isinstance(interval, (list, tuple)) or len(interval) != 2
                    or any(type(value) not in (int, float) or not 0 <= value < float('inf') for value in interval)
                    or not previous <= interval[0] <= interval[1] <= window['end']):
                raise EvidenceError('invalid timed-window round trip')
            total += interval[1] - interval[0]
            previous = interval[1]
        if abs(total - window['instrumentation_s']) > 1e-6:
            raise EvidenceError('contradictory timed-window instrumentation sum')
        if total > TIMING_INSTRUMENTATION_MAX_S:
            raise EvidenceError('timed-window instrumentation exceeds 250 ms')


# Revision 9b site IDs are stable original-source locations, not current lines.
# These tables are an explicit launch contract, never inferred from witnesses.
STOP_PLAN = {'delete-hold-bound': {'RT:294': {'proc': ('main-entered',)},
                       'RT:297': {'proc': ('main-entered', 'destructive-phase')},
                       'RT:299': {'proc': ('main-entered', 'destructive-phase')},
                       'RT:300': {'proc': ('main-entered', 'destructive-phase')},
                       'RT:301': {},
                       'RT:302': {},
                       'RT:303': {},
                       'RT:304': {}},
 'prune-hold-bound': {'RT:294': {'proc': ('main-entered',)},
                      'RT:297': {'proc': ('main-entered', 'destructive-phase')},
                      'RT:299': {'proc': ('main-entered', 'destructive-phase')},
                      'RT:300': {'proc': ('main-entered', 'destructive-phase')},
                      'RT:301': {},
                      'RT:302': {},
                      'RT:303': {},
                      'RT:304': {}},
 'maximal-hold': {'RT:317': {'proc': ('main-entered',)},
                  'RT:319': {'proc': ('main-entered', 'destructive-phase')},
                  'RT:320': {'proc': ('main-entered', 'destructive-phase')},
                  'RT:321': {},
                  'RT:322': {},
                  'RT:323': {},
                  'RT:325': {}},
 'between-batches': {'RT:331': {'proc': ('main-entered',)},
                     'RT:333': {'proc': ('main-entered', 'destructive-phase')},
                     'RT:334': {'proc': ('main-entered', 'destructive-phase')},
                     'RT:335': {},
                     'RT:336': {},
                     'RT:337': {}},
 'full-accept-queue': {'RT:377': {},
                       'RT:397': {'pid': ('main-entered', 'connect-start')},
                       'RT:400': {'pid': ('main-entered', 'connect-start')},
                       'RT:401': {'pid': ('main-entered', 'connect-start')},
                       'RT:402': {'pid': ('main-entered', 'connect-start')},
                       'RT:404': {'pid': ('main-entered', 'connect-start')},
                       'RT:411': {'pid': ('main-entered', 'connect-start')},
                       'RT:422': {}},
 'fifo-keep': {'RT:431': {'proc': ('main-entered',)},
               'RT:434': {'proc': ('main-entered',)},
               'RT:435': {'proc': ('main-entered',)},
               'RT:436': {},
               'RT:437': {}},
 'fifo-spec': {'RT:431': {'proc': ('main-entered',)},
               'RT:434': {'proc': ('main-entered',)},
               'RT:435': {'proc': ('main-entered',)},
               'RT:436': {},
               'RT:437': {}},
 'fifo-role': {'RT:431': {'proc': ('main-entered',)},
               'RT:434': {'proc': ('main-entered',)},
               'RT:435': {'proc': ('main-entered',)},
               'RT:436': {},
               'RT:437': {}},
 'never-switch-lock': {'RT:444': {'proc': ('main-entered',)},
                       'RT:447': {'proc': ('main-entered', 'destructive-phase')},
                       'RT:449': {'proc': ('main-entered', 'destructive-phase')}},
 'instance-and-sigkill': {'RT:455': {'first': ('main-entered',)},
                          'RT:457': {'first': ('main-entered', 'destructive-phase'),
                                     'second': ('main-entered', 'instance-attempt')},
                          'RT:458': {'first': ('main-entered', 'destructive-phase')},
                          'RT:459': {'first': ('main-entered', 'destructive-phase')},
                          'RT:461': {'first': ('main-entered', 'destructive-phase')},
                          'RT:466': {'third': ('main-entered', 'cooldown')},
                          'RT:467': {'third': ('main-entered', 'cooldown')},
                          'RT:468': {'third': ('main-entered', 'destructive-phase')}},
 'r29': {'RT:480': {'first': ('main-entered',)},
         'RT:485': {'first': ('main-entered', 'destructive-phase')},
         'RT:504': {'first': ('main-entered', 'destructive-phase')},
         'RT:515': {'first': ('main-entered', 'destructive-phase')},
         'RT:525': {},
         'RT:529': {}},
 'r30': {'RT:480': {'first': ('main-entered',)},
         'RT:485': {'first': ('main-entered', 'destructive-phase')},
         'RT:492': {'first': ('main-entered', 'destructive-phase')},
         'RT:504': {'first': ('main-entered', 'destructive-phase')},
         'RT:515': {'first': ('main-entered', 'destructive-phase')},
         'RT:525': {},
         'RT:529': {}},
 'r29-adversarial': {'RT:480': {'first': ('main-entered',)},
                     'RT:485': {'first': ('main-entered', 'destructive-phase')},
                     'RT:500': {'first': ('main-entered', 'destructive-phase')},
                     'RT:504': {'first': ('main-entered', 'destructive-phase')},
                     'RT:513': {'first': ('main-entered', 'destructive-phase')},
                     'RT:515': {'first': ('main-entered', 'destructive-phase')},
                     'RT:518': {},
                     'RT:525': {},
                     'RT:529': {}},
 'r30-adversarial': {'RT:480': {'first': ('main-entered',)},
                     'RT:485': {'first': ('main-entered', 'destructive-phase')},
                     'RT:492': {'first': ('main-entered', 'destructive-phase')},
                     'RT:500': {'first': ('main-entered', 'destructive-phase')},
                     'RT:504': {'first': ('main-entered', 'destructive-phase')},
                     'RT:513': {'first': ('main-entered', 'destructive-phase')},
                     'RT:515': {'first': ('main-entered', 'destructive-phase')},
                     'RT:518': {},
                     'RT:525': {},
                     'RT:529': {}},
 'across-runs': {'RT:480': {'first': ('main-entered',)},
                 'RT:485': {'first': ('main-entered', 'destructive-phase')},
                 'RT:487': {'first': ('main-entered', 'destructive-phase')},
                 'RT:504': {'next_run': ('main-entered', 'cooldown')},
                 'RT:508': {'next_run': ('main-entered', 'cooldown')},
                 'RT:510': {},
                 'RT:525': {},
                 'RT:529': {}},
 'four-acquisitions': {'RT:557': {},
                       'RT:565': {'proc': ('main-entered',)},
                       'RT:577': {'proc': ('main-entered', 'destructive-phase')},
                       'RT:578': {'proc': ('main-entered', 'destructive-phase')},
                       'RT:579': {'proc': ('main-entered', 'destructive-phase')},
                       'RT:574': {'proc': ('main-entered', 'destructive-phase')},
                       'RT:585': {}},
 'maximal-hold-r34': {'RT:317': {'proc': ('main-entered',)},
                      'RT:319': {'proc': ('main-entered', 'destructive-phase')},
                      'RT:320': {'proc': ('main-entered', 'destructive-phase')},
                      'RT:321': {},
                      'RT:322': {},
                      'RT:323': {},
                      'RT:325': {}},
 'r29-r34': {'RT:480': {'first': ('main-entered',)},
             'RT:485': {'first': ('main-entered', 'destructive-phase')},
             'RT:504': {'first': ('main-entered', 'destructive-phase')},
             'RT:515': {'first': ('main-entered', 'destructive-phase')},
             'RT:520': {},
             'RT:521': {},
             'RT:525': {},
             'RT:529': {}},
 'r30-r34': {'RT:480': {'first': ('main-entered',)},
             'RT:485': {'first': ('main-entered', 'destructive-phase')},
             'RT:492': {'first': ('main-entered', 'destructive-phase')},
             'RT:504': {'first': ('main-entered', 'destructive-phase')},
             'RT:515': {'first': ('main-entered', 'destructive-phase')},
             'RT:520': {},
             'RT:521': {},
             'RT:525': {},
             'RT:529': {}},
 'r29-adversarial-r34': {'RT:480': {'first': ('main-entered',)},
                         'RT:485': {'first': ('main-entered', 'destructive-phase')},
                         'RT:500': {'first': ('main-entered', 'destructive-phase')},
                         'RT:504': {'first': ('main-entered', 'destructive-phase')},
                         'RT:513': {'first': ('main-entered', 'destructive-phase')},
                         'RT:515': {'first': ('main-entered', 'destructive-phase')},
                         'RT:518': {},
                         'RT:520': {},
                         'RT:521': {},
                         'RT:525': {},
                         'RT:529': {}},
 'r30-adversarial-r34': {'RT:480': {'first': ('main-entered',)},
                         'RT:485': {'first': ('main-entered', 'destructive-phase')},
                         'RT:492': {'first': ('main-entered', 'destructive-phase')},
                         'RT:500': {'first': ('main-entered', 'destructive-phase')},
                         'RT:504': {'first': ('main-entered', 'destructive-phase')},
                         'RT:513': {'first': ('main-entered', 'destructive-phase')},
                         'RT:515': {'first': ('main-entered', 'destructive-phase')},
                         'RT:518': {},
                         'RT:520': {},
                         'RT:521': {},
                         'RT:525': {},
                         'RT:529': {}},
 'across-runs-r34': {'RT:480': {'first': ('main-entered',)},
                     'RT:485': {'first': ('main-entered', 'destructive-phase')},
                     'RT:487': {'first': ('main-entered', 'destructive-phase')},
                     'RT:504': {'next_run': ('main-entered', 'cooldown')},
                     'RT:508': {'next_run': ('main-entered', 'cooldown')},
                     'RT:510': {},
                     'RT:520': {},
                     'RT:521': {},
                     'RT:525': {},
                     'RT:529': {}},
 'four-acquisitions-r34': {'RT:557': {},
                           'RT:565': {'proc': ('main-entered',)},
                           'RT:577': {'proc': ('main-entered', 'destructive-phase')},
                           'RT:578': {'proc': ('main-entered', 'destructive-phase')},
                           'RT:579': {'proc': ('main-entered', 'destructive-phase')},
                           'RT:581': {},
                           'RT:582': {},
                           'RT:574': {'proc': ('main-entered', 'destructive-phase')},
                           'RT:585': {}},
 'trickle-delete-status': {'RT:294': {'proc': ('main-entered',)},
                           'RT:297': {'proc': ('main-entered', 'destructive-phase')},
                           'RT:299': {'proc': ('main-entered', 'destructive-phase')},
                           'RT:300': {'proc': ('main-entered', 'destructive-phase')},
                           'RT:301': {},
                           'RT:302': {},
                           'RT:303': {},
                           'RT:304': {}},
 'trickle-delete-header': {'RT:294': {'proc': ('main-entered',)},
                           'RT:297': {'proc': ('main-entered', 'destructive-phase')},
                           'RT:299': {'proc': ('main-entered', 'destructive-phase')},
                           'RT:300': {'proc': ('main-entered', 'destructive-phase')},
                           'RT:301': {},
                           'RT:302': {},
                           'RT:303': {},
                           'RT:304': {}},
 'trickle-delete-chunk-size': {'RT:294': {'proc': ('main-entered',)},
                               'RT:297': {'proc': ('main-entered', 'destructive-phase')},
                               'RT:299': {'proc': ('main-entered', 'destructive-phase')},
                               'RT:300': {'proc': ('main-entered', 'destructive-phase')},
                               'RT:301': {},
                               'RT:302': {},
                               'RT:303': {},
                               'RT:304': {}},
 'trickle-delete-chunk-data': {'RT:294': {'proc': ('main-entered',)},
                               'RT:297': {'proc': ('main-entered', 'destructive-phase')},
                               'RT:299': {'proc': ('main-entered', 'destructive-phase')},
                               'RT:300': {'proc': ('main-entered', 'destructive-phase')},
                               'RT:301': {},
                               'RT:302': {},
                               'RT:303': {},
                               'RT:304': {}},
 'trickle-delete-body': {'RT:294': {'proc': ('main-entered',)},
                         'RT:297': {'proc': ('main-entered', 'destructive-phase')},
                         'RT:299': {'proc': ('main-entered', 'destructive-phase')},
                         'RT:300': {'proc': ('main-entered', 'destructive-phase')},
                         'RT:301': {},
                         'RT:302': {},
                         'RT:303': {},
                         'RT:304': {}},
 'trickle-delete-stream': {'RT:294': {'proc': ('main-entered',)},
                           'RT:297': {'proc': ('main-entered', 'destructive-phase')},
                           'RT:299': {'proc': ('main-entered', 'destructive-phase')},
                           'RT:300': {'proc': ('main-entered', 'destructive-phase')},
                           'RT:301': {},
                           'RT:302': {},
                           'RT:303': {},
                           'RT:304': {}},
 'trickle-post-status': {'RT:294': {'proc': ('main-entered',)},
                         'RT:297': {'proc': ('main-entered', 'destructive-phase')},
                         'RT:299': {'proc': ('main-entered', 'destructive-phase')},
                         'RT:300': {'proc': ('main-entered', 'destructive-phase')},
                         'RT:301': {},
                         'RT:302': {},
                         'RT:303': {},
                         'RT:304': {}},
 'trickle-post-header': {'RT:294': {'proc': ('main-entered',)},
                         'RT:297': {'proc': ('main-entered', 'destructive-phase')},
                         'RT:299': {'proc': ('main-entered', 'destructive-phase')},
                         'RT:300': {'proc': ('main-entered', 'destructive-phase')},
                         'RT:301': {},
                         'RT:302': {},
                         'RT:303': {},
                         'RT:304': {}},
 'trickle-post-chunk-size': {'RT:294': {'proc': ('main-entered',)},
                             'RT:297': {'proc': ('main-entered', 'destructive-phase')},
                             'RT:299': {'proc': ('main-entered', 'destructive-phase')},
                             'RT:300': {'proc': ('main-entered', 'destructive-phase')},
                             'RT:301': {},
                             'RT:302': {},
                             'RT:303': {},
                             'RT:304': {}},
 'trickle-post-chunk-data': {'RT:294': {'proc': ('main-entered',)},
                             'RT:297': {'proc': ('main-entered', 'destructive-phase')},
                             'RT:299': {'proc': ('main-entered', 'destructive-phase')},
                             'RT:300': {'proc': ('main-entered', 'destructive-phase')},
                             'RT:301': {},
                             'RT:302': {},
                             'RT:303': {},
                             'RT:304': {}},
 'trickle-post-body': {'RT:294': {'proc': ('main-entered',)},
                       'RT:297': {'proc': ('main-entered', 'destructive-phase')},
                       'RT:299': {'proc': ('main-entered', 'destructive-phase')},
                       'RT:300': {'proc': ('main-entered', 'destructive-phase')},
                       'RT:301': {},
                       'RT:302': {},
                       'RT:303': {},
                       'RT:304': {}},
 'trickle-post-stream': {'RT:294': {'proc': ('main-entered',)},
                         'RT:297': {'proc': ('main-entered', 'destructive-phase')},
                         'RT:299': {'proc': ('main-entered', 'destructive-phase')},
                         'RT:300': {'proc': ('main-entered', 'destructive-phase')},
                         'RT:301': {},
                         'RT:302': {},
                         'RT:303': {},
                         'RT:304': {}}}
CASE_ENDPOINTS = {'delete-hold-bound': 'RT:304',
 'prune-hold-bound': 'RT:304',
 'maximal-hold': 'RT:325',
 'between-batches': 'RT:337',
 'full-accept-queue': 'RT:422',
 'fifo-keep': 'RT:437',
 'fifo-spec': 'RT:437',
 'fifo-role': 'RT:437',
 'never-switch-lock': 'RT:449',
 'instance-and-sigkill': 'RT:468',
 'r29': 'RT:529',
 'r30': 'RT:529',
 'r29-adversarial': 'RT:529',
 'r30-adversarial': 'RT:529',
 'across-runs': 'RT:529',
 'four-acquisitions': 'RT:585',
 'maximal-hold-r34': 'RT:325',
 'r29-r34': 'RT:529',
 'r30-r34': 'RT:529',
 'r29-adversarial-r34': 'RT:529',
 'r30-adversarial-r34': 'RT:529',
 'across-runs-r34': 'RT:529',
 'four-acquisitions-r34': 'RT:585',
 'trickle-delete-status': 'RT:304',
 'trickle-delete-header': 'RT:304',
 'trickle-delete-chunk-size': 'RT:304',
 'trickle-delete-chunk-data': 'RT:304',
 'trickle-delete-body': 'RT:304',
 'trickle-delete-stream': 'RT:304',
 'trickle-post-status': 'RT:304',
 'trickle-post-header': 'RT:304',
 'trickle-post-chunk-size': 'RT:304',
 'trickle-post-chunk-data': 'RT:304',
 'trickle-post-body': 'RT:304',
 'trickle-post-stream': 'RT:304'}


# Each alternative is a COMPLETE case/site path, including other workers.
# Choose only by satisfaction of every declared witness, never mutant identity
# or the intersection of witnesses left after a behaviour has been bypassed.
STOP_PATHS = {case: {site: (workers,) for site, workers in sites.items()}
              for case, sites in STOP_PLAN.items()}
STOP_PATHS['instance-and-sigkill']['RT:457'] += ({
    'first': ('main-entered', 'destructive-phase'),
    'second': ('main-entered', 'cooldown')},)
for _site in ('RT:466', 'RT:467'):
    STOP_PATHS['instance-and-sigkill'][_site] += ({'third': ('main-entered', 'destructive-phase')},)
for _case in ('across-runs', 'across-runs-r34'):
    for _site in ('RT:504', 'RT:508'):
        STOP_PATHS[_case][_site] += ({'next_run': ('main-entered', 'destructive-phase')},)


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
        self.case = name.split("-", 1)[1]
        if self.case not in STOP_PLAN:
            raise EvidenceError("case has no predeclared endpoint plan")
        self.stop_plan = STOP_PLAN[self.case]

    def engine(self, **kw):
        server = h.Engine(self.paths["SOCKET_PATH"], self.images, self.containers, **kw)
        self.engines.append(server)
        return server

    def register(self, manifest, events, role):
        self.sequence += 1
        evidence = WorkerEvidence(self.root, f"worker-{self.sequence}", digest(self.source.read_bytes()),
                                  digest(manifest.read_bytes()), self.case)
        return evidence

    def start(self, constants=None):
        index = self.sequence + 1
        manifest = self.root / f"worker-{index}.json"
        events = self.root / f"events-{index}.json"
        manifest.write_text(json.dumps({"source": str(self.source), "paths": self.paths,
                                        "events": str(events), "constants": constants or {}}))
        role = ("first", "second", "third")[index-1] if self.case == "instance-and-sigkill" else (
            "next_run" if self.case.startswith("across-runs") and index == 2 else
            "first" if self.case in {"r29", "r30", "r29-adversarial", "r30-adversarial", "r29-r34", "r30-r34", "r29-adversarial-r34", "r30-adversarial-r34"} or self.case.startswith("across-runs") else "proc")
        evidence = self.register(manifest, events, role)
        try:
            process = subprocess.Popen([sys.executable, "-B", str(Path(__file__).resolve()), "--worker", str(manifest),
                                       "--evidence", str(evidence.send_fd), str(evidence.ack_fd), json.dumps(evidence.identity)],
                                       pass_fds=(evidence.send_fd, evidence.ack_fd),
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        except BaseException:
            for fd in (evidence.read, evidence.send_fd, evidence.ack_fd, evidence.ack_write):
                os.close(fd)
            raise
        process.events, process.evidence, process.role = events, evidence, role
        self.processes.append(process)
        evidence.attach(process.pid)
        self.await_ready(process)
        return process

    def await_ready(self, process):
        evidence = process.evidence
        until = time.monotonic() + 5
        while time.monotonic() < until:
            if evidence.errors:
                raise EvidenceError("worker startup failed: " + "; ".join(evidence.errors))
            if process.events.exists():
                worker_events(process.events)
            with evidence.lock:
                if evidence.state.ready and "main-entered" in evidence.state.phases:
                    evidence.open_window()
                    return
            if process.poll() is not None:
                evidence.validate(process)
                raise EvidenceError("worker startup ended before main-entry")
            time.sleep(.01)
        raise EvidenceError("worker startup timeout before READY/main-entry")

    def stop_at(self, site):
        if site not in self.stop_plan:
            raise EvidenceError(f"undeclared case observation site {site}")
        subjects = {process.role: process for process in self.processes if hasattr(process, "evidence")}
        live = [process for process in self.processes if hasattr(process, "evidence") and process.poll() is None]
        paths = STOP_PATHS[self.case][site]
        complete = [path for path in paths if all(process.role in path
                            and set(path[process.role]) <= process.evidence.state.phases for process in live)
                    and all(role in subjects and required
                            and set(required) <= subjects[role].evidence.state.phases
                            for role, required in path.items())]
        if not complete:
            raise EvidenceError(f"stop {site} has no complete predeclared evidence path")
        path = complete[0]
        # Arm ALL live workers before signalling any of them. A certificate
        # still checks READY, pending transactions, sticky errors and identity.
        for process in live:
            required = path[process.role]
            if process.evidence.stop is None:
                process.evidence.arm(site, required)
        for process in live:
            process.kill()

    def require(self, site, condition, message="case assertion failed"):
        if not condition:
            self.stop_at(site)
            raise CaseFailure(message)

    def wait_for(self, site, predicate, seconds, label):
        try:
            return wait_for(predicate, seconds, label)
        except CaseFailure:
            self.stop_at(site)
            raise

    def finish(self, process, timeout=100, expected=0, *, site=None):
        try:
            out, err = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            if process.events.exists():
                worker_events(process.events)
            if site is None:
                raise EvidenceError("finish watchdog has no declared site") from None
            self.stop_at(site)
            out, err = process.communicate(timeout=5)
            process.evidence.validate(process)
            raise CaseFailure(f"GC watchdog after {timeout}s: {out} {err}") from None
        # The journal is mandatory for every scored worker; reports are secondary.
        events = worker_events(process.events) if process.events.exists() else None
        if not isinstance(getattr(process, "evidence", None), WorkerEvidence):
            raise EvidenceError("worker startup failed: no registered evidence stream")
        process.evidence.validate(process)
        if process.returncode != expected and site is not None:
            self.stop_at(site)
        require(process.returncode == expected, (process.returncode, out, err))
        return events, out + err

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
        errors = []
        for proc in self.processes:
            if not hasattr(proc, "events"):
                continue
            try:
                # Always reject an existing bad summary, even while still live.
                if proc.events.exists():
                    worker_events(proc.events)
                if not isinstance(getattr(proc, "evidence", None), WorkerEvidence):
                    raise EvidenceError("worker startup failed: no registered evidence stream")
                if proc.poll() is not None:
                    proc.evidence.validate(proc)
            except Exception as exc:
                errors.append(str(exc))
        if errors:
            raise EvidenceError("; ".join(errors))

    def finalize_evidence(self):
        # Called only after teardown/reap/drain, outside every case window.
        errors = []
        for process in self.processes:
            if not hasattr(process, "evidence"):
                continue
            try:
                process.evidence.persist()
            except Exception as exc:
                errors.append(str(exc))
            if self.case.endswith('-r34'):
                try:
                    totals = process.evidence.certify_timing()
                    if process.events.exists():
                        check_timing_windows(worker_events(process.events))
                    print(f"timing {self.case} {process.role}: " + json.dumps(totals), flush=True)
                except Exception as exc:
                    errors.append(str(exc))
        if errors:
            raise EvidenceError('; '.join(errors))

    def close(self):
        errors = []
        for proc in self.processes:
            try:
                if proc.poll() is None:
                    if getattr(proc, "owned_group", False):
                        os.killpg(proc.pid, signal.SIGCONT)
                        os.killpg(proc.pid, signal.SIGKILL)
                    else:
                        proc.send_signal(signal.SIGCONT)
                        # Reaping for resource ownership grants NO stop authority.
                        proc.kill()
                proc.wait(timeout=5)
                if not hasattr(proc, "events") and proc.returncode not in (0, -signal.SIGKILL):
                    raise EvidenceError(f"auxiliary failed: {proc.returncode}")
            except Exception as exc:
                errors.append(str(exc))
            finally:
                for pipe in (getattr(proc, "stdout", None), getattr(proc, "stderr", None)):
                    if pipe:
                        try: pipe.close()
                        except Exception as exc: errors.append(str(exc))
        for server in self.engines:
            try: server.close()
            except Exception as exc: errors.append(str(exc))
        # Independent final drain even if a wait, close or engine teardown failed.
        try: self.check_workers()
        except Exception as exc: errors.append(str(exc))
        if errors:
            raise EvidenceError("; ".join(errors))


def deadline(lane, *, method='DELETE', phase=None, delay=600):
    if method == 'POST':
        lane.images[:] = lane.images[:2]
    engine = lane.engine(delay=delay, phase=phase)
    proc = lane.start()
    lane.require('RT:294', engine.sent.wait(55), 'no destructive call after initial cooldown')
    sent = engine.destructive[0][2]
    contender = lane.contender()
    acquired = float(lane.wait_for('RT:297', lambda: contender.acquired.read_text() if contender.acquired.exists() else None, 31 if phase else 45, 'deadline contender'))
    lane.require('RT:299', acquired - sent <= (31 if phase else 45), acquired - sent)
    events, output = lane.finish(proc, 5, 2, site='RT:300')
    lane.require('RT:301', 'not answered in 30 s' in output, output)
    lane.require('RT:302', events['holds'][-1][1] - sent <= 31)
    lane.require('RT:303', len(engine.destructive) == 1, engine.destructive)
    lane.require('RT:304', contender.wait(timeout=5) == 0)


def maximal(lane, *, r34=False):
    engine = lane.engine(delay=[9, 29, 29] if r34 else [5, 24, 24])
    proc = lane.start({'RUN_BUDGET_S': 55})
    lane.require('RT:317', engine.sent.wait(55))
    contender = lane.contender()
    lane.wait_for('RT:319', lambda: contender.acquired.exists(), 45, 'maximal hold')
    events, _ = lane.finish(proc, 50, site='RT:320')
    lane.require('RT:321', max((end - start for start, end in events['holds'])) <= 45, events)
    lane.require('RT:322', float(contender.acquired.read_text()) - events['holds'][0][0] <= 45)
    lane.require('RT:323', len(engine.destructive) >= 2, engine.destructive)
    decision = engine.destructive[1][2] - events['holds'][0][0]
    lane.require('RT:325', 8.9 <= decision <= 10.1 if r34 else 3 <= decision <= 10, decision)


def between(lane):
    engine = lane.engine(delay=[11, 0])
    proc = lane.start({'RUN_BUDGET_S': 110})
    lane.require('RT:331', engine.sent.wait(55))
    contender = lane.contender(hold=3)
    lane.wait_for('RT:333', lambda: contender.acquired.exists(), 45, 'between-batch waiter')
    events, _ = lane.finish(proc, 100, site='RT:334')
    lane.require('RT:335', len(events['holds']) >= 2, events)
    lane.require('RT:336', events['holds'][1][0] - events['holds'][0][1] >= 45, events)
    lane.require('RT:337', float(contender.acquired.read_text()) < events['holds'][1][0])


def backlog_worker(gc, api, root):
    report = {"violations": gc.__ops327_fixture_guard__.violations}
    rc = None
    try:
        os.environ["INVOCATION_ID"] = "ops327-backlog"
        os.environ["DOCKER_IMAGE_GC_DRY_RUN"] = "0"
        signal.signal(signal.SIGTERM, gc.STOP.set)
        rc = gc.main(api)
        return rc
    except h.FixtureViolation as exc:
        report["violations"] = exc.recorded
        return 2
    except BaseException as exc:
        report["setup_error"] = f"{type(exc).__name__}: {exc}"
        return 2
    finally:
        publish_events(root / "backlog.events.json", report)
        if rc is not None:
            Path(root / "backlog.result").write_text(str(rc))


class ForkProcess:
    """The fork has the same ownership/reap API and evidence as Popen workers."""

    stdout = stderr = None

    def __init__(self, pid, events, evidence):
        self.pid, self.events, self.evidence = pid, events, evidence
        self.role, self.returncode = "pid", None

    def poll(self):
        if self.returncode is None:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.returncode = os.waitstatus_to_exitcode(status)
        return self.returncode

    def wait(self, timeout=5):
        until = time.monotonic() + timeout
        while self.poll() is None:
            if time.monotonic() >= until:
                raise subprocess.TimeoutExpired("backlog worker", timeout)
            time.sleep(.01)
        return self.returncode

    def communicate(self, timeout=5):
        self.wait(timeout)
        return "", ""

    def send_signal(self, sig):
        if self.poll() is None:
            os.kill(self.pid, sig)

    def kill(self):
        self.send_signal(signal.SIGKILL)


def backlog(lane):
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    clients = []
    server.bind(lane.paths["SOCKET_PATH"])
    server.listen(1)
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
        lane.require("RT:377", len(clients) >= 1)
        manifest, events = lane.root / "backlog.manifest.json", lane.root / "backlog.events.json"
        manifest.write_text(json.dumps({"source": str(lane.source), "paths": lane.paths,
                                        "events": str(events), "constants": {}}))
        evidence = lane.register(manifest, events, "pid")
        # Registration/channel creation precedes fork; source load is child-only.
        pid = os.fork()
        if pid == 0:
            os.close(evidence.read)
            os.close(evidence.ack_write)
            for client in clients:
                client.close()
            server.close()
            publisher = EvidencePublisher(evidence.send_fd, evidence.ack_fd, evidence.identity)
            def make_api(gc):
                real = gc.docker_api
                def api(method, path, timeout, limit):
                    if method == "GET":
                        return 200, json.dumps(lane.containers if path.startswith("/containers/") else lane.images).encode()
                    publisher.send("PHASE", label="connect-start")
                    return real(method, path, timeout, limit)
                return api
            os._exit(worker(manifest, publisher, make_api))
        process = ForkProcess(pid, events, evidence)
        lane.processes.append(process)
        evidence.attach(pid)
        lane.await_ready(process)
        def started():
            if events.exists():
                worker_events(events)
            if evidence.errors:
                raise EvidenceError("; ".join(evidence.errors))
            with evidence.lock:
                return "connect-start" in evidence.state.phases
        lane.wait_for("RT:397", started, 55, "backlog destructive connect starts")
        contender = lane.contender()
        began = time.monotonic()
        lane.wait_for("RT:400", lambda: contender.acquired.exists(), 31, "full accept queue contender")
        lane.require("RT:401", float(contender.acquired.read_text()) - began <= 31)
        lane.finish(process, 3, 2, site="RT:402")
        # The only queued connections were the prefill: no HTTP request.
        server.settimeout(1)
        for _ in clients:
            conn, _ = server.accept()
            with conn:
                conn.setblocking(False)
                try:
                    lane.require("RT:411", not conn.recv(100), "destructive request reached prefill socket")
                except BlockingIOError:
                    pass
    finally:
        for client in clients:
            client.close()
        server.close()


def fifo(lane, where):
    path = lane.spec if where == 'spec' else Path(lane.paths['KEEP_DIR']) / ('aeon-live.refs' if where == 'role' else 'stuck.refs')
    if path.exists():
        path.unlink()
    os.mkfifo(path)
    engine = lane.engine()
    proc = lane.start()
    lane.wait_for('RT:431', lambda: engine.calls, 55, 'FIFO snapshot starts')
    began = engine.calls[0][2]
    contender = lane.contender()
    lane.wait_for('RT:434', lambda: contender.acquired.exists(), 5, 'FIFO contender')
    _, output = lane.finish(proc, 5, 2, site='RT:435')
    lane.require('RT:436', time.monotonic() - began < 5)
    lane.require('RT:437', 'not a regular file' in output, output)


def never_switch_lock(lane):
    Path(lane.paths['SWITCH_LOCK']).touch()
    engine = lane.engine(delay=5)
    proc = lane.start({'RUN_BUDGET_S': 55})
    lane.require('RT:444', engine.sent.wait(55))
    for _ in range(25):
        result = subprocess.run(['flock', '-n', lane.paths['SWITCH_LOCK'], 'true'], check=False)
        lane.require('RT:447', result.returncode == 0, 'GC locked the switch lock')
        time.sleep(0.02)
    lane.finish(proc, 50, site='RT:449')


def instance(lane):
    engine = lane.engine(delay=600)
    first = lane.start()
    lane.require('RT:455', engine.sent.wait(55))
    second = lane.start()
    events, output = lane.finish(second, 5, site='RT:457')
    lane.require('RT:458', 'another run is in progress' in output)
    lane.require('RT:459', not events['attempts'])
    lane.stop_at('RT:461')
    first.wait(timeout=5)
    restarted_at = time.monotonic()
    third = lane.start()
    time.sleep(40)
    lane.require('RT:466', len(engine.destructive) == 1)
    lane.wait_for('RT:467', lambda: len(engine.destructive) > 1, 10, 'post-SIGKILL first attempt')
    lane.require('RT:468', engine.destructive[1][2] - restarted_at >= 45)
    lane.stop_at('RT:468')


def schedules(lane, *, extra=False, across=False, adversarial=False, r34=False):
    engine = lane.engine(delay=[9, 29, 9, 29] if r34 else [5, 24, 5, 24])
    first = lane.start({'RUN_BUDGET_S': 55 if across else 300 if adversarial else 180})
    lane.require('RT:480', engine.sent.wait(55))
    b = lane.contender(hold=50 if adversarial else 7 if r34 else 5, prefix='B')
    a = lane.contender(prefix='A')
    a.send_signal(signal.SIGSTOP)
    lane.wait_for('RT:485', lambda: b.acquired.exists(), 45, 'B wins first release')
    if across:
        first_events, _ = lane.finish(first, 5, site='RT:487')
    b.wait(timeout=60)
    if extra:
        c = lane.contender(hold=0.5, prefix='C')
        lane.wait_for('RT:492', lambda: c.acquired.exists(), 3, "C's intervening hold")
        c.wait(timeout=3)
    if across:
        next_run = lane.start({'RUN_BUDGET_S': 90})
    if adversarial:
        lane.wait_for('RT:500', lambda: len(engine.destructive) >= 3, 100, 'next GC hold inside A wait')
    else:
        time.sleep(8)
    a.send_signal(signal.SIGCONT)
    lane.wait_for('RT:504', lambda: a.acquired.exists(), 50, 'A after B/C')
    acquired = float(a.acquired.read_text())
    a.wait(timeout=5)
    if across:
        later_events, _ = lane.finish(next_run, 140, site='RT:508')
        holds = first_events['holds'] + later_events['holds']
        lane.require('RT:510', later_events['attempts'][0] - first_events['holds'][-1][1] >= 45)
    else:
        if adversarial:
            lane.require('RT:513', first.poll() is None, 'GC exited before adversarial SIGTERM')
        first.send_signal(signal.SIGTERM)
        events, _ = lane.finish(first, 40, 1, site='RT:515')
        holds = events['holds']
    if adversarial:
        lane.require('RT:518', len(holds) >= 2, ('adversarial bound needs two GC holds', holds))
    if r34:
        lane.require('RT:520', 8.9 <= engine.destructive[1][2] - holds[0][0] <= 10.1)
        lane.require('RT:521', all((end - start <= 45 for start, end in holds)), holds)
    began = engine.destructive[0][2]
    w = acquired - began
    g = sum((max(0, min(end, acquired) - max(start, began)) for start, end in holds))
    lane.require('RT:525', g <= 45 + (w - g) + 0.2, {'W': w, 'G': g, 'holds': holds})
    if adversarial:
        print(f'adversarial bound checked: W={w:.3f} G={g:.3f} holds={len(holds)}', flush=True)
    if not adversarial:
        lane.require('RT:529', acquired < holds[1][0] if len(holds) > 1 else True)


def four_acquisitions(lane, *, r34=False):
    script = lane.root / 'hausv-user.sh'
    script.write_text('#!/usr/bin/env bash\nset -eu\nstopped=1\nacquire() {\n  n=$(cat "$1/count"); n=$((n+1)); echo "$n" > "$1/count"\n  echo "$n" > "$1/ready"\n  while [ ! -f "$1/go-$n" ]; do sleep 0.02; done\n  flock -w 570 "$2" python3 -c \'import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text(str(time.monotonic()))\' "$1/got-$n"\n}\nrestart() { if [ "$stopped" = 1 ]; then acquire "$1" "$2"; fi; }\ntrap \'restart "$1" "$2"\' EXIT HUP INT TERM\nacquire "$1" "$2"\nacquire "$1" "$2"\nstopped=0\n')
    (lane.root / 'count').write_text('0')
    user = subprocess.Popen(['bash', str(script), str(lane.root), lane.paths['LOCK_PATHS'][0]], start_new_session=True)
    user.owned_group = True
    lane.processes.append(user)
    last_release = None
    for n in range(1, 5):
        lane.wait_for('RT:557', lambda: (lane.root / 'ready').read_text().strip() == str(n) if (lane.root / 'ready').exists() else False, 10, f'acquisition {n} ready')
        if last_release is not None:
            time.sleep(max(0, last_release + 45 - time.monotonic()))
        lane.paths['SOCKET_PATH'] = str(lane.root / f'engine-{n}.sock')
        engine = lane.engine(delay=[9, 29, 29] if r34 else [5, 24, 24])
        proc = lane.start({'RUN_BUDGET_S': 55})
        lane.require('RT:565', engine.sent.wait(55))
        began = time.monotonic()
        (lane.root / f'go-{n}').touch()
        if n == 2:
            time.sleep(0.1)
            os.killpg(user.pid, signal.SIGTERM)
            lane.require('RT:574', time.monotonic() - began <= 45)
        else:
            got = lane.root / f'got-{n}'
            lane.wait_for('RT:577', lambda: got.exists(), 45, f'handler acquisition {n}')
            lane.require('RT:578', float(got.read_text()) - began <= 45)
        events, _ = lane.finish(proc, 45 if n == 2 else 10, site='RT:579')
        if r34:
            lane.require('RT:581', 8.9 <= engine.destructive[1][2] - events['holds'][0][0] <= 10.1)
            lane.require('RT:582', all((end - start <= 45 for start, end in events['holds'])), events)
        last_release = events['holds'][-1][1]
    user.wait(timeout=10)
    lane.require('RT:585', (lane.root / 'count').read_text().strip() == '4')


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
        except h.FixtureViolation as exc:
            error, setup = RuntimeError(str(exc)), True
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
                try:
                    # Re-check after reaping: a worker can report a violation
                    # between the first check and cleanup's signal delivery.
                    lane.check_workers()
                except Exception as exc:
                    error, setup = exc, True
                try:
                    lane.finalize_evidence()
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
    parser.add_argument("--evidence", nargs=3, metavar=("SEND", "ACK", "IDENTITY"))
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
        publisher = EvidencePublisher(int(args.evidence[0]), int(args.evidence[1]), json.loads(args.evidence[2])) if args.evidence else None
        return worker(args.worker, publisher)
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
