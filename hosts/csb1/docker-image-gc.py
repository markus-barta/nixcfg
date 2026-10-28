"""Docker image and build-cache GC for csb1 (OPS-327, design round 5).

`docker image prune --all` and `docker system prune -a` are off limits here: they
drop images that rollbacks and the Janus engine pipeline depend on, and the
latter also takes the unmounted Janus volumes (csb1 never-prune rule).

Protection is a pure function of one snapshot. An image is protected if any holds:
  1. a container uses it, in any state;
  2. a compose spec of a NixOS system on disk names it: every system-*-link
     generation, the running and the booted system;
  3. keep.d names it (the release kit's role and staged files);
  4. it is among the newest KEEP_NEWEST of a repository it is tagged or pulled by digest in;
  5. it is younger than KEEP_DAYS (by build time);
  6. it is tagged *:rollback, is the newest prev-* of its repository, or is in a Janus repository;
  7. the Nix-declared compose spec names it (DECLARED_REFS).
Every reference is resolved against the snapshot's own listing; nothing carries over.

Release baseline (keep.d contract v2, OPS-327): nothing at all is deleted unless
aeon-live.refs and aeon-previous.refs exist, parse, are non-empty and differ, and
aeon-live.refs names the image of every running AEON container. The release kit is the
authority on which release is previous; the GC checks what it can and fails closed.

Deletes run under the compose deploy locks, taken non-blocking (release all and retry
for LOCK_WAIT_S, then skip the day), in batches of BATCH_S. Before every DELETE the GC
takes a complete fresh snapshot (t0 just before its first request), plans from it, and
deletes only if the image is still deletable and the snapshot is at most
SNAPSHOT_MAX_AGE_S old. DELETE /images/<id>?noprune=1: by ID, never forced, never
untagged, no client timeout (a 409 keeps the image). GETs end at a watchdog. Inputs are
capped per item and per snapshot; a cap reached stops the run before any delete.
Everything comes from the Engine API list endpoints over the docker socket (no inspect).

Real deletes only under systemd (INVOCATION_ID); any other run, or
DOCKER_IMAGE_GC_DRY_RUN=1, lists what would go and changes nothing.
"""

from __future__ import annotations

import errno
import fcntl
import http.client
import json
import os
import re
import signal
import socket
import sys
import time
import urllib.parse
from contextlib import contextmanager

SOCKET_PATH = "/var/run/docker.sock"
DECLARED_REFS: list[str] = json.loads(r"""@DECLARED_REFS@""")
PROTECTED_REPOS = frozenset(
    {
        "ghcr.io/inspr-at/janus/janus-engine",
        "ghcr.io/inspr-at/janus/janus-envelope",
    }
)
AEON_REPO = "ghcr.io/inspr-at/aeon"
KEEP_DIR = "/var/lib/docker-image-gc/keep.d"
LIVE_REFS = "aeon-live.refs"
PREVIOUS_REFS = "aeon-previous.refs"
KEEP_LINE = re.compile(r"^[^\s@]+@sha256:[0-9a-f]{64}$")
PROFILES_DIR = "/nix/var/nix/profiles"
GENERATION = re.compile(r"^system-(\d+)-link$")
CURRENT_SYSTEM = "/run/current-system"
BOOTED_SYSTEM = "/run/booted-system"
COMPOSE_DIR = "etc/compose"
# Every compose deploy path on csb1 serializes on one of these (flock -w), the activation's
# compose reconcile included. Never a lock that anyone takes non-blocking: the Janus Pharos
# lock (flock -n) and /run/nixos/switch-to-configuration.lock (switch-to-configuration takes
# it with LockExclusiveNonblock and dies when it is held) would make those fail.
LOCK_PATHS = (
    "/run/lock/compose-csb1.lock",
    "/run/lock/compose-hausv.lock",
    "/run/lock/compose-hausv-next.lock",
)
LOCK_WAIT_S = 300
BATCH_S = 60
SNAPSHOT_MAX_AGE_S = 2.0
SLOW_SNAPSHOTS = 3
GET_WATCHDOG_S = 30

MIB = 1024 * 1024
# Per item.
CAP_CONTAINERS_BYTES = 4 * MIB
CAP_IMAGES_BYTES = 16 * MIB
CAP_KEEP_FILE_BYTES = 64 * 1024
CAP_KEEP_FILES = 64
CAP_SPEC_BYTES = 1 * MIB
CAP_RESPONSE_BYTES = 64 * 1024
# Per snapshot; each distinct store path counts once.
CAP_GENERATIONS = 200
CAP_SPECS_PER_SYSTEM = 16
CAP_SPEC_BYTES_TOTAL = 64 * MIB
CAP_REFS = 100_000
CAP_DIR_ENTRIES = 5_000


class Fatal(Exception):
    """The run cannot judge safely; nothing more is removed."""


class CapExceeded(Fatal):
    """An input is larger than its cap."""


class Busy(Exception):
    """A deploy holds a compose lock for LOCK_WAIT_S; this run skips the day."""


class Stopped(Exception):
    """SIGTERM: stop after the call in flight."""


class BatchOver(Exception):
    """The batch budget is spent: no new operation, give the locks back."""


class Interrupted(BatchOver):
    """The watchdog ended a GET."""


class StopFlag:
    """Set by SIGTERM. The handler only sets it, so a call in flight finishes."""

    def __init__(self) -> None:
        self.set_ = False

    def set(self, *_args) -> None:
        self.set_ = True

    def __bool__(self) -> bool:
        return self.set_


STOP = StopFlag()


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path: str, timeout: float | None) -> None:
        super().__init__("localhost", timeout=timeout)
        self.unix_path = path

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        sock.connect(self.unix_path)
        self.sock = sock


def docker_api(method: str, path: str, timeout: float | None, limit: int) -> tuple[int, bytes]:
    """One Engine call; reads at most limit + 1 bytes of the answer. timeout None blocks."""
    conn = UnixHTTPConnection(SOCKET_PATH, timeout=timeout)
    try:
        conn.request(method, path)
        res = conn.getresponse()
        return res.status, res.read(limit + 1)
    finally:
        conn.close()


class Budget:
    """The batch deadline. check() runs between every request, read, enumeration and step."""

    def __init__(self, seconds: float) -> None:
        self.deadline = time.monotonic() + seconds

    def left(self) -> float:
        return self.deadline - time.monotonic()

    def check(self) -> None:
        if self.left() <= 0:
            raise BatchOver()


@contextmanager
def watchdog(seconds: float):
    """Raise Interrupted in a GET still running after seconds, even one that keeps trickling."""

    def fire(signum, frame):
        raise Interrupted()

    previous = signal.signal(signal.SIGALRM, fire)
    signal.setitimer(signal.ITIMER_REAL, max(seconds, 0.001))
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def get_json(api, path: str, cap: int, budget: Budget):
    budget.check()
    seconds = min(GET_WATCHDOG_S, budget.left())
    with watchdog(seconds):
        status, body = api("GET", path, timeout=seconds, limit=cap)
    if len(body) > cap:
        raise CapExceeded(f"GET {path}: answer larger than {cap} bytes")
    if status != 200:
        raise Fatal(f"GET {path} -> {status}: {body[:200]!r}")
    budget.check()
    return json.loads(body)


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, str(default))
    if not raw.isdigit() or int(raw) < 1:
        raise Fatal(f"{name}={raw!r} is not a positive integer")
    return int(raw)


def tags_of(image: dict) -> list[str]:
    return [t for t in image.get("RepoTags") or [] if t and not t.startswith("<none>")]


def digests_of(image: dict) -> list[str]:
    return [d for d in image.get("RepoDigests") or [] if d and not d.startswith("<none>")]


def repo_of_tag(tag: str) -> str:
    name, sep, last = tag.rpartition(":")
    # "registry:5000/app" has no tag: the colon belongs to the host part.
    return name if sep and "/" not in last else tag


def repositories(image: dict) -> set[str]:
    return {repo_of_tag(t) for t in tags_of(image)} | {d.split("@", 1)[0] for d in digests_of(image)}


class Index:
    """Resolves references against one listing: name[:tag], name[:tag]@sha256:<digest>, sha256:<id>."""

    def __init__(self, images: list[dict]) -> None:
        self.ids = {i["Id"] for i in images}
        self.by_tag: dict[str, set[str]] = {}
        self.by_digest: dict[str, set[str]] = {}
        for image in images:
            for tag in tags_of(image):
                self.by_tag.setdefault(tag, set()).add(image["Id"])
            for ref in digests_of(image):
                digest = ref.partition("@")[2]
                if digest:
                    self.by_digest.setdefault(digest, set()).add(image["Id"])

    def resolve(self, ref: str) -> set[str]:
        name, _, digest = ref.partition("@")
        if digest:
            return self.by_digest.get(digest, set())
        if name.startswith("sha256:"):
            return {name} & self.ids
        if repo_of_tag(name) == name:
            name += ":latest"
        return self.by_tag.get(name, set())


class Reader:
    """Local reads for one snapshot, with the deadline and the per-snapshot caps.

    Nothing is cached beyond this snapshot. Within it, a spec file is read once per distinct
    store path (generations share them).
    """

    def __init__(self, budget: Budget) -> None:
        self.budget = budget
        self.entries = 0
        self.spec_bytes = 0
        self.refs = 0
        self.specs: dict[str, dict[str, str]] = {}

    def listdir(self, path: str) -> list[str]:
        self.budget.check()
        names = []
        with os.scandir(path) as it:
            for entry in it:
                self.entries += 1
                if self.entries > CAP_DIR_ENTRIES:
                    raise CapExceeded(f"more than {CAP_DIR_ENTRIES} directory entries")
                names.append(entry.name)
        self.budget.check()
        return names

    def read(self, path: str, cap: int) -> bytes:
        self.budget.check()
        with open(path, "rb") as fh:
            data = fh.read(cap + 1)
        if len(data) > cap:
            raise CapExceeded(f"{path} is larger than {cap} bytes")
        self.budget.check()
        return data

    def count_refs(self, n: int) -> None:
        self.refs += n
        if self.refs > CAP_REFS:
            raise CapExceeded(f"more than {CAP_REFS} image references")

    def compose_services(self, system: str) -> dict[str, str]:
        """{stack/service: image} of one NixOS system. No etc/compose (or a vanished system) declares nothing."""
        compose = os.path.join(system, COMPOSE_DIR)
        try:
            stacks = sorted(self.listdir(compose))
        except FileNotFoundError:
            return {}
        if len(stacks) > CAP_SPECS_PER_SYSTEM:
            raise CapExceeded(f"{compose}: more than {CAP_SPECS_PER_SYSTEM} compose specs")
        services: dict[str, str] = {}
        for stack in stacks:
            path = os.path.join(compose, stack, "docker-compose.yml")
            self.budget.check()
            real = os.path.realpath(path)
            if real not in self.specs:
                data = self.read(path, CAP_SPEC_BYTES)
                self.spec_bytes += len(data)
                if self.spec_bytes > CAP_SPEC_BYTES_TOTAL:
                    raise CapExceeded(f"more than {CAP_SPEC_BYTES_TOTAL} bytes of compose specs")
                spec = json.loads(data)  # rendered by builtins.toJSON
                self.budget.check()
                if not isinstance(spec, dict) or not isinstance(spec.get("services"), dict):
                    raise Fatal(f"{path}: no services map")
                found = {
                    name: service["image"]
                    for name, service in spec["services"].items()
                    if isinstance(service, dict) and isinstance(service.get("image"), str)
                }
                self.count_refs(len(found))
                self.specs[real] = found
            services.update({f"{stack}/{name}": image for name, image in self.specs[real].items()})
        return services

    def systems(self) -> list[tuple[str, dict[str, str]]]:
        """[(system, services)]: generations oldest first, then the running and the booted system."""
        found = sorted((int(m.group(1)), name) for name in self.listdir(PROFILES_DIR) if (m := GENERATION.match(name)))
        if len(found) > CAP_GENERATIONS:
            raise CapExceeded(f"more than {CAP_GENERATIONS} NixOS generations")
        paths = [os.path.join(PROFILES_DIR, name) for _, name in found]
        paths += [p for p in (CURRENT_SYSTEM, BOOTED_SYSTEM) if os.path.lexists(p)]
        systems = [(path, self.compose_services(path)) for path in paths]
        if not any(services for _, services in systems):
            raise Fatal("no compose spec found in any NixOS system; refusing to judge")
        return systems

    def keep(self) -> dict[str, list[str]]:
        """{file: refs} of keep.d/*.refs: one name[:tag]@sha256:<digest> per line, # comments and blanks allowed."""
        try:
            names = self.listdir(KEEP_DIR)
        except FileNotFoundError:
            raise Fatal(f"{KEEP_DIR} is missing; refusing to judge") from None
        files = sorted(n for n in names if n.endswith(".refs"))
        if len(files) > CAP_KEEP_FILES:
            raise CapExceeded(f"more than {CAP_KEEP_FILES} keep.d files")
        keep = {}
        for name in files:
            data = self.read(os.path.join(KEEP_DIR, name), CAP_KEEP_FILE_BYTES)
            refs = []
            try:
                lines = data.decode("utf-8").splitlines()
            except UnicodeDecodeError:
                raise Fatal(f"{name}: not UTF-8") from None
            for n, raw in enumerate(lines, start=1):
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if not KEEP_LINE.match(line):
                    raise Fatal(f"{name}:{n}: not a name[:tag]@sha256:<digest> ref: {line[:120]!r}")
                refs.append(line)
            self.count_refs(len(refs))
            keep[name] = refs
        self.budget.check()
        return keep


class Snapshot:
    def __init__(self, t0, containers, images, systems, keep) -> None:
        self.t0 = t0
        self.containers = containers
        self.images = images
        self.systems = systems
        self.keep = keep


def snapshot(api, budget: Budget) -> Snapshot:
    """Listings first, t0 just before the first request; then the local reads."""
    budget.check()
    t0 = time.monotonic()
    containers = get_json(api, "/containers/json?all=1", CAP_CONTAINERS_BYTES, budget)
    images = get_json(api, "/images/json", CAP_IMAGES_BYTES, budget)
    reader = Reader(budget)
    reader.count_refs(len(DECLARED_REFS))
    systems = reader.systems()
    keep = reader.keep()
    return Snapshot(t0, containers, images, systems, keep)


def validate(containers, images) -> None:
    if not isinstance(containers, list) or not isinstance(images, list):
        raise Fatal("container or image listing is not a list")
    if not containers:
        raise Fatal("the daemon lists no containers at all; refusing to judge")
    for c in containers:
        if (
            not isinstance(c, dict)
            or not str(c.get("ImageID", "")).startswith("sha256:")
            or not isinstance(c.get("State"), str)
        ):
            raise Fatal(f"container without a usable ImageID/State: {str(c)[:120]}")
    for i in images:
        if (
            not isinstance(i, dict)
            or not str(i.get("Id", "")).startswith("sha256:")
            or not isinstance(i.get("Created"), int)
        ):
            raise Fatal(f"image without a usable Id/Created: {str(i)[:120]}")
        # Protection reads the names: a listing without them must not read as "untagged".
        for key in ("RepoTags", "RepoDigests"):
            names = i.get(key)
            usable = names is None or (isinstance(names, list) and all(isinstance(n, str) for n in names))
            if key not in i or not usable:
                raise Fatal(f"image {i['Id'][:19]} without a usable {key}: {str(i)[:120]}")


def is_aeon(container: dict, by_id: dict[str, dict]) -> bool:
    image = by_id.get(container["ImageID"])
    if image is not None and AEON_REPO in repositories(image):
        return True
    named = str(container.get("Image", "")).partition("@")[0]
    return repo_of_tag(named) == AEON_REPO


def baseline_error(snap: Snapshot, index: Index) -> str | None:
    """Why the release baseline does not hold, or None. Any reason stops every delete."""
    live, previous = snap.keep.get(LIVE_REFS), snap.keep.get(PREVIOUS_REFS)
    if live is None:
        return f"{LIVE_REFS} is missing"
    if previous is None:
        return f"{PREVIOUS_REFS} is missing"
    if not live:
        return f"{LIVE_REFS} is empty"
    if not previous:
        return f"{PREVIOUS_REFS} is empty"
    if set(live) == set(previous):
        return f"{PREVIOUS_REFS} equals {LIVE_REFS}"
    by_id = {i["Id"]: i for i in snap.images}
    running = [c for c in snap.containers if c["State"] == "running" and is_aeon(c, by_id)]
    if not running:
        return "no AEON container is running"
    live_ids = set().union(*(index.resolve(ref) for ref in live))
    for c in running:
        if c["ImageID"] not in live_ids:
            return f"running AEON container {c.get('Id', '?')[:12]} uses {c['ImageID'][7:19]}, which {LIVE_REFS} does not name"
    return None


class Plan:
    def __init__(self, reasons, candidates, baseline) -> None:
        self.reasons = reasons
        # What the rules alone would remove; deletable is empty unless the baseline holds.
        self.candidates = candidates
        self.baseline = baseline
        self.deletable = [] if baseline else candidates


def plan(snap: Snapshot, now: float, keep_days: int, keep_newest: int, budget: Budget) -> Plan:
    validate(snap.containers, snap.images)
    budget.check()
    index = Index(snap.images)
    budget.check()
    reasons: dict[str, str] = {}

    def protect(image_id: str, why: str) -> None:
        reasons.setdefault(image_id, why)

    for c in snap.containers:
        protect(c["ImageID"], "used by a container")
    refsets = {
        "declared in the Nix compose spec": DECLARED_REFS,
        "declared by a NixOS system on disk": [ref for _, spec in snap.systems for ref in spec.values()],
        "listed in keep.d": [ref for refs in snap.keep.values() for ref in refs],
    }
    for why, refs in refsets.items():
        budget.check()
        for ref in refs:
            for image_id in index.resolve(ref):
                protect(image_id, why)
    budget.check()

    newest_first = sorted(snap.images, key=lambda i: (i["Created"], i["Id"]), reverse=True)
    per_repo: dict[str, int] = {}
    prev_seen: set[str] = set()
    cutoff = now - keep_days * 86400
    for image in newest_first:
        image_id = image["Id"]
        if any(t.endswith(":rollback") for t in tags_of(image)):
            protect(image_id, "tagged :rollback")
        for tag in tags_of(image):
            repo, _, name = tag.rpartition(":")
            if name.startswith("prev-") and "/" not in name and repo not in prev_seen:
                prev_seen.add(repo)
                protect(image_id, "newest prev-* of its repository")
        repos = repositories(image)
        if repos & PROTECTED_REPOS:
            protect(image_id, "protected repository")
        for repo in sorted(repos):
            per_repo[repo] = per_repo.get(repo, 0) + 1
            if per_repo[repo] <= keep_newest:
                protect(image_id, f"newest {keep_newest} of its repository")
        if image["Created"] >= cutoff:
            protect(image_id, f"younger than {keep_days} days")
    budget.check()
    candidates = [i for i in newest_first if i["Id"] not in reasons]
    baseline = baseline_error(snap, index)
    budget.check()
    return Plan(reasons, candidates, baseline)


def describe(image: dict) -> str:
    refs = tags_of(image) or digests_of(image) or ["<untagged>"]
    created = time.strftime("%Y-%m-%d", time.gmtime(image["Created"]))
    return f"{image['Id'][7:19]} {' '.join(refs)} created {created} {image.get('Size', 0) / 1e9:.2f} GB"


def summary(snap: Snapshot, p: Plan) -> str:
    by_reason: dict[str, int] = {}
    for why in p.reasons.values():
        by_reason[why] = by_reason.get(why, 0) + 1
    detail = ", ".join(f"{n} {why}" for why, n in sorted(by_reason.items()))
    return (
        f"docker-image-gc: {len(snap.images)} images, {len(snap.systems)} NixOS systems, "
        f"{len(snap.keep)} keep.d files; protected {len(p.reasons)} ({detail})"
    )


def classify(status: int, text: str, ref: str) -> str:
    if status in (200, 404):
        return "removed"
    if status == 409:
        # In use, named in several repositories (never untagged here), or a parent: keep it.
        print(f"docker-image-gc: DELETE {ref} -> 409, kept: {text[:200]}")
        return "kept"
    print(f"docker-image-gc: DELETE {ref} -> {status}: {text[:200]}", file=sys.stderr)
    return "failed"


@contextmanager
def deploy_locks(paths, wait_s: float, sleep=time.sleep, stop=STOP):
    """Hold every compose deploy lock, or raise Busy after wait_s. Never holds one while waiting for another."""
    deadline = time.monotonic() + wait_s
    while True:
        fds, busy = [], None
        try:
            for path in paths:
                if stop:
                    raise Stopped()
                # Like flock(1): open read-only, create if missing.
                fd = os.open(path, os.O_RDONLY | os.O_CREAT | os.O_CLOEXEC, 0o666)
                fds.append(fd)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except OSError as exc:
                    if exc.errno not in (errno.EWOULDBLOCK, errno.EAGAIN):
                        raise
                    busy = path
                    break
            if busy is None:
                if stop:
                    raise Stopped()
                yield
                return
        finally:
            for fd in fds:
                os.close(fd)
        if time.monotonic() >= deadline:
            raise Busy(busy)
        sleep(5)


DONE, SLOW, OVER, BASELINE = "done", "slow", "over", "baseline"


def batch(api, budget: Budget, run: dict) -> str:
    """Delete under the locks until done, the budget is spent or snapshots stay slow.

    Every DELETE is decided on its own fresh snapshot.
    """
    slow = 0
    try:
        while True:
            if STOP:
                raise Stopped()
            snap = snapshot(api, budget)
            p = plan(snap, run["now"], run["keep_days"], run["keep_newest"], budget)
            if not run["summarized"]:
                run["summarized"] = True
                print(summary(snap, p))
            if p.baseline:
                print(f"docker-image-gc: release baseline not met ({p.baseline}); nothing deleted")
                return BASELINE
            todo = [i for i in p.deletable if i["Id"] not in run["attempted"]]
            if not todo:
                return DONE
            budget.check()
            if STOP:
                raise Stopped()
            age = time.monotonic() - snap.t0
            if age > SNAPSHOT_MAX_AGE_S:
                slow += 1
                print(f"docker-image-gc: snapshot too slow ({age:.1f} s since its first request); retaking")
                if slow >= SLOW_SNAPSHOTS:
                    return SLOW
                continue
            slow = 0
            image = todo[0]
            run["attempted"].add(image["Id"])
            status, body = api("DELETE", f"/images/{image['Id']}?noprune=1", timeout=None, limit=CAP_RESPONSE_BYTES)
            result = classify(status, body.decode("utf-8", "replace"), image["Id"])
            run["counts"][result] += 1
            run["deleted"] += 1
            print(f"{result} {describe(image)}")
    except BatchOver:
        return OVER


def dry_run(api, now: float, keep_days: int, keep_newest: int, why: str) -> int:
    budget = Budget(BATCH_S)
    snap = snapshot(api, budget)
    p = plan(snap, now, keep_days, keep_newest, budget)
    print(summary(snap, p))
    for image in p.candidates:
        print(f"would remove {describe(image)}")
    total = sum(i.get("Size", 0) for i in p.candidates) / 1e9
    if p.baseline:
        print(f"docker-image-gc (dry run, {why}): release baseline not met ({p.baseline}); a real run deletes nothing")
    else:
        print(
            f"docker-image-gc (dry run, {why}): {len(p.candidates)} images would go "
            f"(~{total:.1f} GB, shared layers counted per image)"
        )
    return 0


def main(api=docker_api, now: float | None = None, sleep=time.sleep) -> int:
    now = time.time() if now is None else now
    try:
        keep_days = env_int("DOCKER_IMAGE_GC_KEEP_DAYS", 2)
        keep_newest = env_int("DOCKER_IMAGE_GC_KEEP_NEWEST", 3)
        if os.environ.get("DOCKER_IMAGE_GC_DRY_RUN", "0") == "1":
            return dry_run(api, now, keep_days, keep_newest, "requested")
        if not os.environ.get("INVOCATION_ID"):
            return dry_run(api, now, keep_days, keep_newest, "not under systemd")
    except (Fatal, BatchOver, OSError, ValueError) as exc:
        print(f"docker-image-gc: {exc or type(exc).__name__}; nothing removed", file=sys.stderr)
        return 2

    run = {
        "now": now,
        "keep_days": keep_days,
        "keep_newest": keep_newest,
        "attempted": set(),
        "counts": {"removed": 0, "kept": 0, "failed": 0},
        "deleted": 0,
        "summarized": False,
    }

    def tally() -> str:
        return "docker-image-gc: " + ", ".join(f"{n} {k}" for k, n in run["counts"].items())

    try:
        while True:
            with deploy_locks(LOCK_PATHS, LOCK_WAIT_S, sleep):
                before = run["deleted"]
                outcome = batch(api, Budget(BATCH_S), run)
            if outcome == DONE:
                break
            if outcome == BASELINE:
                print(tally())
                return 0
            if run["deleted"] == before:
                # Nothing fit into a whole batch: stop instead of looping.
                raise Fatal(f"batch ended ({outcome}) before a single DELETE")
            # Let a deploy that waits on a lock (flock -w) in before the next batch.
            sleep(2)
    except Busy as busy:
        print(f"docker-image-gc: {busy} held by a deploy for {LOCK_WAIT_S} s; skipping today")
        print(tally())
        return 0
    except Stopped:
        print("docker-image-gc: stopped by SIGTERM")
        print(tally())
        return 1
    except (Fatal, OSError, ValueError) as exc:
        print(f"docker-image-gc: {exc}; nothing more removed", file=sys.stderr)
        print(tally())
        return 2

    filters = urllib.parse.quote(json.dumps({"until": [f"{keep_days * 24}h"]}))
    status, body = api("POST", f"/build/prune?all=1&filters={filters}", timeout=300, limit=CAP_RESPONSE_BYTES)
    if status != 200:
        print(f"docker-image-gc: build cache prune -> {status}: {body[:200]!r}", file=sys.stderr)
        run["counts"]["failed"] += 1
    else:
        freed = json.loads(body).get("SpaceReclaimed") or 0
        print(f"docker-image-gc: build cache older than {keep_days} days pruned ({freed / 1e9:.2f} GB)")
    print(tally())
    return 1 if run["counts"]["failed"] else 0


def cli(argv: list[str]) -> int:
    if argv:
        print("usage: docker-image-gc", file=sys.stderr)
        return 64
    previous = signal.signal(signal.SIGTERM, STOP.set)
    try:
        return main()
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == "__main__":
    sys.exit(cli(sys.argv[1:]))
