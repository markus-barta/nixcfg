"""csb1 Docker image GC (OPS-327, design r34).

Every DELETE and the old build-cache prune use a fresh, capped snapshot under
all three compose locks. Switches are observed, never locked or ordered.
Protection includes generations, current/booted, every named store system and
recursive specialisations, containers, keep.d, declared refs and release rules.
A GC-only instance lock plus 45-second cooldowns separate every compose hold,
including busy/partial acquisitions and successive runs. Each destructive
Engine call has a 30-second absolute deadline through one socket subclass.
Nothing is printed while a compose fd is open. Manual invocations are dry runs.
See the host RUNBOOK for the accepted publication and unanswered-call races.
"""

from __future__ import annotations

import fcntl
import http.client
import json
import os
import re
import signal
import socket
import stat
import sys
import time
import urllib.parse
from contextlib import contextmanager
from typing import NamedTuple

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
STORE_DIR = "/nix/store"
STORE_SYSTEM = re.compile(r"^[0-9a-z]{32}-nixos-system-[^/]+$")
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
# Read, never locked: an activation in progress holds it (or waits for it).
SWITCH_LOCK = "/run/nixos/switch-to-configuration.lock"
PROC = "/proc"
PROC_LOCKS = "/proc/locks"
INSTANCE_LOCK = "/run/lock/docker-image-gc.lock"
LOCK_WAIT_S = 300
BATCH_S = 10
CALL_DEADLINE_S = 30
COOLDOWN_S = 45
RUN_BUDGET_S = 50 * 60
SNAPSHOT_MAX_AGE_S = 2.0
SLOW_SNAPSHOTS = 3
GET_WATCHDOG_S = 30
KEEP_DAYS = 2
KEEP_NEWEST = 3
LINE_MAX = 300

MIB = 1024 * 1024
# Per item.
CAP_CONTAINERS_BYTES = 4 * MIB
CAP_IMAGES_BYTES = 16 * MIB
CAP_KEEP_FILE_BYTES = 64 * 1024
CAP_KEEP_FILES = 64
CAP_SPEC_BYTES = 1 * MIB
CAP_RESPONSE_BYTES = 64 * 1024
# The prune answer lists every cache record it removed.
CAP_PRUNE_BYTES = 16 * MIB
CAP_PROC_LOCKS_BYTES = 1 * MIB
# Per snapshot; each distinct store path counts once.
CAP_GENERATIONS = 200
CAP_STORE_ENTRIES = 1_000_000
CAP_SYSTEMS = 500
CAP_SPECS_PER_SYSTEM = 16
CAP_SPEC_BYTES_TOTAL = 64 * MIB
CAP_REFS = 100_000
CAP_DIR_ENTRIES = 5_000

# Docker's reference grammar (distribution/reference v0.6, ParseNormalizedNamed).
IMAGE_ID = re.compile(r"^sha256:[0-9a-f]{64}$")
# What dockerd also resolves as an image ID: a full or short ID, with or without sha256:.
ID_FORM = re.compile(r"^(?:sha256:)?([0-9a-f]{1,64})$")
FULL_HEX = re.compile(r"^[0-9a-f]{64}$")
_DOMAIN_PART = r"(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9])"
_HOST = rf"(?:{_DOMAIN_PART}(?:\.{_DOMAIN_PART})*|\[[0-9A-Fa-f:]+\])"
_PATH_PART = r"[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*"
DOMAIN = re.compile(rf"^{_HOST}(?::[0-9]+)?$")
PATH = re.compile(rf"^{_PATH_PART}(?:/{_PATH_PART})*$")
TAG = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
# What go-digest validates: a registered algorithm and its exact lowercase hex length.
DIGEST = re.compile(r"^(?:sha256:[0-9a-f]{64}|sha384:[0-9a-f]{96}|sha512:[0-9a-f]{128})$")
SHA256_DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
PATH_MAX = 255


class Fatal(Exception):
    """The run cannot judge safely; nothing more is removed."""


class CapExceeded(Fatal):
    """An input is larger than its cap."""


class Busy(Exception):
    """A deploy or an activation keeps the GC out for LOCK_WAIT_S; this run skips the day."""


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


class Ref(NamedTuple):
    name: str  # normalized: domain/path
    tag: str | None
    digest: str | None


def parse_ref(raw) -> Ref:
    """Docker's ParseNormalizedNamed: redis:7 -> docker.io/library/redis:7. ValueError if malformed."""
    if not isinstance(raw, str) or not raw or raw != raw.strip():
        raise ValueError(f"not an image reference: {str(raw)[:120]!r}")
    if FULL_HEX.match(raw):
        raise ValueError(f"a 64-hex string is an ID, not a name: {raw[:120]!r}")
    rest, at, digest = raw.partition("@")
    if at and not DIGEST.match(digest):
        raise ValueError(f"bad digest in {raw[:120]!r}")
    tag = None
    colon = rest.rfind(":")
    if colon > rest.rfind("/"):
        rest, tag = rest[:colon], rest[colon + 1 :]
        if not TAG.match(tag):
            raise ValueError(f"bad tag in {raw[:120]!r}")
    first, slash, remainder = rest.partition("/")
    if slash and ("." in first or ":" in first or first == "localhost" or first.lower() != first):
        domain, path = first, remainder
        if not DOMAIN.match(domain):
            raise ValueError(f"bad registry in {raw[:120]!r}")
    else:
        domain, path = "docker.io", rest
    if not PATH.match(path):
        raise ValueError(f"bad repository in {raw[:120]!r}")
    if domain == "index.docker.io":
        domain = "docker.io"
    if domain == "docker.io" and "/" not in path:
        path = "library/" + path
    if len(path) > PATH_MAX:
        raise ValueError(f"repository path longer than {PATH_MAX}: {raw[:120]!r}")
    if tag is None and not at:
        tag = "latest"
    return Ref(f"{domain}/{path}", tag, digest if at else None)


def as_name(raw: str) -> Ref | None:
    """The named reference raw also is, or None for a string that is only an ID form."""
    try:
        return parse_ref(raw)
    except ValueError:
        if ID_FORM.fullmatch(raw):
            return None
        raise


def check_ref(raw, where: str, need_digest: bool = False) -> None:
    """Fatal unless raw is an ID form or a reference; with need_digest, only name[:tag]@sha256:<digest>."""
    if not need_digest and isinstance(raw, str) and ID_FORM.fullmatch(raw):
        return
    try:
        ref = parse_ref(raw)
    except ValueError as exc:
        raise Fatal(f"{where}: {exc}") from None
    if need_digest and not (ref.digest and SHA256_DIGEST.match(ref.digest)):
        raise Fatal(f"{where}: not a name[:tag]@sha256:<digest> ref: {raw[:120]!r}")


class DeadlineSocket(socket.socket):
    """The sole destructive-call timeout setter, including connection setup.

    SocketIO (used by http.client's buffered reader) dispatches recv_into here
    for every HTTP phase. sendall's timeout also bounds its entire C-level loop.
    """

    def __init__(self, deadline: float) -> None:
        super().__init__(socket.AF_UNIX, socket.SOCK_STREAM)
        self.deadline = deadline

    def remaining(self) -> float:
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError("Engine call deadline")
        return left

    def connect(self, address):
        self.settimeout(self.remaining())
        return super().connect(address)

    def send(self, data, flags=0):
        self.settimeout(self.remaining())
        return super().send(data, flags)

    def sendall(self, data, flags=0):
        self.settimeout(self.remaining())
        return super().sendall(data, flags)

    def recv(self, size, flags=0):
        self.settimeout(self.remaining())
        return super().recv(size, flags)

    def recv_into(self, buffer, nbytes=0, flags=0):
        self.settimeout(self.remaining())
        return super().recv_into(buffer, nbytes, flags)


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path: str, timeout: float | None, deadline: float | None = None) -> None:
        super().__init__("localhost", timeout=timeout)
        self.unix_path = path
        self.deadline = deadline

    def connect(self) -> None:
        if self.deadline is not None:
            sock = DeadlineSocket(self.deadline)
        else:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(self.timeout)
        # Assign before connecting: finally closes even a failed/timed-out connect.
        self.sock = sock
        sock.connect(self.unix_path)


def docker_api(method: str, path: str, timeout: float | None, limit: int) -> tuple[int, bytes]:
    """One capped Engine call, connect through last byte on the same deadline."""
    deadline = time.monotonic() + CALL_DEADLINE_S if method != "GET" else None
    conn = UnixHTTPConnection(SOCKET_PATH, timeout=timeout, deadline=deadline)
    res = None
    try:
        conn.request(method, path)
        res = conn.getresponse()
        body = res.read(limit + 1)
        if deadline is not None and time.monotonic() >= deadline:
            raise TimeoutError("Engine call deadline")
        return res.status, body
    finally:
        try:
            if res is not None:
                res.close()
        finally:
            conn.close()


def destructive_call(api, method: str, path: str, limit: int, label: str):
    try:
        return api(method, path, timeout=CALL_DEADLINE_S, limit=limit)
    except TimeoutError:
        raise Fatal(f"{label} not answered in {CALL_DEADLINE_S:g} s") from None
    except Exception as exc:
        raise Fatal(f"{label}: {type(exc).__name__}: {str(exc)[:200]}") from None


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
    """Raise Interrupted in a GET still running after seconds, even one that keeps trickling.

    The timer is one-shot and the handler raises only while armed, so at most one Interrupted;
    the outer finally restores the previous handler whenever the signal lands.
    """
    armed = True

    def fire(signum, frame):
        if armed:
            raise Interrupted()

    previous = signal.getsignal(signal.SIGALRM)
    try:
        try:
            signal.signal(signal.SIGALRM, fire)
            signal.setitimer(signal.ITIMER_REAL, max(seconds, 0.001))
            yield
        finally:
            armed = False
            signal.setitimer(signal.ITIMER_REAL, 0)
    finally:
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


def names_of(image: dict) -> list[str]:
    return [n for key in ("RepoTags", "RepoDigests") for n in image.get(key) or [] if not n.startswith("<none>")]


def gone(path: str) -> bool:
    """Whether path itself does not exist: only lstat's ENOENT says so; any other error raises."""
    try:
        os.lstat(path)
    except FileNotFoundError:
        return True
    return False


class Reader:
    """Local reads for one snapshot, with the deadline and the caps enforced while reading.

    Nothing is cached beyond this snapshot. Within it, a spec file is read once per distinct
    store path (generations share them).
    """

    def __init__(self, budget: Budget) -> None:
        self.budget = budget
        self.entries = 0
        self.spec_bytes = 0
        self.refs = 0
        self.specs: dict[str, dict[str, str]] = {}
        self.store_only: set[str] = set()
        self.store_device = os.stat(STORE_DIR).st_dev

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

    def read(self, path: str, cap: int, over: str | None = None, *, device=None, nofollow=False) -> bytes:
        """Nonblocking regular-file read, expected device, cap checked before parsing."""
        self.budget.check()
        flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY | os.O_CLOEXEC
        if nofollow:
            flags |= os.O_NOFOLLOW
        fd = os.open(path, flags)
        try:
            info = os.fstat(fd)
            expected = self.store_device if device is None else device
            if not stat.S_ISREG(info.st_mode):
                raise Fatal(f"{path}: not a regular file")
            if info.st_dev != expected:
                raise Fatal(f"{path}: unexpected file system")
            # procfs reports size zero. Read the descriptor, never trust st_size.
            chunks, size = [], 0
            while size <= cap:
                chunk = os.read(fd, min(64 * 1024, cap + 1 - size))
                if not chunk:
                    break
                chunks.append(chunk)
                size += len(chunk)
            data = b"".join(chunks)
        finally:
            os.close(fd)
        if len(data) > cap:
            raise CapExceeded(over or f"{path} is larger than {cap} bytes")
        self.budget.check()
        return data

    def count_refs(self, n: int) -> None:
        self.refs += n
        if self.refs > CAP_REFS:
            raise CapExceeded(f"more than {CAP_REFS} image references")

    def system(self, link: str, required: bool) -> str | None:
        """The store path link resolves to; None if a generation link vanished since the listing.

        Only ENOENT from lstat means gone; an lexists-style helper would read EACCES as gone too.
        """
        self.budget.check()
        try:
            target = os.path.realpath(link, strict=True)
        except FileNotFoundError:
            if not required and gone(link):
                return None
            raise Fatal(f"{link} does not resolve; refusing to judge") from None
        if not os.path.isdir(target) or not os.path.isdir(os.path.join(target, "etc")):
            raise Fatal(f"{link} -> {target} is not a NixOS system; refusing to judge")
        return target

    def compose_services(self, system: str) -> dict[str, str]:
        """{stack/service: image} of one resolved NixOS system. No etc/compose declares nothing."""
        compose = os.path.join(system, COMPOSE_DIR)
        try:
            stacks = sorted(self.listdir(compose))
        except FileNotFoundError:
            if not gone(compose):
                raise Fatal(f"{compose} does not resolve; refusing to judge") from None
            return {}
        if len(stacks) > CAP_SPECS_PER_SYSTEM:
            raise CapExceeded(f"{compose}: more than {CAP_SPECS_PER_SYSTEM} compose specs")
        services: dict[str, str] = {}
        for stack in stacks:
            path = os.path.join(compose, stack, "docker-compose.yml")
            self.budget.check()
            try:
                real = os.path.realpath(path, strict=True)
            except FileNotFoundError:
                raise Fatal(f"{path} does not resolve; refusing to judge") from None
            if real not in self.specs:
                left = CAP_SPEC_BYTES_TOTAL - self.spec_bytes
                over = f"more than {CAP_SPEC_BYTES_TOTAL} bytes of compose specs" if left < CAP_SPEC_BYTES else None
                data = self.read(real, min(CAP_SPEC_BYTES, left), over)
                self.spec_bytes += len(data)
                spec = json.loads(data)  # rendered by builtins.toJSON
                self.budget.check()
                if not isinstance(spec, dict) or not isinstance(spec.get("services"), dict):
                    raise Fatal(f"{path}: no services map")
                found = {}
                for name, service in spec["services"].items():
                    if not isinstance(service, dict):
                        raise Fatal(f"{path}: service {name!r} is not a map")
                    if "image" in service:
                        check_ref(service["image"], f"{path}: service {name!r}")
                        found[name] = service["image"]
                self.count_refs(len(found))
                self.specs[real] = found
            services.update({f"{stack}/{name}": image for name, image in self.specs[real].items()})
        return services

    def systems(self) -> tuple[list[tuple[str, dict[str, str]]], str, str]:
        """Distinct systems: rooted closure first, then store-only closure.

        Listing a store entry is not enough to call it a system: lstat must show
        a directory. ENOENT skips a removed entry; incomplete systems fail closed.
        """
        listed = self.listdir(PROFILES_DIR)
        found = sorted((int(m.group(1)), name) for name in listed if (m := GENERATION.match(name)))
        if len(found) > CAP_GENERATIONS:
            raise CapExceeded(f"more than {CAP_GENERATIONS} NixOS generations")
        roots = []
        for _, name in found:
            target = self.system(os.path.join(PROFILES_DIR, name), required=False)
            if target is not None:
                roots.append(target)
        current = self.system(CURRENT_SYSTEM, required=True)
        booted = self.system(BOOTED_SYSTEM, required=True)
        roots.extend((current, booted))
        systems: dict[str, dict[str, str]] = {}

        def visit(target):
            if target in systems:
                return
            if len(systems) >= CAP_SYSTEMS:
                raise CapExceeded(f"more than {CAP_SYSTEMS} distinct NixOS systems")
            systems[target] = self.compose_services(target)
            special = os.path.join(target, "specialisation")
            self.budget.check()
            try:
                mode = os.lstat(special).st_mode
            except FileNotFoundError:
                return
            if not stat.S_ISDIR(mode):
                raise Fatal(f"{special}: not a directory")
            for name in sorted(self.listdir(special)):
                path = os.path.join(special, name)
                if not stat.S_ISLNK(os.lstat(path).st_mode):
                    raise Fatal(f"{path}: specialisation is not a symlink")
                child = self.system(path, required=True)
                if os.path.commonpath((os.path.realpath(STORE_DIR), child)) != os.path.realpath(STORE_DIR):
                    raise Fatal(f"{path}: specialisation is outside the store")
                visit(child)

        for target in roots:
            visit(target)
        rooted = set(systems)
        self.budget.check()
        with os.scandir(STORE_DIR) as entries:
            for n, entry in enumerate(entries, start=1):
                if n > CAP_STORE_ENTRIES:
                    raise CapExceeded(f"more than {CAP_STORE_ENTRIES} store entries")
                if not STORE_SYSTEM.fullmatch(entry.name) or entry.name.endswith(".drv"):
                    continue
                self.budget.check()
                try:
                    mode = os.lstat(entry.path).st_mode
                except FileNotFoundError:
                    continue
                if stat.S_ISDIR(mode):
                    visit(self.system(entry.path, required=True))
        self.budget.check()
        self.store_only = set(systems) - rooted
        if not any(systems.values()):
            raise Fatal("no compose spec found in any NixOS system; refusing to judge")
        return list(systems.items()), current, booted

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
        device = os.stat(KEEP_DIR).st_dev
        for name in files:
            data = self.read(os.path.join(KEEP_DIR, name), CAP_KEEP_FILE_BYTES, device=device, nofollow=True)
            refs = []
            try:
                lines = data.decode("utf-8").splitlines()
            except UnicodeDecodeError:
                raise Fatal(f"{name}: not UTF-8") from None
            for n, raw in enumerate(lines, start=1):
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                check_ref(line, f"{name}:{n}", need_digest=True)
                refs.append(line)
            self.count_refs(len(refs))
            keep[name] = refs
        self.budget.check()
        return keep


class Snapshot:
    def __init__(self, t0, containers, images, systems, keep, current=None, booted=None, store_only=()) -> None:
        self.t0 = t0
        self.containers = containers
        self.images = images
        self.systems = systems
        self.keep = keep
        self.current = current
        self.booted = booted
        self.store_only = set(store_only)


def snapshot(api, budget: Budget) -> Snapshot:
    """Listings first, t0 just before the first request; then the local reads."""
    budget.check()
    t0 = time.monotonic()
    containers = get_json(api, "/containers/json?all=1", CAP_CONTAINERS_BYTES, budget)
    images = get_json(api, "/images/json", CAP_IMAGES_BYTES, budget)
    reader = Reader(budget)
    reader.count_refs(len(DECLARED_REFS))
    for ref in DECLARED_REFS:
        check_ref(ref, "declared compose spec")
    systems, current, booted = reader.systems()
    keep = reader.keep()
    return Snapshot(t0, containers, images, systems, keep, current, booted, reader.store_only)


def validate(containers, images) -> dict[str, list[Ref]]:
    """Fatal on anything malformed; returns each image's parsed names."""
    if not isinstance(containers, list) or not isinstance(images, list):
        raise Fatal("container or image listing is not a list")
    if not containers:
        raise Fatal("the daemon lists no containers at all; refusing to judge")
    for c in containers:
        if (
            not isinstance(c, dict)
            or not isinstance(c.get("ImageID"), str)
            or not IMAGE_ID.fullmatch(c["ImageID"])
            or not isinstance(c.get("State"), str)
        ):
            raise Fatal(f"container without a usable ImageID/State: {str(c)[:120]}")
        if c.get("Image") is not None:
            check_ref(c["Image"], f"container {str(c.get('Id', '?'))[:12]} Image")
    names: dict[str, list[Ref]] = {}
    for i in images:
        if (
            not isinstance(i, dict)
            or not isinstance(i.get("Id"), str)
            or not IMAGE_ID.fullmatch(i["Id"])
            or not isinstance(i.get("Created"), int)
            or not isinstance(i.get("Size", 0), int)
            or i.get("Size", 0) < 0
        ):
            raise Fatal(f"image without a usable Id/Created: {str(i)[:120]}")
        # Protection reads the names: a listing without them must not read as "untagged".
        for key in ("RepoTags", "RepoDigests"):
            value = i.get(key)
            usable = value is None or (isinstance(value, list) and all(isinstance(n, str) for n in value))
            if key not in i or not usable:
                raise Fatal(f"image {i['Id'][:19]} without a usable {key}: {str(i)[:120]}")
        refs = []
        for key in ("RepoTags", "RepoDigests"):
            for n in i.get(key) or []:
                if n.startswith("<none>"):
                    continue
                try:
                    ref = parse_ref(n)
                except ValueError as exc:
                    raise Fatal(f"image {i['Id'][:19]}: {exc}") from None
                if key == "RepoTags" and (ref.tag is None or ref.digest is not None):
                    raise Fatal(f"image {i['Id'][:19]}: RepoTags requires a tag without a digest")
                if key == "RepoDigests" and ref.digest is None:
                    raise Fatal(f"image {i['Id'][:19]}: RepoDigests requires a digest")
                refs.append(ref)
        names[i["Id"]] = refs
    return names


class Index:
    """Resolves references against one listing like dockerd: an ID form by ID prefix, a name by
    normalized name:tag or by digest (any name). A string that is both resolves both ways."""

    def __init__(self, images: list[dict], names: dict[str, list[Ref]]) -> None:
        self.ids = sorted(i["Id"] for i in images)
        self.by_tag: dict[str, set[str]] = {}
        self.by_digest: dict[str, set[str]] = {}
        for image_id, refs in names.items():
            for ref in refs:
                if ref.digest:
                    self.by_digest.setdefault(ref.digest, set()).add(image_id)
                elif ref.tag:
                    self.by_tag.setdefault(f"{ref.name}:{ref.tag}", set()).add(image_id)

    def resolve(self, raw: str) -> set[str]:
        found: set[str] = set()
        if m := ID_FORM.fullmatch(raw):
            prefix = "sha256:" + m.group(1)
            found |= {image_id for image_id in self.ids if image_id.startswith(prefix)}
        ref = as_name(raw)
        if ref is None:
            return found
        if ref.digest:
            return found | self.by_digest.get(ref.digest, set())
        return found | self.by_tag.get(f"{ref.name}:{ref.tag}", set())


def is_aeon(container: dict, names: dict[str, list[Ref]]) -> bool:
    if any(ref.name == AEON_REPO for ref in names.get(container["ImageID"], [])):
        return True
    named = container.get("Image")
    ref = as_name(named) if isinstance(named, str) else None
    return ref is not None and ref.name == AEON_REPO


def baseline_error(snap: Snapshot, index: Index, names: dict[str, list[Ref]]) -> str | None:
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
    running = [c for c in snap.containers if c["State"] == "running" and is_aeon(c, names)]
    if not running:
        return "no AEON container is running"
    live_ids = set().union(*(index.resolve(ref) for ref in live))
    for c in running:
        if c["ImageID"] not in live_ids:
            return f"running AEON container {str(c.get('Id', '?'))[:12]} uses {c['ImageID'][7:19]}, which {LIVE_REFS} does not name"
    return None


class Plan:
    def __init__(self, reasons, candidates, baseline) -> None:
        self.reasons = reasons
        # What the rules alone would remove; deletable is empty unless the baseline holds.
        self.candidates = candidates
        self.baseline = baseline
        self.deletable = [] if baseline else candidates


def plan(snap: Snapshot, now: float, budget: Budget) -> Plan:
    names = validate(snap.containers, snap.images)
    budget.check()
    index = Index(snap.images, names)
    budget.check()
    reasons: dict[str, str] = {}
    ordinary: set[str] = set()

    def protect(image_id: str, why: str) -> None:
        reasons.setdefault(image_id, why)
        if why != "declared only by store scan":
            ordinary.add(image_id)

    for c in snap.containers:
        protect(c["ImageID"], "used by a container")
    refsets = {
        "declared in the Nix compose spec": DECLARED_REFS,
        "declared by a NixOS system on disk": [ref for path, spec in snap.systems if path not in snap.store_only for ref in spec.values()],
        "declared only by store scan": [ref for path, spec in snap.systems if path in snap.store_only for ref in spec.values()],
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
    cutoff = now - KEEP_DAYS * 86400
    for image in newest_first:
        image_id = image["Id"]
        refs = names[image_id]
        if any(ref.tag == "rollback" for ref in refs):
            protect(image_id, "tagged :rollback")
        for ref in refs:
            if ref.tag and ref.tag.startswith("prev-") and ref.name not in prev_seen:
                prev_seen.add(ref.name)
                protect(image_id, "newest prev-* of its repository")
        repos = {ref.name for ref in refs}
        if repos & PROTECTED_REPOS:
            protect(image_id, "protected repository")
        for repo in sorted(repos):
            per_repo[repo] = per_repo.get(repo, 0) + 1
            if per_repo[repo] <= KEEP_NEWEST:
                protect(image_id, f"newest {KEEP_NEWEST} of its repository")
        if image["Created"] >= cutoff:
            protect(image_id, f"younger than {KEEP_DAYS} days")
    budget.check()
    candidates = [i for i in newest_first if i["Id"] not in reasons]
    baseline = baseline_error(snap, index, names)
    budget.check()
    result = Plan(reasons, candidates, baseline)
    result.store_images = set(reasons) - ordinary
    return result


def describe(image: dict) -> str:
    refs = names_of(image) or ["<untagged>"]
    created = time.strftime("%Y-%m-%d", time.gmtime(image["Created"]))
    return f"{image['Id'][7:19]} {' '.join(refs)} created {created} {image.get('Size', 0) / 1e9:.2f} GB"


SHORT = {
    "used by a container": "container",
    "declared in the Nix compose spec": "nix",
    "declared by a NixOS system on disk": "system",
    "listed in keep.d": "keep.d",
    "declared only by store scan": "store",
    "tagged :rollback": "rollback",
    "newest prev-* of its repository": "prev",
    "protected repository": "janus",
    f"newest {KEEP_NEWEST} of its repository": "newest",
    f"younger than {KEEP_DAYS} days": "young",
}


def summary(snap: Snapshot, p: Plan) -> str:
    by_reason: dict[str, int] = {}
    for why in p.reasons.values():
        by_reason[SHORT[why]] = by_reason.get(SHORT[why], 0) + 1
    detail = " ".join(f"{why}={n}" for why, n in sorted(by_reason.items()))
    extra = [(path, refs) for path, refs in snap.systems if path in snap.store_only]
    extra_refs = {ref for _, refs in extra for ref in refs.values()}
    rooted_refs = {ref for path, refs in snap.systems if path not in snap.store_only for ref in refs.values()}
    return (
        f"docker-image-gc: {len(snap.images)} images, {len(snap.systems)} NixOS systems, "
        f"{len(snap.keep)} keep.d files; protected {len(p.reasons)} ({detail}); "
        f"store-only systems={len(extra)}, extra refs={len(extra_refs - rooted_refs)}, images={len(p.store_images)}, "
        f"bytes={sum(i.get('Size', 0) for i in snap.images if i['Id'] in p.store_images)}"
    )


def switch_lock_used(budget: Budget) -> bool:
    """Whether anyone holds or waits for switch-to-configuration's lock. Reads /proc/locks; never locks."""
    budget.check()
    try:
        st = os.stat(SWITCH_LOCK)
    except FileNotFoundError:
        return False
    token = (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)
    data = Reader(budget).read(PROC_LOCKS, CAP_PROC_LOCKS_BYTES, device=os.stat(PROC).st_dev)
    for line in data.decode("ascii", "strict").splitlines():
        for word in line.split():
            if re.fullmatch(r"[0-9a-fA-F]+:[0-9a-fA-F]+:[0-9]+", word):
                major, minor, inode = word.split(":")
                other = (int(major, 16), int(minor, 16), int(inode, 10))
                if token == other:
                    return True
    return False


def activation_seen(budget: Budget) -> str | None:
    """Observation (a), before every fresh snapshot as well as after its plan."""
    if switch_lock_used(budget):
        return f"{SWITCH_LOCK} is held or awaited"
    return None


def activation(snap: Snapshot, budget: Budget) -> str | None:
    """Best-effort (a), then (b); a later switch/retarget is the accepted race."""
    if why := activation_seen(budget):
        return why
    for link, seen in ((CURRENT_SYSTEM, snap.current), (BOOTED_SYSTEM, snap.booted)):
        budget.check()
        if os.path.realpath(link, strict=True) != seen:
            return f"{link} changed since the snapshot"
    return None


@contextmanager
def instance_lock():
    fd = os.open(INSTANCE_LOCK, os.O_RDONLY | os.O_CREAT | os.O_CLOEXEC, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Busy("another run is in progress") from None
        yield
    finally:
        os.close(fd)


@contextmanager
def deploy_locks(paths):
    """One nonblocking attempt. The caller owns cooldown and both run budgets."""
    fds = []
    try:
        for path in paths:
            if STOP:
                raise Stopped()
            fd = os.open(path, os.O_RDONLY | os.O_CREAT | os.O_CLOEXEC, 0o600)
            fds.append(fd)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Busy(path) from None
        if STOP:
            raise Stopped()
        yield
    finally:
        for fd in reversed(fds):
            os.close(fd)


DONE, SLOW, OVER, BASELINE, ACTIVE = "done", "slow", "over", "baseline", "active"


def say(run: dict, line: str, err: bool = False) -> None:
    """Output while the locks are held waits in memory (a blocked journal must not hold them)."""
    run["log"].append((err, line[:LINE_MAX]))


def flush(run: dict) -> None:
    for err, line in run["log"]:
        print(line, file=sys.stderr if err else sys.stdout)
    run["log"].clear()
    sys.stdout.flush()
    sys.stderr.flush()


PRUNE_PATH = "/build/prune?" + urllib.parse.urlencode(
    {"all": "1", "filters": json.dumps({"until": [f"{KEEP_DAYS * 24}h"]})}
)


def batch(api, budget: Budget, run: dict) -> str:
    """Delete under the locks until done, the budget is spent, snapshots stay slow or an activation starts.

    Every destructive call (each DELETE, then the one build-cache prune) is decided on its own
    fresh snapshot and passes the fence right before it.
    """
    slow = 0
    try:
        while True:
            if STOP:
                raise Stopped()
            if why := activation_seen(budget):
                say(run, f"docker-image-gc: {why}; giving the locks back")
                return ACTIVE
            snap = snapshot(api, budget)
            p = plan(snap, run["now"], budget)
            if not run["summarized"]:
                run["summarized"] = True
                say(run, summary(snap, p))
            if p.baseline:
                say(run, f"docker-image-gc: release baseline not met ({p.baseline}); nothing deleted")
                return BASELINE
            todo = [i for i in p.deletable if i["Id"] not in run["attempted"]]
            if not todo and run["pruned"]:
                return DONE
            # The r34 post-plan switch and retarget checks precede the final
            # in-memory STOP, budget, age and ID checks.
            why = activation(snap, budget)
            if why:
                say(run, f"docker-image-gc: {why}; giving the locks back")
                return ACTIVE
            if STOP:
                raise Stopped()
            budget.check()
            age = time.monotonic() - snap.t0
            if age > SNAPSHOT_MAX_AGE_S:
                slow += 1
                say(run, f"docker-image-gc: snapshot too slow ({age:.1f} s since its first request); retaking")
                if slow >= SLOW_SNAPSHOTS:
                    return SLOW
                continue
            slow = 0
            if not todo:
                run["pruned"] = True
                run["deleted"] += 1
                status, body = destructive_call(api, "POST", PRUNE_PATH, CAP_PRUNE_BYTES, "prune")
                if len(body) > CAP_PRUNE_BYTES:
                    raise CapExceeded(f"build cache prune: answer larger than {CAP_PRUNE_BYTES} bytes")
                answer = json.loads(body) if status == 200 else None
                if not isinstance(answer, dict) or not isinstance(answer.get("SpaceReclaimed"), int):
                    raise Fatal(f"build cache prune -> {status}: {body[:200].decode('utf-8', 'replace')}")
                say(run, f"pruned build cache older than {KEEP_DAYS * 24} h: {answer['SpaceReclaimed'] / 1e9:.2f} GB")
                return DONE
            image = todo[0]
            if not IMAGE_ID.fullmatch(image["Id"]):
                raise Fatal(f"refusing to delete {image['Id'][:80]!r}: not an image ID")
            run["attempted"].add(image["Id"])
            status, body = destructive_call(
                api, "DELETE",
                f"/images/{urllib.parse.quote(image['Id'], safe=':')}?noprune=1",
                CAP_RESPONSE_BYTES, f"DELETE {image['Id']}",
            )
            if len(body) > CAP_RESPONSE_BYTES:
                raise CapExceeded(f"DELETE answer larger than {CAP_RESPONSE_BYTES} bytes")
            text = body[:200].decode("utf-8", "replace")
            run["deleted"] += 1
            if status in (200, 404):
                run["counts"]["removed"] += 1
                say(run, f"removed {describe(image)}")
            elif status == 409:
                # In use, named in several repositories (never untagged here), or a parent: keep it.
                run["counts"]["kept"] += 1
                say(run, f"kept {describe(image)} (409: {text})")
            else:
                run["counts"]["failed"] += 1
                raise Fatal(f"DELETE {image['Id']} -> {status}: {text}")
    except BatchOver:
        return OVER


def dry_run(api, now: float, why: str) -> int:
    budget = Budget(BATCH_S)
    snap = snapshot(api, budget)
    p = plan(snap, now, budget)
    print(summary(snap, p))
    for image in p.candidates:
        print(f"would remove {describe(image)}")
    total = sum(i.get("Size", 0) for i in p.candidates) / 1e9
    if p.baseline:
        print(f"docker-image-gc (dry run, {why}): release baseline not met ({p.baseline}); a real run deletes nothing")
    else:
        print(
            f"docker-image-gc (dry run, {why}): {len(p.candidates)} images would go "
            f"(~{total:.1f} GB, shared layers counted per image), then build cache older than {KEEP_DAYS * 24} h"
        )
    return 0


ERRORS = (Fatal, OSError, ValueError, http.client.HTTPException)


def main(api=docker_api, now: float | None = None, sleep=time.sleep) -> int:
    now = time.time() if now is None else now
    try:
        if os.environ.get("DOCKER_IMAGE_GC_DRY_RUN", "0") == "1":
            return dry_run(api, now, "requested")
        if not os.environ.get("INVOCATION_ID"):
            return dry_run(api, now, "not under systemd")
    except (*ERRORS, BatchOver) as exc:
        print(f"docker-image-gc: {exc or type(exc).__name__}; nothing removed", file=sys.stderr)
        return 2

    run = {
        "now": now,
        "attempted": set(),
        "counts": {"removed": 0, "kept": 0, "failed": 0},
        "deleted": 0,
        "summarized": False,
        "pruned": False,
        "log": [],
    }

    def tally() -> str:
        return "docker-image-gc: " + ", ".join(f"{n} {k}" for k, n in run["counts"].items())

    started = time.monotonic()
    waiting_since = None

    def run_over():
        if time.monotonic() - started >= RUN_BUDGET_S:
            print("docker-image-gc: run budget used; continuing tomorrow")
            return True
        return False

    def cooldown(released):
        # Never sleep past either budget; checks run again immediately on waking.
        until = released + COOLDOWN_S
        if waiting_since is not None:
            until = min(until, waiting_since + LOCK_WAIT_S)
        until = min(until, started + RUN_BUDGET_S)
        while time.monotonic() < until:
            if STOP:
                raise Stopped()
            sleep(min(1.0, until - time.monotonic()))

    try:
        with instance_lock():
            released = time.monotonic()
            while True:
                if STOP:
                    raise Stopped()
                if run_over():
                    break
                if waiting_since is not None and time.monotonic() - waiting_since >= LOCK_WAIT_S:
                    raise Busy("a compose lock or switch")
                cooldown(released)
                if STOP:
                    raise Stopped()
                if run_over():
                    break
                if waiting_since is not None and time.monotonic() - waiting_since >= LOCK_WAIT_S:
                    raise Busy("a compose lock or switch")
                before = run["deleted"]
                busy_at = None
                try:
                    try:
                        with deploy_locks(LOCK_PATHS):
                            outcome = batch(api, Budget(BATCH_S), run)
                            if outcome == ACTIVE:
                                busy_at = time.monotonic()
                    except Busy:
                        outcome = ACTIVE
                        busy_at = time.monotonic()
                finally:
                    # Every compose fd is closed, including partial attempts and errors.
                    released = time.monotonic()
                # Check immediately after release, before flushing or sleeping.
                over = run_over()
                flush(run)
                if STOP:
                    raise Stopped()
                if over or outcome in (DONE, BASELINE):
                    break
                if outcome == ACTIVE:
                    if waiting_since is None:
                        waiting_since = busy_at
                elif run["deleted"] == before:
                    raise Fatal(f"batch ended ({outcome}) before a single DELETE")
    except Busy as busy:
        if str(busy) == "another run is in progress":
            print(f"docker-image-gc: {busy}")
        else:
            print(f"docker-image-gc: {busy} kept the GC out for {LOCK_WAIT_S} s; skipping today")
        print(tally())
        return 0
    except Stopped:
        flush(run)
        print("docker-image-gc: stopped by SIGTERM")
        print(tally())
        return 1
    except ERRORS as exc:
        flush(run)
        print(f"docker-image-gc: {exc}; nothing more removed", file=sys.stderr)
        print(tally())
        return 2
    print(tally())
    return 0


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
