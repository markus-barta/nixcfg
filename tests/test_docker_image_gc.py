"""OPS-327 r34 portable unit and source-mutation tests.

Protection, release baseline, grammar, bounded reads, store/specialisation
closure, fresh snapshots, switch observations, every socket method's absolute
deadline, cooldown/run budgets, signals, status codes and buffered output.
Real Unix trickle tests skip only when this sandbox refuses bind; the injected
29/58-second cases and every source mutant still run without a socket server.
"""

from __future__ import annotations

import atexit
import ast
import builtins
import fcntl
import hashlib
import io
import json
import os
import re
import shutil
import select
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import types
import unittest
import unicodedata
import urllib.parse
import http.client
import importlib.util
from contextlib import ExitStack, contextmanager, redirect_stderr, redirect_stdout, nullcontext
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "hosts" / "csb1" / "docker-image-gc.py"
_harness_spec = importlib.util.spec_from_file_location("gc_unit_harness", REPO / "tests/docker-image-gc-harness.py")
HARNESS = importlib.util.module_from_spec(_harness_spec)
_harness_spec.loader.exec_module(HARNESS)
NOW = 1_800_000_000
DAY = 86400
AEON = "ghcr.io/inspr-at/aeon"

# MutantTests sets this to ("text", source -> source), always on a source copy.
OVERRIDE = None

# Keep each absent socket's private parent alive until this process exits.
# Even a mutant that bypasses the wrapper must never connect to host Docker.
SOCKET_DIRS = ExitStack()
atexit.register(SOCKET_DIRS.close)


def returns_normally(call, *args, **kwargs):
    """A behavioural assertion scoped to the production call under test.

    Keep fixture setup and test-name lookup outside this boundary. Tests of a
    raised exception use assertRaises directly instead.
    """
    try:
        return call(*args, **kwargs)
    except Exception as exc:
        raise AssertionError(f"{call.__qualname__} must return normally; raised {type(exc).__name__}: {exc}") from exc


def load(declared=(), tmp: Path | None = None):
    source = SCRIPT.read_text()
    if OVERRIDE and OVERRIDE[0] == "text":
        source = OVERRIDE[1](source)
    source = source.replace("@DECLARED_REFS@", json.dumps(list(declared)))
    socket_dir = SOCKET_DIRS.enter_context(tempfile.TemporaryDirectory(prefix="ops327-unit-", dir=tmp))
    module = HARNESS.execute_source(source, tmp if tmp is not None else socket_dir)
    module.SOCKET_PATH = str(Path(socket_dir) / "absent.sock")
    if tmp is not None:
        module.STORE_DIR = str(tmp)
        module.INSTANCE_LOCK = str(tmp / "instance.lock")
        module.PROFILES_DIR = str(tmp / "profiles")
        (tmp / "profiles").mkdir(exist_ok=True)
        module.CURRENT_SYSTEM = str(tmp / "current-system")
        module.BOOTED_SYSTEM = str(tmp / "booted-system")
        module.KEEP_DIR = str(tmp / "keep.d")
        (tmp / "keep.d").mkdir(exist_ok=True)
        module.LOCK_PATHS = tuple(str(tmp / f"{n}.lock") for n in ("a", "b", "c"))
        module.SWITCH_LOCK = str(tmp / "switch-to-configuration.lock")
        module.PROC_LOCKS = str(tmp / "proc-locks")
        (tmp / "proc-locks").write_text("")
        module.PROC = str(tmp / "proc")
        (tmp / "proc").mkdir(exist_ok=True)
    return module


def dg(n: int) -> str:
    return f"sha256:{n + 0xD16E57:064x}"


def img(n: int, age_days: float, tags=(), digests=(), size=1_000_000_000):
    return {
        "Id": f"sha256:{n:064x}",
        "Created": int(NOW - age_days * DAY),
        "RepoTags": list(tags),
        "RepoDigests": list(digests),
        "Size": size,
    }


def aeon(n: int, age_days: float, release: str):
    return img(n, age_days, tags=[f"{AEON}:{release}"], digests=[f"{AEON}@{dg(n)}"])


def pin(image) -> str:
    """The name@sha256:<digest> ref a release kit writes for image."""
    return image["RepoDigests"][0]


def ctr(image, state="running"):
    named = (image.get("RepoTags") or [image["Id"]])[0]
    return {"Id": "c" + image["Id"][-11:], "ImageID": image["Id"], "State": state, "Image": named}


def layout(path: Path) -> Path:
    """A minimal complete NixOS system; activation layout is irrelevant to r34."""
    (path / "etc").mkdir(parents=True, exist_ok=True)
    return path


def system(path: Path, services: dict[str, str], stack="csb1") -> Path:
    """A NixOS system at path whose compose spec for stack runs services (name -> image)."""
    layout(path)
    d = path / "etc" / "compose" / stack
    d.mkdir(parents=True, exist_ok=True)
    spec = {"services": {k: {"image": v} for k, v in services.items()}}
    spec["services"]["builder"] = {"build": {"context": "."}}
    (d / "docker-compose.yml").write_text(json.dumps(spec))
    return path


def gen(tmp: Path, n: int) -> Path:
    return tmp / "profiles" / f"system-{n}-link"


def generations(tmp: Path, specs: list[dict[str, str]], first: int = 1) -> None:
    for n, services in enumerate(specs, start=first):
        system(gen(tmp, n), services)


def link(tmp: Path, name: str, target: Path) -> None:
    path = tmp / name
    if path.is_symlink():
        path.unlink()
    path.symlink_to(target)


def keep(tmp: Path, name: str, refs: list[str]) -> Path:
    path = tmp / "keep.d" / name
    path.write_text("".join(f"{r}\n" for r in refs))
    return path


def roles(tmp: Path, live: list[str] | None, previous: list[str] | None) -> None:
    for name, refs in (("aeon-live.refs", live), ("aeon-previous.refs", previous)):
        path = tmp / "keep.d" / name
        if refs is None:
            path.unlink(missing_ok=True)
        else:
            keep(tmp, name, refs)


class FakeApi:
    """A tiny Engine: the two list endpoints, DELETE by ID (stateful) and the build-cache prune."""

    PRUNED = (200, json.dumps({"CachesDeleted": ["x1", "x2"], "SpaceReclaimed": 2_500_000_000}).encode())

    def __init__(self, containers, images, delete=None, on_get=None, after_delete=None, prune=None):
        self.containers = containers
        self.images = images
        self.delete = delete or {}
        self.prune = prune
        self.on_get = on_get
        self.after_delete = after_delete
        self.calls: list[tuple[str, str]] = []
        self.timeouts: list[tuple[str, float | None]] = []

    def __call__(self, method, path, timeout=None, limit=None):
        self.calls.append((method, path))
        self.timeouts.append((method, timeout))
        if method == "GET":
            if self.on_get:
                self.on_get(self, path)
            if path.startswith("/containers/json"):
                return 200, json.dumps(self.containers).encode()
            if path.startswith("/images/json"):
                return 200, json.dumps(self.images).encode()
        if method == "DELETE":
            ref = urllib.parse.unquote(path[len("/images/") :].split("?")[0])
            resp = self.delete.get(ref)
            if callable(resp):
                resp = resp(self)
            if resp is None:
                self.images[:] = [i for i in self.images if i["Id"] != ref]
                resp = (200, b"[]")
            if self.after_delete:
                self.after_delete(self, ref)
            return resp
        if method == "POST" and path.startswith("/build/prune?"):
            resp = self.prune(self) if callable(self.prune) else self.prune
            return resp or self.PRUNED
        return 500, b"unexpected"

    def posts(self) -> list[str]:
        return [p for m, p in self.calls if m == "POST"]

    def deleted(self) -> list[str]:
        return [urllib.parse.unquote(p[len("/images/") :].split("?")[0]) for m, p in self.calls if m == "DELETE"]

    def gets(self, prefix: str) -> int:
        return sum(1 for m, p in self.calls if m == "GET" and p.startswith(prefix))


class Clock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += seconds


@contextmanager
def fake_clock(gc):
    clock = Clock()
    with mock.patch.object(gc.time, "monotonic", clock):
        yield clock


@contextmanager
def preserved_process_state():
    """In-process worker calls get the same isolation as a subprocess exit."""
    handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGALRM, signal.SIGINT, signal.SIGHUP)}
    with mock.patch.dict(os.environ):
        try:
            yield
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)


def in_process_worker(runner, manifest):
    with preserved_process_state():
        return runner.worker(str(manifest))


def run(gc, api, dry=False, manual=False, env=None, sleep=None):
    out, err = io.StringIO(), io.StringIO()
    environ = {"DOCKER_IMAGE_GC_DRY_RUN": "1" if dry else "0", "INVOCATION_ID": "test", **(env or {})}
    pauses = []

    clock = gc.time.monotonic if isinstance(gc.time.monotonic, Clock) else Clock()

    def fake_sleep(seconds):
        pauses.append(seconds)
        if len(pauses) > 10_000:
            raise AssertionError("more than 10000 pauses")
        clock.advance(seconds)
        if sleep:
            sleep(seconds)

    with mock.patch.object(gc.time, "monotonic", clock), mock.patch.dict(os.environ, environ, clear=False), redirect_stdout(out), redirect_stderr(err):
        if manual:
            del os.environ["INVOCATION_ID"]
        rc = returns_normally(gc.main, api=api, now=NOW, sleep=fake_sleep)
    return rc, out.getvalue(), err.getvalue()


def locks_free(gc) -> bool:
    for path in gc.LOCK_PATHS:
        fd = os.open(path, os.O_RDONLY | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return False
        finally:
            os.close(fd)
    return True


class Base(unittest.TestCase):
    declared: tuple = ()

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.gc = load(self.declared, self.tmp)

    def world(self):
        """AEON live L (running) and previous P with role files; app:0 (newest) .. app:4.

        app:3 and app:4 are the candidates, deleted newest first.
        """
        self.L, self.P = aeon(1, 30, "r2"), aeon(2, 40, "r1")
        self.apps = [img(10 + k, 10 + k, tags=[f"app:{k}"]) for k in range(5)]
        self.images = [self.L, self.P, *self.apps]
        self.containers = [ctr(self.L)]
        generations(self.tmp, [{"aeon": pin(self.L)}])
        link(self.tmp, "current-system", gen(self.tmp, 1))
        link(self.tmp, "booted-system", gen(self.tmp, 1))
        roles(self.tmp, [pin(self.L)], [pin(self.P)])

    def api(self, **kwargs):
        return FakeApi(self.containers, self.images, **kwargs)

    def candidates(self) -> list[str]:
        return [self.apps[3]["Id"], self.apps[4]["Id"]]


class PlanTests(unittest.TestCase):
    """The rules on one snapshot, without the release baseline."""

    def setUp(self):
        self.gc = load([])

    def plan(self, containers, images, refs=(), keep=None):
        snap = self.gc.Snapshot(0.0, containers, images, [("sys", {f"s{k}": r for k, r in enumerate(refs)})], keep or {})
        return self.gc.plan(snap, NOW, self.gc.Budget(1e6))

    def ids(self, p):
        return {i["Id"] for i in p.candidates}

    def test_used_by_any_container_is_kept(self):
        a = img(1, 30, tags=["app:1"])
        b = img(2, 30, tags=["other:1"])
        c = img(3, 30, tags=["third:1"])
        filler = [img(10 + k, 1, tags=[f"other:{k + 2}"], digests=[]) for k in range(3)]
        p = self.plan([ctr(a), ctr(c, state="exited")], [a, b, c, *filler])
        self.assertEqual(p.reasons[a["Id"]], "used by a container")
        self.assertEqual(p.reasons[c["Id"]], "used by a container")
        self.assertIn(b["Id"], self.ids(p))

    def test_newest_n_per_repository_including_digest_only_refs(self):
        images = [img(k, 10 + k, digests=[f"{AEON}@{dg(k)}"]) for k in range(1, 6)]
        p = self.plan([ctr(img(99, 1))], images)
        self.assertEqual(self.ids(p), {images[3]["Id"], images[4]["Id"]})

    def test_newest_n_counts_every_repository_of_an_image(self):
        # m is old in repository a (alphabetically first) but the newest of repository z.
        a = [img(k, 5 + k, tags=[f"a:{k}"]) for k in range(1, 4)]
        m = img(9, 30, tags=["a:old", "z:1"])
        z_old = [img(20 + k, 40 + k, tags=[f"z:old{k}"]) for k in range(3)]
        p = self.plan([ctr(img(99, 1))], [*a, m, *z_old])
        self.assertNotIn(m["Id"], self.ids(p))

    def test_registry_port_is_not_a_tag(self):
        self.assertEqual(self.gc.parse_ref("reg:5000/app:1"), ("reg:5000/app", "1", None))
        self.assertEqual(self.gc.parse_ref("reg:5000/app"), ("reg:5000/app", "latest", None))
        self.assertEqual(self.gc.parse_ref("localhost:5000/a/b@" + dg(1)), ("localhost:5000/a/b", None, dg(1)))

    def test_rollback_tag_and_newest_prev_tag_are_kept(self):
        r = img(1, 40, tags=["site:rollback"])
        live = img(2, 30, tags=["hausvogt:live", "hausvogt:release-3"])
        prev_new = img(3, 31, tags=["hausvogt:prev-2", "hausvogt:release-2"])
        prev_old = img(4, 32, tags=["hausvogt:prev-1", "hausvogt:release-1"])
        newer = [img(10 + k, 20, tags=[f"site:v{k}", f"hausvogt:build-{k}"]) for k in range(3)]
        p = self.plan([ctr(live)], [r, live, prev_new, prev_old, *newer])
        self.assertEqual(p.reasons.get(r["Id"]), "tagged :rollback")
        self.assertEqual(p.reasons.get(prev_new["Id"]), "newest prev-* of its repository")
        self.assertIn(prev_old["Id"], self.ids(p))

    def test_janus_repositories_are_always_kept(self):
        engines = [img(k, 50 + k, digests=[f"ghcr.io/inspr-at/janus/janus-engine@{dg(k)}"]) for k in range(1, 7)]
        self.assertEqual(self.plan([ctr(img(99, 1))], engines).candidates, [])

    def test_keep_window_protects_young_images(self):
        young = [img(k, 1, tags=[f"hausv-next:{k}"]) for k in range(1, 6)]
        self.assertEqual(self.plan([ctr(img(99, 1))], young).candidates, [])

    def test_system_ref_without_container_is_kept(self):
        staged = img(1, 30, tags=["ghcr.io/inspr-at/x:v0.1.44"], digests=["ghcr.io/inspr-at/x@" + dg(1)])
        newer = [img(10 + k, 20, tags=[f"ghcr.io/inspr-at/x:v{k}"]) for k in range(3)]
        p = self.plan([ctr(img(99, 1))], [staged, *newer], refs=["ghcr.io/inspr-at/x:v0.1.44@" + dg(1)])
        self.assertEqual(p.reasons.get(staged["Id"]), "declared by a NixOS system on disk")

    def test_keep_d_refs_are_kept(self):
        held = img(1, 30, digests=["x@" + dg(1)])
        newer = [img(10 + k, 20, digests=[f"x@{dg(10 + k)}"]) for k in range(3)]
        p = self.plan([ctr(img(99, 1))], [held, *newer], keep={"hold.refs": ["x@" + dg(1)]})
        self.assertEqual(p.reasons.get(held["Id"]), "listed in keep.d")

    def test_declared_forms(self):
        a = img(1, 30, tags=["redis:latest"])
        b = img(2, 30, tags=["postgres:16-alpine"])
        c = img(3, 30)
        d = img(4, 30, digests=["other@" + dg(4)])
        images = [a, b, c, d]
        index = self.gc.Index(images, self.gc.validate([ctr(img(99, 1))], images))
        for ref, image in (("redis", a), ("postgres:16-alpine", b), (c["Id"], c), ("any/name:v1@" + dg(4), d)):
            self.assertEqual(index.resolve(ref), {image["Id"]}, ref)
        self.assertEqual(index.resolve("redis:7"), set())

    def test_docker_hub_names_are_normalized(self):
        listed = img(1, 30, tags=["redis:7"], digests=["redis@" + dg(1)])
        images = [listed]
        index = self.gc.Index(images, self.gc.validate([ctr(img(99, 1))], images))
        for ref in ("redis:7", "library/redis:7", "docker.io/library/redis:7", "index.docker.io/library/redis:7"):
            self.assertEqual(index.resolve(ref), {listed["Id"]}, ref)
        self.assertEqual(self.gc.parse_ref("Registry/app:1").name, "Registry/app")
        self.assertEqual(self.gc.parse_ref("ghcr.io/inspr-at/aeon:r1").name, AEON)

    def test_declared_docker_hub_alias_protects_the_listed_image(self):
        old = img(1, 30, tags=["redis:7"])
        newer = [img(10 + k, 20, tags=[f"redis:8.{k}"]) for k in range(3)]
        p = self.plan([ctr(img(99, 1))], [old, *newer], refs=["docker.io/library/redis:7"])
        self.assertEqual(p.reasons.get(old["Id"]), "declared by a NixOS system on disk")

    def test_malformed_references_refuse(self):
        for bad in ("!!!@" + dg(1), "Upper:1", "app:", "app:-bad", "a@sha256:abc", " app:1", "a//b:1", ""):
            with self.subTest(bad):
                with self.assertRaises(ValueError):
                    self.gc.parse_ref(bad)

    def test_no_containers_refuses(self):
        with self.assertRaises(self.gc.Fatal):
            self.plan([], [img(1, 30, tags=["a:1"])])

    def test_malformed_listing_refuses(self):
        ok = ctr(img(9, 1))
        no_tags = img(1, 30, digests=["ghcr.io/inspr-at/janus/janus-engine@" + dg(1)])
        del no_tags["RepoTags"]
        no_digests = img(2, 30, tags=["ghcr.io/inspr-at/janus/janus-engine:v1"])
        del no_digests["RepoDigests"]
        no_state = dict(ok)
        del no_state["State"]
        for containers, images in (
            ([{"Id": "c1"}], [img(1, 30)]),
            ([no_state], [img(1, 30)]),
            ([ok], [{"Id": "sha256:" + "1" * 64, "Created": "yesterday", "RepoTags": [], "RepoDigests": []}]),
            ({"oops": 1}, []),
            ([ok], [no_tags]),
            ([ok], [no_digests]),
            ([ok], [{**img(3, 30), "RepoTags": "app:1"}]),
            ([ok], [{**img(4, 30), "RepoDigests": [None]}]),
            ([ok], [{**img(5, 30), "Id": "sha256:" + "5" * 64 + "?force=1&noprune=0&x="}]),
            ([ok], [{**img(6, 30), "Id": "sha256:" + "6" * 63}]),
            ([ok], [img(7, 30, tags=["!!!:1"])]),
            ([ok], [img(8, 30, digests=["app@sha256:abc"])]),
            ([{**ok, "ImageID": "sha256:" + "9" * 64 + "/x"}], [img(9, 30)]),
            ([{**ok, "Image": "Not A Ref"}], [img(9, 30)]),
        ):
            with self.assertRaises(self.gc.Fatal):
                self.plan(containers, images)

    def test_null_names_are_a_legitimate_untagged_image(self):
        untagged = {**img(1, 30), "RepoTags": None, "RepoDigests": None}
        self.assertEqual(self.ids(self.plan([ctr(img(9, 1))], [untagged])), {untagged["Id"]})


class GrammarTests(unittest.TestCase):
    """Each normalization step and ID form decides on its own (Docker's ParseNormalizedNamed and
    dockerd's ID-prefix lookup): an old image, three newer in its repository, one declared spelling."""

    def protected(self, declared, listed, newer, declared_refs=False, old_id=None):
        gc = load([declared] if declared_refs else [])
        old = img(1, 30, tags=[listed] if "@" not in listed else [], digests=[listed] if "@" in listed else [])
        if old_id:
            old["Id"] = old_id
        images = [old, *[img(10 + k, 20, tags=[newer.format(k)]) for k in range(3)]]
        refs = {} if declared_refs else {"s": declared}
        snap = gc.Snapshot(0.0, [ctr(img(99, 1))], images, [("sys", refs)], {})
        p = returns_normally(gc.plan, snap, NOW, gc.Budget(1e6))
        return old["Id"] in p.reasons

    def test_control_another_name_is_not_protection(self):
        self.assertFalse(self.protected("redis:6", "redis:7", "redis:8.{}"))

    def test_default_domain(self):
        self.assertTrue(self.protected("library/redis:7", "docker.io/library/redis:7", "docker.io/library/redis:8.{}"))

    def test_library_prefix(self):
        self.assertTrue(self.protected("docker.io/redis:7", "docker.io/library/redis:7", "docker.io/library/redis:8.{}"))

    def test_index_docker_io(self):
        self.assertTrue(self.protected("index.docker.io/library/redis:7", "docker.io/library/redis:7", "redis:8.{}"))

    def test_latest_default(self):
        self.assertTrue(self.protected("ghcr.io/x/app", "ghcr.io/x/app:latest", "ghcr.io/x/app:v{}"))

    def test_uppercase_first_component_is_a_domain(self):
        self.assertTrue(self.protected("Registry/app:1", "Registry/app:1", "Registry/app:v{}"))
        self.assertEqual(load([]).parse_ref("Registry/app:1").name, "Registry/app")

    def test_localhost_is_a_domain(self):
        gc = load([])
        self.assertEqual(gc.parse_ref("localhost/app:1").name, "localhost/app")
        self.assertEqual(gc.parse_ref("localhost:5000/app").name, "localhost:5000/app")

    def test_port_is_decimal(self):
        self.assertTrue(self.protected("reg:5000/app:1", "reg:5000/app:1", "reg:5000/app:v{}"))
        with self.assertRaises(ValueError):
            load([]).parse_ref("reg:50a0/app:1")

    def test_ipv6_domain(self):
        self.assertTrue(self.protected("[::1]:5000/team/app:v1", "[::1]:5000/team/app:v1", "[::1]:5000/team/app:w{}"))
        self.assertEqual(load([]).parse_ref("[fe80::1]/app").name, "[fe80::1]/app")

    def test_path_length_limit(self):
        path = "/".join(["a" * 127, "b" * 127])  # 255 characters after any domain
        self.assertTrue(self.protected(f"ghcr.io/{path}:1", f"ghcr.io/{path}:1", f"ghcr.io/{path}:v{{}}"))
        gc = load([])
        self.assertEqual(len(gc.parse_ref("a" * 247 + ":1").name.split("/", 1)[1]), 255)  # library/ counts
        for bad in ("a" * 248 + ":1", "ghcr.io/" + "a" * 256 + ":1"):
            with self.assertRaises(ValueError):
                gc.parse_ref(bad)

    def test_uppercase_path_is_rejected(self):
        for bad in ("ghcr.io/Org/app:1", "app/Sub:1"):
            with self.subTest(bad), self.assertRaises(ValueError):
                load([]).parse_ref(bad)

    def test_tagged_digest_resolves_by_digest(self):
        self.assertTrue(self.protected("redis:9@" + dg(1), "redis@" + dg(1), "redis:8.{}"))

    def test_sha384_and_sha512_digests_resolve(self):
        for digest in ("sha384:" + "c" * 96, "sha512:" + "d" * 128):
            with self.subTest(digest):
                self.assertTrue(self.protected("registry.example/team/app@" + digest, "registry.example/team/app@" + digest, "registry.example/team/app:v{}"))
                self.assertTrue(self.protected("registry.example/team/app@" + digest, "registry.example/team/app@" + digest, "registry.example/team/app:v{}", declared_refs=True))

    def test_unsupported_digests_are_rejected(self):
        for bad in ("redis@sha512:" + "a" * 64, "redis@md5:" + "a" * 32, "redis@sha256:" + "A" * 64, "redis@sha384:" + "a" * 128):
            with self.subTest(bad), self.assertRaises(ValueError):
                load([]).parse_ref(bad)

    def test_id_forms_in_a_spec_and_baked_in(self):
        old_id = "sha256:" + "ab12" * 16
        for form in (old_id, old_id[7:], old_id[:19], old_id[7:19]):
            for baked in (False, True):
                with self.subTest(form=form, baked=baked):
                    self.assertTrue(self.protected(form, "app:old", "app:v{}", declared_refs=baked, old_id=old_id))

    def test_id_form_that_is_also_a_name_resolves_both_ways(self):
        # cafe is an ID prefix and a Docker Hub name; the old cafe:latest's ID does not start with cafe.
        self.assertTrue(self.protected("cafe", "cafe:latest", "cafe:v{}"))
        self.assertTrue(self.protected("cafe", "cafe:latest", "cafe:v{}", declared_refs=True))

    def test_a_64_hex_string_is_never_a_name(self):
        with self.assertRaises(ValueError):
            load([]).parse_ref("ab12" * 16)


class SnapshotTests(Base):
    """Local reads: every NixOS system on disk, keep.d, fail-closed on what cannot be read."""

    def test_baseline_ok_deletes_the_candidates(self):
        self.world()
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())
        self.assertIn("2 removed, 0 kept, 0 failed", out)

    def test_every_generation_and_the_booted_system_are_kept(self):
        self.world()
        olds = [img(40 + k, 60 + k, tags=[f"app:old{k}"]) for k in range(3)]
        self.images += olds
        generations(self.tmp, [{"a": "app:old0"}, {"a": "app:old1"}], first=2)
        link(self.tmp, "booted-system", system(self.tmp / "booted", {"a": "app:old2"}))
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())

    def test_unreadable_generation_refuses(self):
        self.world()
        generations(self.tmp, [{"a": "app:3"}], first=2)
        compose = gen(self.tmp, 2) / "etc" / "compose"
        compose.chmod(0)
        self.addCleanup(compose.chmod, 0o755)
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(api.deleted(), [])

    def test_no_compose_spec_refuses(self):
        self.world()
        shutil.rmtree(gen(self.tmp, 1))
        layout(self.tmp / "bare")
        link(self.tmp, "current-system", self.tmp / "bare")
        link(self.tmp, "booted-system", self.tmp / "bare")
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertIn("no compose spec", err)
        self.assertEqual(api.deleted(), [])

    def test_keep_d_missing_or_broken_refuses(self):
        for breakage in ("missing", "bad line", "not utf-8", "short digest", "bad name", "long path", "sha512", "an ID"):
            with self.subTest(breakage):
                self.setUp()
                self.world()
                if breakage == "missing":
                    shutil.rmtree(self.tmp / "keep.d")
                elif breakage == "bad line":
                    keep(self.tmp, "x.refs", ["app:3"])
                elif breakage == "not utf-8":
                    (self.tmp / "keep.d" / "x.refs").write_bytes(b"\xff\xfe\n")
                elif breakage == "short digest":
                    keep(self.tmp, "x.refs", ["x@sha256:abc"])
                elif breakage == "long path":
                    keep(self.tmp, "x.refs", ["a" * 256 + "@" + dg(1)])
                elif breakage == "sha512":
                    keep(self.tmp, "x.refs", ["x@sha512:" + "a" * 128])
                elif breakage == "an ID":
                    keep(self.tmp, "x.refs", [self.apps[3]["Id"]])
                else:
                    keep(self.tmp, "x.refs", ["!!!@" + dg(1)])
                api = self.api()
                rc, out, err = run(self.gc, api)
                self.assertEqual(rc, 2, out + err)
                self.assertEqual(api.deleted(), [])

    def test_dangling_or_missing_system_refuses(self):
        for breakage in ("dangling generation", "missing booted", "dangling current", "dangling compose", "missing spec"):
            with self.subTest(breakage):
                self.setUp()
                self.world()
                if breakage == "dangling generation":
                    (self.tmp / "profiles" / "system-2-link").symlink_to(self.tmp / "gone")
                elif breakage == "missing booted":
                    (self.tmp / "booted-system").unlink()
                elif breakage == "dangling current":
                    link(self.tmp, "current-system", self.tmp / "gone")
                elif breakage == "dangling compose":
                    system(gen(self.tmp, 2), {"a": "app:0"})
                    shutil.rmtree(gen(self.tmp, 2) / "etc" / "compose")
                    (gen(self.tmp, 2) / "etc" / "compose").symlink_to(self.tmp / "gone")
                else:
                    system(gen(self.tmp, 2), {"a": "app:0"})
                    (gen(self.tmp, 2) / "etc" / "compose" / "csb1" / "docker-compose.yml").unlink()
                api = self.api()
                rc, out, err = run(self.gc, api)
                self.assertEqual(rc, 2, out + err)
                self.assertEqual(api.deleted(), [])

    def test_system_without_compose_declares_nothing(self):
        self.world()
        layout(gen(self.tmp, 2))
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())

    def test_malformed_spec_image_refuses(self):
        for image in ("Bad Image!", 7, None):
            with self.subTest(image):
                self.setUp()
                self.world()
                d = layout(gen(self.tmp, 2)) / "etc" / "compose" / "csb1"
                d.mkdir(parents=True)
                (d / "docker-compose.yml").write_text(json.dumps({"services": {"a": {"image": image}}}))
                api = self.api()
                rc, out, err = run(self.gc, api)
                self.assertEqual(rc, 2, out + err)
                self.assertEqual(api.deleted(), [])

    def test_only_refs_files_are_read(self):
        self.world()
        (self.tmp / "keep.d" / ".aeon-live.refs.tmp").write_text("half written")
        (self.tmp / "keep.d" / "aeon-previous.pre-r2").write_text("not a refs file\n")
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())

    def test_comments_and_blank_lines_are_allowed(self):
        self.world()
        (self.tmp / "keep.d" / "aeon-previous.refs").write_text(f"# r1\n\n{pin(self.P)}\n")
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())


class IsolationTests(Base):
    """Each protection rule protects on its own (design r6 4.8): only that rule names image I."""

    def old_image(self):
        # app:0..2 are newer, so newest-3 never protects I; it is 60 days old.
        self.world()
        self.I = img(50, 60, tags=["app:9"])
        self.images.append(self.I)

    def assert_protected(self):
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())

    def test_unprotected_control(self):
        self.old_image()
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), [*self.candidates(), self.I["Id"]])

    def test_generation_alone(self):
        self.old_image()
        generations(self.tmp, [{"a": "app:9"}], first=2)
        self.assert_protected()

    def test_current_alone(self):
        self.old_image()
        link(self.tmp, "current-system", system(self.tmp / "cur", {"aeon": pin(self.L), "a": "app:9"}))
        self.assert_protected()

    def test_booted_alone(self):
        self.old_image()
        link(self.tmp, "booted-system", system(self.tmp / "boot", {"a": "app:9"}))
        self.assert_protected()

    def test_created_container_alone(self):
        self.old_image()
        self.containers.append(ctr(self.I, state="created"))
        self.assert_protected()


class DeclaredRefsTests(Base):
    """The Nix-declared spec (DECLARED_REFS, baked in at build time) protects on its own."""

    declared = ("docker.io/library/app:9",)

    def test_declared_alone(self):
        self.world()
        self.I = img(50, 60, tags=["app:9"])
        self.images.append(self.I)
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())

    def test_malformed_declared_ref_refuses(self):
        self.gc.DECLARED_REFS = ["Bad Ref!"]
        self.world()
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(api.deleted(), [])


class BaselineTests(Base):
    """keep.d contract v2: any failed check deletes nothing in any repository, build cache included."""

    def assert_nothing_deleted(self, api, why):
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), [])
        self.assertIn(f"release baseline not met ({why}", out)
        self.assertNotIn("POST", [m for m, _ in api.calls])

    def test_bootstrap_without_role_files_deletes_nothing(self):
        self.world()
        roles(self.tmp, None, None)
        self.assert_nothing_deleted(self.api(), "aeon-live.refs is missing")

    def test_missing_previous_deletes_nothing_in_any_repository(self):
        self.world()
        roles(self.tmp, [pin(self.L)], None)
        self.assert_nothing_deleted(self.api(), "aeon-previous.refs is missing")

    def test_leftover_staged_files_do_not_stand_in_for_previous(self):
        self.world()
        roles(self.tmp, [pin(self.L)], None)
        keep(self.tmp, "aeon-staged-r0.refs", [pin(self.P)])
        keep(self.tmp, "aeon-staged-r3.refs", [f"{AEON}@{dg(77)}"])
        self.assert_nothing_deleted(self.api(), "aeon-previous.refs is missing")

    def test_empty_previous_deletes_nothing(self):
        self.world()
        (self.tmp / "keep.d" / "aeon-previous.refs").write_text("# nothing\n")
        self.assert_nothing_deleted(self.api(), "aeon-previous.refs is empty")

    def test_empty_live_deletes_nothing(self):
        self.world()
        (self.tmp / "keep.d" / "aeon-live.refs").write_text("")
        self.assert_nothing_deleted(self.api(), "aeon-live.refs is empty")

    def test_previous_equal_to_live_deletes_nothing(self):
        self.world()
        roles(self.tmp, [pin(self.L)], [pin(self.L)])
        self.assert_nothing_deleted(self.api(), "aeon-previous.refs equals aeon-live.refs")

    def test_live_not_naming_the_running_image_deletes_nothing(self):
        self.world()
        roles(self.tmp, [pin(self.P)], [pin(self.L)])
        self.assert_nothing_deleted(self.api(), "running AEON container")

    def test_aeon_container_known_only_by_its_image_field(self):
        # Its image is gone from the listing; Image alone says AEON, and live.refs does not name it.
        self.world()
        ghost = aeon(70, 5, "r3")
        self.containers.append({**ctr(ghost), "Image": f"{AEON}:r3"})
        self.assert_nothing_deleted(self.api(), "running AEON container")

    def test_no_running_aeon_container_deletes_nothing(self):
        self.world()
        self.containers[:] = [ctr(self.L, state="exited")]
        self.assert_nothing_deleted(self.api(), "no AEON container is running")

    def test_companion_named_only_in_previous_is_kept(self):
        self.world()
        x = img(60, 60, tags=["companion:old"], digests=["companion@" + dg(60)])
        newer = [img(61 + k, 20, tags=[f"companion:{k}"]) for k in range(3)]
        self.images += [x, *newer]
        roles(self.tmp, [pin(self.L)], [pin(self.P), pin(x)])
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())

    def test_dropped_previous_keeps_the_companion_because_nothing_is_deleted(self):
        self.world()
        x = img(60, 60, tags=["companion:old"], digests=["companion@" + dg(60)])
        newer = [img(61 + k, 20, tags=[f"companion:{k}"]) for k in range(3)]
        self.images += [x, *newer]
        roles(self.tmp, [pin(self.L)], None)
        self.assert_nothing_deleted(self.api(), "aeon-previous.refs is missing")

    def test_staged_file_protects_a_prestaged_image(self):
        self.world()
        staged = img(70, 20, digests=[f"{AEON}@{dg(70)}"])
        old = [aeon(71 + k, 15, f"r9{k}") for k in range(3)]
        self.images += [staged, *old]
        keep(self.tmp, "aeon-staged-r3.refs", [pin(staged)])
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertNotIn(staged["Id"], api.deleted())


class FreshSnapshotTests(Base):
    """The one rule: a fresh snapshot and plan before every DELETE; what was published before its t0 counts."""

    def first_delete_then(self, change, target):
        """Run with change(api) applied right after the first DELETE; return the deleted IDs."""
        done = []

        def after_delete(api, ref):
            if not done:
                done.append(ref)
                change(api)

        api = self.api(after_delete=after_delete)
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(done, [self.apps[3]["Id"]])
        self.assertIn(self.apps[4]["Id"], api.deleted())
        return api.deleted()

    def with_old_image(self, **names):
        """I: old, deleted after app:3 and app:4 unless something protects it.

        Repository x has three newer images, so a digest in x alone never protects I.
        """
        self.world()
        self.I = img(50, 60, **names)
        self.images += [self.I, *(img(90 + k, 20, digests=[f"x@{dg(90 + k)}"]) for k in range(3))]

    def test_every_delete_has_its_own_snapshot(self):
        self.world()
        api = self.api()
        run(self.gc, api)
        # Two deletes, then a final snapshot that finds nothing more to do.
        self.assertEqual(api.gets("/containers/json"), 3)
        self.assertEqual(api.gets("/images/json"), 3)

    def test_stale_reference_regression(self):
        self.with_old_image()  # dangling: no name at all

        def change(api):
            self.I["RepoDigests"] = ["x@" + dg(50)]
            keep(self.tmp, "hold.refs", ["x@" + dg(50)])

        self.assertNotIn(self.I["Id"], self.first_delete_then(change, self.I))

    def test_generation_published_before_t0(self):
        self.with_old_image(tags=["app:9"])
        change = lambda api: generations(self.tmp, [{"a": "app:9"}], first=2)  # noqa: E731
        self.assertNotIn(self.I["Id"], self.first_delete_then(change, self.I))

    def test_generation_by_digest_published_before_t0(self):
        self.with_old_image(tags=["app:9"])

        def change(api):
            self.I["RepoDigests"] = ["app@" + dg(50)]
            generations(self.tmp, [{"a": "app:9@" + dg(50)}], first=2)

        self.assertNotIn(self.I["Id"], self.first_delete_then(change, self.I))

    def test_current_system_retargeted_before_t0(self):
        self.with_old_image(tags=["app:9"])
        change = lambda api: link(self.tmp, "current-system", system(self.tmp / "next", {"a": "app:9"}))  # noqa: E731
        self.assertNotIn(self.I["Id"], self.first_delete_then(change, self.I))

    def test_booted_system_retargeted_before_t0(self):
        self.with_old_image(tags=["app:9"])
        change = lambda api: link(self.tmp, "booted-system", system(self.tmp / "boot", {"a": "app:9"}))  # noqa: E731
        self.assertNotIn(self.I["Id"], self.first_delete_then(change, self.I))

    def test_container_created_before_t0(self):
        self.with_old_image(tags=["app:9"])
        change = lambda api: self.containers.append(ctr(self.I, state="created"))  # noqa: E731
        self.assertNotIn(self.I["Id"], self.first_delete_then(change, self.I))

    def test_rank_promotion_is_seen(self):
        self.world()
        done = []

        def after_delete(api, ref):
            if not done:
                done.append(ref)
                api.images.remove(self.apps[0])  # app:4 becomes one of the newest 3

        api = self.api(after_delete=after_delete)
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), [self.apps[3]["Id"]])

    def test_newest_prev_promotion_is_seen(self):
        self.world()
        hv = [img(80 + k, 5 + k, tags=[f"hv:b{k}"]) for k in range(3)]
        prev2 = img(84, 20, tags=["hv:prev-2"])
        prev1 = img(85, 25, tags=["hv:prev-1"])
        self.images += [*hv, prev2, prev1]
        done = []

        def after_delete(api, ref):
            if not done:
                done.append(ref)
                api.images.remove(prev2)

        api = self.api(after_delete=after_delete)
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertNotIn(prev1["Id"], api.deleted())

    def test_keep_d_content_change_with_identical_metadata(self):
        self.with_old_image(digests=["x@" + dg(50)])
        path = keep(self.tmp, "hold.refs", ["x@" + dg(51)])
        before = path.stat()

        def change(api):
            keep(self.tmp, "hold.refs", ["x@" + dg(50)])
            os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
            self.assertEqual((path.stat().st_size, path.stat().st_mtime_ns), (before.st_size, before.st_mtime_ns))

        self.assertNotIn(self.I["Id"], self.first_delete_then(change, self.I))


class SnapshotAgeTests(Base):
    """t0 is taken before the first request; a snapshot older than 2 s never leads to a DELETE."""

    def slow_get(self, clock, prefix, times=1):
        seen = []

        def on_get(api, path):
            if path.startswith(prefix) and len(seen) < times:
                seen.append(path)
                clock.advance(2.5)

        return on_get

    def calls_before_first_delete(self, api):
        first = next(n for n, (m, _) in enumerate(api.calls) if m == "DELETE")
        return api.calls[:first]

    def test_slow_containers_get_leads_to_no_delete_from_that_snapshot(self):
        self.world()
        with fake_clock(self.gc) as clock:
            api = self.api(on_get=self.slow_get(clock, "/containers/json"))
            rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        before = self.calls_before_first_delete(api)
        self.assertEqual([p for m, p in before if m == "GET"].count("/containers/json?all=1"), 2)
        self.assertIn("snapshot too slow", out)
        self.assertEqual(api.deleted(), self.candidates())

    def test_t0_is_taken_before_the_first_request(self):
        self.world()
        with fake_clock(self.gc) as clock:
            api = self.api(on_get=self.slow_get(clock, "/images/json"))
            rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(sum(1 for m, p in self.calls_before_first_delete(api) if p == "/images/json"), 2)

    def test_three_slow_snapshots_end_the_batch(self):
        self.world()
        with fake_clock(self.gc) as clock:
            api = self.api(on_get=self.slow_get(clock, "/containers/json", times=99))
            rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(out.count("snapshot too slow"), 3)
        self.assertEqual(api.deleted(), [])
        self.assertTrue(locks_free(self.gc))

    def test_fast_snapshot_deletes(self):
        self.world()
        with fake_clock(self.gc) as clock:
            api = self.api(on_get=lambda api, path: clock.advance(0.5))
            rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())


class BudgetTests(Base):
    """No new operation once the batch budget is spent; the deadline is checked between steps."""

    def timed_locks(self, clock):
        holds: list[float] = []
        real = self.gc.deploy_locks

        @contextmanager
        def tracked(*args, **kwargs):
            with real(*args, **kwargs):
                start = clock()
                try:
                    yield
                finally:
                    holds.append(clock() - start)

        self.gc.deploy_locks = tracked
        return holds

    def test_lock_hold_is_the_budget_plus_one_delete(self):
        self.world()
        extra = [img(30 + k, 30 + k, tags=[f"app:x{k}"]) for k in range(6)]
        self.images += extra
        with fake_clock(self.gc) as clock:
            holds = self.timed_locks(clock)
            api = self.api(after_delete=lambda api, ref: clock.advance(25))
            rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(len(api.deleted()), 8)
        self.assertGreater(len(holds), 2)
        self.assertLessEqual(max(holds), self.gc.BATCH_S + 25, holds)

    def test_deadline_crossed_during_plan(self):
        self.world()
        real_index = self.gc.Index
        with fake_clock(self.gc) as clock:
            holds = self.timed_locks(clock)

            def slow_index(images, names):
                clock.advance(61)
                return real_index(images, names)

            self.gc.Index = slow_index
            api = self.api()
            rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(api.deleted(), [])
        self.assertEqual(holds, [61])
        self.assertTrue(locks_free(self.gc))

    def test_budget_spent_in_the_fence_reads(self):
        # The last fence read (booted-system) stalls past the deadline; the snapshot is only 1.5 s old.
        self.world()
        real_snapshot, real_plan, real_realpath = self.gc.snapshot, self.gc.plan, os.path.realpath
        armed = []
        with fake_clock(self.gc) as clock:

            def snapshot(api, budget):
                clock.advance(9)  # t0 one second before the deadline
                return real_snapshot(api, budget)

            def plan(snap, now, budget):
                p = real_plan(snap, now, budget)
                armed.append(1)
                return p

            def realpath(path, *args, **kwargs):
                if armed and str(path) == self.gc.BOOTED_SYSTEM:
                    clock.advance(1.5)
                return real_realpath(path, *args, **kwargs)

            self.gc.snapshot, self.gc.plan = snapshot, plan
            api = self.api()
            with mock.patch.object(os.path, "realpath", realpath):
                rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(api.deleted(), [])

    def test_stalled_local_read_starts_no_new_operation(self):
        self.world()
        real_read = self.gc.Reader.read
        with fake_clock(self.gc) as clock:

            def stalled(reader, path, cap, over=None, **kwargs):
                clock.advance(70)
                return real_read(reader, path, cap, over, **kwargs)

            self.gc.Reader.read = stalled
            api = self.api()
            rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(api.deleted(), [])
        self.assertEqual(api.gets("/containers/json"), 1)


class CapTests(Base):
    """Every cap + 1 stops the run before any delete; at the cap the run proceeds."""

    def assert_capped(self, api=None):
        api = api or self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(api.deleted(), [])
        return err

    def assert_runs(self):
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())

    def test_container_listing_cap(self):
        self.world()
        size = len(json.dumps(self.containers).encode())
        self.gc.CAP_CONTAINERS_BYTES = size
        self.assert_runs()
        self.setUp()
        self.world()
        self.gc.CAP_CONTAINERS_BYTES = size - 1
        self.assertIn("larger than", self.assert_capped())

    def test_image_listing_cap(self):
        self.world()
        self.gc.CAP_IMAGES_BYTES = len(json.dumps(self.images).encode()) - 1
        self.assertIn("larger than", self.assert_capped())

    def test_keep_file_cap(self):
        self.world()
        size = (self.tmp / "keep.d" / "aeon-live.refs").stat().st_size
        self.gc.CAP_KEEP_FILE_BYTES = size
        self.assert_runs()
        self.setUp()
        self.world()
        self.gc.CAP_KEEP_FILE_BYTES = size - 1
        self.assertIn("larger than", self.assert_capped())

    def test_keep_files_cap(self):
        self.world()
        self.gc.CAP_KEEP_FILES = 1
        self.assertIn("keep.d files", self.assert_capped())

    def test_spec_cap(self):
        self.world()
        spec = gen(self.tmp, 1) / "etc" / "compose" / "csb1" / "docker-compose.yml"
        self.gc.CAP_SPEC_BYTES = spec.stat().st_size - 1
        self.assertIn("larger than", self.assert_capped())

    def test_generations_cap(self):
        self.world()
        generations(self.tmp, [{"a": "app:0"}], first=2)
        self.gc.CAP_GENERATIONS = 1
        self.assertIn("NixOS generations", self.assert_capped())

    def test_specs_per_system_cap(self):
        self.world()
        system(gen(self.tmp, 1), {"b": "app:0"}, stack="other")
        self.gc.CAP_SPECS_PER_SYSTEM = 1
        self.assertIn("compose specs", self.assert_capped())

    def test_spec_bytes_total_cap(self):
        self.world()
        size = (gen(self.tmp, 1) / "etc" / "compose" / "csb1" / "docker-compose.yml").stat().st_size
        # current-system shares generation 1's spec: one distinct path, counted once.
        self.gc.CAP_SPEC_BYTES_TOTAL = size
        self.assert_runs()
        self.setUp()
        self.world()
        generations(self.tmp, [{"aeon": pin(self.L)}], first=2)
        self.gc.CAP_SPEC_BYTES_TOTAL = 2 * size - 1
        self.assertIn("bytes of compose specs", self.assert_capped())

    def test_spec_bytes_total_is_enforced_while_reading(self):
        self.world()
        size = (gen(self.tmp, 1) / "etc" / "compose" / "csb1" / "docker-compose.yml").stat().st_size
        system(gen(self.tmp, 2), {"aeon": pin(self.L), "pad": "x" * 64})
        self.gc.CAP_SPEC_BYTES_TOTAL = size + 10
        consumed = []
        real_read = self.gc.Reader.read

        def recording(reader, path, cap, over=None, **kwargs):
            if path.endswith("docker-compose.yml"):
                consumed.append(min(os.path.getsize(path), cap + 1))
            return real_read(reader, path, cap, over, **kwargs)

        self.gc.Reader.read = recording
        self.assertIn("bytes of compose specs", self.assert_capped())
        self.assertEqual(len(consumed), 2)
        self.assertLessEqual(sum(consumed), self.gc.CAP_SPEC_BYTES_TOTAL + 1)

    def test_refs_cap(self):
        self.world()
        # One ref in the spec, one each in the role files.
        self.gc.CAP_REFS = 3
        self.assert_runs()
        self.setUp()
        self.world()
        self.gc.CAP_REFS = 2
        self.assertIn("image references", self.assert_capped())

    def test_dir_entries_cap(self):
        self.world()
        for k in range(5):
            (self.tmp / "profiles" / f"other-{k}").mkdir()
        self.gc.CAP_DIR_ENTRIES = 5
        self.assertIn("directory entries", self.assert_capped())


class TimingTests(Base):
    """At the aggregate caps, every step between two deadline checks stays below 5 s."""

    def slowest_step(self, api) -> float:
        marks: list[float] = []
        real_check = self.gc.Budget.check

        def check(budget):
            marks.append(time.perf_counter())
            real_check(budget)

        self.gc.Budget.check = check
        self.gc.BATCH_S = 1e6
        budget = self.gc.Budget(1e6)
        marks.append(time.perf_counter())
        snap = self.gc.snapshot(api, budget)
        self.gc.plan(snap, NOW, budget)
        marks.append(time.perf_counter())
        self.total = marks[-1] - marks[0]
        return max(b - a for a, b in zip(marks, marks[1:]))

    def report(self, shape, seconds):
        if os.environ.get("OPS327_TIMING"):
            print(f"\n  {shape}: slowest step {seconds:.3f} s, snapshot + plan {self.total:.2f} s", file=sys.stderr)

    def base(self):
        layout(self.tmp / "bare")
        link(self.tmp, "current-system", self.tmp / "bare")
        link(self.tmp, "booted-system", self.tmp / "bare")
        self.L = aeon(1, 30, "r2")
        self.containers = [ctr(self.L)]
        roles(self.tmp, [pin(self.L)], [f"{AEON}@{dg(2)}"])

    def test_200_generations_of_16_specs_of_20_kib(self):
        self.base()
        ref = 0
        per_spec = (self.gc.CAP_REFS - 100) // (self.gc.CAP_GENERATIONS * self.gc.CAP_SPECS_PER_SYSTEM)
        for g in range(1, self.gc.CAP_GENERATIONS + 1):
            for s in range(self.gc.CAP_SPECS_PER_SYSTEM):
                services = {}
                for _ in range(per_spec):
                    ref += 1
                    services[f"svc{ref}"] = {"image": f"ghcr.io/inspr-at/svc{ref % 97}:v{ref}@{dg(ref)}"}
                spec = {"services": services}
                spec["x-pad"] = "p" * (20 * 1024 - len(json.dumps(spec)) - 12)
                d = layout(gen(self.tmp, g)) / "etc" / "compose" / f"s{s}"
                d.mkdir(parents=True)
                (d / "docker-compose.yml").write_text(json.dumps(spec))
        self.assertLessEqual(ref, self.gc.CAP_REFS - 2)
        seconds = self.slowest_step(FakeApi(self.containers, [self.L]))
        self.report(f"{self.gc.CAP_GENERATIONS} x {self.gc.CAP_SPECS_PER_SYSTEM} specs, {ref} refs", seconds)
        self.assertLess(seconds, 5)

    def test_a_few_1_mib_specs(self):
        self.base()
        for s in range(8):
            spec = {"services": {"a": {"image": f"app:{s}"}}, "x-pad": "p" * (self.gc.CAP_SPEC_BYTES - 200)}
            d = layout(gen(self.tmp, 1)) / "etc" / "compose" / f"s{s}"
            d.mkdir(parents=True)
            (d / "docker-compose.yml").write_text(json.dumps(spec))
        seconds = self.slowest_step(FakeApi(self.containers, [self.L]))
        self.report("8 specs of 1 MiB", seconds)
        self.assertLess(seconds, 5)

    def test_100000_refs_against_a_16_mib_listing(self):
        self.base()
        images, size, n = [self.L], 0, 100
        while True:
            image = img(n, 30 + n % 50, tags=[f"ghcr.io/inspr-at/r{n % 211}:v{n}"], digests=[f"ghcr.io/inspr-at/r{n % 211}@{dg(n)}"])
            size += len(json.dumps(image)) + 2
            if size > self.gc.CAP_IMAGES_BYTES - 4096:
                break
            images.append(image)
            n += 1
        refs = [f"ghcr.io/inspr-at/r{k % 211}@{dg(k)}" for k in range(100, 100 + self.gc.CAP_REFS - 1000)]
        per_spec = len(refs) // 16
        for s in range(16):
            system(gen(self.tmp, 1), {f"x{k}": r for k, r in enumerate(refs[s * per_spec : (s + 1) * per_spec])}, stack=f"s{s}")
        api = FakeApi(self.containers, images)
        self.assertLessEqual(len(json.dumps(images)), self.gc.CAP_IMAGES_BYTES)
        seconds = self.slowest_step(api)
        self.report(f"{len(images)} images ({size >> 20} MiB), {len(refs)} refs", seconds)
        self.assertLess(seconds, 5)


class WatchdogTests(Base):
    """GETs end at the watchdog, even a trickling one; a DELETE has no client timeout."""

    def trickling_engine(self, path: str, total_s: float = 3.0) -> None:
        """An Engine on a unix socket whose answer arrives one byte every 50 ms."""
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            server.bind(path)
        except PermissionError as exc:
            server.close()
            self.skipTest(f"sandbox refuses Unix bind: {exc}")
        server.listen(1)
        stop = threading.Event()
        n = int(total_s / 0.05)

        def serve():
            conn, _ = server.accept()
            with conn:
                conn.recv(65536)
                try:
                    conn.sendall(
                        f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {n + 1}\r\n\r\n[".encode()
                    )
                    for _ in range(n):
                        if stop.wait(0.05):
                            break
                        conn.sendall(b" ")
                except OSError:
                    pass

        threading.Thread(target=serve, daemon=True).start()
        self.addCleanup(server.close)
        self.addCleanup(stop.set)

    def test_trickling_get_is_ended_by_the_watchdog(self):
        path = str(self.tmp / "d.sock")
        self.trickling_engine(path)
        self.gc.SOCKET_PATH = path
        self.gc.GET_WATCHDOG_S = 0.3
        start = time.monotonic()
        with self.assertRaises(self.gc.Interrupted):
            self.gc.get_json(self.gc.docker_api, "/images/json", 1024, self.gc.Budget(60))
        self.assertLess(time.monotonic() - start, 1.5)

    def test_gets_have_a_watchdog_and_deletes_absolute_timeout(self):
        self.world()
        api = self.api()
        run(self.gc, api)
        for method, timeout in api.timeouts:
            if method == "GET":
                self.assertLessEqual(timeout, self.gc.GET_WATCHDOG_S)
            elif method == "DELETE":
                self.assertEqual(timeout, self.gc.CALL_DEADLINE_S)
        self.assertIn("DELETE", [m for m, _ in api.timeouts])


class WatchdogTeardownTests(unittest.TestCase):
    """SIGALRM landing anywhere in the watchdog never leaks its handler (design r6 4.2)."""

    def test_signal_on_every_line_restores_the_handler(self):
        gc = load([])
        code = gc.watchdog.__wrapped__.__code__
        lines = sorted({line for _, _, line in code.co_lines() if line and line > code.co_firstlineno})
        sentinel = lambda signum, frame: None  # noqa: E731
        before = signal.getsignal(signal.SIGALRM)
        self.addCleanup(signal.signal, signal.SIGALRM, before)
        fired_somewhere = 0
        for target in lines:
            with self.subTest(line=target):
                signal.signal(signal.SIGALRM, sentinel)
                fired = []

                def tracer(frame, event, arg):
                    if frame.f_code is not code:
                        return None
                    if event == "line" and frame.f_lineno == target and not fired:
                        fired.append(target)
                        signal.raise_signal(signal.SIGALRM)
                    return tracer

                sys.settrace(tracer)
                try:
                    with gc.watchdog(30):
                        pass
                except gc.Interrupted:
                    pass
                finally:
                    sys.settrace(None)
                    signal.setitimer(signal.ITIMER_REAL, 0)
                fired_somewhere += bool(fired)
                self.assertIs(signal.getsignal(signal.SIGALRM), sentinel)
        self.assertGreater(fired_somewhere, 4)


class LockTests(Base):
    """Non-blocking, all or nothing: a deploy that holds one lock and waits on another never deadlocks."""

    def hold(self, path):
        fd = os.open(path, os.O_RDONLY | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        self.addCleanup(os.close, fd)
        return fd

    def test_lock_held_by_a_deploy_skips_the_day(self):
        self.world()
        self.hold(self.gc.LOCK_PATHS[1])
        self.gc.LOCK_WAIT_S = 0
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertIn("skipping today", out)
        self.assertEqual(api.calls, [])

    def test_lock_contender_is_never_deadlocked(self):
        self.world()
        a, b = self.gc.LOCK_PATHS[0], self.gc.LOCK_PATHS[1]
        got_a, holding_b, gc_took_a = threading.Event(), threading.Event(), threading.Event()
        real_flock = fcntl.flock
        main = threading.current_thread()

        def flock(fd, op):
            real_flock(fd, op)
            if threading.current_thread() is main and os.fstat(fd).st_ino == os.stat(a).st_ino:
                gc_took_a.set()  # the first compose lock, after the instance cooldown

        def contender():
            fb = os.open(b, os.O_RDONLY | os.O_CREAT, 0o600)
            fa = os.open(a, os.O_RDONLY | os.O_CREAT, 0o600)
            try:
                real_flock(fb, fcntl.LOCK_EX)
                holding_b.set()
                gc_took_a.wait(5)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:  # flock -w 5 on a, while holding b
                    try:
                        real_flock(fa, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        got_a.set()
                        break
                    except OSError:
                        time.sleep(0.005)
            finally:
                os.close(fa)
                os.close(fb)

        t = threading.Thread(target=contender, daemon=True)
        t.start()
        holding_b.wait(5)
        api = self.api()
        with mock.patch.object(self.gc.fcntl, "flock", flock):
            rc, out, err = run(self.gc, api, sleep=lambda s: time.sleep(0.05))
        t.join(10)
        self.assertTrue(gc_took_a.is_set())
        self.assertTrue(got_a.is_set(), "the GC held a while waiting for b")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())


class ActivationTests(Base):
    """The fence never takes switch-to-configuration's lock; it reads /proc/locks and the system links."""

    def token(self) -> str:
        st = os.stat(self.gc.SWITCH_LOCK)
        return f"{os.major(st.st_dev):02x}:{os.minor(st.st_dev):02x}:{st.st_ino}"

    def switch(self, waiter=False):
        Path(self.gc.SWITCH_LOCK).touch()
        arrow = "-> " if waiter else ""
        Path(self.gc.PROC_LOCKS).write_text(
            "1: POSIX  ADVISORY  WRITE 1993560 00:e1:451718 0 EOF\n"
            f"2: {arrow}FLOCK  ADVISORY  WRITE 4242 {self.token()} 0 EOF\n"
        )

    def unswitch(self):
        Path(self.gc.PROC_LOCKS).write_text("1: POSIX  ADVISORY  WRITE 1993560 00:e1:451718 0 EOF\n")

    def after_first_plan(self, change):
        real, calls = self.gc.plan, []

        def plan(snap, now, budget):
            p = real(snap, now, budget)
            calls.append(1)
            if len(calls) == 1:
                change()
            return p

        self.gc.plan = plan

    def test_lock_file_alone_is_not_an_activation(self):
        self.world()
        Path(self.gc.SWITCH_LOCK).touch()
        self.unswitch()
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())

    def test_activation_at_acquisition_waits_then_skips_the_day(self):
        for waiter in (False, True):
            with self.subTest(waiter=waiter):
                self.setUp()
                self.world()
                self.switch(waiter)
                self.gc.LOCK_WAIT_S = 0
                api = self.api()
                rc, out, err = run(self.gc, api)
                self.assertEqual(rc, 0, out + err)
                self.assertIn("kept the GC out", out)
                self.assertEqual(api.calls, [])

    def test_activation_after_the_snapshot_stops_the_delete(self):
        for waiter in (False, True):
            with self.subTest(waiter=waiter):
                self.setUp()
                self.world()
                self.after_first_plan(lambda: self.switch(waiter))
                self.gc.LOCK_WAIT_S = 0
                api = self.api()
                rc, out, err = run(self.gc, api)
                self.assertEqual(rc, 0, out + err)
                self.assertEqual(api.deleted(), [])
                self.assertIn("giving the locks back", out)
                self.assertTrue(locks_free(self.gc))

    def test_the_run_resumes_once_the_activation_is_over(self):
        self.world()
        self.after_first_plan(lambda: self.switch())
        pauses = []

        def sleep(seconds):
            pauses.append(seconds)
            self.unswitch()

        api = self.api()
        rc, out, err = run(self.gc, api, sleep=sleep)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())

    def retarget_after_first_plan(self, name):
        """The gate's scenario: after the snapshot, an activation points name at a system naming app:3."""
        self.world()
        self.after_first_plan(lambda: link(self.tmp, name, system(self.tmp / "next", {"a": "app:3", "aeon": pin(self.L)})))
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertIn("changed since the snapshot", out)
        self.assertEqual(api.deleted(), [self.apps[4]["Id"]])

    def test_current_system_retargeted_after_the_snapshot(self):
        self.retarget_after_first_plan("current-system")

    def test_booted_system_retargeted_after_the_snapshot(self):
        self.retarget_after_first_plan("booted-system")

    def test_switch_lock_is_never_locked(self):
        self.world()
        Path(self.gc.SWITCH_LOCK).touch()
        self.unswitch()
        opened = []
        real_open = os.open

        def tracking_open(path, *args, **kwargs):
            opened.append(str(path))
            fd = real_open(path, *args, **kwargs)
            if str(path) == self.gc.SWITCH_LOCK:
                # The lock-taking mutant deliberately retains this descriptor.
                # Release it even when the behavioural assertion fails.
                self.addCleanup(os.close, fd)
            return fd

        with mock.patch.object(self.gc.os, "open", tracking_open):
            rc, out, err = run(self.gc, self.api())
        self.assertEqual(rc, 0, out + err)
        self.assertNotIn(self.gc.SWITCH_LOCK, opened)


class AbsenceTests(Base):
    """Only ENOENT means absent; EACCES on lstat is never read as "gone"."""

    def denied_lstat(self, target: Path):
        real = os.lstat

        def lstat(path, *args, **kwargs):
            if str(path) == str(target):
                raise PermissionError(13, "Permission denied", str(path))
            return real(path, *args, **kwargs)

        return mock.patch.object(os, "lstat", lstat)

    def test_generation_link_lstat_denied_refuses(self):
        self.world()
        link(self.tmp / "profiles", "system-2-link", self.tmp / "gone")  # realpath: ENOENT
        api = self.api()
        real = os.path.realpath
        def unresolved(path, *a, **kw):
            if str(path) == str(gen(self.tmp, 2)): raise FileNotFoundError('target missing')
            return real(path, *a, **kw)
        with self.denied_lstat(gen(self.tmp, 2)), mock.patch.object(os.path, 'realpath', unresolved):
            rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(api.deleted(), [])

    def test_compose_lstat_denied_refuses(self):
        self.world()
        system(gen(self.tmp, 2), {"a": "app:0"})
        compose = gen(self.tmp, 2) / "etc" / "compose"
        shutil.rmtree(compose)
        compose.symlink_to(self.tmp / "gone")  # scandir: ENOENT
        api = self.api()
        with self.denied_lstat(Path(os.path.realpath(gen(self.tmp, 2))) / "etc" / "compose"):  # the GC reads under the resolved system
            rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(api.deleted(), [])


class PruneTests(Base):
    """Build cache older than the keep window goes once, after the images, through the same fence."""

    def test_once_after_the_images_with_absolute_timeout(self):
        self.world()
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.posts(), [self.gc.PRUNE_PATH])
        self.assertEqual([m for m, _ in api.calls if m != "GET"], ["DELETE", "DELETE", "POST"])
        self.assertIn(("POST", self.gc.CALL_DEADLINE_S), api.timeouts)
        query = urllib.parse.parse_qs(self.gc.PRUNE_PATH.split("?", 1)[1])
        self.assertEqual(query, {"all": ["1"], "filters": ['{"until": ["48h"]}']})
        self.assertIn("pruned build cache older than 48 h: 2.50 GB", out)
        self.assertTrue(locks_free(self.gc))

    def test_filters_keep_young_cache_and_reach_all_old_cache(self):
        self.world()
        cache = [
            {"id": "old-shared", "age_h": 72, "dangling": False},
            {"id": "old-dangling", "age_h": 72, "dangling": True},
            {"id": "young-shared", "age_h": 1, "dangling": False},
            {"id": "young-dangling", "age_h": 1, "dangling": True},
        ]

        def prune(api):
            # dockerd's semantics: without all only dangling records; until keeps anything younger.
            path = api.posts()[-1]
            query = urllib.parse.parse_qs(path.split("?", 1)[1])
            reach_all = query.get("all") == ["1"]
            until = json.loads(query.get("filters", ["{}"])[0]).get("until", ["0h"])[0]
            hours = int(until.rstrip("h"))
            gone_ = [r for r in cache if (reach_all or r["dangling"]) and r["age_h"] > hours]
            cache[:] = [r for r in cache if r not in gone_]
            return 200, json.dumps({"CachesDeleted": [r["id"] for r in gone_], "SpaceReclaimed": len(gone_)}).encode()

        rc, out, err = run(self.gc, self.api(prune=prune))
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(sorted(r["id"] for r in cache), ["young-dangling", "young-shared"])

    def test_runs_when_no_image_is_deletable(self):
        self.world()
        self.images[:] = [self.L, self.P, *self.apps[:3]]
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), [])
        self.assertEqual(api.posts(), [self.gc.PRUNE_PATH])

    def test_not_during_an_activation(self):
        self.world()
        def switching(api, ref):
            if ref == self.apps[4]["Id"]:
                Path(self.gc.SWITCH_LOCK).touch()
                st = os.stat(self.gc.SWITCH_LOCK)
                token = f"{os.major(st.st_dev):02x}:{os.minor(st.st_dev):02x}:{st.st_ino}"
                Path(self.gc.PROC_LOCKS).write_text(f"1: FLOCK ADVISORY WRITE 1 {token} 0 EOF\n")
        real_plan = self.gc.plan
        def plan(snap, now, budget):
            p = real_plan(snap, now, budget)
            if not p.deletable:
                switching(None, self.apps[4]["Id"])
            return p
        self.gc.plan = plan
        api = self.api()
        self.gc.LOCK_WAIT_S = 0
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())
        self.assertEqual(api.posts(), [])

    def test_errors_stop_the_run(self):
        def boom(api):
            raise ConnectionResetError("dockerd went away")

        for name, prune in (
            ("500", (500, b"boom")),
            ("no SpaceReclaimed", (200, b'{"CachesDeleted": []}')),
            ("not JSON", (200, b"<html>")),
            ("exception", boom),
            ("over the cap", lambda api: (200, b" " * (self.gc.CAP_PRUNE_BYTES + 1))),
        ):
            with self.subTest(name):
                self.setUp()
                self.world()
                api = self.api(prune=prune)
                rc, out, err = run(self.gc, api)
                self.assertEqual(rc, 2, out + err)
                self.assertEqual(len(api.posts()), 1)
                self.assertTrue(locks_free(self.gc))


class OutputTests(Base):
    """Nothing reaches stdout or stderr while a compose lock is held (design r6 4.1)."""

    class Guarded(io.StringIO):
        def __init__(self, gc, violations):
            super().__init__()
            self.gc, self.violations = gc, violations

        def write(self, text):
            if text.strip() and not locks_free(self.gc):
                self.violations.append(text)
            return super().write(text)

    def guarded_run(self, api, sleep=None):
        violations = []
        out, err = self.Guarded(self.gc, violations), self.Guarded(self.gc, violations)
        env = {"DOCKER_IMAGE_GC_DRY_RUN": "0", "INVOCATION_ID": "test"}
        with fake_clock(self.gc) as clock, mock.patch.dict(os.environ, env), redirect_stdout(out), redirect_stderr(err):
            rc = self.gc.main(api=api, now=NOW, sleep=lambda s: (clock.advance(s), sleep(s) if sleep else None))
        return rc, out.getvalue() + err.getvalue(), violations

    def test_no_output_under_lock_on_any_path(self):
        cases = {
            "done": lambda: self.api(),
            "409": lambda: self.api(delete={self.apps[3]["Id"]: (409, b"in use")}),
            "500": lambda: self.api(delete={self.apps[3]["Id"]: (500, b"boom")}),
            "sigterm": lambda: self.api(after_delete=lambda api, ref: self.gc.STOP.set()),
            "baseline": lambda: (roles(self.tmp, [pin(self.L)], None), self.api())[1],
            "slow": lambda: self.api(),
            "prune 500": lambda: self.api(prune=(500, b"boom")),
        }
        for name, make in cases.items():
            with self.subTest(name):
                self.setUp()
                self.world()
                api = make()
                if name == "slow":
                    self.gc.SNAPSHOT_MAX_AGE_S = -1
                rc, text, violations = self.guarded_run(api)
                self.assertTrue(text.strip(), name)
                self.assertEqual(violations, [], name)

    def test_no_output_under_lock_on_activation(self):
        self.world()
        Path(self.gc.SWITCH_LOCK).touch()
        Path(self.gc.PROC_LOCKS).write_text("")
        real = self.gc.plan

        def plan(snap, now, budget):
            p = real(snap, now, budget)
            st = os.stat(self.gc.SWITCH_LOCK)
            token = f"{os.major(st.st_dev):02x}:{os.minor(st.st_dev):02x}:{st.st_ino}"
            Path(self.gc.PROC_LOCKS).write_text(f"1: FLOCK  ADVISORY  WRITE 1 {token} 0 EOF\n")
            return p

        self.gc.plan = plan
        self.gc.LOCK_WAIT_S = 0
        rc, text, violations = self.guarded_run(self.api())
        self.assertIn("giving the locks back", text)
        self.assertEqual(violations, [])


class SigtermTests(Base):
    """SIGTERM sets a flag; the call in flight finishes and nothing new starts."""

    def test_sigterm_during_lock_acquisition(self):
        self.world()
        real_flock = fcntl.flock
        calls = []

        def flock(fd, op):
            real_flock(fd, op)
            calls.append(op)
            if len(calls) == 1:
                self.gc.STOP.set()

        api = self.api()
        with mock.patch.object(self.gc.fcntl, "flock", flock):
            rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 1, out + err)
        self.assertEqual(len(calls), 1)
        self.assertEqual(api.calls, [])
        self.assertTrue(locks_free(self.gc))

    def test_sigterm_during_a_get(self):
        self.world()
        api = self.api(on_get=lambda api, path: self.gc.STOP.set())
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 1, out + err)
        self.assertEqual(api.deleted(), [])
        self.assertTrue(locks_free(self.gc))

    def test_sigterm_during_a_delete_lets_it_finish(self):
        self.world()
        previous = signal.signal(signal.SIGTERM, self.gc.STOP.set)
        self.addCleanup(signal.signal, signal.SIGTERM, previous)
        api = self.api(after_delete=lambda api, ref: os.kill(os.getpid(), signal.SIGTERM))
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 1, out + err)
        self.assertEqual(api.deleted(), [self.apps[3]["Id"]])
        self.assertIn("1 removed", out)
        self.assertIn("stopped by SIGTERM", out)

    def test_sigterm_during_the_prune_still_exits_1(self):
        self.world()
        api = self.api(prune=lambda api: self.gc.STOP.set())
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 1, out + err)
        self.assertEqual(api.deleted(), self.candidates())
        self.assertEqual(len(api.posts()), 1)
        self.assertIn("stopped by SIGTERM", out)

    def test_sigterm_and_a_fatal_exit_2(self):
        def stop_then(status):
            def answer(api):
                self.gc.STOP.set()
                return status
            return answer

        for name, kwargs in (
            ("prune 500", {"prune": stop_then((500, b"boom"))}),
            ("delete 500", {"delete": {"__first__": None}}),
        ):
            with self.subTest(name):
                self.setUp()
                self.world()
                if name == "delete 500":
                    kwargs = {"delete": {self.apps[3]["Id"]: stop_then((500, b"boom"))}}
                api = self.api(**kwargs)
                rc, out, err = run(self.gc, api)
                self.assertEqual(rc, 2, out + err)

    def test_sigterm_during_the_last_snapshot_still_exits_1(self):
        self.world()
        gets = []

        def on_get(api, path):
            gets.append(path)
            if len(gets) == 5:  # the third snapshot finds nothing left to do
                self.gc.STOP.set()

        api = self.api(on_get=on_get)
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 1, out + err)
        self.assertEqual(api.deleted(), self.candidates())
        self.assertNotIn("POST", [m for m, _ in api.calls])

    def test_cli_installs_and_restores_the_handler(self):
        seen = []
        before = signal.getsignal(signal.SIGTERM)
        with mock.patch.object(self.gc, "main", lambda: seen.append(signal.getsignal(signal.SIGTERM)) or 0):
            self.assertEqual(self.gc.cli([]), 0)
        self.assertEqual(seen, [self.gc.STOP.set])
        self.assertEqual(signal.getsignal(signal.SIGTERM), before)
        with redirect_stderr(io.StringIO()):
            self.assertEqual(self.gc.cli(["record", "x"]), 64)


class DeleteTests(Base):
    """By ID, noprune, never forced, never untagged; a 409 keeps the image."""

    def test_deletes_by_id_without_pruning_parents(self):
        self.world()
        api = self.api()
        run(self.gc, api)
        self.assertEqual(
            [p for m, p in api.calls if m == "DELETE"], [f"/images/{i}?noprune=1" for i in self.candidates()]
        )

    def test_409_keeps_and_never_untags(self):
        self.world()
        self.apps[3]["RepoTags"].append("app:3-alias")
        conflict = (409, b"conflict: unable to delete (must be forced) - image is referenced in multiple repositories")
        api = self.api(delete={self.apps[3]["Id"]: conflict})
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())
        self.assertEqual(self.apps[3]["RepoTags"], ["app:3", "app:3-alias"])
        self.assertIn("1 removed, 1 kept, 0 failed", out)

    def test_in_use_409_is_kept_and_404_counts_as_removed(self):
        self.world()
        api = self.api(
            delete={
                self.apps[3]["Id"]: (409, b"image is being used by running container"),
                self.apps[4]["Id"]: (404, b"No such image"),
            }
        )
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertIn("1 removed, 1 kept, 0 failed", out)

    def test_other_errors_stop_the_run(self):
        self.world()
        api = self.api(delete={self.apps[3]["Id"]: (500, b"boom")})
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(api.deleted(), [self.apps[3]["Id"]])
        self.assertIn("0 removed, 0 kept, 1 failed", out)

    def test_an_exception_during_a_delete_stops_the_run(self):
        for exc in (ConnectionResetError("reset"), http.client.RemoteDisconnected("gone"), http.client.IncompleteRead(b"")):
            with self.subTest(type(exc).__name__):
                self.setUp()
                self.world()

                def boom(api, exc=exc):
                    raise exc

                api = self.api(delete={self.apps[3]["Id"]: boom})
                rc, out, err = run(self.gc, api)
                self.assertEqual(rc, 2, out + err)
                self.assertEqual(api.deleted(), [self.apps[3]["Id"]])

    def test_injected_id_is_never_sent(self):
        self.world()
        self.apps[3]["Id"] = "sha256:" + "3" * 64 + "?force=1&noprune=0&x="
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(api.deleted(), [])


class RunTests(Base):
    """Only a run under systemd deletes; policy knobs are not a thing."""

    def test_manual_run_never_deletes(self):
        self.world()
        api = self.api()
        rc, out, err = run(self.gc, api, manual=True)
        self.assertEqual(rc, 0, out + err)
        self.assertIn("not under systemd", out)
        self.assertEqual([m for m, _ in api.calls], ["GET", "GET"])

    def test_dry_run_changes_nothing(self):
        self.world()
        api = self.api()
        rc, out, err = run(self.gc, api, dry=True)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual([m for m, _ in api.calls], ["GET", "GET"])
        self.assertIn(f"would remove {self.apps[3]['Id'][7:19]}", out)
        self.assertIn("2 images would go", out)

    def test_dry_run_reports_the_baseline(self):
        self.world()
        roles(self.tmp, [pin(self.L)], None)
        rc, out, err = run(self.gc, self.api(), dry=True)
        self.assertEqual(rc, 0, out + err)
        self.assertIn("release baseline not met (aeon-previous.refs is missing); a real run deletes nothing", out)

    def test_only_gets_image_deletes_and_one_prune(self):
        self.world()
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual({m for m, _ in api.calls}, {"GET", "DELETE", "POST"})
        self.assertEqual(api.posts(), [self.gc.PRUNE_PATH])

    def test_environment_cannot_weaken_retention(self):
        self.world()
        younger = [img(20 + k, 1.5, tags=[f"young:y{k}"]) for k in range(2)]
        self.images += younger
        env = {"DOCKER_IMAGE_GC_KEEP_DAYS": "1", "DOCKER_IMAGE_GC_KEEP_NEWEST": "1"}
        api = self.api()
        rc, out, err = run(self.gc, api, env=env)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.deleted(), self.candidates())


# Harmful edits of the script. Each must make every listed test fail.
def swap(*pairs):
    def apply(source):
        for old, new in pairs:
            source = source.replace(old, new)
        return source

    apply.pairs = pairs
    return ("text", apply)


def _reuse_plan():
    return swap(
        ('SOCKET_PATH =', 'MUTANT_CACHE = {}\nSOCKET_PATH ='),
        ('    names = validate(snap.containers, snap.images)\n',
         '    if id(budget) in MUTANT_CACHE: return MUTANT_CACHE[id(budget)][1]\n    names = validate(snap.containers, snap.images)\n'),
        ('    return result\n', '    MUTANT_CACHE[id(budget)] = (budget, result)\n    return result\n'),
    )


def _keep_by_metadata():
    return swap(
        ('SOCKET_PATH =', 'MUTANT_CACHE = {}\nSOCKET_PATH ='),
        ('        try:\n            names = self.listdir(KEEP_DIR)\n',
         '        sig = tuple(sorted((e.name, e.stat().st_size, e.stat().st_mtime_ns) for e in os.scandir(KEEP_DIR)))\n'
         '        if MUTANT_CACHE.get("sig") == sig: return MUTANT_CACHE["keep"]\n'
         '        try:\n            names = self.listdir(KEEP_DIR)\n'),
        ('        return keep\n', '        MUTANT_CACHE.update(sig=sig, keep=keep)\n        return keep\n'),
    )


def _cache_generations():
    return swap(
        ('SOCKET_PATH =', 'MUTANT_CACHE = {}\nSOCKET_PATH ='),
        ('        listed = self.listdir(PROFILES_DIR)\n',
         '        if id(self.budget) in MUTANT_CACHE: return MUTANT_CACHE[id(self.budget)][1]\n'
         '        listed = self.listdir(PROFILES_DIR)\n'),
        ('        return list(systems.items()), current, booted\n',
         '        result = list(systems.items()), current, booted\n'
         '        MUTANT_CACHE[id(self.budget)] = (self.budget, result)\n'
         '        return result\n'),
    )


RESOLVE = "        for ref in refs:\n            for image_id in index.resolve(ref):\n"


def _stale(why):
    return swap(
        ('SOCKET_PATH =', 'STALE = {}\nSOCKET_PATH ='),
        (
            RESOLVE,
            f"        stale = STALE.setdefault((id(budget), why), index) if why == {why!r} else index\n"
            "        for ref in refs:\n            for image_id in stale.resolve(ref):\n",
        ),
    )


FRESH = "FreshSnapshotTests.test_"
MUTANTS = {
    "reuse the batch plan": (
        _reuse_plan(),
        [FRESH + "generation_published_before_t0", FRESH + "container_created_before_t0", FRESH + "rank_promotion_is_seen"],
    ),
    "selective staleness (keep.d against the batch listing)": (
        _stale("listed in keep.d"),
        [FRESH + "stale_reference_regression"],
    ),
    "keep.d by metadata": (_keep_by_metadata(), [FRESH + "keep_d_content_change_with_identical_metadata"]),
    "newest-N over tags only": (
        swap(("        repos = {ref.name for ref in refs}\n", "        repos = {ref.name for ref in refs if ref.tag}\n")),
        ["PlanTests.test_newest_n_per_repository_including_digest_only_refs"],
    ),
    "newest-N over the first repository only": (
        swap(("        for repo in sorted(repos):\n", "        for repo in sorted(repos)[:1]:\n")),
        ["PlanTests.test_newest_n_counts_every_repository_of_an_image"],
    ),
    "drop the previous-exists check": (
        swap(("snap.keep.get(PREVIOUS_REFS)\n", 'snap.keep.get(PREVIOUS_REFS, ["absent"])\n')),
        ["BaselineTests.test_missing_previous_deletes_nothing_in_any_repository"],
    ),
    "drop the non-empty check": (
        swap(('    if not previous:\n        return f"{PREVIOUS_REFS} is empty"\n', "")),
        ["BaselineTests.test_empty_previous_deletes_nothing"],
    ),
    "drop the differ check": (
        swap(('    if set(live) == set(previous):\n        return f"{PREVIOUS_REFS} equals {LIVE_REFS}"\n', "")),
        ["BaselineTests.test_previous_equal_to_live_deletes_nothing"],
    ),
    "drop the live-names-running check": (
        swap(('        if c["ImageID"] not in live_ids:\n', "        if False:\n")),
        ["BaselineTests.test_live_not_naming_the_running_image_deletes_nothing"],
    ),
    "drop the running-AEON check": (
        swap(('    if not running:\n        return "no AEON container is running"\n', "")),
        ["BaselineTests.test_no_running_aeon_container_deletes_nothing"],
    ),
    "role-file failure stops AEON images only": (
        swap(
            (
                "        self.deletable = [] if baseline else candidates\n",
                "        self.deletable = [i for i in candidates if not any(n.startswith(AEON_REPO) for n in names_of(i))] if baseline else candidates\n",
            ),
            (
                '            if p.baseline:\n                say(run, f"docker-image-gc: release baseline not met ({p.baseline}); nothing deleted")\n                return BASELINE\n',
                "",
            ),
        ),
        ["BaselineTests.test_missing_previous_deletes_nothing_in_any_repository"],
    ),
    "t0 after the image listing": (
        swap(
            (
                "    t0 = time.monotonic()\n"
                '    containers = get_json(api, "/containers/json?all=1", CAP_CONTAINERS_BYTES, budget)\n'
                '    images = get_json(api, "/images/json", CAP_IMAGES_BYTES, budget)\n',
                '    containers = get_json(api, "/containers/json?all=1", CAP_CONTAINERS_BYTES, budget)\n'
                '    images = get_json(api, "/images/json", CAP_IMAGES_BYTES, budget)\n'
                "    t0 = time.monotonic()\n",
            )
        ),
        ["SnapshotAgeTests.test_t0_is_taken_before_the_first_request"],
    ),
    "drop a per-item cap (keep.d file)": (
        swap(("KEEP_DIR, name), CAP_KEEP_FILE_BYTES, device=device, nofollow=True)", "KEEP_DIR, name), 10**9)")),
        ["CapTests.test_keep_file_cap"],
    ),
    "drop an aggregate cap (spec bytes)": (
        swap(("min(CAP_SPEC_BYTES, left)", "CAP_SPEC_BYTES")),
        ["CapTests.test_spec_bytes_total_cap"],
    ),
    "aggregate cap checked after reading": (
        swap(
            (
                "                data = self.read(real, min(CAP_SPEC_BYTES, left), over)\n",
                "                data = self.read(real, CAP_SPEC_BYTES, over)\n"
                "                if self.spec_bytes + len(data) > CAP_SPEC_BYTES_TOTAL:\n"
                '                    raise CapExceeded(f"more than {CAP_SPEC_BYTES_TOTAL} bytes of compose specs")\n',
            )
        ),
        ["CapTests.test_spec_bytes_total_is_enforced_while_reading"],
    ),
    "cache generation protection": (
        _cache_generations(),
        # A cached running or booted system is caught by the fence's retarget check.
        [FRESH + "generation_published_before_t0"],
    ),
    "cache spec reference resolution": (
        _stale("declared by a NixOS system on disk"),
        [FRESH + "generation_by_digest_published_before_t0"],
    ),
    'remove the watchdog': (swap(*[('    with watchdog(seconds):\n', '    if True:\n')]), ['R34DeadlineTests.test_injected_get_watchdog']),
    'a blocking lock': (swap(*[('                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n', '                fcntl.flock(fd, fcntl.LOCK_EX)\n')]), ['R34LockTests.test_all_lock_attempts_nonblocking']),
    "untag a multi-repository image": (
        swap(
            (
                '            text = body[:200].decode("utf-8", "replace")\n',
                '            if status == 409 and b"referenced in" in body:\n'
                '                for name in names_of(image):\n'
                '                    api("DELETE", "/images/" + urllib.parse.quote(name, safe="/:@") + "?noprune=1", timeout=None, limit=CAP_RESPONSE_BYTES)\n'
                '            text = body[:200].decode("utf-8", "replace")\n',
            )
        ),
        ["DeleteTests.test_409_keeps_and_never_untags"],
    ),
    "delete without INVOCATION_ID": (
        swap(('        if not os.environ.get("INVOCATION_ID"):\n', "        if False:\n")),
        ["RunTests.test_manual_run_never_deletes"],
    ),
    "no age check before DELETE": (
        swap(("            if age > SNAPSHOT_MAX_AGE_S:\n", "            if False:\n")),
        ["SnapshotAgeTests.test_slow_containers_get_leads_to_no_delete_from_that_snapshot"],
    ),
    "skip numbered generations": (
        swap(("            if target is not None:\n                roots.append(target)\n", "            pass\n")),
        ["IsolationTests.test_generation_alone", FRESH + "generation_published_before_t0"],
    ),
    "skip the running system": (
        swap(("roots.extend((current, booted))", "roots.extend((booted,))")),
        ["IsolationTests.test_current_alone"],
    ),
    "skip the booted system": (
        swap(("roots.extend((current, booted))", "roots.extend((current,))")),
        ["IsolationTests.test_booted_alone"],
    ),
    "drop container protection": (
        swap(('        protect(c["ImageID"], "used by a container")\n', "        pass\n")),
        ["PlanTests.test_used_by_any_container_is_kept", "IsolationTests.test_created_container_alone"],
    ),
    "running containers only": (
        swap(("    for c in snap.containers:\n        protect(", '    for c in [c for c in snap.containers if c["State"] == "running"]:\n        protect(')),
        ["PlanTests.test_used_by_any_container_is_kept", "IsolationTests.test_created_container_alone"],
    ),
    "drop DECLARED_REFS": (
        swap(('"declared in the Nix compose spec": DECLARED_REFS,', '"declared in the Nix compose spec": [],')),
        ["DeclaredRefsTests.test_declared_alone"],
    ),
    "drop keep.d protection": (
        swap(('"listed in keep.d": [ref for refs in snap.keep.values() for ref in refs],', '"listed in keep.d": [],')),
        ["PlanTests.test_keep_d_refs_are_kept", "BaselineTests.test_staged_file_protects_a_prestaged_image"],
    ),
    "drop :rollback": (
        swap(('        if any(ref.tag == "rollback" for ref in refs):\n', "        if False:\n")),
        ["PlanTests.test_rollback_tag_and_newest_prev_tag_are_kept"],
    ),
    "drop newest prev-*": (
        swap(('            if ref.tag and ref.tag.startswith("prev-") and ref.name not in prev_seen:\n', "            if False:\n")),
        ["PlanTests.test_rollback_tag_and_newest_prev_tag_are_kept"],
    ),
    "protect every prev-*": (
        swap((' and ref.name not in prev_seen:\n', ":\n")),
        ["PlanTests.test_rollback_tag_and_newest_prev_tag_are_kept"],
    ),
    "drop Janus": (
        swap(("        if repos & PROTECTED_REPOS:\n", "        if False:\n")),
        ["PlanTests.test_janus_repositories_are_always_kept"],
    ),
    "drop newest-N": (
        swap(("            if per_repo[repo] <= KEEP_NEWEST:\n", "            if per_repo[repo] <= 0:\n")),
        ["PlanTests.test_newest_n_per_repository_including_digest_only_refs", "PlanTests.test_newest_n_counts_every_repository_of_an_image"],
    ),
    "drop the age window": (
        swap(('        if image["Created"] >= cutoff:\n', "        if False:\n")),
        ["PlanTests.test_keep_window_protects_young_images"],
    ),
    "drop the fence's budget check": (
        swap(
            (
                "                raise Stopped()\n            budget.check()\n            age = time.monotonic() - snap.t0\n",
                "                raise Stopped()\n            age = time.monotonic() - snap.t0\n",
            )
        ),
        ["BudgetTests.test_budget_spent_in_the_fence_reads"],
    ),
    "drop the activation fence": (
        swap(("            why = activation(snap, budget)\n", "            why = None\n")),
        [
            "ActivationTests.test_activation_after_the_snapshot_stops_the_delete",
            "ActivationTests.test_current_system_retargeted_after_the_snapshot",
        ],
    ),
    'never read `/proc/locks`': (swap(*[('    data = Reader(budget).read(PROC_LOCKS, CAP_PROC_LOCKS_BYTES, device=os.stat(PROC).st_dev)', '    data = b""')]), ['ActivationTests.test_activation_after_the_snapshot_stops_the_delete']),
    'ignore waiter lines': (swap(*[('    for line in data.decode("ascii", "strict").splitlines():', '    for line in (line for line in data.decode("ascii", "strict").splitlines() if "->" not in line):')]), ['ActivationTests.test_activation_after_the_snapshot_stops_the_delete']),
    "no running-system retarget check": (
        swap(("((CURRENT_SYSTEM, snap.current), (BOOTED_SYSTEM, snap.booted))", "((BOOTED_SYSTEM, snap.booted),)")),
        ["ActivationTests.test_current_system_retargeted_after_the_snapshot"],
    ),
    "no booted-system retarget check": (
        swap(("((CURRENT_SYSTEM, snap.current), (BOOTED_SYSTEM, snap.booted))", "((CURRENT_SYSTEM, snap.current),)")),
        ["ActivationTests.test_booted_system_retargeted_after_the_snapshot"],
    ),
    "lexists decides a generation is gone": (
        swap(("            if not required and gone(link):\n", "            if not required and not os.path.lexists(link):\n")),
        ["AbsenceTests.test_generation_link_lstat_denied_refuses"],
    ),
    "lexists decides compose is absent": (
        swap(("            if not gone(compose):\n", "            if os.path.lexists(compose):\n")),
        ["AbsenceTests.test_compose_lstat_denied_refuses"],
    ),
    "no name union for ID forms": (
        swap(("            found |= {image_id for image_id in self.ids if image_id.startswith(prefix)}\n", "            return {image_id for image_id in self.ids if image_id.startswith(prefix)}\n")),
        ["GrammarTests.test_id_form_that_is_also_a_name_resolves_both_ways"],
    ),
    "sha256-only digests": (
        swap(('DIGEST = re.compile(r"^(?:sha256:[0-9a-f]{64}|sha384:[0-9a-f]{96}|sha512:[0-9a-f]{128})$")', 'DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")')),
        ["GrammarTests.test_sha384_and_sha512_digests_resolve"],
    ),
    "keep.d takes any digest": (
        swap(("    if need_digest and not (ref.digest and SHA256_DIGEST.match(ref.digest)):\n", "    if need_digest and not ref.digest:\n")),
        ["SnapshotTests.test_keep_d_missing_or_broken_refuses"],
    ),
    "prune without all": (
        swap(('{"all": "1", "filters":', '{"filters":')),
        ["PruneTests.test_filters_keep_young_cache_and_reach_all_old_cache"],
    ),
    "prune without until": (
        swap(('"filters": json.dumps({"until": [f"{KEEP_DAYS * 24}h"]})', '"filters": json.dumps({})')),
        ["PruneTests.test_filters_keep_young_cache_and_reach_all_old_cache"],
    ),
    "Stopped beats Fatal": (
        swap(
            (
                "    except ERRORS as exc:\n        flush(run)\n        print(f\"docker-image-gc: {exc}; nothing more removed\", file=sys.stderr)\n",
                "    except ERRORS as exc:\n        flush(run)\n        if STOP:\n            return 1\n        print(f\"docker-image-gc: {exc}; nothing more removed\", file=sys.stderr)\n",
            )
        ),
        ["SigtermTests.test_sigterm_and_a_fatal_exit_2"],
    ),
    "prune before the fence": (
        swap(
            (
                "            if not todo and run[\"pruned\"]:\n                return DONE\n",
                "            if not todo and run[\"pruned\"]:\n                return DONE\n"
                "            if not todo:\n"
                "                run[\"pruned\"] = True\n"
                "                api(\"POST\", PRUNE_PATH, timeout=None, limit=CAP_PRUNE_BYTES)\n"
                "                return DONE\n",
            )
        ),
        ["PruneTests.test_not_during_an_activation"],
    ),
    "prune on a failed baseline": (
        swap(("            if p.baseline:\n", '            if p.baseline and run["pruned"]:\n')),
        ["BaselineTests.test_missing_previous_deletes_nothing_in_any_repository"],
    ),
    "prune without the keep window": (
        swap(('{"until": [f"{KEEP_DAYS * 24}h"]}', '{"until": ["1h"]}')),
        ["PruneTests.test_once_after_the_images_with_absolute_timeout"],
    ),
    "prune error tolerated": (
        swap(("                    raise Fatal(f\"build cache prune -> {status}", "                    pass  # (f\"build cache prune -> {status}")),
        ["PruneTests.test_errors_stop_the_run"],
    ),
    "no prune": (
        swap(("            if not todo and run[\"pruned\"]:\n", "            if not todo:\n")),
        ["PruneTests.test_once_after_the_images_with_absolute_timeout", "PruneTests.test_runs_when_no_image_is_deletable"],
    ),
    "loose image IDs": (
        swap(
            ('            or not IMAGE_ID.fullmatch(i["Id"])\n', '            or not i["Id"].startswith("sha256:")\n'),
            ('            if not IMAGE_ID.fullmatch(image["Id"]):\n', "            if False:\n"),
        ),
        ["DeleteTests.test_injected_id_is_never_sent", "PlanTests.test_malformed_listing_refuses"],
    ),
    "loose repository grammar": (
        swap(("    if not PATH.match(path):\n", "    if False:\n")),
        [
            "SnapshotTests.test_keep_d_missing_or_broken_refuses",
            "SnapshotTests.test_malformed_spec_image_refuses",
            "PlanTests.test_malformed_references_refuse",
            "DeclaredRefsTests.test_malformed_declared_ref_refuses",
        ],
    ),
    "keep.d without a digest": (
        swap(('check_ref(line, f"{name}:{n}", need_digest=True)', 'check_ref(line, f"{name}:{n}")')),
        ["SnapshotTests.test_keep_d_missing_or_broken_refuses"],
    ),
    "no library/ prefix": (
        swap(('        path = "library/" + path\n', "        path = path\n")),
        ["PlanTests.test_docker_hub_names_are_normalized", "PlanTests.test_declared_docker_hub_alias_protects_the_listed_image"],
    ),
    "no default registry": (
        swap(('        domain, path = "docker.io", rest\n', '        domain, path = "", rest\n')),
        ["PlanTests.test_docker_hub_names_are_normalized", "PlanTests.test_declared_docker_hub_alias_protects_the_listed_image"],
    ),
    "dangling generation tolerated": (
        swap(('            raise Fatal(f"{link} does not resolve; refusing to judge") from None\n', "            return None\n")),
        ["SnapshotTests.test_dangling_or_missing_system_refuses"],
    ),
    "dangling compose tolerated": (
        swap(('                raise Fatal(f"{compose} does not resolve; refusing to judge") from None\n', "                return {}\n")),
        ["SnapshotTests.test_dangling_or_missing_system_refuses"],
    ),
    "unexpected DELETE status tolerated": (
        swap(('                raise Fatal(f"DELETE {image[\'Id\']} -> {status}: {text}")\n', "                pass\n")),
        ["DeleteTests.test_other_errors_stop_the_run"],
    ),
    "print under the locks": (
        swap(('    run["log"].append((err, line[:LINE_MAX]))\n', "    print(line[:LINE_MAX], file=sys.stderr if err else sys.stdout)\n")),
        ["OutputTests.test_no_output_under_lock_on_any_path", "OutputTests.test_no_output_under_lock_on_activation"],
    ),
    "watchdog teardown race": (
        swap(
            (
                "    previous = signal.getsignal(signal.SIGALRM)\n"
                "    try:\n"
                "        try:\n"
                "            signal.signal(signal.SIGALRM, fire)\n"
                "            signal.setitimer(signal.ITIMER_REAL, max(seconds, 0.001))\n"
                "            yield\n"
                "        finally:\n"
                "            armed = False\n"
                "            signal.setitimer(signal.ITIMER_REAL, 0)\n"
                "    finally:\n"
                "        signal.signal(signal.SIGALRM, previous)\n",
                "    previous = signal.signal(signal.SIGALRM, fire)\n"
                "    signal.setitimer(signal.ITIMER_REAL, max(seconds, 0.001))\n"
                "    try:\n"
                "        yield\n"
                "    finally:\n"
                "        signal.setitimer(signal.ITIMER_REAL, 0)\n"
                "        signal.signal(signal.SIGALRM, previous)\n"
                "        armed = False\n",
            )
        ),
        ["WatchdogTeardownTests.test_signal_on_every_line_restores_the_handler"],
    ),
    'SIGTERM after the last batch ignored': (swap(*[('                if STOP:\n                    raise Stopped()\n                if over or outcome', '                if over or outcome')]), ['SigtermTests.test_sigterm_during_the_prune_still_exits_1']),
    "no index.docker.io rewrite": (
        swap(('    if domain == "index.docker.io":\n        domain = "docker.io"\n', "")),
        ["GrammarTests.test_index_docker_io"],
    ),
    "no :latest default": (
        swap(('    if tag is None and not at:\n        tag = "latest"\n', "")),
        ["GrammarTests.test_latest_default"],
    ),
    "no uppercase-domain rule": (
        swap((' or first.lower() != first)', ")")),
        ["GrammarTests.test_uppercase_first_component_is_a_domain"],
    ),
    "no localhost rule": (
        swap((' or first == "localhost"', "")),
        ["GrammarTests.test_localhost_is_a_domain"],
    ),
    "loose port": (
        swap(('(?::[0-9]+)?$', '(?::[0-9A-Za-z]+)?$')),
        ["GrammarTests.test_port_is_decimal"],
    ),
    "no IPv6 domains": (
        swap(('|\\[[0-9A-Fa-f:]+\\])"', ')"')),
        ["GrammarTests.test_ipv6_domain"],
    ),
    "no path length limit": (
        swap(("    if len(path) > PATH_MAX:\n", "    if False:\n")),
        ["GrammarTests.test_path_length_limit", "SnapshotTests.test_keep_d_missing_or_broken_refuses"],
    ),
    "length limit on the whole name": (
        swap(("    if len(path) > PATH_MAX:\n", '    if len(f"{domain}/{path}") > PATH_MAX:\n')),
        ["GrammarTests.test_path_length_limit"],
    ),
    "uppercase repository paths": (
        swap(('_PATH_PART = r"[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*"', '_PATH_PART = r"[A-Za-z0-9]+(?:(?:[._]|__|-+)[A-Za-z0-9]+)*"')),
        ["GrammarTests.test_uppercase_path_is_rejected"],
    ),
    "tagged digest by tag": (
        swap(("        if ref.digest:\n            return found | self.by_digest", "        if ref.digest and not ref.tag:\n            return found | self.by_digest")),
        ["GrammarTests.test_tagged_digest_resolves_by_digest"],
    ),
    "non-sha256 digests": (
        swap(('DIGEST = re.compile(r"^(?:sha256:[0-9a-f]{64}|sha384:[0-9a-f]{96}|sha512:[0-9a-f]{128})$")', 'DIGEST = re.compile(r"^[a-z0-9]+:[0-9a-fA-F]{32,}$")')),
        ["GrammarTests.test_unsupported_digests_are_rejected"],
    ),
    "IDs by exact match only": (
        swap(("if image_id.startswith(prefix)}", "if image_id == prefix}")),
        ["GrammarTests.test_id_forms_in_a_spec_and_baked_in"],
    ),
    "ID forms need sha256:": (
        swap(('ID_FORM = re.compile(r"^(?:sha256:)?([0-9a-f]{1,64})$")', 'ID_FORM = re.compile(r"^sha256:([0-9a-f]{1,64})$")')),
        ["GrammarTests.test_id_forms_in_a_spec_and_baked_in"],
    ),
    "ID forms parsed as names": (
        swap(("        if m := ID_FORM.fullmatch(raw):\n", "        if m := None:\n")),
        ["GrammarTests.test_id_forms_in_a_spec_and_baked_in"],
    ),
    "64-hex accepted as a name": (
        swap(("    if FULL_HEX.match(raw):\n", "    if False:\n")),
        ["GrammarTests.test_a_64_hex_string_is_never_a_name"],
    ),
    "ID forms in keep.d": (
        swap(("    if not need_digest and isinstance(raw, str) and ID_FORM.fullmatch(raw):\n", "    if isinstance(raw, str) and ID_FORM.fullmatch(raw):\n")),
        ["SnapshotTests.test_keep_d_missing_or_broken_refuses"],
    ),
    "AEON by listing names only": (
        swap(("    return ref is not None and ref.name == AEON_REPO\n", "    return False\n")),
        ["BaselineTests.test_aeon_container_known_only_by_its_image_field"],
    ),
}


class R34SwitchTests(Base):
    def switch_token(self, word, token=(0, 0, 1)):
        # Isolate token parsing from the byte cap and strict ASCII decoding,
        # which have their own tests. This also exercises non-ASCII characters.
        data = mock.Mock()
        data.decode.return_value = word
        real_stat = os.stat
        def stat_(path, *args, **kw):
            if str(path) == self.gc.SWITCH_LOCK:
                return types.SimpleNamespace(st_dev=os.makedev(*token[:2]), st_ino=token[2])
            return real_stat(path, *args, **kw)
        with mock.patch.object(os, "stat", stat_), mock.patch.object(self.gc, "Reader") as reader:
            reader.return_value.read.return_value = data
            return returns_normally(self.gc.switch_lock_used, self.gc.Budget(10))

    def test_switch_token_exact_ascii_grammar(self):
        for word, token in (("00:e1:451718", (0, 0xe1, 451718)), ("0A:E1:5", (10, 0xe1, 5))):
            with self.subTest(word=word):
                self.assertTrue(self.switch_token(word, token))
        for word in ("0:0:", ":0:0", "0::1", "0:0:0:0", "0:0", "g:0:1", "0x1:0:1",
                     "0:0x1:1", "0:0:1a", "0:0:+1", "0:0: 1", "\u0660:0:1", "0:\u0660:1", "0:0:\u0661"):
            with self.subTest(word=word):
                self.assertFalse(self.switch_token(word))
        # If a hex-prefix slips through the character guard, int(..., 16)
        # accepts it. Match that numeric token so either x mutant is observable.
        for word, token in (("0x1:0:1", (1, 0, 1)), ("0:0x1:1", (0, 1, 1))):
            with self.subTest(word=word):
                self.assertFalse(self.switch_token(word, token))

    def test_every_switch_token_character(self):
        for position, alphabet in enumerate(SWITCH_ALPHABETS):
            for char in alphabet:
                parts = ["0", "0", "1"]
                parts[position] = char
                token = (int(parts[0], 16), int(parts[1], 16), int(parts[2]))
                line = f"17: -> FLOCK ADVISORY WRITE 42 {':'.join(parts)} 0 EOF\n"
                with self.subTest(position=position, char=char):
                    self.assertTrue(self.switch_token(line, token))
            for char in ("gGxX" if position < 2 else "aA"):
                parts = ["0", "0", "1"]
                parts[position] = char
                with self.subTest(position=position, rejected=char):
                    self.assertFalse(self.switch_token(":".join(parts)))

    def test_long_switch_tokens_finish_quickly(self):
        previous = signal.getsignal(signal.SIGALRM)
        def expired(*_):
            raise AssertionError("switch-token parsing exceeded two seconds")
        signal.signal(signal.SIGALRM, expired)
        try:
            for word in ("0" * (1024 * 1024), "0:" + "0" * (1024 * 1024) + "x"):
                signal.setitimer(signal.ITIMER_REAL, 2)
                started = time.monotonic()
                self.assertFalse(self.switch_token(word))
                self.assertLess(time.monotonic() - started, 2)
                signal.setitimer(signal.ITIMER_REAL, 0)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)

    def test_non_ascii_lock_table_fails_closed(self):
        Path(self.gc.SWITCH_LOCK).touch()
        Path(self.gc.PROC_LOCKS).write_bytes("0:0:\u0661".encode())
        with self.assertRaises(UnicodeDecodeError):
            self.gc.switch_lock_used(self.gc.Budget(10))

    def test_listing_reference_fields_and_ids_are_strict(self):
        self.world()
        for field, value in (("RepoTags", ["app@" + dg(5)]), ("RepoDigests", ["app:latest"]),
                             ("Id", self.apps[3]["Id"] + "\n"), ("Size", "invalid")):
            with self.subTest(field=field):
                original = self.apps[3][field]
                self.apps[3][field] = value
                with self.assertRaises(self.gc.Fatal):
                    self.gc.validate(self.containers, self.images)
                self.apps[3][field] = original
        with self.assertRaises((ValueError, self.gc.Fatal)):
            self.gc.check_ref("sha256:" + "a" * 64 + "\n", "fixture")

    def test_numeric_switch_table(self):
        self.world()
        st = types.SimpleNamespace(st_dev=os.makedev(0, 0x1a), st_ino=67043)
        real_stat = os.stat
        def stat_(path, *a, **kw):
            return st if str(path) == self.gc.SWITCH_LOCK else real_stat(path, *a, **kw)
        cases = [("00:1a:67043", True), ("0:01A:067043", True),
                 ("00:1a:67044", False), ("01:1a:67043", False), ("00:1b:67043", False)]
        with mock.patch.object(os, "stat", stat_):
            for token, expected in cases:
                for arrow in ("", "-> "):
                    with self.subTest(token=token, arrow=arrow):
                        Path(self.gc.PROC_LOCKS).write_text(f"17: {arrow}FLOCK ADVISORY WRITE 42 {token} 0 EOF\n")
                        self.assertEqual(returns_normally(self.gc.switch_lock_used, self.gc.Budget(10)), expected)

    def test_switch_absent_and_errors(self):
        self.world()
        self.assertFalse(self.gc.switch_lock_used(self.gc.Budget(10)))
        real_stat = os.stat
        def denied(path, *a, **kw):
            if str(path) == self.gc.SWITCH_LOCK:
                raise PermissionError("fixture denial")
            return real_stat(path, *a, **kw)
        with mock.patch.object(os, "stat", denied):
            with self.assertRaises(OSError):
                self.gc.switch_lock_used(self.gc.Budget(10))

    def test_proc_reads_and_cap(self):
        self.world()
        Path(self.gc.SWITCH_LOCK).touch()
        self.gc.CAP_PROC_LOCKS_BYTES = 16
        Path(self.gc.PROC_LOCKS).write_bytes(b" " * 17)
        with self.assertRaises(self.gc.CapExceeded):
            self.gc.switch_lock_used(self.gc.Budget(10))
        Path(self.gc.PROC_LOCKS).unlink()
        with self.assertRaises(OSError):
            self.gc.switch_lock_used(self.gc.Budget(10))


class R34StoreTests(Base):
    def test_specialisation_from_each_source_alone(self):
        for source in ("generation", "current", "booted", "store"):
            with self.subTest(source=source):
                self.setUp(); self.world()
                parent = self.tmp / ("1" * 32 + "-nixos-system-parent" if source == "store" else "custom-parent")
                layout(parent)
                child = self.extra("pre-change-custom-child")
                special = parent / "specialisation"; special.mkdir()
                (special / "child").symlink_to(child)
                if source == "generation": gen(self.tmp, 42).symlink_to(parent)
                elif source in ("current", "booted"): link(self.tmp, source + "-system", parent)
                self.assertNotIn(self.apps[3]["Id"], {i["Id"] for i in self.decision()[1].deletable})

    def test_store_lstat_permission_error_is_fatal(self):
        self.world(); target = self.extra()
        original = os.lstat
        def denied(path, *a, **kw):
            if str(path) == str(target): raise PermissionError("store entry denial")
            return original(path, *a, **kw)
        with mock.patch.object(os, "lstat", denied):
            with self.assertRaises(OSError): self.decision()

    def extra(self, name=None):
        return system(self.tmp / (name or ("0" * 32 + "-nixos-system-old")), {"old": "app:3"})

    def decision(self):
        budget = self.gc.Budget(10)
        snap = self.gc.snapshot(self.api(), budget)
        return snap, self.gc.plan(snap, NOW, budget)

    def test_store_only_and_report(self):
        self.world()
        path = self.extra()
        snap, p = self.decision()
        self.assertNotIn(self.apps[3]["Id"], {i["Id"] for i in p.deletable})
        self.assertEqual(snap.store_only, {str(path)})
        self.assertIn("store-only systems=1, extra refs=1, images=1", self.gc.summary(snap, p))
        self.assertIn("bytes=1000000000", self.gc.summary(snap, p))
        self.images[3]["Created"] = NOW
        # A second independent protection must remove it from the store-only image count.
        self.apps[3]["Created"] = NOW
        snap, p = self.decision()
        self.assertIn("images=0", self.gc.summary(snap, p))

    def test_specialisations_recursive_custom_names_and_cycles(self):
        self.world()
        parent = gen(self.tmp, 1)
        child = self.extra("custom-child")
        grand = system(self.tmp / "custom-grandchild", {"g": "app:4"})
        for source, name, target in ((parent, "child", child), (child, "grand", grand), (grand, "cycle", parent)):
            d = source / "specialisation"
            d.mkdir()
            (d / name).symlink_to(target)
        snap, p = returns_normally(self.decision)
        self.assertEqual(p.deletable, [])
        self.assertEqual(len(snap.systems), 3)
        self.assertEqual(snap.store_only, set())

    def test_bad_specialisation_and_incomplete_store_are_fatal(self):
        for mode in ("plain", "dangling", "outside", "incomplete"):
            with self.subTest(mode=mode):
                self.setUp(); self.world()
                if mode == "incomplete":
                    (self.tmp / ("1" * 32 + "-nixos-system-incomplete")).mkdir()
                else:
                    d = gen(self.tmp, 1) / "specialisation"; d.mkdir()
                    if mode == "plain":
                        (d / "bad").mkdir()
                    elif mode == "dangling":
                        (d / "bad").symlink_to(self.tmp / "absent")
                    else:
                        # A real directory on the same device but outside STORE_DIR.
                        # Outside STORE_DIR but within the guarded fixture.
                        self.gc.STORE_DIR = str(self.tmp / "store-boundary")
                        Path(self.gc.STORE_DIR).mkdir()
                        outside = self.tmp / "outside-store"
                        layout(outside)
                        (d / "bad").symlink_to(outside)
                with self.assertRaises((self.gc.Fatal, OSError)):
                    self.decision()

    def test_store_name_filter_and_caps(self):
        self.world()
        for name in ("0" * 32 + "-nixos-system-x.drv", "0" * 32 + "-custom-toplevel", "short-nixos-system-x"):
            self.extra(name)
        self.assertIn(self.apps[3]["Id"], {i["Id"] for i in self.decision()[1].deletable})
        Path(self.tmp / ("2" * 32 + "-nixos-system-file")).touch()
        self.decision()
        self.gc.CAP_STORE_ENTRIES = 1
        with self.assertRaises(self.gc.CapExceeded):
            self.decision()
        self.gc.CAP_STORE_ENTRIES = 1_000_000
        self.extra()
        self.gc.CAP_SYSTEMS = 1
        with self.assertRaises(self.gc.CapExceeded):
            self.decision()

    def test_generation_deleted_during_snapshot_and_store_gc(self):
        for removed in (False, True):
            with self.subTest(removed=removed):
                self.setUp(); self.world()
                target = self.extra()
                gen(self.tmp, 42).symlink_to(target)
                def change(api, path):
                    if path.startswith("/containers/"):
                        gen(self.tmp, 42).unlink()
                        if removed:
                            # Absolute operations: shutil's fd-relative open
                            # loses dir_fd in its audit event, while cwd is
                            # deliberately outside this fixture.
                            for child in sorted(target.rglob("*"), key=lambda p: len(p.parts), reverse=True):
                                child.rmdir() if child.is_dir() else child.unlink()
                            target.rmdir()
                self.gc.snapshot  # ensure the removal happens after t0, before profiles.
                budget = self.gc.Budget(10)
                snap = self.gc.snapshot(self.api(on_get=change), budget)
                p = self.gc.plan(snap, NOW, budget)
                self.assertEqual(self.apps[3]["Id"] in {i["Id"] for i in p.deletable}, removed)

    def test_entry_removed_between_listing_and_lstat(self):
        self.world(); path = self.extra()
        original = os.lstat
        def stat_(name, *a, **kw):
            if str(name) == str(path):
                raise FileNotFoundError("store GC after listing")
            return original(name, *a, **kw)
        with mock.patch.object(os, "lstat", stat_):
            self.assertIn(self.apps[3]["Id"], {i["Id"] for i in self.decision()[1].deletable})

    def test_after_snapshot_removal_does_not_drop_protection(self):
        self.world(); path = self.extra()
        snap, _ = self.decision()
        shutil.rmtree(path)
        p = self.gc.plan(snap, NOW, self.gc.Budget(10))
        self.assertNotIn(self.apps[3]["Id"], {i["Id"] for i in p.deletable})

    def test_custom_publication_interleavings(self):
        # Four residual (b) schedules: source already read, other sources unchanged.
        for schedule in ("after", "before-store", "before-current", "after-current", "rooted", "named"):
            with self.subTest(schedule=schedule):
                self.setUp(); self.world()
                target = self.extra("0" * 32 + ("-nixos-system-x" if schedule == "named" else "-custom-toplevel"))
                def publish():
                    if schedule == "after-current":
                        link(self.tmp, "current-system", target)
                    else:
                        gen(self.tmp, 42).symlink_to(target)
                if schedule == "rooted":
                    publish()
                original_list, original_system = self.gc.Reader.listdir, self.gc.Reader.system
                def listed(reader, path):
                    result = original_list(reader, path)
                    if str(path) == self.gc.PROFILES_DIR and schedule in ("before-store", "before-current"):
                        publish()
                    return result
                def system_(reader, path, required):
                    result = original_system(reader, path, required)
                    if str(path) == self.gc.CURRENT_SYSTEM and schedule == "after-current":
                        publish()
                    return result
                with mock.patch.object(self.gc.Reader, "listdir", listed), mock.patch.object(self.gc.Reader, "system", system_):
                    snap, p = self.decision()
                if schedule == "after":
                    publish()
                self.assertEqual(self.apps[3]["Id"] in {i["Id"] for i in p.deletable}, schedule not in ("rooted", "named"))


class R34ReadTests(Base):
    def test_nonregular_reads_are_nonblocking_and_fatal(self):
        self.world()
        for where in ("keep", "role", "spec"):
            with self.subTest(where=where):
                if where == "spec":
                    path = gen(self.tmp, 1) / "etc/compose/csb1/docker-compose.yml"
                else:
                    path = self.tmp / "keep.d" / ("stuck.refs" if where == "keep" else "aeon-live.refs")
                if path.exists():
                    path.unlink()
                os.mkfifo(path)
                flags_seen = []
                original = os.open
                def opened(name, flags, *a, **kw):
                    if str(name) == str(path):
                        flags_seen.append(flags)
                        # A blocking-open mutant must fail without hanging the unit suite.
                        self.assertTrue(flags & os.O_NONBLOCK, "blocking FIFO open")
                    return original(name, flags, *a, **kw)
                with mock.patch.object(os, "open", opened):
                    rc, out, err = run(self.gc, self.api())
                self.assertEqual(rc, 2, out + err)
                self.assertIn("not a regular file", err)
                self.assertTrue(flags_seen)
                self.assertTrue(locks_free(self.gc))
                path.unlink()
                if where == "role":
                    keep(self.tmp, "aeon-live.refs", [pin(self.L)])

    def test_keep_symlink_and_wrong_device(self):
        self.world()
        target = self.tmp / "plain"; target.write_text("")
        symlink = self.tmp / "keep.d/link.refs"; symlink.symlink_to(target)
        with self.assertRaises((OSError, self.gc.Fatal)):
            self.gc.Reader(self.gc.Budget(10)).keep()
        symlink.unlink()
        original = os.fstat
        def other_device(fd):
            st = original(fd)
            return types.SimpleNamespace(st_mode=st.st_mode, st_dev=st.st_dev + 1)
        with mock.patch.object(os, "fstat", other_device):
            with self.assertRaises(self.gc.Fatal):
                self.gc.Reader(self.gc.Budget(10)).keep()

    def test_every_read_flag_and_regular_cap(self):
        self.world()
        path = self.tmp / "regular"; path.write_bytes(b"x" * 9)
        real = os.open
        def opened(name, flags, *a, **kw):
            expected = os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY | os.O_CLOEXEC
            self.assertEqual(flags & expected, expected)
            return real(name, flags, *a, **kw)
        reader = self.gc.Reader(self.gc.Budget(10))
        with mock.patch.object(os, "open", opened):
            with self.assertRaises(self.gc.CapExceeded):
                reader.read(str(path), 8)


class R34LockTests(Base):
    def test_fifty_minute_budget_and_last_second_batch(self):
        self.world()
        self.images += [img(100 + n, 40) for n in range(80)]
        with fake_clock(self.gc) as clock:
            rc, out, err = run(self.gc, self.api(after_delete=lambda *_: clock.advance(11)))
            self.assertEqual(rc, 0, out + err)
            self.assertIn("run budget used; continuing tomorrow", out)
            self.assertLessEqual(clock() - 1000, 3045)
            self.assertGreaterEqual(clock() - 1000, 3000)
        self.setUp(); self.world()
        with fake_clock(self.gc) as clock:
            original = self.gc.deploy_locks
            @contextmanager
            def late(paths):
                clock.t = 1000 + 2999
                with original(paths): yield
            self.gc.deploy_locks = late
            rc, out, err = run(self.gc, self.api(after_delete=lambda *_: clock.advance(29)))
            self.assertEqual(rc, 0, out + err)
            self.assertEqual(clock(), 1000 + 2999 + 29)
            self.assertIn("run budget used; continuing tomorrow", out)

    def test_all_lock_attempts_nonblocking(self):
        self.world()
        real = fcntl.flock
        def flock(fd, op):
            self.assertTrue(op & fcntl.LOCK_NB)
            return real(fd, op)
        with mock.patch.object(fcntl, "flock", flock):
            self.assertEqual(run(self.gc, self.api())[0], 0)

    def test_cooldown_every_release_and_first_attempt(self):
        for case in ("batch", "active", "busy-0", "busy-1", "busy-2"):
            with self.subTest(case=case):
                self.setUp(); self.world()
                with fake_clock(self.gc) as clock:
                    started = clock()
                    attempts, releases, paths = [], [], {}
                    original_open, original_close, original_flock = os.open, os.close, fcntl.flock
                    failed = False
                    held = set()
                    def opened(path, *a, **kw):
                        fd = original_open(path, *a, **kw); paths[fd] = str(path); return fd
                    def flock(fd, op):
                        nonlocal failed
                        path = paths.get(fd)
                        if path in self.gc.LOCK_PATHS:
                            attempts.append((clock(), path))
                            if case.startswith("busy") and path == self.gc.LOCK_PATHS[int(case[-1])] and not failed:
                                failed = True
                                raise BlockingIOError(11, "busy fixture")
                            held.add(fd)
                        return original_flock(fd, op)
                    def closed(fd):
                        held.discard(fd)
                        if paths.get(fd) in self.gc.LOCK_PATHS and not held:
                            releases.append(clock())
                        paths.pop(fd, None)
                        return original_close(fd)
                    if case == "batch":
                        api = self.api(after_delete=lambda *_: clock.advance(11))
                    else:
                        api = self.api()
                    if case == "active":
                        original = self.gc.activation_seen
                        observations = []
                        def seen(budget):
                            observations.append(1)
                            return "switch fixture" if len(observations) == 1 else original(budget)
                        self.gc.activation_seen = seen
                    with mock.patch.object(os, "open", opened), mock.patch.object(os, "close", closed), mock.patch.object(fcntl, "flock", flock):
                        rc, out, err = run(self.gc, api)
                    self.assertEqual(rc, 0, out + err)
                    self.assertGreaterEqual(attempts[0][0] - started, 45)
                    for release in releases[:-1]:
                        following = [t for t, _ in attempts if t > release]
                        if following:
                            self.assertGreaterEqual(min(following) - release, 45, (case, attempts, releases))
                    # Attempts in the same instant as release must not evade the assertion.
                    if len(releases) > 1:
                        next_batch = attempts[3 if case in ("batch", "active") else int(case[-1]) + 1][0]
                        self.assertGreaterEqual(next_batch - releases[0], 45)

    def test_instance_busy_open_error_and_lifetime(self):
        self.world()
        fd = os.open(self.gc.INSTANCE_LOCK, os.O_RDONLY | os.O_CREAT, 0o600)
        self.addCleanup(os.close, fd)
        fcntl.flock(fd, fcntl.LOCK_EX)
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertIn("another run is in progress", out)
        self.assertEqual(api.calls, [])
        fcntl.flock(fd, fcntl.LOCK_UN)
        original = self.gc.batch
        def batch(*args):
            with self.assertRaises(BlockingIOError):
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return original(*args)
        self.gc.batch = batch
        self.assertEqual(run(self.gc, self.api())[0], 0)
        self.gc.INSTANCE_LOCK = str(self.tmp / "missing/instance")
        self.assertEqual(run(self.gc, self.api())[0], 2)

    def test_run_budget_after_release_and_before_attempt(self):
        self.world()
        with fake_clock(self.gc) as clock:
            self.gc.RUN_BUDGET_S = 50
            api = self.api(after_delete=lambda *_: clock.advance(29))
            rc, out, err = run(self.gc, api)
            self.assertEqual(rc, 0, out + err)
            self.assertIn("run budget used; continuing tomorrow", out)
            self.assertEqual(len(api.deleted()), 1)
            self.assertEqual(clock.t, 1000 + 45 + 29)
        self.setUp(); self.world()
        with fake_clock(self.gc) as clock:
            self.gc.RUN_BUDGET_S = 44
            api = self.api()
            rc, out, err = run(self.gc, api)
            self.assertEqual(rc, 0, out + err)
            self.assertEqual(api.calls, [])
            self.assertEqual(clock.t, 1044)

    def test_wait_budget_is_shared_and_starts_at_first_busy(self):
        self.world()
        attempts = []
        with fake_clock(self.gc) as clock:
            original = self.gc.deploy_locks
            @contextmanager
            def busy(paths):
                attempts.append(clock())
                with original(paths):
                    raise self.gc.Busy("fixture")
                    yield
            self.gc.deploy_locks = busy
            rc, out, err = run(self.gc, self.api())
            self.assertEqual(rc, 0, out + err)
            self.assertIn("skipping today", out)
            self.assertEqual(clock.t, attempts[0] + 300)
            self.assertLessEqual(len(attempts), 7)

    def test_maximal_hold_and_restart_spacing(self):
        self.world()
        self.images += [img(30 + n, 40, tags=[]) for n in range(4)]
        with fake_clock(self.gc) as clock:
            holds = BudgetTests.timed_locks(self, clock)
            self.gc.RUN_BUDGET_S = 55
            n = []
            def answer(*_):
                n.append(1); clock.advance(9.9 if len(n) == 1 else 29)
            rc, out, err = run(self.gc, self.api(after_delete=answer))
            self.assertEqual(rc, 0, out + err)
            self.assertLessEqual(max(holds), 45)
            last_release = clock()
            original = self.gc.batch
            entered = []
            def batch(*a):
                entered.append(clock()); return original(*a)
            self.gc.batch = batch
            self.assertEqual(run(self.gc, self.api())[0], 0)
            self.assertGreaterEqual(entered[0] - last_release, 45)

    def test_batch_over_releases_without_hidden_sleep(self):
        self.world()
        self.images += [img(30 + n, 40, tags=[]) for n in range(4)]
        with fake_clock(self.gc) as clock, mock.patch.object(self.gc.time, "sleep", side_effect=clock.advance):
            holds = BudgetTests.timed_locks(self, clock)
            self.gc.RUN_BUDGET_S = 55
            calls = []
            def answer(*_):
                calls.append(clock())
                clock.advance(9.9 if len(calls) == 1 else 29)
            rc, out, err = run(self.gc, self.api(after_delete=answer))
            self.assertEqual(rc, 0, out + err)
            self.assertEqual(len(calls), 2)
            # An injected clock must include a direct time.sleep in BatchOver,
            # not just main's injected cooldown sleep. Both 5 and 12 s regress.
            self.assertAlmostEqual(max(holds), 38.9)


class R34DeadlineTests(Base):
    def test_injected_http_connect_never_sends_after_deadline(self):
        clock, created, sent = Clock(), [], []
        class BlockingSocket:
            def __init__(self, *a):
                self.timeout = None; self.closed = False; created.append(self)
            def settimeout(self, seconds): self.timeout = seconds
            def connect(self, *_):
                clock.advance(min(58, self.timeout) if self.timeout is not None else 58)
                if self.timeout is not None and self.timeout < 58: raise TimeoutError()
            def sendall(self, *_): sent.append(1)
            def close(self): self.closed = True
        source = SCRIPT.read_text()
        if OVERRIDE and OVERRIDE[0] == "text": source = OVERRIDE[1](source)
        source = source.replace("@DECLARED_REFS@", "[]").replace("class DeadlineSocket(socket.socket):", "class DeadlineSocket(BlockingSocket):")
        ns = HARNESS.execute_source(source, self.tmp, bindings={"BlockingSocket": BlockingSocket}).__dict__
        ns["SOCKET_PATH"] = self.gc.SOCKET_PATH
        with mock.patch.object(time, "monotonic", clock), mock.patch.object(socket, "socket", BlockingSocket):
            with self.assertRaises(TimeoutError):
                ns["docker_api"]("DELETE", "/images/fixture", 30, 1024)
        self.assertLessEqual(clock() - 1000, 30)
        self.assertTrue(created and all(isinstance(sock, ns["DeadlineSocket"]) for sock in created))
        self.assertTrue(all(sock.closed for sock in created))
        self.assertEqual(sent, [])

    def test_delete_response_cap_stops_the_run(self):
        self.world()
        self.gc.CAP_RESPONSE_BYTES = 16
        api = self.api(delete={self.apps[3]["Id"]: (200, b" " * 17)})
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertIn("DELETE answer larger", err)
        self.assertEqual(len(api.deleted()), 1)
        self.assertEqual(api.posts(), [])

    def test_unexpected_exception_during_destructive_call_is_fatal(self):
        self.world()
        def broken(*_): raise RuntimeError("fixture Engine failure")
        api = self.api(delete={self.apps[3]["Id"]: broken})
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(len(api.deleted()), 1)
        self.assertEqual(api.posts(), [])
        self.assertTrue(locks_free(self.gc))

    def test_injected_get_watchdog(self):
        self.gc.GET_WATCHDOG_S = 0.02
        def api(*a, **kw):
            time.sleep(0.08)
            return 200, b"[]"
        with self.assertRaises(self.gc.Interrupted):
            self.gc.get_json(api, "/images/json", 100, self.gc.Budget(10))

    def test_every_socket_method_blocks_for_58_seconds(self):
        for method, args in (("connect", ("fixture",)), ("send", (b"x",)), ("sendall", (b"x",)),
                             ("recv", (10,)), ("recv_into", (bytearray(10),))):
            with self.subTest(method=method):
                clock = Clock()
                class BlockingSocket:
                    def __init__(self, *a): self.timeout = None
                    def settimeout(self, seconds): self.timeout = seconds
                    def blocked(self, *a):
                        clock.advance(min(58, self.timeout) if self.timeout is not None else 58)
                        if self.timeout is not None and self.timeout < 58:
                            raise TimeoutError("blocked syscall")
                        return 1
                    connect = send = sendall = recv = recv_into = blocked
                    def close(self): pass
                source = SCRIPT.read_text()
                if OVERRIDE and OVERRIDE[0] == "text":
                    source = OVERRIDE[1](source)
                source = source.replace("@DECLARED_REFS@", "[]").replace("class DeadlineSocket(socket.socket):", "class DeadlineSocket(BlockingSocket):")
                ns = HARNESS.execute_source(source, self.tmp, bindings={"BlockingSocket": BlockingSocket}).__dict__
                ns["SOCKET_PATH"] = self.gc.SOCKET_PATH
                with mock.patch.object(time, "monotonic", clock):
                    sock = ns["DeadlineSocket"](clock() + ns["CALL_DEADLINE_S"])
                    if method != 'connect':
                        # Prior connection/first bytes consumed 29 seconds. A
                        # stale 30 s timeout now blocks beyond the absolute bound.
                        sock.settimeout(30)
                        clock.advance(29)
                    with self.assertRaises(TimeoutError):
                        getattr(sock, method)(*args)
                    self.assertLessEqual(clock() - 1000, 30)
                    clock.advance(1)
                    # Expired calls never enter a second syscall.
                    before = clock()
                    with self.assertRaises(TimeoutError):
                        getattr(sock, method)(*args)
                    self.assertEqual(clock(), before)

    def test_trickle_phases_injected(self):
        # r34's original 29/58 schedule, without a socket syscall. The real
        # Unix fixtures use 18/45; each injected parser frame retains r34's
        # own numbers and selects the corresponding mutant.
        for frame in ("_read_status", "_read_headers", "_read_chunked", "read"):
            with self.subTest(frame=frame):
                clock = Clock()
                class TrickleSocket:
                    def __init__(self, *a): self.timeout = None; self.n = 0
                    def settimeout(self, seconds): self.timeout = seconds
                    def recv_into(self, *a):
                        self.n += 1
                        delay = 29
                        wait = min(delay, self.timeout) if self.timeout is not None else delay
                        clock.advance(wait)
                        if wait < delay: raise TimeoutError()
                        return 1
                source = SCRIPT.read_text()
                if OVERRIDE and OVERRIDE[0] == "text": source = OVERRIDE[1](source)
                source = source.replace("@DECLARED_REFS@", "[]").replace("class DeadlineSocket(socket.socket):", "class DeadlineSocket(TrickleSocket):")
                ns = HARNESS.execute_source(source, self.tmp, bindings={"TrickleSocket": TrickleSocket}).__dict__
                ns["SOCKET_PATH"] = self.gc.SOCKET_PATH
                exec(f"def {frame}(sock):\n    sock.recv_into(bytearray(1))\n    sock.recv_into(bytearray(1))", ns)
                with mock.patch.object(time, "monotonic", clock):
                    sock = ns["DeadlineSocket"](clock() + 30)
                    with self.assertRaises(TimeoutError): ns[frame](sock)
                    self.assertLessEqual(clock() - 1000, 30)

    def test_connection_setup_uses_the_wrapper(self):
        with fake_clock(self.gc) as clock:
            created = []
            class Sock:
                def __init__(self, deadline): created.append(("create", deadline))
                def connect(self, path): created.append(("connect", path)); raise TimeoutError()
                def close(self): created.append(("close",))
            with mock.patch.object(self.gc, "DeadlineSocket", Sock), mock.patch.object(
                socket, "socket", side_effect=AssertionError("plain socket created")
            ) as plain_socket:
                with self.assertRaises(TimeoutError):
                    self.gc.docker_api("DELETE", "/images/test", 30, 100)
                plain_socket.assert_not_called()
            self.assertEqual(created, [("create", clock() + 30), ("connect", self.gc.SOCKET_PATH), ("close",)])

    def test_timeout_releases_all_locks_exits_2_and_stops_sending(self):
        for method in ("DELETE", "POST"):
            with self.subTest(method=method):
                self.setUp(); self.world()
                if method == "POST": self.images[:] = self.images[:2]
                def expired(api): raise TimeoutError()
                api = self.api(delete={self.apps[3]["Id"]: expired}, prune=expired)
                with fake_clock(self.gc) as clock, mock.patch.object(time, "sleep", clock.advance):
                    start = clock()
                    rc, out, err = run(self.gc, api)
                    self.assertLessEqual(clock() - start, 75)
                self.assertEqual(rc, 2, out + err)
                self.assertIn("not answered in 30 s", err)
                self.assertEqual(len(api.deleted()) + len(api.posts()), 1)
                self.assertTrue(locks_free(self.gc))

    def test_real_unix_trickle_every_http_phase(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("gc_harness", REPO / "tests/docker-image-gc-harness.py")
        harness = importlib.util.module_from_spec(spec); spec.loader.exec_module(harness)
        for method in ("DELETE", "POST"):
            for phase in ("status", "header", "chunk-size", "chunk-data", "body", "stream"):
                with self.subTest(method=method, phase=phase):
                    path = str(self.tmp / f"{method}-{phase}.sock")
                    try:
                        engine = harness.Engine(path, phase=phase, scale=0.01)
                    except PermissionError as exc:
                        self.skipTest(f"sandbox refuses Unix bind: {exc}")
                    with engine:
                        self.gc.SOCKET_PATH = path
                        self.gc.CALL_DEADLINE_S = 0.3
                        started = time.monotonic()
                        with self.assertRaises(TimeoutError):
                            self.gc.docker_api(method, "/images/test" if method == "DELETE" else self.gc.PRUNE_PATH, 0.3, 1024)
                        self.assertLess(time.monotonic() - started, 0.48)
                        self.assertEqual(len(engine.destructive), 1)


def r34_mutants():
    """Named source edits, shared by the Linux harness. Missing anchors fail.

    Socket-phase mutations deliberately retain the absolute check between
    receives; they reproduce the gate's counterexamples rather than disabling
    all checking. No mutation is applied to the working source file.
    """
    result = {}
    def add(name, pairs, *tests):
        result[name] = (swap(*pairs), list(tests))
    switch = "R34SwitchTests.test_numeric_switch_table"
    alphabets = '("0123456789abcdefABCDEF", "0123456789abcdefABCDEF", "0123456789")'
    grammar = "R34SwitchTests.test_switch_token_exact_ascii_grammar"
    add("switch inode accepts hex", [(alphabets, '("0123456789abcdefABCDEF", "0123456789abcdefABCDEF", "0123456789abcdefABCDEF")')], grammar)
    add("switch accepts two parts", [("if len(parts) == 3 and all(", "if len(parts) in (2, 3) and all(")], grammar)
    add("switch accepts an empty part", [("                part and all(char in alphabet for char in part)", "                all(char in alphabet for char in part)")], grammar)
    add("switch major accepts x", [(alphabets, '("0123456789abcdefABCDEFx", "0123456789abcdefABCDEF", "0123456789")')], grammar)
    add("switch minor accepts x", [(alphabets, '("0123456789abcdefABCDEF", "0123456789abcdefABCDEFx", "0123456789")')], grammar)
    add("treat a stat error as no switch", [("    except FileNotFoundError:\n        return False\n", "    except OSError:\n        return False\n")], "R34SwitchTests.test_switch_absent_and_errors")
    for name, expr in (("match the inode only", "token[2] == other[2]"),
                       ("drop the major", "token[1:] == other[1:]"),
                       ("drop the minor", "token[::2] == other[::2]")):
        add(name, [("                if token == other:\n", f"                if {expr}:\n")], switch)
    add("parse the minor as decimal", [("int(minor, 16)", "int(minor, 10)")], switch)
    add("the GC takes the lock", [("    token = (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)",
        "    fd = os.open(SWITCH_LOCK, os.O_RDONLY)\n    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n    # mutant deliberately keeps the fd open\n    token = (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)")], "ActivationTests.test_switch_lock_is_never_locked")
    add("no switch check before a fresh snapshot", [("            if why := activation_seen(budget):\n", "            if why := None:\n")], "ActivationTests.test_activation_at_acquisition_waits_then_skips_the_day")
    add("no store scan", [("                if stat.S_ISDIR(mode):\n", "                if False:\n")], "R34StoreTests.test_store_only_and_report", "R34StoreTests.test_generation_deleted_during_snapshot_and_store_gc")
    add("a name pattern that misses `nixos-system-*` entries", [('STORE_SYSTEM = re.compile(r"^[0-9a-z]{32}-nixos-system-[^/]+$")', 'STORE_SYSTEM = re.compile(r"^[0-9a-z]{32}-nixos-system$")')], "R34StoreTests.test_custom_publication_interleavings")
    add("no specialisations", [("            for name in sorted(self.listdir(special)):\n", "            for name in []:\n")], "R34StoreTests.test_specialisations_recursive_custom_names_and_cycles")
    add("specialisations only from current", [("            systems[target] = self.compose_services(target)\n", "            systems[target] = self.compose_services(target)\n            if target != current: return\n")], "R34StoreTests.test_specialisation_from_each_source_alone")
    add("no visited set", [("            if target in systems:\n                return\n", "")], "R34StoreTests.test_specialisations_recursive_custom_names_and_cycles")
    add("no .drv exclusion", [(" or entry.name.endswith(\".drv\")", "")], "R34StoreTests.test_store_name_filter_and_caps")
    add("store EACCES treated as skip", [("                except FileNotFoundError:\n                    continue\n", "                except OSError:\n                    continue\n")], "R34StoreTests.test_store_lstat_permission_error_is_fatal")
    add("no store entry cap", [("                if n > CAP_STORE_ENTRIES:\n", "                if False:\n")], "R34StoreTests.test_store_name_filter_and_caps")
    add("no distinct system cap", [("            if len(systems) >= CAP_SYSTEMS:\n", "            if False:\n")], "R34StoreTests.test_store_name_filter_and_caps")
    add("omit the over-protection report", [("store-only systems={len(extra)}, extra refs=", "omitted={len(extra)}, refs=")], "R34StoreTests.test_store_only_and_report")
    add("specialisations only one level", [("                visit(child)\n", "                systems[child] = self.compose_services(child)\n")], "R34StoreTests.test_specialisations_recursive_custom_names_and_cycles")
    add("skip a missing rooted target", [('            raise Fatal(f"{link} does not resolve; refusing to judge") from None\n', "            return None\n")], "SnapshotTests.test_dangling_or_missing_system_refuses")
    add("re-check presence after the snapshot and drop it", [("    for why, refs in refsets.items():\n", "    refsets['declared only by store scan'] = [ref for path, spec in snap.systems if path in snap.store_only and os.path.isdir(path) for ref in spec.values()]\n    for why, refs in refsets.items():\n")], "R34StoreTests.test_after_snapshot_removal_does_not_drop_protection")
    add("plain blocking open", [("flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY | os.O_CLOEXEC", "flags = os.O_RDONLY | os.O_CLOEXEC")], "R34ReadTests.test_nonregular_reads_are_nonblocking_and_fatal")
    add("no `S_ISREG` check", [("            if not stat.S_ISREG(info.st_mode):\n", "            if False:\n")], "R34ReadTests.test_nonregular_reads_are_nonblocking_and_fatal")
    add("following symlinks in keep.d", [("        if nofollow:\n", "        if False:\n")], "R34ReadTests.test_keep_symlink_and_wrong_device")
    add("no device check", [("            if info.st_dev != expected:\n", "            if False:\n")], "R34ReadTests.test_keep_symlink_and_wrong_device")
    add("BATCH_S 60", [("BATCH_S = 10\n", "BATCH_S = 60\n")], "R34LockTests.test_maximal_hold_and_restart_spacing")
    for seconds in (5, 12):
        add(f"BatchOver sleeps {seconds} s",
            [("    except BatchOver:\n        return OVER\n", f"    except BatchOver:\n        time.sleep({seconds})\n        return OVER\n")],
            "R34LockTests.test_batch_over_releases_without_hidden_sleep")
    add("deadline 120", [("CALL_DEADLINE_S = 30\n", "CALL_DEADLINE_S = 120\n")], "R34DeadlineTests.test_every_socket_method_blocks_for_58_seconds")
    add("no deadline", [("deadline = time.monotonic() + CALL_DEADLINE_S if method != \"GET\" else None", "deadline = None")], "R34DeadlineTests.test_connection_setup_uses_the_wrapper")
    add("the locks kept after the deadline", [("    except TimeoutError:\n        raise Fatal", "    except TimeoutError:\n        time.sleep(60)\n        raise Fatal")], "R34DeadlineTests.test_timeout_releases_all_locks_exits_2_and_stops_sending")
    add("no DELETE response cap", [("            if len(body) > CAP_RESPONSE_BYTES:\n", "            if False:\n")], "R34DeadlineTests.test_delete_response_cap_stops_the_run")
    add("unexpected destructive exceptions escape exit 2", [("    except Exception as exc:\n        raise Fatal(f\"{label}: {type(exc).__name__}: {str(exc)[:200]}\") from None\n", "")], "R34DeadlineTests.test_unexpected_exception_during_destructive_call_is_fatal")
    add("exit 0 instead of 2 after the deadline", [("    except ERRORS as exc:\n        flush(run)\n", "    except ERRORS as exc:\n        if 'not answered' in str(exc): return 0\n        flush(run)\n")], "R34DeadlineTests.test_timeout_releases_all_locks_exits_2_and_stops_sending")
    for method, signature, args in (("connect", "address", "address"), ("send", "data, flags=0", "data, flags"),
                                    ("sendall", "data, flags=0", "data, flags"), ("recv", "size, flags=0", "size, flags"),
                                    ("recv_into", "buffer, nbytes=0, flags=0", "buffer, nbytes, flags")):
        anchor = f"    def {method}(self, {signature}):\n        self.settimeout(self.remaining())\n"
        add(f"the timeout update dropped from `{method}`", [(anchor, f"    def {method}(self, {signature}):\n")], "R34DeadlineTests.test_every_socket_method_blocks_for_58_seconds")
    add("the wrapper bypassed for connection setup", [("            sock = DeadlineSocket(self.deadline)\n", "            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n            self.sock = sock\n            sock.connect(self.unix_path)\n            sock.close()\n            sock = DeadlineSocket(self.deadline)\n")], "R34DeadlineTests.test_connection_setup_uses_the_wrapper")
    add("a parser that reads through its own unwrapped socket", [("            sock = DeadlineSocket(self.deadline)\n", "            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n            sock.settimeout(CALL_DEADLINE_S)\n")], "R34DeadlineTests.test_connection_setup_uses_the_wrapper")
    add("a per-receive timeout only", [("        return left\n", "        return CALL_DEADLINE_S\n")], "R34DeadlineTests.test_trickle_phases_injected")
    add("a fresh 30 s socket timeout before each receive", [("        return left\n", "        return CALL_DEADLINE_S\n")], "R34DeadlineTests.test_trickle_phases_injected")
    for label, frames in (("status line", ("_read_status",)), ("header lines", ("_read_headers",)),
                           ("chunked reader", ("_read_chunked", "_read_next_chunk_size")), ("body", ("read",))):
        # Only frame names matter; source context would read the host test
        # runner under the production guard and make mutation results depend
        # on linecache contents and discovery/random/reverse order.
        code = f"        import inspect\n        if any(f.function in {frames!r} for f in inspect.stack(context=0)): return CALL_DEADLINE_S\n        return left\n"
        add(f"a fresh 30 s socket timeout confined to the {label}", [("        return left\n", code)], "R34DeadlineTests.test_trickle_phases_injected")
    cooltest = "R34LockTests.test_cooldown_every_release_and_first_attempt"
    add("cooldown 2 s", [("COOLDOWN_S = 45\n", "COOLDOWN_S = 2\n")], cooltest)
    add("re-take the locks without the sleep", [("                cooldown(released)\n", "                pass\n")], cooltest)
    add("no cooldown after a busy attempt", [("                    except Busy:\n                        outcome = ACTIVE\n", "                    except Busy:\n                        run['busy_attempt'] = True\n                        outcome = ACTIVE\n"), ("                cooldown(released)\n", "                if not run.pop('busy_attempt', False): cooldown(released)\n")], cooltest)
    add("no cooldown after a partial acquisition", [("                raise Busy(path) from None\n", "                globals()['MUTANT_PARTIAL'] = len(fds) > 1\n                raise Busy(path) from None\n"), ("                cooldown(released)\n", "                if not globals().pop('MUTANT_PARTIAL', False): cooldown(released)\n")], cooltest)
    add("no cooldown after `ACTIVE`", [("                cooldown(released)\n", "                if locals().get('outcome') != ACTIVE: cooldown(released)\n")], cooltest)
    # A new acquisition order that tries other locks in the cooldown violates
    # the all-lock rule even if compose-csb1 still observes its own cooldown.
    add("cooldown on compose-csb1 only", [("                cooldown(released)\n", "                if released != started:\n                    with deploy_locks(LOCK_PATHS[1:]): pass\n                cooldown(released)\n")], cooltest)
    add("no wait before the first attempt", [("            released = time.monotonic()\n            while True:\n", "            released = time.monotonic() - COOLDOWN_S\n            while True:\n")], cooltest)
    add("no instance lock", [("        with instance_lock():\n", "        if True:\n")], "R34LockTests.test_instance_busy_open_error_and_lifetime")
    add("the instance lock released before the run's last compose release", [("        yield\n    finally:\n        os.close(fd)\n\n\n@contextmanager\ndef deploy_locks", "        fcntl.flock(fd, fcntl.LOCK_UN)\n        yield\n    finally:\n        os.close(fd)\n\n\n@contextmanager\ndef deploy_locks")], "R34LockTests.test_instance_busy_open_error_and_lifetime")
    add("no run budget", [("if time.monotonic() - started >= RUN_BUDGET_S:", "if False:"), ("        until = min(until, started + RUN_BUDGET_S)\n", "")], "R34LockTests.test_run_budget_after_release_and_before_attempt", "R34LockTests.test_fifty_minute_budget_and_last_second_batch")
    add("the budget checked only before attempts", [("                over = run_over()\n", "                over = False\n"), ("        until = min(until, started + RUN_BUDGET_S)\n", "")], "R34LockTests.test_run_budget_after_release_and_before_attempt")
    add("exit 2 instead of 0 on run budget", [("            print(\"docker-image-gc: run budget used; continuing tomorrow\")", "            raise Fatal('run budget used; continuing tomorrow')")], "R34LockTests.test_run_budget_after_release_and_before_attempt")
    add("hold above 45 s", [("BATCH_S = 10\n", "BATCH_S = 60\n")], "R34LockTests.test_maximal_hold_and_restart_spacing")
    for name in ("no deadline", "the timeout update dropped from `connect`",
                 "the wrapper bypassed for connection setup", "a parser that reads through its own unwrapped socket"):
        result[name][1].append("R34DeadlineTests.test_injected_http_connect_never_sends_after_deadline")
    return result


MUTANTS.update(r34_mutants())


SWITCH_ALPHABETS = ("0123456789abcdefABCDEF", "0123456789abcdefABCDEF", "0123456789")


def safety_inventory(source):
    """Scripted inventory; a new regex/helper or token class requires a sweep decision."""
    tree = ast.parse(source)
    regexes, helpers, tokens = set(), set(), []
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if not isinstance(target, ast.Name):
                    continue
                if isinstance(node.value, ast.Call) and ast.unparse(node.value.func) == "re.compile":
                    regexes.add(target.id)
                elif target.id in ("_DOMAIN_PART", "_HOST", "_PATH_PART"):
                    helpers.add(target.id)
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name):
            if node.func.value.id == "re" and node.func.attr != "compile":
                regexes.add(f"inline:{node.lineno}:{node.func.attr}")
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "zip":
            if len(node.args) == 2 and isinstance(node.args[1], ast.Tuple):
                tokens.append(ast.literal_eval(node.args[1]))
    return regexes, helpers, tokens


class SafetyAlphabetTests(Base):
    def test_inventory_is_closed(self):
        regexes, helpers, tokens = safety_inventory(SCRIPT.read_text())
        self.assertEqual(regexes, {"IMAGE_ID", "ID_FORM", "FULL_HEX", "DOMAIN", "PATH", "TAG",
                                  "DIGEST", "SHA256_DIGEST", "STORE_SYSTEM", "GENERATION"})
        self.assertEqual(helpers, {"_DOMAIN_PART", "_HOST", "_PATH_PART"})
        self.assertEqual(tokens, [SWITCH_ALPHABETS])

    def test_store_suffix_entire_unicode_alphabet_and_narrowing_mutants(self):
        # Unlike the hash and switch classes, [^/] is not an ASCII alphabet.
        # Exercise its entire Python character domain without creating a
        # million filesystem fixtures. Store-scan integration is tested below.
        import re
        pattern = self.gc.STORE_SYSTEM.pattern
        self.assertEqual(pattern.count("[^/]"), 1, "missing store suffix class anchor")
        prefix = "0" * 32 + "-nixos-system-"
        killed = 0
        for point in range(sys.maxunicode + 1):
            char = chr(point)
            if char == "/":
                self.assertIsNone(self.gc.STORE_SYSTEM.fullmatch(prefix + char))
                continue
            name = prefix + char
            self.assertIsNotNone(self.gc.STORE_SYSTEM.fullmatch(name), f"suffix U+{point:04X}")
            narrowed = pattern.replace("[^/]", "(?:(?!" + re.escape(char) + ")[^/])")
            self.assertIsNone(re.compile(narrowed).fullmatch(name), f"surviving suffix U+{point:04X}")
            killed += 1
        self.assertEqual(killed, sys.maxunicode)
        print(f"ok store suffix regex mutants: {killed}", file=sys.stderr)


def safety_character_tests():
    """Generate focused integration tests and source mutants, never hand-list characters."""
    result = {}
    token_anchor = repr(SWITCH_ALPHABETS).replace("'", '"')
    # Production formats the tuple on one line; an absent anchor is fatal.
    for position, alphabet in enumerate(SWITCH_ALPHABETS):
        for char in alphabet:
            changed = list(SWITCH_ALPHABETS)
            changed[position] = alphabet.replace(char, "")
            replacement = repr(tuple(changed)).replace("'", '"')
            result[f"switch alphabet {position} without {char}"] = (
                swap((token_anchor, replacement)), ["R34SwitchTests.test_every_switch_token_character"])

    def add(kind, char, old, new, check):
        name = f"test_{kind}_u{ord(char):04x}"
        def test(self):
            self.world()
            check(self, char)
        setattr(SafetyAlphabetTests, name, test)
        result[f"{kind} alphabet without U+{ord(char):04X}"] = (swap((old, new)), [f"SafetyAlphabetTests.{name}"])

    def identifier(self, char):
        image = img(int(char * 64, 16), 40)
        self.images.append(image)
        self.gc.DECLARED_REFS = [char * 12]
        _, plan = R34StoreTests.decision(self)
        self.assertIn(image["Id"], plan.reasons)
    old = 'ID_FORM = re.compile(r"^(?:sha256:)?([0-9a-f]{1,64})$")'
    for char in "0123456789abcdef":
        alphabet = "0123456789abcdef".replace(char, "")
        add("id_form", char, old, old.replace("[0-9a-f]", "[" + alphabet + "]"), identifier)

    def store_hash(self, char):
        system(self.tmp / (char * 32 + "-nixos-system-old"), {"old": "app:3"})
        _, plan = R34StoreTests.decision(self)
        self.assertIn(self.apps[3]["Id"], plan.reasons)
    old = 'STORE_SYSTEM = re.compile(r"^[0-9a-z]{32}-nixos-system-[^/]+$")'
    for char in "0123456789abcdefghijklmnopqrstuvwxyz":
        alphabet = "0123456789abcdefghijklmnopqrstuvwxyz".replace(char, "")
        add("store_hash", char, old, old.replace("[0-9a-z]", "[" + alphabet + "]"), store_hash)

    def generation(self, char):
        target = system(self.tmp / "custom-system", {"old": "app:3"})
        (self.tmp / "profiles" / f"system-42{char}-link").symlink_to(target)
        _, plan = R34StoreTests.decision(self)
        self.assertIn(self.apps[3]["Id"], plan.reasons)
    old = 'GENERATION = re.compile(r"^system-(\\d+)-link$")'
    for point in range(sys.maxunicode + 1):
        char = chr(point)
        if unicodedata.category(char) == "Nd":
            # Python's \d includes every Unicode decimal digit, not only 0..9.
            narrowed = "(?:(?!" + f"\\U{point:08x}" + ")\\d)"
            add("generation", char, old, old.replace("\\d", narrowed), generation)
    return result


MUTANTS.update(safety_character_tests())


class SocketIsolationTests(unittest.TestCase):
    @staticmethod
    def helper(name, pairs=()):
        import importlib.util
        spec = importlib.util.spec_from_file_location(name, REPO / "tests" / (name + ".py"))
        module = importlib.util.module_from_spec(spec)
        if pairs:
            source = Path(spec.origin).read_text()
            for before, after in pairs:
                if source.count(before) != 1:
                    raise AssertionError(f"missing or ambiguous helper mutation anchor: {before!r}")
                source = source.replace(before, after)
            exec(compile(source, spec.origin, "exec"), module.__dict__)
        else:
            spec.loader.exec_module(module)
        return module

    def test_every_load_has_a_fresh_absent_socket(self):
        with tempfile.TemporaryDirectory() as tmp:
            modules = [load(), load(), load(tmp=Path(tmp))]
            with mock.patch.object(sys.modules[__name__], "OVERRIDE", MUTANTS["no deadline"][0]):
                modules.append(load())
            paths = [Path(module.SOCKET_PATH) for module in modules]
            self.assertEqual(len({path.parent for path in paths}), len(paths))
            for path in paths:
                self.assertTrue(path.parent.is_dir())
                self.assertFalse(path.exists())

    def test_offline_harness_requires_a_fixture_socket(self):
        harness = self.helper("docker-image-gc-harness")
        # Reject before executing even the copied production source.
        source = "raise AssertionError('source must not be evaluated')"
        with self.assertRaises(KeyError):
            harness.load(source, {})
        for path in ("/var/run/docker.sock", "/run/docker.sock"):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "host Docker socket"):
                harness.load(source, {"SOCKET_PATH": path})

    def test_vm_helper_cannot_use_workstation_docker(self):
        support = self.helper("docker-image-gc-vm-support")
        with mock.patch.object(sys, "platform", "darwin"), mock.patch.object(socket, "socket") as plain_socket, \
             mock.patch.object(support.subprocess, "run") as subprocess_run:
            with self.assertRaisesRegex(RuntimeError, "isolated test VM"):
                support.UnixConnection("localhost").connect()
            with self.assertRaisesRegex(RuntimeError, "isolated test VM"):
                support.command("docker", "ps")
            with self.assertRaisesRegex(RuntimeError, "isolated test VM"):
                support.load_gc()
            plain_socket.assert_not_called()
            subprocess_run.assert_not_called()

    def test_mutants_ignore_a_listening_source_default(self):
        harness = self.helper("docker-image-gc-harness")
        # Short paths work with macOS's small sockaddr_un as well as Linux.
        with tempfile.TemporaryDirectory(prefix="ops327-proof-", dir="/tmp") as tmp:
            path = str(Path(tmp) / "daemon.sock")
            try:
                engine = harness.Engine(path)
            except PermissionError as exc:
                self.skipTest(f"sandbox refuses listening source-default proof: {exc}")
            with engine:
                source = SCRIPT.read_text()
                original = next(line for line in source.splitlines() if line.startswith("SOCKET_PATH = "))
                self.assertEqual(source.count(original), 1)
                copy = Path(tmp) / "gc.py"
                copy.write_text(source.replace(original, f"SOCKET_PATH = {path!r}"))
                names = ("the wrapper bypassed for connection setup", "no deadline",
                         "a parser that reads through its own unwrapped socket")
                selected = {name: MUTANTS[name] for name in names}
                with mock.patch.object(sys.modules[__name__], "SCRIPT", copy), mock.patch.dict(MUTANTS, selected, clear=True):
                    suite = unittest.TestSuite([MutantTests("test_every_mutant_is_caught")])
                    output = io.StringIO()
                    result = unittest.TextTestRunner(stream=output, verbosity=0).run(suite)
                self.assertTrue(result.wasSuccessful(), output.getvalue())
                self.assertEqual(engine.calls, [], "test reached the listening source default")


class RunnerPathTests(unittest.TestCase):
    OPTIONS = ("root", "compose-lock-dir", "instance-lock", "switch-lock", "keep-dir",
               "store", "engine-socket", "source", "worker")

    def check_rejection(self, runner, option, value):
        output = io.StringIO()
        with mock.patch.object(sys, "argv", ["realtime", "--" + option, value]), \
             mock.patch.object(sys, "platform", "darwin"), redirect_stderr(output), \
             mock.patch.object(runner, "worker", return_value=99) as worker, \
             mock.patch.object(runner, "Lane") as lane, mock.patch.object(Path, "mkdir") as mkdir:
            try:
                rc = runner.main()
            except SystemExit as exc:
                rc = exc.code
        self.assertEqual(rc, 2, output.getvalue())
        self.assertIn("path must stay inside checkout", output.getvalue())
        worker.assert_not_called()
        lane.assert_not_called()
        mkdir.assert_not_called()

    def test_every_argv_path_rejected_before_platform_or_creation(self):
        runner = SocketIsolationTests.helper("docker-image-gc-realtime")
        with tempfile.TemporaryDirectory(prefix="ops327-outside-") as outside:
            missing = str(Path(outside) / "never-created")
            for option in self.OPTIONS:
                for value in ("/", missing, str(REPO) + "-sibling/missing", str(REPO / ".." / "outside")):
                    with self.subTest(option=option, value=value):
                        self.check_rejection(runner, option, value)
            self.assertFalse(Path(missing).exists())

    def test_barrier_normalizes_paths_and_rejects_symlink_escapes(self):
        runner = SocketIsolationTests.helper("docker-image-gc-realtime")
        with tempfile.TemporaryDirectory(prefix="ops327-paths-", dir=REPO) as inside, \
             tempfile.TemporaryDirectory(prefix="ops327-outside-") as outside:
            self.assertEqual(runner.repo_path(str(Path(inside) / "new" / ".." / "file")), str(Path(inside) / "file"))
            self.assertEqual(runner.repo_path(str(REPO), directory=True), str(REPO))
            escape = Path(inside) / "escape"
            escape.symlink_to(outside, target_is_directory=True)
            for option in self.OPTIONS:
                with self.subTest(option=option):
                    self.check_rejection(runner, option, str(escape / "never-created"))
            self.assertFalse((Path(outside) / "never-created").exists())

    def test_each_skipped_option_is_killed(self):
        for option in self.OPTIONS:
            directory = option in ("root", "compose-lock-dir", "keep-dir", "store")
            anchor = f'        ("{option.replace("-", "_")}", {directory}),\n'
            runner = SocketIsolationTests.helper("docker-image-gc-realtime", [(anchor, "")])
            with self.subTest(mutant="skip barrier for --" + option):
                with self.assertRaises(AssertionError):
                    self.check_rejection(runner, option, "/")
            print(f"ok mutant: skip path barrier for --{option}", file=sys.stderr)


class AuditGuardTests(unittest.TestCase):
    # A fresh interpreter for each probe: permanent hook/mutant installation,
    # cwd changes and any descriptor operations cannot contaminate later tests.
    PROBE = r'''
import importlib.util, json, os, sys, tempfile
from pathlib import Path
request = json.load(sys.stdin)
repo = Path(request["repo"])
spec = importlib.util.spec_from_file_location("audit_probe_harness", repo / "tests/docker-image-gc-harness.py")
h = importlib.util.module_from_spec(spec)
helper_source = Path(spec.origin).read_text()
for before, after in request.get("mutations", []):
    assert helper_source.count(before) == 1, ("ambiguous audit mutation", before)
    helper_source = helper_source.replace(before, after)
exec(compile(helper_source, spec.origin, "exec"), h.__dict__)
with tempfile.TemporaryDirectory(prefix="ops327-audit-", dir="/tmp") as tmp:
    base = Path(tmp).resolve()
    root, outside = base / "fixture", base / "outside"
    root.mkdir(); outside.mkdir()
    (outside / "data").write_text("outside control")
    (root / "inside").write_text("fixture control")
    (root / "inside-link").symlink_to(root / "inside")
    (root / "escape").symlink_to(outside, target_is_directory=True)
    fragment = request["fragment"].replace("@OUTSIDE@", repr(str(outside / "data")))
    fragment = fragment.replace("@ROOT@", repr(str(root)))
    source = (repo / "hosts/csb1/docker-image-gc.py").read_text() + "\n" + fragment
    os.chdir(root if request.get("inside_cwd", True) else base)
    fd = os.open(outside / "data", os.O_RDONLY)
    dir_fd = os.open(outside, os.O_RDONLY)
    result = {"root": str(root), "outside": str(outside / "data"), "violations": []}
    try:
        if request.get("loader") == "load":
            paths, *_ = h.fixture(root)
            module = h.load(source, paths)
        else:
            # Deliberately exercise the behavioural layer independently of
            # static literal rejection. No inventory widening is the barrier.
            module = h.execute_source(source, root)
        module.PROBE_FD = fd
        module.PROBE_DIR_FD = dir_fd
        module.leak()
        result["violations"] = module.__ops327_fixture_guard__.violations
        result["outcome"] = "returned"
    except h.FixtureViolation as exc:
        result.update(outcome="violation", event=exc.event, path=exc.path, violations=exc.recorded)
    except BaseException as exc:
        result.update(outcome="unrelated", error=type(exc).__name__ + ": " + str(exc))
    finally:
        os.close(fd)
        os.close(dir_fd)
        os.chdir(repo)
    print(json.dumps(result))
'''

    def probe(self, fragment, *, loader=None, inside_cwd=True):
        request = {"repo": str(REPO), "fragment": fragment, "loader": loader,
                   "inside_cwd": inside_cwd, "mutations": getattr(self, "mutations", [])}
        result = subprocess.run([sys.executable, "-B", "-c", self.PROBE], input=json.dumps(request),
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def violation(self, fragment, event, path, **kwargs):
        result = self.probe(fragment, **kwargs)
        expected = path(result) if callable(path) else os.path.realpath(path)
        self.assertEqual(result["outcome"], "violation", result)
        self.assertEqual((result["event"], result["path"]), (event, expected), result)
        self.assertEqual(result["violations"], [{"event": event, "path": expected}])

    def control(self, fragment, **kwargs):
        result = self.probe(fragment, **kwargs)
        self.assertEqual(result["outcome"], "returned", result)
        self.assertEqual(result["violations"], [])

    def test_shared_assignment_dict_is_guarded_after_load(self):
        self.violation('SOCKET_PATH, NOTES = "/var/run/docker.sock", {"log": "/var/log/docker-image-gc"}\n'
                       'def leak(): open(NOTES["log"])', "open", "/var/log/docker-image-gc", loader="load")

    def test_derived_dict_is_guarded_after_load(self):
        self.violation('STATE = {"file": os.path.join(KEEP_DIR, "state")}\n'
                       'def leak(): open(STATE["file"])', "open", "/var/lib/docker-image-gc/keep.d/state", loader="load")

    def test_subscript_assignment_is_guarded_after_load(self):
        self.violation('cache = {}\ncache[SOCKET_PATH] = "/etc/docker/daemon.json"\n'
                       'def leak(): open(next(iter(cache.values())))', "open", "/etc/docker/daemon.json", loader="load")

    def test_function_default_is_guarded_after_load(self):
        self.violation('def leak(path=KEEP_DIR): open(os.path.join(path, "state"))',
                       "open", "/var/lib/docker-image-gc/keep.d/state", loader="load")

    def test_standalone_dict_is_guarded_without_inventory(self):
        self.violation('NOTES = {"log": "/var/log/docker-image-gc"}\ndef leak(): open(NOTES["log"])',
                       "open", "/var/log/docker-image-gc")

    def test_globals_protocol_value_is_guarded_after_load(self):
        self.violation('def leak(): open(globals()["PRUNE_PATH"])', "open",
                       "/build/prune?all=1&filters=%7B%22until%22%3A+%5B%2248h%22%5D%7D", loader="load")

    def test_call_time_path_is_guarded(self):
        self.violation('def leak(): open("/" + "etc/hosts")', "open", "/etc/hosts")

    def test_pathlib_join_is_guarded(self):
        self.violation('from pathlib import Path\ndef leak(): (Path("/etc") / "hosts").open()', "open", "/etc/hosts")

    def test_bytes_path_is_guarded(self):
        self.violation('def leak(): open(b"/etc/hosts")', "open", "/etc/hosts")

    def test_relative_parent_escape_is_guarded(self):
        self.violation('def leak(): open("../outside/data")', "open", lambda r: r["outside"])

    def test_relative_path_requires_fixture_cwd(self):
        self.violation('def leak(): open("fixture/inside")', "open", lambda r: r["root"] + "/inside", inside_cwd=False)

    def test_symlink_escape_is_guarded(self):
        self.violation('def leak(): open("escape/data")', "open", lambda r: r["outside"])

    def test_descriptor_relative_escape_is_guarded(self):
        for operation, event in (
            ('os.open("data", os.O_RDONLY, dir_fd=PROBE_DIR_FD)', 'open'),
            ('os.unlink("data", dir_fd=PROBE_DIR_FD)', 'os.remove'),
            ('os.rename("inside", "data", dst_dir_fd=PROBE_DIR_FD)', 'os.rename'),
            ('os.stat("data", dir_fd=PROBE_DIR_FD)', 'metadata.stat'),
        ):
            with self.subTest(operation=operation):
                self.violation('def leak(): ' + operation, event, lambda r: r["outside"])

    def test_unsafe_symlink_target_is_guarded(self):
        self.violation('def leak():\n'
                       '    os.symlink("inside", "changing")\n'
                       '    with open("changing") as stream: stream.read()\n'
                       '    os.unlink("changing")\n'
                       '    os.symlink(@OUTSIDE@, "changing")', "os.symlink", lambda r: r["outside"])

    def test_uninventoried_socket_is_guarded(self):
        self.violation('hidden = {"socket": SOCKET_PATH}\n'
                       'def leak():\n    with socket.socket(socket.AF_UNIX) as sock: sock.connect(hidden["socket"])',
                       "socket.connect", "/var/run/docker.sock", loader="load")

    def test_socket_event_family_is_guarded(self):
        # Missing sibling socket is owned by this probe; a disabled event guard
        # can fail only with an unrelated OS error, never reach host Docker.
        self.violation('def leak():\n    with socket.socket(socket.AF_UNIX) as sock: sock.connect(@OUTSIDE@)',
                       "socket.connect", lambda r: r["outside"])

    def test_top_level_io_is_guarded_before_exec(self):
        self.violation('open("/etc/hosts")\ndef leak(): pass', "open", "/etc/hosts")

    def test_unit_loader_is_guarded_before_exec_and_after_return(self):
        with mock.patch.object(sys.modules[__name__], "OVERRIDE", ("text", lambda s: s + '\nopen(KEEP_DIR)\n')):
            with self.assertRaises(HARNESS.FixtureViolation) as raised:
                load()
        self.assertEqual((raised.exception.event, raised.exception.path), ("open", os.path.realpath("/var/lib/docker-image-gc/keep.d")))
        with mock.patch.object(sys.modules[__name__], "OVERRIDE", ("text", lambda s: s + '\ndef leak(path=KEEP_DIR): open(path)\n')):
            module = load()
        with self.assertRaises(HARNESS.FixtureViolation) as raised:
            module.leak()
        self.assertEqual((raised.exception.event, raised.exception.path), ("open", os.path.realpath("/var/lib/docker-image-gc/keep.d")))
        self.assertEqual(module.__ops327_fixture_guard__.violations,
                         [{"event": "open", "path": os.path.realpath("/var/lib/docker-image-gc/keep.d")}])

    def test_guard_disabled_is_killed(self):
        # Benign owned sibling file: even the disabled-guard mutant performs
        # no read of an operator file and no write outside the fixture.
        self.violation('def leak():\n    with open(@OUTSIDE@) as stream: stream.read()',
                       "open", lambda r: r["outside"])

    def test_write_and_relative_read_under_fixture_pass(self):
        self.control('def leak():\n    with open("created", "w") as stream: stream.write("ok")\n'
                     '    with open("created") as stream: assert stream.read() == "ok"')

    def test_import_and_interpreter_read_roots_pass(self):
        self.control('def leak():\n    import fractions, sysconfig\n'
                     '    for path in (sys.prefix, sys.base_prefix, sysconfig.get_path("stdlib"), '
                     'sysconfig.get_path("platstdlib")):\n        os.listdir(path)')

    def test_nix_store_import_root_passes(self):
        if not Path("/nix/store").is_dir():
            self.skipTest("Nix interpreter import store is absent")
        self.control('def leak(): os.listdir("/nix/store")')

    def test_proc_and_proc_locks_read_passes(self):
        if not Path("/proc/locks").is_file():
            self.skipTest("Linux-only /proc/locks control")
        self.control('def leak():\n    os.listdir("/proc")\n    with open("/proc/locks") as stream: stream.read(64)')

    def test_dev_null_read_passes(self):
        self.control('def leak():\n    with open("/dev/null") as stream: assert stream.read() == ""')

    def test_read_exceptions_never_allow_writes(self):
        for path in (sys.prefix, sys.base_prefix, "/nix/store", "/proc", "/dev/null"):
            with self.subTest(path=path):
                self.violation(f'def leak(): open({path!r}, "w")', "open", path)

    def test_filesystem_event_families_are_guarded(self):
        cases = [
            ('os.unlink(@OUTSIDE@)', 'os.remove'), ('os.remove(@OUTSIDE@)', 'os.remove'),
            ('os.rename(@OUTSIDE@, "renamed")', 'os.rename'),
            ('os.replace("inside", @OUTSIDE@)', 'os.rename'),
            ('os.mkdir(@OUTSIDE@)', 'os.mkdir'), ('os.rmdir(@OUTSIDE@)', 'os.rmdir'),
            ('os.listdir(@OUTSIDE@)', 'os.listdir'), ('os.scandir(@OUTSIDE@)', 'os.scandir'),
            ('os.chmod(@OUTSIDE@, 0o600)', 'os.chmod'), ('os.chown(@OUTSIDE@, -1, -1)', 'os.chown'),
            ('os.utime(@OUTSIDE@, None)', 'os.utime'), ('os.truncate(@OUTSIDE@, 0)', 'os.truncate'),
            ('os.link(@OUTSIDE@, "linked")', 'os.link'), ('os.symlink(@OUTSIDE@, "linked")', 'os.symlink'),
            ('fcntl.flock(PROBE_FD, fcntl.LOCK_EX | fcntl.LOCK_NB)', 'fcntl.flock'),
            ('fcntl.lockf(PROBE_FD, fcntl.LOCK_EX | fcntl.LOCK_NB)', 'fcntl.lockf'),
            ('open(PROBE_FD)', 'open'),
            ('socket.socket(socket.AF_UNIX).bind(@OUTSIDE@)', 'socket.bind'),
            ('shutil.copyfile(@OUTSIDE@, "copy")', 'shutil.copyfile'),
            ('shutil.copyfile("inside", @OUTSIDE@)', 'shutil.copyfile'),
            ('shutil.copymode("inside", @OUTSIDE@)', 'shutil.copymode'),
            ('shutil.copystat("inside", @OUTSIDE@)', 'shutil.copystat'),
            ('shutil.move(@OUTSIDE@, "moved")', 'shutil.move'),
            ('shutil.rmtree(@OUTSIDE@)', 'shutil.rmtree'),
            ('os.stat(@OUTSIDE@)', 'metadata.stat'), ('os.lstat(@OUTSIDE@)', 'metadata.lstat'),
            ('os.path.exists(@OUTSIDE@)', 'metadata.exists'), ('os.path.isdir(@OUTSIDE@)', 'metadata.isdir'),
        ]
        for operation, event in cases:
            with self.subTest(event=event, operation=operation):
                self.violation('import shutil\ndef leak(): ' + operation, event, lambda r: r["outside"])

    def test_samefile_checks_both_paths_and_keywords(self):
        for operation in ('os.path.samefile("inside", @OUTSIDE@)',
                          'os.path.samefile(f1="inside", f2=@OUTSIDE@)',
                          'os.path.samefile(f1=@OUTSIDE@, f2="inside")'):
            self.violation('def leak(): ' + operation, "metadata.samefile", lambda r: r["outside"])
        self.control('def leak():\n    assert os.path.samefile(f1="inside", f2="inside-link")')

    def test_os_path_import_spellings_keep_metadata_guard(self):
        for imports, function in (("from os import path", "path.getsize"),
                                  ("import os.path", "os.path.getsize"),
                                  ("import os.path as path", "path.getsize"),
                                  ("from os.path import getsize", "getsize"),
                                  ('path = __import__("os.path", fromlist=["getsize"])', "path.getsize")):
            self.violation(imports + '\ndef leak(): ' + function + '(@OUTSIDE@)',
                           "metadata.getsize", lambda r: r["outside"])
            self.control(imports + '\ndef leak(): assert ' + function + '("inside") == 15')

    def test_sqlite_connect_is_a_guarded_write(self):
        self.violation('import sqlite3\ndef leak(): sqlite3.connect(@OUTSIDE@)',
                       "sqlite3.connect", lambda r: r["outside"])
        self.control('import sqlite3\ndef leak(): sqlite3.connect("inside-db").close()')

    def test_each_audit_guard_mutant_is_killed_by_named_test(self):
        mutants = [
            ('            guard.audit(event, args)\n', '', 'test_guard_disabled_is_killed'),
            ('{"socket.connect", "socket.bind", "socket.sendto"}', '{"socket.bind", "socket.sendto"}',
             'test_socket_event_family_is_guarded'),
            ('resolved = _REALPATH(path)', 'resolved = os.path.abspath(path)', 'test_symlink_escape_is_guarded'),
            ('allowed = self.inside(resolved, self.root)', 'allowed = self.inside(resolved, "/")',
             'test_guard_disabled_is_killed'),
            ('("getsize", "getmtime", "getatime", "getctime", "realpath")',
             '("getmtime", "getatime", "getctime", "realpath")', 'test_metadata_getsize_is_guarded'),
            ('("getsize", "getmtime", "getatime", "getctime", "realpath")',
             '("getsize", "getmtime", "getatime", "getctime")', 'test_metadata_realpath_is_guarded'),
        ]
        for before, after, method in mutants:
            probe = type(self)(method)
            probe.mutations = [(before, after)]
            result = unittest.TestResult()
            probe.run(result)
            self.assertFalse(result.errors, result.errors)
            self.assertEqual(len(result.failures), 1, f"audit mutant survived: {before}")
            print(f"ok audit mutant: {method}: {before.strip()}", file=sys.stderr)


# Independent inventory of non-audited filesystem APIs on macOS/Linux CPython
# 3.13/3.14. Each entry becomes its own discovered test and named mutation gate.
# Spelling-only os.path functions and descriptor-only APIs do not access a path.
METADATA_PROBES = {
    "stat": ('os.stat(@PATH@)', 'os.stat("inside").st_size == 15'),
    "lstat": ('os.lstat(@PATH@)', 'os.lstat("inside").st_size == 15'),
    "access": ('os.access(@PATH@, os.F_OK)', 'os.access("inside", os.F_OK)'),
    "readlink": ('os.readlink(@PATH@)', 'os.readlink("inside-link") == os.path.join(@ROOT@, "inside")'),
    "pathconf": ('os.pathconf(@PATH@, "PC_NAME_MAX")', 'os.pathconf("inside", "PC_NAME_MAX") > 0'),
    "statvfs": ('os.statvfs(@PATH@)', 'os.statvfs("inside").f_bsize > 0'),
    "exists": ('os.path.exists(@PATH@)', 'os.path.exists("inside")'),
    "lexists": ('os.path.lexists(@PATH@)', 'os.path.lexists("inside-link")'),
    "isdir": ('os.path.isdir(@PATH@)', 'os.path.isdir(@ROOT@)'),
    "isfile": ('os.path.isfile(@PATH@)', 'os.path.isfile("inside")'),
    "islink": ('os.path.islink(@PATH@)', 'os.path.islink("inside-link")'),
    "ismount": ('os.path.ismount(@PATH@)', 'not os.path.ismount(@ROOT@)'),
    "isjunction": ('os.path.isjunction(@PATH@)', 'not os.path.isjunction("inside")'),
    "isdevdrive": ('os.path.isdevdrive(@PATH@)', 'not os.path.isdevdrive("inside")'),
    "getsize": ('os.path.getsize(@PATH@)', 'os.path.getsize("inside") == 15'),
    "getmtime": ('os.path.getmtime(@PATH@)', 'os.path.getmtime("inside") > 0'),
    "getatime": ('os.path.getatime(@PATH@)', 'os.path.getatime("inside") > 0'),
    "getctime": ('os.path.getctime(@PATH@)', 'os.path.getctime("inside") > 0'),
    "samefile": ('os.path.samefile(@PATH@, "inside")', 'os.path.samefile("inside", "inside-link")'),
    "realpath": ('os.path.realpath(@PATH@, strict=True)',
                 'os.path.realpath("inside-link", strict=True) == os.path.join(@ROOT@, "inside")'),
    "mkfifo": ('os.mkfifo(@PATH@)', 'os.mkfifo("inside-fifo") is None'),
    "mknod": ('os.mknod(@PATH@)', None),
    "chroot": ('os.chroot(@PATH@)', None),
}


def metadata_probe(name, operation, control):
    def test(self):
        event = ("os." if name in {"mkfifo", "mknod", "chroot"} else "metadata.") + name
        self.violation('def leak(): ' + operation.replace("@PATH@", "@OUTSIDE@"),
                       event, lambda r: r["outside"])
        if control is not None:
            self.control('def leak():\n    assert ' + control)
        else:
            # Never chroot or create device nodes in a test interpreter. This
            # positive control proves fixture admission/native delegation only.
            with tempfile.TemporaryDirectory(prefix="ops327-metadata-") as tmp:
                guard = HARNESS.FixtureGuard(tmp)
                with mock.patch.object(os, name, return_value="delegated") as implementation:
                    self.assertEqual(getattr(HARNESS.GuardedOS(guard), name)(tmp), "delegated")
                    implementation.assert_called_once_with(tmp)
                self.assertEqual(guard.violations, [])
    return test


for _name, (_operation, _control) in METADATA_PROBES.items():
    setattr(AuditGuardTests, f"test_metadata_{_name}_is_guarded", metadata_probe(_name, _operation, _control))


class PathInventoryTests(unittest.TestCase):
    def setUp(self):
        self.h = SocketIsolationTests.helper("docker-image-gc-harness")

    def form(self, fragment, names=("FAKE_PATH",)):
        source = "import os\nfrom pathlib import Path\nSOCKET_PATH = '/fixture/socket'\n" + fragment
        expected = {"SOCKET_PATH", *names}
        self.assertEqual(returns_normally(self.h.path_constants, source), expected)
        paths = {name: "/fixture/override-" + name for name in expected}
        with self.assertRaisesRegex(ValueError, "path keys"):
            self.h.check_path_contract(source, {"SOCKET_PATH": paths["SOCKET_PATH"]})
        with self.assertRaisesRegex(ValueError, "path keys"):
            self.h.load(source, {"SOCKET_PATH": paths["SOCKET_PATH"]})
        self.h.check_path_contract(source, paths)
        module = self.h.load(source, paths)
        for name in expected:
            self.assertEqual(getattr(module, name), paths[name])

    def test_computed_join(self):
        self.form("FAKE_PATH = os.path.join('/fixture', 'state')\n")

    def test_f_string(self):
        self.form("part = 'state'\nFAKE_PATH = f'/fixture/{part}'\n")

    def test_concatenation(self):
        self.form("part = 'state'\nFAKE_PATH = '/fixture/' + part\n")

    def test_pathlike(self):
        self.form("FAKE_PATH = Path('/fixture/state')\n")

    def test_list(self):
        self.form("FAKE_PATH = ['/fixture/state']\n")

    def test_set(self):
        self.form("FAKE_PATH = {'/fixture/state'}\n")

    def test_tuple(self):
        self.form("FAKE_PATH = ('/fixture/state',)\n")

    def test_frozenset(self):
        self.form("FAKE_PATH = frozenset({'/fixture/state'})\n")

    def test_mixed_nested_collection(self):
        self.form("FAKE_PATH = [None, [Path('/fixture/state')]]\n")

    def test_multiple_targets(self):
        self.form("FAKE_PATH = ALIAS_PATH = '/fixture/state'\n", ("FAKE_PATH", "ALIAS_PATH"))

    def test_inside_if(self):
        self.form("if True:\n    FAKE_PATH = '/fixture/state'\n")

    def test_inside_try(self):
        self.form("try:\n    FAKE_PATH = '/fixture/state'\nexcept ValueError:\n    pass\n")

    def test_bytes(self):
        self.form("FAKE_PATH = b'/fixture/state'\n")

    def test_derived_constant(self):
        self.form("RUN_DIR = '/fixture/run'\nSTATE_FILE = os.path.join(RUN_DIR, 'state')\n", ("RUN_DIR", "STATE_FILE"))

    def test_annotated_constant(self):
        self.form("FAKE_PATH: str = '/fixture/state'\n")

    def test_absolute_literal_outside_constant(self):
        for fragment in ("def leak(): return '/unowned'", "def leak():\n    LOCAL = '/unowned'",
                         "if False:\n    HIDDEN = '/unowned'", "def leak(): return b'/unowned'"):
            with self.subTest(fragment=fragment), self.assertRaisesRegex(ValueError, "uninventoried absolute path"):
                self.h.path_constants(fragment)

    def test_allowlisted_name_cannot_be_used_as_filesystem_path(self):
        for fragment in ("def leak(): open(PRUNE_PATH)", "def leak(): return Path(PRUNE_PATH)",
                         "def leak():\n    alias = PRUNE_PATH\n    return alias"):
            with self.subTest(fragment=fragment), self.assertRaisesRegex(ValueError, "non-filesystem name"):
                self.h.path_constants(SCRIPT.read_text() + "\n" + fragment)

    def test_http_and_separator_literals_cannot_be_filesystem_paths(self):
        self.assertEqual(returns_normally(self.h.path_constants, SCRIPT.read_text()),
                         {"SOCKET_PATH", "KEEP_DIR", "STORE_DIR", "PROFILES_DIR", "CURRENT_SYSTEM", "BOOTED_SYSTEM",
                          "LOCK_PATHS", "SWITCH_LOCK", "PROC", "PROC_LOCKS", "INSTANCE_LOCK"})
        self.h.check_path_contract(SCRIPT.read_text(), dict.fromkeys(self.h.path_constants(SCRIPT.read_text())))
        for path in ("/", "/containers/json?all=1", "/images/json", "/images/", "/build/prune?"):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "uninventoried absolute path"):
                self.h.path_constants(SCRIPT.read_text() + f"\ndef leak(): open({path!r})\n")

    def test_each_inventory_rule_removed_is_killed(self):
        rules = [
            ('(str, bytes, os.PathLike)', '(bytes, os.PathLike)', 'test_computed_join'),
            ('(str, bytes, os.PathLike)', '(str, os.PathLike)', 'test_bytes'),
            ('(str, bytes, os.PathLike)', '(str, bytes)', 'test_pathlike'),
            ('(list, tuple, set, frozenset)', '(tuple, set, frozenset)', 'test_list'),
            ('(list, tuple, set, frozenset)', '(list, set, frozenset)', 'test_tuple'),
            ('(list, tuple, set, frozenset)', '(list, tuple, frozenset)', 'test_set'),
            ('(list, tuple, set, frozenset)', '(list, tuple, set)', 'test_frozenset'),
            ('any(contains_path(item) for item in value)', 'all(absolute_path(item) for item in value)', 'test_mixed_nested_collection'),
            ('found = {name for name, value in vars(module).items() if contains_path(value)}',
             'found = {target.id for node in ast.parse(source).body if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) and absolute_path(node.value.value) for target in node.targets if isinstance(target, ast.Name)}', 'test_derived_constant'),
            ('if not call_argument(node, NON_FILESYSTEM_NAMES[node.id]):', 'if False:', 'test_allowlisted_name_cannot_be_used_as_filesystem_path'),
            ('if not isinstance(node, ast.Constant) or not absolute_path(node.value):', 'if True:', 'test_absolute_literal_outside_constant'),
            ('if names & found:', 'if True:', 'test_absolute_literal_outside_constant'),
            ('    check_path_contract(source, paths, module)\n', '', 'test_computed_join'),
            ('    found -= NON_FILESYSTEM_NAMES.keys()\n', '', 'test_http_and_separator_literals_cannot_be_filesystem_paths'),
        ]
        for before, after, method in rules:
            mutant = SocketIsolationTests.helper("docker-image-gc-harness", [(before, after)])
            probe = type(self)(method)
            probe.setUp = lambda mutant=mutant: setattr(probe, "h", mutant)
            result = unittest.TextTestRunner(stream=io.StringIO(), resultclass=BehavioralResult).run(unittest.TestSuite([probe]))
            self.assertFalse(result.errors, result.errors)
            self.assertTrue(result.failures, f"inventory mutant survived: {before}")
            print(f"ok inventory mutant: {before}", file=sys.stderr)


class WorkerContractTests(unittest.TestCase):
    def setUp(self):
        self.runner = SocketIsolationTests.helper("docker-image-gc-realtime")
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="ops327-worker-", dir=REPO)))
        self.paths, *_ = self.runner.h.fixture(self.root / "fixture")
        self.source = self.root / "source.py"
        # Execute the real loader and post-load checks; main alone is a stub.
        self.source.write_text(SCRIPT.read_text() + "\ndef main(): return 0\n")
        self.manifest = self.root / "manifest.json"
        self.data = {"source": str(self.source), "paths": self.paths,
                     "events": str(self.root / "events.json"), "constants": {"RUN_BUDGET_S": 300}}

    def rejection(self, runner, data, reason, *, subprocess_worker=False, reported=False):
        self.manifest.write_text(json.dumps(data))
        before = {str(path.relative_to(self.root)) for path in self.root.rglob("*")}
        if subprocess_worker:
            result = subprocess.run([sys.executable, "-B", str(REPO / "tests/docker-image-gc-realtime.py"),
                                     "--worker", str(self.manifest)], capture_output=True, text=True, timeout=10)
            rc, error = result.returncode, result.stderr
            self.assertEqual(result.stdout, "")
        else:
            error = io.StringIO()
            with redirect_stderr(error):
                try: rc = in_process_worker(runner, self.manifest)
                except SystemExit as exc: rc = exc.code
            error = error.getvalue()
        self.assertEqual(rc, 2, error)
        self.assertIn(reason, error)
        self.assertEqual(len(error.splitlines()), 1, error)
        after = {str(path.relative_to(self.root)) for path in self.root.rglob("*")}
        if reported:
            events = Path(self.data["events"])
            self.assertEqual(json.loads(events.read_text())["violations"], [])
            with self.assertRaisesRegex(RuntimeError, "worker setup failed"):
                runner.worker_events(events)
            after.discard(str(events.relative_to(self.root)))
            before.discard(str(events.relative_to(self.root)))
            events.unlink()
        self.assertEqual(before, after)

    def invalid_manifests(self, outside):
        import copy
        def variant(): return copy.deepcopy(self.data)
        for key in self.paths:
            data = variant(); del data["paths"][key]
            yield f"missing {key}", data, "path keys"
        data = variant(); data["paths"]["EXTRA"] = str(self.root / "extra")
        yield "extra path", data, "path keys"
        for key in self.paths:
            if key in ("PROC", "PROC_LOCKS"):
                data = variant(); data["paths"][key] = str(self.root / "fake-proc")
                yield key, data, key + " must name"
            else:
                data = variant(); data["paths"][key] = [outside] * 3 if key == "LOCK_PATHS" else outside
                yield key, data, "path must stay inside checkout"
        for key in ("source", "events"):
            data = variant(); data[key] = outside
            yield key, data, "path must stay inside checkout"
        for value in (None, True, False, "300", 3.5, [], {}):
            data = variant(); data["constants"]["RUN_BUDGET_S"] = value
            yield f"budget type {value!r}", data, "must be an int"
        for value in (-1, 0, 3001):
            data = variant(); data["constants"]["RUN_BUDGET_S"] = value
            yield f"budget bound {value}", data, "within 1..3000"
        for key in ("SOCKET_PATH", "INSTANCE_LOCK", "PROC", "PROC_LOCKS", "BATCH_S", "unknown"):
            data = variant(); data["constants"][key] = str(self.root / "override")
            yield f"constant {key}", data, "constants keys"
        for key in self.data:
            data = variant(); del data[key]
            yield f"top missing {key}", data, "top-level keys"
        data = variant(); data["extra"] = 1
        yield "top extra", data, "top-level keys"
        for value in ("bad", [], None):
            data = variant(); data["constants"] = value
            yield f"constants type {value!r}", data, "constants keys"
        for value in ([], "bad", [str(self.root)] * 2):
            data = variant(); data["paths"]["LOCK_PATHS"] = value
            yield f"lock tuple {value!r}", data, "LOCK_PATHS must contain"

    def test_every_manifest_rule_in_subprocess(self):
        with tempfile.TemporaryDirectory(prefix="ops327-escape-") as outside:
            for label, data, reason in self.invalid_manifests(outside):
                with self.subTest(rule=label):
                    self.rejection(self.runner, data, reason, subprocess_worker=True)
                    self.assertEqual(list(Path(outside).iterdir()), [])

    def test_valid_manifest_and_closed_fixture_inventory(self):
        self.runner.h.check_path_contract(SCRIPT.read_text(), self.paths)
        with self.assertRaisesRegex(ValueError, "path keys"):
            self.runner.h.check_path_contract(SCRIPT.read_text() + '\nFAKE_PATH = "/fake"\n', self.paths)
        self.manifest.write_text(json.dumps(self.data))
        result = subprocess.run([sys.executable, "-B", str(REPO / "tests/docker-image-gc-realtime.py"),
                                 "--worker", str(self.manifest)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(Path(self.data["events"]).is_file())

    def test_in_process_and_subprocess_workers_enforce_audit_guard(self):
        # Same worker path as every real-time Lane.start, with no engine,
        # wall-clock schedule or socket bind needed for this safety proof.
        base = SCRIPT.read_text()
        for fragment in ('open(KEEP_DIR)', 'def main(path=KEEP_DIR): open(path)'):
            self.source.write_text(base + "\n" + fragment + "\n")
            self.manifest.write_text(json.dumps(self.data))
            for child in (False, True):
                with self.subTest(fragment=fragment, subprocess=child):
                    if child:
                        result = subprocess.run([sys.executable, "-B", str(REPO / "tests/docker-image-gc-realtime.py"),
                                                 "--worker", str(self.manifest)], capture_output=True, text=True, timeout=10)
                        rc, error = result.returncode, result.stderr
                    else:
                        output = io.StringIO()
                        with redirect_stderr(output):
                            rc = in_process_worker(self.runner, self.manifest)
                        error = output.getvalue()
                    self.assertEqual(rc, 2, error)
                    self.assertTrue(error.startswith("fixture audit violation: "), error)
                    self.assertEqual(json.loads(error.split(": ", 1)[1]),
                                     [{"event": "open", "path": os.path.realpath("/var/lib/docker-image-gc/keep.d")}])
                    events = Path(self.data["events"])
                    self.assertEqual(json.loads(events.read_text())["violations"],
                                     [{"event": "open", "path": os.path.realpath("/var/lib/docker-image-gc/keep.d")}])
                    events.unlink(missing_ok=True)

    def test_worker_fixture_write_passes_and_records_no_violation(self):
        self.source.write_text(SCRIPT.read_text() + '\ndef main():\n'
                               '    with open(os.path.join(KEEP_DIR, "audit-control"), "w") as stream: stream.write("ok")\n'
                               '    return 0\n')
        self.manifest.write_text(json.dumps(self.data))
        self.assertEqual(in_process_worker(self.runner, self.manifest), 0)
        self.assertEqual(Path(self.paths["KEEP_DIR"], "audit-control").read_text(), "ok")
        events = json.loads(Path(self.data["events"]).read_text())
        self.assertIn("violations", events)
        self.assertEqual(events["violations"], [])

    def test_captured_host_default_is_setup_failure_in_realtime(self):
        r = self.runner
        self.source.write_text(SCRIPT.read_text() + '\ndef main(path=SWITCH_LOCK): os.stat(path)\n')
        self.manifest.write_text(json.dumps(self.data))
        process = subprocess.Popen([sys.executable, "-B", str(REPO / "tests/docker-image-gc-realtime.py"),
                                    "--worker", str(self.manifest)], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        process.events = Path(self.data["events"])
        out, err = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 2, (out, err))
        records = [{"event": "metadata.stat", "path": os.path.realpath("/run/nixos/switch-to-configuration.lock")}]
        self.assertEqual(json.loads(process.events.read_text())["violations"], records)
        lane = types.SimpleNamespace(processes=[process])
        for check in (lambda: r.Lane.finish(lane, process, expected=2), lambda: r.Lane.check_workers(lane)):
            with self.assertRaisesRegex(RuntimeError, "metadata.stat") as caught:
                check()
            self.assertIn(records[0]["path"], str(caught.exception))
            for mutant in (None, "captured default"):
                passed, message = r.classify_case("r29", mutant, True, caught.exception)
                self.assertFalse(passed, message)
                self.assertIn("(setup:", message)

    def test_worker_success_omits_violations_mutant_is_killed(self):
        before = 'def finish_worker_report(events, report, publisher, rc):'
        after = before + '\n    report.pop("violations", None)'
        probe = type(self)("test_worker_fixture_write_passes_and_records_no_violation")
        result = unittest.TestResult()
        # Keep setup's fresh fixture/runner, then mutate the worker under test.
        original = probe.setUp
        def setup():
            original()
            probe.runner = SocketIsolationTests.helper("docker-image-gc-realtime", [(before, after)])
        probe.setUp = setup
        probe.run(result)
        self.assertFalse(result.errors, result.errors)
        self.assertEqual(len(result.failures), 1, "worker success reporting mutant survived")
        print("ok real-time mutant: success omits violations: test_worker_fixture_write_passes_and_records_no_violation",
              file=sys.stderr)

    def test_backlog_worker_violations_are_setup_failures(self):
        r = self.runner
        for fragment, violation in (('def main(api): return 2', False),
                                    ('def main(api, path=SWITCH_LOCK): os.stat(path)', True),
                                    ('def main(api): raise RuntimeError("worker setup")', False)):
            self.source.write_text(SCRIPT.read_text() + '\n' + fragment + '\n')
            self.manifest.write_text(json.dumps(self.data))
            gc, _ = r.prepare_worker(str(self.manifest))
            with preserved_process_state():
                self.assertEqual(r.backlog_worker(gc, None, self.root), 2)
            path = self.root / "backlog.events.json"
            events = json.loads(path.read_text())
            self.assertIn("violations", events)
            if violation or "RuntimeError" in fragment:
                with self.assertRaises(RuntimeError) as caught:
                    r.worker_events(path)
                for mutant in (None, "backlog mutant"):
                    passed, message = r.classify_case("full-accept-queue", mutant, True, caught.exception)
                    self.assertFalse(passed, message)
                    self.assertIn("(setup:", message)
                if violation:
                    self.assertEqual(events["violations"], [{"event": "metadata.stat", "path":
                                      os.path.realpath("/run/nixos/switch-to-configuration.lock")}])
            else:
                self.assertEqual(r.worker_events(path)["violations"], [])
                self.assertEqual((self.root / "backlog.result").read_text(), "2")

    def test_duplicate_json_keys_rejected(self):
        self.manifest.write_text('{"source":1,"source":2}')
        error = io.StringIO()
        with redirect_stderr(error): self.assertEqual(in_process_worker(self.runner, self.manifest), 2)
        self.assertIn("duplicate manifest key", error.getvalue())
        self.assertFalse(Path(self.data["events"]).exists())

    def test_loaded_paths_and_socket_are_rechecked(self):
        for key, value in (("KEEP_DIR", str(self.root / "other-keep")), ("PROC", "/wrong-proc"),
                           ("SOCKET_PATH", "/var/run/docker.sock")):
            original = self.runner.h.load
            def tamper(source, paths):
                module = original(source, paths); setattr(module, key, value); return module
            with self.subTest(key=key), mock.patch.object(self.runner.h, "load", side_effect=tamper):
                reason = "loaded path constants" if key == "KEEP_DIR" else ("PROC must name" if key == "PROC" else "path must stay")
                self.rejection(self.runner, self.data, reason, reported=True)
        # Re-run the same socket barrier after applying constants, even though
        # today's constant whitelist excludes paths.
        with mock.patch.object(self.runner.h, "check_socket") as guard:
            self.manifest.write_text(json.dumps(self.data))
            self.runner.prepare_worker(str(self.manifest))
        self.assertEqual(guard.call_args_list, [mock.call(self.paths["SOCKET_PATH"])] * 2)

    def test_in_process_worker_restores_state_on_return_and_exception(self):
        for raises in (False, True):
            previous_env = dict(os.environ)
            previous_handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGALRM, signal.SIGINT, signal.SIGHUP)}
            def main():
                self.assertEqual(os.environ.get("INVOCATION_ID"), "ops327-offline-fixture")
                self.assertEqual(os.environ.get("DOCKER_IMAGE_GC_DRY_RUN"), "0")
                if raises: raise RuntimeError("fixture main failure")
                return 0
            gc = types.SimpleNamespace(main=main, STOP=mock.Mock(), deploy_locks=mock.Mock(),
                                       __ops327_fixture_guard__=types.SimpleNamespace(violations=[]))
            with mock.patch.object(self.runner, "prepare_worker", return_value=(gc, self.data["events"])):
                if raises:
                    with self.assertRaisesRegex(RuntimeError, "fixture main failure"):
                        in_process_worker(self.runner, self.manifest)
                else:
                    self.assertEqual(in_process_worker(self.runner, self.manifest), 0)
            # Avoid including environment values in any failure transcript.
            self.assertTrue(dict(os.environ) == previous_env, "worker leaked environment state")
            self.assertEqual({sig: signal.getsignal(sig) for sig in previous_handlers}, previous_handlers)
            Path(self.data["events"]).unlink(missing_ok=True)

    def test_each_worker_guard_removed_is_killed(self):
        guards = [
            ('set(data) != {"source", "paths", "events", "constants"}', 'False', 'top extra'),
            ('    h.check_path_contract(source, paths)\n', '', 'extra path'),
            ('if value != {"PROC": "/proc", "PROC_LOCKS": "/proc/locks"}[key]:', 'if False:', 'PROC'),
            ('not isinstance(value, (tuple, list)) or len(value) != 3', 'False', 'lock tuple []'),
            ('not isinstance(constants, dict) or not set(constants) <= {"RUN_BUDGET_S"}', 'False', 'constant BATCH_S'),
            ('type(value) is not int', 'False', 'budget type True'),
            ('not 1 <= value <= 3000', 'False', 'budget bound 0'),
            ('checked[key] = repo_path(value)', 'checked[key] = value', 'KEEP_DIR'),
            ('tuple(repo_path(path) for path in value)', 'tuple(value)', 'LOCK_PATHS'),
        ]
        with tempfile.TemporaryDirectory(prefix="ops327-escape-") as outside:
            cases = {label: (data, reason) for label, data, reason in self.invalid_manifests(outside)}
            for before, after, label in guards:
                runner = SocketIsolationTests.helper("docker-image-gc-realtime", [(before, after)])
                data, reason = cases[label]
                with self.assertRaises(AssertionError, msg=f"worker guard survived: {before}"):
                    if "h.check_path_contract" in before:
                        # load() now independently enforces the same contract.
                        # Exercise this barrier directly so its own removal is
                        # caught even when the deeper defense still rejects it.
                        with self.assertRaisesRegex(ValueError, "path keys"):
                            runner.checked_paths(self.source.read_text(), data["paths"])
                    else:
                        self.rejection(runner, data, reason)
                Path(self.data["events"]).unlink(missing_ok=True)
                print(f"ok worker guard mutant: {before.strip()}", file=sys.stderr)
        for before, after in [
            ('if checked_paths(source, actual) != paths:', 'if False:'),
            ('    h.check_socket(gc.SOCKET_PATH)\n', ''),
        ]:
            runner = SocketIsolationTests.helper("docker-image-gc-realtime", [(before, after)])
            def check():
                if "checked_paths" in before:
                    original = runner.h.load
                    def tamper(source, paths):
                        module = original(source, paths)
                        module.KEEP_DIR = str(self.root / "other-keep")
                        return module
                    with mock.patch.object(runner.h, "load", side_effect=tamper):
                        self.rejection(runner, self.data, "loaded path constants")
                else:
                    self.manifest.write_text(json.dumps(self.data))
                    with mock.patch.object(runner.h, "check_socket") as guard:
                        runner.prepare_worker(str(self.manifest))
                    self.assertEqual(guard.call_count, 2)
            with self.assertRaises(AssertionError): check()
            Path(self.data["events"]).unlink(missing_ok=True)
            print(f"ok worker guard mutant: {before.strip()}", file=sys.stderr)


class RealtimeRunnerTests(unittest.TestCase):
    def setUp(self):
        self.runner = SocketIsolationTests.helper("docker-image-gc-realtime")

    def test_table_must_be_valid_even_for_list(self):
        for table in ({"unknown-mutant": ["r29"]}, {"BATCH_S 60": ["typo"]}, {"BATCH_S 60": []}):
            output = io.StringIO()
            with self.subTest(table=table), mock.patch.dict(self.runner.REAL_MUTANTS, table, clear=True), \
                 mock.patch.object(sys, "argv", ["realtime", "--list"]), redirect_stdout(output):
                self.assertEqual(self.runner.main(), 1)
            self.assertIn("FAIL mutant table:", output.getvalue())

    def test_classification_requires_behavior_and_passing_baseline(self):
        r = self.runner
        for error, baseline, setup, passed in (
            (KeyError("typo"), True, False, False), (AssertionError("setup"), True, True, False),
            (OSError("AF_UNIX path too long"), True, False, False),
            (r.CaseFailure("observed bound"), True, False, True),
            (r.CaseFailure("observed bound"), False, False, False), (None, True, False, False),
        ):
            result, message = r.classify_case("case", "mutant", baseline, error, setup=setup)
            self.assertEqual(result, passed, message)
            if error and not isinstance(error, r.CaseFailure): self.assertIn("(setup:", message)

    def report_outcomes(self, contents, *, returncode=2, expected=2, timeout=False, killed=False):
        """Exercise both real consumer paths, including their classifier input."""
        r = self.runner
        with tempfile.TemporaryDirectory(prefix="ops327-report-") as tmp:
            path = Path(tmp) / "events.json"
            if contents is not None:
                path.write_text(contents)
            process = mock.Mock(events=path, returncode=returncode, fixture_killed=killed)
            process.poll.return_value = returncode
            # Summary cleanliness alone is no longer a certificate. Supply an
            # independent already-reaped/EOF journal for legacy rc controls.
            channel = object.__new__(r.WorkerEvidence)
            channel.identity = dict(worker="legacy-control", token="owned", source="s", manifest="m")
            channel.state = r.EvidenceState(channel.identity, 1234)
            for kind, fields in (("START", {}), ("READY", {}),
                                 ("END", dict(rc=max(returncode, 0), violations=[], setup_error=None))):
                channel.state.accept(dict(identity=channel.identity, pid=1234, seq=len(channel.state.records)+1, kind=kind, **fields))
            channel.thread = mock.Mock()
            channel.thread.is_alive.return_value = False
            channel.eof = threading.Event(); channel.eof.set()
            channel.lock = threading.RLock(); channel.errors = []; channel.stop = None
            process.evidence = channel
            if contents is not None:
                try: data = json.loads(contents)
                except ValueError: data = None
                if isinstance(data, dict) and data.get("violations") == []:
                    data.update(identity=channel.identity, pid=1234, last_seq=3, rc=returncode)
                    path.write_text(json.dumps(data))
            process.communicate.side_effect = ([subprocess.TimeoutExpired("worker", 1), ("", "")]
                                               if timeout else None)
            process.communicate.return_value = ("", "")
            lane = types.SimpleNamespace(processes=[process])
            for consumer in (lambda: r.Lane.finish(lane, process, expected=expected),
                             lambda: r.Lane.check_workers(lane)):
                error = None
                try:
                    consumer()
                except Exception as exc:
                    error = exc
                yield error

    def test_worker_violations_never_kill(self):
        records = [{"event": "metadata.stat", "path": "/outside/switch.lock"}]
        for timeout, killed, rc in ((False, False, 2), (True, False, 2), (False, True, -9)):
            for error in self.report_outcomes(json.dumps({"violations": records}),
                                              timeout=timeout, killed=killed, returncode=rc):
                self.assertIsInstance(error, RuntimeError)
                self.assertIn("metadata.stat: /outside/switch.lock", str(error))
                for mutant in (None, "guard-aborted worker"):
                    passed, message = self.runner.classify_case("r29", mutant, True, error)
                    self.assertFalse(passed, message)
                    self.assertIn("(setup:", message)

    def test_missing_or_unreadable_violations_is_setup_failure(self):
        for contents in (None, "", "not JSON", "{}", "[]", "null", '{"violations":null}',
                         '{"violations":{}}', '{"violations":[{}]}', '{"violations":["open"]}'):
            with self.subTest(contents=contents):
                for error in self.report_outcomes(contents):
                    self.assertIsInstance(error, RuntimeError)
                    for mutant in (None, "missing worker report"):
                        passed, message = self.runner.classify_case("r29", mutant, True, error)
                        self.assertFalse(passed, message)
                        self.assertIn("(setup:", message)

    def test_clean_violations_preserves_normal_classification(self):
        r = self.runner
        for error in self.report_outcomes('{"violations":[]}', returncode=0, expected=0):
            self.assertIsNone(error)
            self.assertTrue(r.classify_case("r29", None, False, error)[0])
            self.assertFalse(r.classify_case("r29", "survives", True, error)[0])
        finish_error, check_error = list(self.report_outcomes('{"violations":[]}', returncode=2, expected=0))
        self.assertIsInstance(finish_error, r.CaseFailure)
        self.assertIsNone(check_error)
        self.assertTrue(r.classify_case("r29", "behavior changed", True, finish_error)[0])

    def test_ignored_worker_violations_mutant_is_killed(self):
        probe = type(self)("test_worker_violations_never_kill")
        probe.runner = SocketIsolationTests.helper("docker-image-gc-realtime", [('    if violations:\n', '    if False:\n')])
        probe.setUp = lambda: None
        result = unittest.TestResult()
        probe.run(result)
        self.assertFalse(result.errors, result.errors)
        self.assertEqual(len(result.failures), 1, "ignored real-time violations mutant survived")
        print("ok real-time mutant: ignore violations: test_worker_violations_never_kill", file=sys.stderr)

    def test_cleanup_guard_failure_overrides_case_and_diagnostic_kill(self):
        r = self.runner
        check_workers = r.Lane.check_workers
        name, probe = "maximal-hold-r34", "BatchOver sleeps 5 s"
        for mutant in ("mutant", probe):
            with tempfile.TemporaryDirectory(prefix="ops327-report-") as tmp:
                path = Path(tmp) / "events.json"
                process = types.SimpleNamespace(events=path, poll=lambda: 2, returncode=2, fixture_killed=False)
                def lane(args, directory, source):
                    def close():
                        # Simulate a guard failure completing during cleanup,
                        # after run_checks' initial check of the clean report.
                        if source == "changed":
                            path.write_text(json.dumps({"violations": [{"event": "open", "path": "/outside"}]}))
                    path.write_text('{"violations":[]}')
                    result = types.SimpleNamespace(source=source, processes=[process], close=close, finalize_evidence=lambda: None)
                    result.check_workers = lambda: check_workers(result)
                    return result
                def case(lane):
                    if lane.source == "changed":
                        raise r.CaseFailure("no destructive call")
                output = io.StringIO()
                with mock.patch.dict(r.CASES, {name: case}), mock.patch.object(r, "Lane", side_effect=lane), \
                     redirect_stdout(output):
                    self.assertEqual(r.run_checks(None, [(name, None, "base"), (name, mutant, "changed")]), 1)
                self.assertIn("FAIL " + name + " [mutant: " + mutant + "] (setup:", output.getvalue())
                self.assertNotIn("KILLED probe", output.getvalue())

    def test_worker_start_failure_overrides_case_watchdog(self):
        r = self.runner
        check_workers = r.Lane.check_workers
        proc = types.SimpleNamespace(events=Path("/never-created-ops327-events"), poll=lambda: 2,
                                     returncode=2, communicate=lambda: ("", "invalid worker manifest"))
        lane = types.SimpleNamespace(processes=[proc])
        with self.assertRaisesRegex(RuntimeError, "worker startup failed"):
            check_workers(lane)
        lane.check_workers = lambda: check_workers(lane)
        lane.close = lambda: None
        lane.finalize_evidence = lambda: None
        def case(_): raise r.CaseFailure("watchdog")
        checks = [("r29", None, "baseline"), ("r29", "mutant", "changed")]
        output = io.StringIO()
        with mock.patch.dict(r.CASES, {"r29": case}), mock.patch.object(r, "Lane", return_value=lane), redirect_stdout(output):
            self.assertEqual(r.run_checks(None, checks), 1)
        self.assertEqual(output.getvalue().count("(setup: worker startup failed"), 2)

    def test_engine_timing_fixture_is_not_deadline_aligned(self):
        h = self.runner.h
        for phase, waits in (("stream", [9, 9, 9, 600]), ("body", [18, 27])):
            server = types.SimpleNamespace(scale=1, phase=phase, calls=[], destructive=[], on_request=None,
                                           stop=mock.Mock(), sent=mock.Mock())
            server.stop.wait.return_value = False
            conn = mock.MagicMock()
            conn.__enter__.return_value = conn
            conn.recv.return_value = b"DELETE /images/test HTTP/1.1\r\n\r\n"
            h.Engine.answer(server, conn)
            self.assertEqual(server.stop.wait.call_args_list, [mock.call(value) for value in waits])
            self.assertEqual(len(server.destructive), 1)
            if phase == "stream": self.assertEqual(conn.sendall.call_count, 4)

    def test_run_checks_tracks_actual_baselines_and_setup(self):
        r = self.runner
        checks = [("r29", None, "baseline"), ("r29", "mutant", "changed")]
        for baseline_fails, setup_fails, rc in ((False, False, 0), (True, False, 1), (False, True, 1)):
            def case(lane):
                if lane.source == "changed" or baseline_fails: raise r.CaseFailure("bound")
            def lane(args, name, source):
                if setup_fails and source == "changed": raise AssertionError("existing directory")
                return types.SimpleNamespace(source=source, close=lambda: None, check_workers=lambda: None, finalize_evidence=lambda: None)
            with mock.patch.dict(r.CASES, {"r29": case}), mock.patch.object(r, "Lane", side_effect=lane), redirect_stdout(io.StringIO()):
                self.assertEqual(r.run_checks(None, checks), rc)

    def test_diagnostic_probe_reports_survival_without_hiding_setup_errors(self):
        r = self.runner
        checks = [("maximal-hold-r34", None, "baseline"),
                  ("maximal-hold-r34", "BatchOver sleeps 5 s", "changed")]
        for error, expected, label in ((None, 0, "SURVIVED probe"), (r.CaseFailure("bound"), 0, "KILLED probe"),
                                       (KeyError("setup typo"), 1, "(setup:")):
            def case(lane):
                if lane.source == "changed" and error: raise error
            def lane(args, name, source):
                return types.SimpleNamespace(source=source, close=lambda: None, check_workers=lambda: None, finalize_evidence=lambda: None)
            output = io.StringIO()
            with mock.patch.dict(r.CASES, {"maximal-hold-r34": case}), \
                 mock.patch.object(r, "Lane", side_effect=lane), redirect_stdout(output):
                self.assertEqual(r.run_checks(None, checks), expected)
            self.assertIn(label, output.getvalue())

    def test_socket_inventory_and_byte_preflight(self):
        source = (REPO / "tests/docker-image-gc-realtime.py").read_text()
        tree = ast.parse(source)
        sites = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in ("bind", "Engine"):
                sites.append(ast.unparse(node))
            if isinstance(node, (ast.Assign, ast.AnnAssign)):
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                for target in targets:
                    if isinstance(target, ast.Subscript) and ast.unparse(target).endswith("['SOCKET_PATH']"):
                        sites.append(ast.unparse(node))
        self.assertEqual(sorted(sites), sorted([
            "h.Engine(self.paths['SOCKET_PATH'], self.images, self.containers, **kw)",
            "server.bind(lane.paths['SOCKET_PATH'])",
            "lane.paths['SOCKET_PATH'] = str(lane.root / f'engine-{n}.sock')",
        ]))
        checks = [("r29", None, ""), ("four-acquisitions", "hold above 45 s", "")]
        args = types.SimpleNamespace(root="/a", engine_socket="/e/engine.sock")
        self.assertIn("/a/001-four-acquisitions/engine-4.sock", list(self.runner.socket_paths(args, checks)))
        self.assertTrue(self.runner.preflight_sockets(args, checks))
        for attr in ("root", "engine_socket"):
            long = types.SimpleNamespace(**vars(args))
            setattr(long, attr, "/" + "é" * 55 + ("/engine.sock" if attr == "engine_socket" else ""))
            output = io.StringIO()
            with redirect_stdout(output): self.assertFalse(self.runner.preflight_sockets(long, checks))
            self.assertIn("FAIL socket path too long:", output.getvalue())
            self.assertIn("bytes; shorten --root)", output.getvalue())

    def test_long_socket_main_exits_before_creation_or_platform(self):
        root = str(REPO / ("x" * 110))
        argv = ["realtime", "--root", root, "--case", "four-acquisitions", "--mutants"]
        for name in ("compose-lock-dir", "instance-lock", "switch-lock", "keep-dir", "store", "engine-socket"):
            argv += ["--" + name, root + "/" + name]
        with mock.patch.object(sys, "argv", argv), mock.patch.object(self.runner, "Lane") as lane, \
             mock.patch.object(self.runner.subprocess, "run") as run, redirect_stdout(io.StringIO()):
            self.assertEqual(self.runner.main(), 2)
        lane.assert_not_called(); run.assert_not_called()


class RegistryPathTests(unittest.TestCase):
    @staticmethod
    def handler(support, path, method="GET"):
        handler = object.__new__(support.RegistryHandler)
        handler.path, handler.command, handler.headers = path, method, {}
        handler.wfile = io.BytesIO()
        for name in ("send_error", "send_response", "send_header", "end_headers"):
            setattr(handler, name, mock.Mock())
        return handler

    def check_rejection(self, support, path):
        handler = self.handler(support, path)
        with mock.patch.object(support, "record") as record, mock.patch.object(support, "settings", return_value={}) as settings, \
             mock.patch.object(support.http.client, "HTTPConnection", side_effect=AssertionError("rejected path reached upstream")) as connection:
            handler.forward()
        handler.send_error.assert_called_once_with(400, "unsupported registry request path")
        record.assert_called_once_with("registry-rejected", method="GET", path=path)
        settings.assert_not_called()
        connection.assert_not_called()

    def test_rejects_non_registry_paths_without_forwarding(self):
        support = SocketIsolationTests.helper("docker-image-gc-vm-support")
        for path in ("/", "http://example.invalid/v2/", "//example.invalid/v2/", "/v2/../manifests/r8",
                     "/v2/_catalog", "/v2/fixture/tags/list", "/v2/fixture/blobs/uploads/",
                     "/v2/fixture/manifests/", "/v2/fixture/manifests/r8?x=1",
                     "/v2/fixture/manifests/r8#fragment", "/v2/fixture/manifests/r8/extra",
                     "/v2/%2e%2e/manifests/r8", "/v2/fixture/manifests/\u0661", "/v2/fixture/manifests/r8\n",
                     "/v2/fixture/blobs/sha256:" + "0" * 63, "/v2/fixture/blobs/sha256:" + "0" * 65,
                     "/v2/" + "a" * 65 + "/manifests/r8", "/v2/fixture/manifests/" + "r" * 129,
                     "/v2/" + "a/" * 5 + "manifests/r8", "/v2/fixture/blobs/sha256:" + "A" * 64):
            with self.subTest(path=path):
                self.check_rejection(support, path)

    def test_discovery_blob_and_undelayed_manifests_are_forwarded_unchanged(self):
        support = SocketIsolationTests.helper("docker-image-gc-vm-support")
        cases = (("/v2/", 10), ("/v2/fixture/blobs/" + dg(0), 10),
                 ("/v2/fixture/manifests/" + dg(0), 10),
                 ("/v2/fixture/manifests/r8", None), ("/v2/team/fixture/manifests/r2", 0))
        for path, delay in cases:
            for method in ("GET", "HEAD"):
                with self.subTest(path=path, method=method, delay=delay), tempfile.TemporaryDirectory() as tmp:
                    cfg = {"epoch": "unit"}
                    if delay is not None: cfg["pull_delay"] = delay
                    handler = self.handler(support, path, method)
                    handler.headers = {"X-Fixture": "unit"}
                    response = mock.Mock(status=200)
                    response.read.return_value = b"" if method == "HEAD" else b"0123456789"
                    response.getheaders.return_value = [("Content-Type", "fixture"), ("Content-Length", "10")]
                    with mock.patch.object(support, "ROOT", Path(tmp)), mock.patch.object(support, "settings", return_value=cfg), \
                         mock.patch.object(support, "record") as record, mock.patch.object(support.time, "sleep") as sleep, \
                         mock.patch.object(support.http.client, "HTTPConnection") as connection:
                        connection.return_value.getresponse.return_value = response
                        handler.forward()
                    handler.send_error.assert_not_called()
                    handler.send_response.assert_called_once_with(200)
                    self.assertEqual(handler.send_header.call_args_list,
                                     [mock.call("Content-Type", "fixture"), mock.call("Content-Length", "10")])
                    handler.end_headers.assert_called_once_with()
                    connection.assert_called_once_with("127.0.0.1", 5000, timeout=650)
                    connection.return_value.request.assert_called_once_with(method, path, headers={"X-Fixture": "unit"})
                    connection.return_value.close.assert_called_once_with()
                    sleep.assert_not_called()
                    record.assert_not_called()
                    self.assertEqual(handler.wfile.getvalue(), b"" if method == "HEAD" else b"0123456789")
                    self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_manifest_variant_is_persisted_and_only_first_digest_get_is_paced(self):
        support = SocketIsolationTests.helper("docker-image-gc-vm-support")
        media_types = ("application/vnd.docker.distribution.manifest.v2+json",
                       "application/vnd.oci.image.manifest.v1+json; charset=utf-8")
        tag = "/v2/team/fixture/manifests/r8"
        manifest = {"schemaVersion": 2, "config": {"digest": dg(1), "size": 2},
                    "layers": [], "annotations": {"fixture": "preserved"}}
        for media_type in media_types:
            for first_method in ("HEAD", "GET"):
                for delay, slices in ((10, 2), (12, 3)):
                    with self.subTest(media_type=media_type, first_method=first_method, delay=delay), \
                         tempfile.TemporaryDirectory() as tmp:
                        root = Path(tmp) / "registry"
                        cfg = {"pull_delay": delay, "epoch": "unit", "pull_index": 3}
                        upstream_body = json.dumps({**manifest, "mediaType": media_type.split(";", 1)[0]}, indent=2).encode()
                        response = mock.Mock(status=200)
                        response.read.return_value = upstream_body
                        response.getheaders.return_value = [("Content-Type", media_type),
                                                            ("Content-Length", str(len(upstream_body)))]
                        with mock.patch.object(support, "ROOT", root), mock.patch.object(support, "settings", return_value=cfg), \
                             mock.patch.object(support, "record") as record, mock.patch.object(support.time, "sleep") as sleep, \
                             mock.patch.object(support.http.client, "HTTPConnection") as connection:
                            connection.return_value.getresponse.return_value = response
                            first = self.handler(support, tag, first_method)
                            first.forward()
                            marker = root / "registry-delay-unit-3"
                            state = json.loads(marker.read_text())
                            body, digest = state["body"].encode(), state["digest"]
                            self.assertEqual(state, {"path": tag, "body": body.decode(), "content_type": media_type,
                                                     "digest": digest, "used": False})
                            self.assertEqual(digest, "sha256:" + hashlib.sha256(body).hexdigest())
                            self.assertNotEqual(body, upstream_body)
                            self.assertEqual(json.loads(body), {**json.loads(upstream_body),
                                             "annotations": {"fixture": "preserved", "ops327.work": '["unit",3]'}})
                            digest_path = tag.rsplit("/", 1)[0] + "/" + digest
                            # Tag GET/HEAD and digest HEAD share the persisted bytes;
                            # none consumes the one delayed digest GET.
                            immediate = [first]
                            for path, method in ((tag, "HEAD"), (tag, "GET"), (digest_path, "HEAD")):
                                handler = self.handler(support, path, method)
                                handler.forward()
                                immediate.append(handler)
                            expected_headers = [mock.call("Content-Type", media_type),
                                                mock.call("Docker-Content-Digest", digest),
                                                mock.call("Docker-Distribution-Api-Version", "registry/2.0"),
                                                mock.call("Content-Length", str(len(body)))]
                            for handler in immediate:
                                handler.send_error.assert_not_called()
                                handler.send_response.assert_called_once_with(200)
                                self.assertEqual(handler.send_header.call_args_list, expected_headers)
                                handler.end_headers.assert_called_once_with()
                                self.assertEqual(handler.wfile.getvalue(), b"" if handler.command == "HEAD" else body)
                            sleep.assert_not_called()
                            record.assert_not_called()
                            self.assertFalse(json.loads(marker.read_text())["used"])

                            delayed = self.handler(support, digest_path)
                            delayed.wfile = mock.Mock(wraps=io.BytesIO())
                            timeline = mock.Mock()
                            timeline.attach_mock(sleep, "sleep")
                            timeline.attach_mock(delayed.wfile.write, "write")
                            timeline.attach_mock(delayed.wfile.flush, "flush")
                            sleep.side_effect = lambda _: delayed.end_headers.assert_called_once_with()
                            delayed.forward()
                            self.assertEqual(delayed.wfile.getvalue(), body)
                            self.assertEqual(delayed.send_header.call_args_list, expected_headers)
                            delayed.send_response.assert_called_once_with(200)
                            delayed.send_error.assert_not_called()
                            self.assertEqual(sleep.call_args_list, [mock.call(delay / slices)] * slices)
                            self.assertEqual(sum(call.args[0] for call in sleep.call_args_list), delay)
                            chunks = [call.args[0] for call in delayed.wfile.write.call_args_list]
                            self.assertEqual(len(chunks), slices)
                            self.assertTrue(all(chunks))
                            self.assertEqual(b"".join(chunks), body)
                            self.assertEqual(timeline.mock_calls, [call for chunk in chunks for call in (
                                mock.call.sleep(delay / slices), mock.call.write(chunk), mock.call.flush())])
                            record.assert_called_once_with("registry-wait", epoch="unit", pull_index=3)
                            self.assertEqual(json.loads(marker.read_text()), {**state, "used": True})

                            sleep.reset_mock(side_effect=True)
                            retry = self.handler(support, digest_path)
                            retry.forward()
                            self.assertEqual(retry.wfile.getvalue(), body)
                            self.assertEqual(retry.send_header.call_args_list, expected_headers)
                            sleep.assert_not_called()
                            record.assert_called_once_with("registry-wait", epoch="unit", pull_index=3)
                            self.assertEqual(json.loads(marker.read_text()), {**state, "used": True})
                            self.assertEqual(list(root.iterdir()), [marker])
                            connection.assert_called_once_with("127.0.0.1", 5000, timeout=650)
                            connection.return_value.request.assert_called_once_with("GET", tag, headers={})
                            connection.return_value.close.assert_called_once_with()

    def test_manifest_variant_digest_changes_with_epoch_or_pull_index(self):
        support = SocketIsolationTests.helper("docker-image-gc-vm-support")
        tag = "/v2/fixture/manifests/r8"
        with tempfile.TemporaryDirectory() as tmp:
            response = mock.Mock(status=200)
            response.read.return_value = b'{"schemaVersion":2,"config":{"digest":"unchanged"},"layers":[]}'
            response.getheaders.return_value = [("Content-Type", "application/vnd.oci.image.manifest.v1+json")]
            with mock.patch.object(support, "ROOT", Path(tmp)), mock.patch.object(support, "settings") as settings, \
                 mock.patch.object(support, "record") as record, mock.patch.object(support.time, "sleep") as sleep, \
                 mock.patch.object(support.http.client, "HTTPConnection") as connection:
                connection.return_value.getresponse.return_value = response
                digests = []
                for epoch, index in (("one", 0), ("two", 0), ("two", 1)):
                    settings.return_value = {"epoch": epoch, "pull_index": index, "pull_delay": 10}
                    handler = self.handler(support, tag, "HEAD")
                    handler.forward()
                    state = json.loads((Path(tmp) / f"registry-delay-{epoch}-{index}").read_text())
                    digests.append(state["digest"])
                    self.assertEqual(state["digest"], "sha256:" + hashlib.sha256(state["body"].encode()).hexdigest())
                    self.assertIn(mock.call("Docker-Content-Digest", state["digest"]), handler.send_header.call_args_list)
                    self.assertEqual(json.loads(state["body"]), {**json.loads(response.read.return_value),
                                     "annotations": {"ops327.work": json.dumps([epoch, index], separators=(",", ":"))}})
                self.assertEqual(len(set(digests)), 3)
                self.assertEqual(len(list(Path(tmp).iterdir())), 3)
                self.assertEqual(connection.call_count, 3)
                sleep.assert_not_called()
                record.assert_not_called()

    def test_manifest_variant_rejects_unsupported_upstream_media_type(self):
        support = SocketIsolationTests.helper("docker-image-gc-vm-support")
        for media_type in ("fixture", "application/vnd.oci.image.index.v1+json"):
            with self.subTest(media_type=media_type), tempfile.TemporaryDirectory() as tmp:
                handler = self.handler(support, "/v2/fixture/manifests/r8", "HEAD")
                response = mock.Mock(status=200)
                response.read.return_value = b'{"schemaVersion":2}'
                response.getheaders.return_value = [("Content-Type", media_type)]
                with mock.patch.object(support, "ROOT", Path(tmp)), \
                     mock.patch.object(support, "settings", return_value={"epoch": "unit", "pull_delay": 10}), \
                     mock.patch.object(support, "record") as record, mock.patch.object(support.time, "sleep") as sleep, \
                     mock.patch.object(support.http.client, "HTTPConnection") as connection:
                    connection.return_value.getresponse.return_value = response
                    with self.assertRaisesRegex(AssertionError, "unsupported fixture manifest media type"):
                        handler.forward()
                connection.return_value.request.assert_called_once_with("GET", handler.path, headers={})
                connection.return_value.close.assert_called_once_with()
                handler.send_response.assert_not_called()
                handler.send_header.assert_not_called()
                handler.end_headers.assert_not_called()
                self.assertEqual(handler.wfile.getvalue(), b"")
                sleep.assert_not_called()
                record.assert_not_called()
                self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_skipped_registry_allowlist_is_killed(self):
        support = SocketIsolationTests.helper("docker-image-gc-vm-support", [("        if not re.fullmatch(\n", "        if False and not re.fullmatch(\n")])
        with self.assertRaises(AssertionError):
            self.check_rejection(support, "/v2/fixture/manifests/r8?x=1")
        print("ok mutant: skip registry path allowlist", file=sys.stderr)


class BehavioralResult(unittest.TextTestResult):
    def addFailure(self, test, err):
        trace = err[2]
        while trace:
            if trace.tb_frame.f_code.co_name == "_callTestMethod":
                return super().addFailure(test, err)
            trace = trace.tb_next
        # AssertionError in setUp/tearDown is a fixture error, too.
        self.addError(test, err)


class VMFailureReasonTests(unittest.TestCase):
    def test_outcome_classifier_uses_result_and_real_timeout_messages(self):
        support = SocketIsolationTests.helper("docker-image-gc-vm-support")
        for phase, message in (("start", "start operation timed out. Terminating."),
                               ("stop", "Stopping timed out. Terminating.")):
            for result in ("success", "timeout", "exit-code", "signal", ""):
                with self.subTest(phase=phase, result=result), \
                     mock.patch.object(support, "unit_value", return_value=result), \
                     mock.patch.object(support, "journal_since", return_value=message) as journal:
                    if result in ("success", "timeout"):
                        self.assertEqual(support.require_outcome("fixture", 100, allowed=("success", "timeout"), phase=phase), result)
                        self.assertEqual(journal.call_count, int(result == "timeout"))
                    else:
                        with self.assertRaisesRegex(AssertionError, "unexpected Result"):
                            support.require_outcome("fixture", 100, allowed=("success", "timeout"), phase=phase)
                        journal.assert_not_called()
        for result, log in (("timeout", "stop operation timed out"), ("timeout", "unrelated traceback"),
                            ("exit-code", "Stopping timed out. Terminating.")):
            with mock.patch.object(support, "unit_value", return_value=result), \
                 mock.patch.object(support, "journal_since", return_value=log), self.assertRaises(AssertionError):
                support.require_outcome("fixture", 100, allowed=("success", "timeout"), phase="stop")

    def test_journal_reads_sync_before_unit_scoped_query(self):
        support = SocketIsolationTests.helper("docker-image-gc-vm-support")
        with mock.patch.object(support, "command", return_value=types.SimpleNamespace(stdout="message")) as command:
            self.assertEqual(support.journal_since("fixture", 100), "message")
        self.assertEqual(command.call_args_list, [mock.call("journalctl", "--sync", timeout=10),
                         mock.call("journalctl", "--unit", "fixture", "--since", "@100.000000", "--output=cat", "--no-pager", timeout=10)])

    def test_state_classifier_rejects_unexpected_or_missing_properties(self):
        support = SocketIsolationTests.helper("docker-image-gc-vm-support")
        for active, sub in (("inactive", "dead"), ("failed", "failed"), ("active", "running"), ("", "dead"), ("inactive", "")):
            with mock.patch.object(support, "unit_value", side_effect=[active, sub]):
                if (active, sub) in (("inactive", "dead"), ("failed", "failed")):
                    support.require_state("fixture", ("inactive", "failed"), ("dead", "failed"))
                else:
                    with self.assertRaises(AssertionError):
                        support.require_state("fixture", ("inactive", "failed"), ("dead", "failed"))

    def test_start_limit_requires_its_own_result(self):
        support = SocketIsolationTests.helper("docker-image-gc-vm-support")
        for result in ("start-limit-hit", "exit-code", "timeout"):
            with mock.patch.object(support, "command", return_value=types.SimpleNamespace(stdout=result)):
                if result == "start-limit-hit": support.require_start_limit()
                else:
                    with self.assertRaisesRegex(AssertionError, "unexpected start-limit failure"):
                        support.require_start_limit()

    def test_registry_rejection_assertion_at_end(self):
        support = SocketIsolationTests.helper("docker-image-gc-vm-support")
        with mock.patch.object(support, "events", return_value=[]): support.assert_no_registry_rejections()
        with mock.patch.object(support, "events", return_value=[{"event": "registry-rejected", "path": "/v3/"}]):
            with self.assertRaisesRegex(AssertionError, "registry-rejected"): support.assert_no_registry_rejections()
        tree = ast.parse((REPO / "tests/docker-image-gc-vm-support.py").read_text())
        checks = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "checks")
        calls = [ast.unparse(node.value) for node in checks.body if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)]
        self.assertLess(calls.index("full_unit_outcomes(outcomes)"), calls.index("assert_no_registry_rejections()"))

    def test_expected_vm_failure_requires_its_own_reason(self):
        support = SocketIsolationTests.helper("docker-image-gc-vm-support")
        for log in ("unrelated traceback", "compose-csb1.service: start operation timed out. Terminating."):
            with mock.patch.object(support, "unit_value", return_value="timeout"), mock.patch.object(support, "journal_since", return_value=log):
                if "timed out" in log: support.require_timeout("compose-csb1", 100)
                else:
                    with self.assertRaisesRegex(AssertionError, "expected unit timeout"):
                        support.require_timeout("compose-csb1", 100)
        def command(*argv, **kw):
            return types.SimpleNamespace(stdout={"ActiveState": "failed", "Result": "exit-code", "ExecMainStatus": "2"}[argv[-2]])
        with mock.patch.object(support, "command", side_effect=command):
            with mock.patch.object(support, "journal_since", return_value="not answered in 30 s"):
                support.gc_done(since=100)
            with mock.patch.object(support, "journal_since", return_value="unrelated traceback"):
                with self.assertRaisesRegex(AssertionError, "unexpected GC failure"):
                    support.gc_done(since=100)


class MutantTests(unittest.TestCase):
    def test_setup_assertion_and_runtime_error_never_kill(self):
        module = sys.modules[__name__]
        for stage in ("setup", "runtime"):
            class Probe(unittest.TestCase):
                def setUp(self):
                    if OVERRIDE and stage == "setup": raise AssertionError("fixture setup")
                def test_probe(self):
                    if OVERRIDE: raise KeyError("unrelated")
            with mock.patch.object(module, "Probe", Probe, create=True), \
                 mock.patch.dict(MUTANTS, {"probe": (swap(), ["Probe.test_probe"])}, clear=True):
                output = io.StringIO()
                result = unittest.TextTestRunner(stream=output).run(unittest.TestSuite([type(self)("test_every_mutant_is_caught")]))
            self.assertFalse(result.wasSuccessful())
            self.assertIn("setup/runtime error", output.getvalue())

    def test_unknown_test_is_rejected(self):
        # Run the deliberate typo in isolation: a loader placeholder failure
        # must fail the harness itself, rather than count as a mutant kill.
        unknown = "R34DeadlineTests.test_deliberately_unknown"
        with mock.patch.dict(MUTANTS, {"lookup self-check": (swap(), [unknown])}, clear=True):
            suite = unittest.TestSuite([type(self)("test_every_mutant_is_caught")])
            output = io.StringIO()
            result = unittest.TextTestRunner(stream=output, verbosity=0).run(suite)
        self.assertEqual(result.testsRun, 1)
        self.assertFalse(result.wasSuccessful())
        self.assertIn(f"unknown mutant test {unknown!r}", output.getvalue())

    def test_every_mutant_is_caught(self):
        global OVERRIDE
        source = SCRIPT.read_text()
        module = sys.modules[__name__]
        baselines = set()
        for name, (override, tests) in MUTANTS.items():
            with self.subTest(mutant=name):
                for old, _ in getattr(override[1], "pairs", ()):
                    self.assertEqual(source.count(old), 1, f"mutant {name!r} does not apply: {old!r}")
                for test in tests:
                    try:
                        class_name, method_name = test.split(".")
                        test_class = getattr(module, class_name)
                        getattr(test_class, method_name)
                    except (AttributeError, ValueError):
                        self.fail(f"unknown mutant test {test!r}")
                    if test not in baselines:
                        suite = unittest.TestSuite([test_class(method_name)])
                        baseline = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0,
                                                           resultclass=BehavioralResult).run(suite)
                        self.assertTrue(baseline.wasSuccessful() and not baseline.skipped,
                                        f"baseline did not pass: {test}")
                        baselines.add(test)
                    OVERRIDE = override
                    try:
                        suite = unittest.TestSuite([test_class(method_name)])
                        result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0,
                                                         resultclass=BehavioralResult).run(suite)
                    finally:
                        OVERRIDE = None
                    self.assertEqual(result.testsRun, 1, test)
                    self.assertFalse(result.errors, f"mutant {name!r} setup/runtime error: {result.errors}")
                    self.assertFalse(result.skipped, f"mutant {name!r} skipped {test}")
                    self.assertTrue(result.failures, f"mutant {name!r} passed {test}")
                print(f"ok mutant: {name}", file=sys.stderr)


class Isolation9PathTests(unittest.TestCase):
    def setUp(self):
        self.base = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="ops327-r9-", dir=REPO)))
        self.root, self.outside = self.base / "fixture", self.base / "outside"
        self.root.mkdir(); self.outside.mkdir()
        self.guard = HARNESS.FixtureGuard(self.root)

    def denies(self, path, **kw):
        with self.assertRaises(HARNESS.FixtureViolation):
            self.guard.check("probe", path, **kw)

    def test_nixos_etc_hosts_store_chain(self):
        store, etc = self.base / "nix/store", self.base / "etc"
        store.mkdir(parents=True); etc.mkdir()
        (store / "hosts").write_text("owned fixture")
        (etc / "hop").symlink_to(store / "hosts")
        (etc / "hosts").symlink_to("hop")
        self.guard.add_root(store, "R", interpreter=True)
        self.guard.check("probe", store / "hosts")
        self.denies(etc / "hosts")
        # The resolved-only mutant used in r8 admits this exact fixture chain.
        mutant = SocketIsolationTests.helper("docker-image-gc-harness", [
            ('self.inside(lexical, left) and self.inside(resolved, right)', 'self.inside(resolved, right)')])
        guard = mutant.FixtureGuard(self.root, interpreter_roots=(store,))
        guard.check("probe", etc / "hosts")
        self.assertEqual(guard.violations, [])

    def test_profile_alias_store_import(self):
        store = self.base / "nix/store"; store.mkdir(parents=True)
        profile = self.base / "profile"; profile.symlink_to(store, target_is_directory=True)
        guard = HARNESS.FixtureGuard(self.root, interpreter_roots=(profile,))
        for path in (store / "code", profile / "code"):
            guard.check("read", path)
            for kind in "WDSL":
                with self.assertRaises(HARNESS.FixtureViolation): guard.check("write", path, kind=kind)

    def test_fixture_canonical_self_pair_and_all_aliases(self):
        alias = self.base / "alias"; alias.symlink_to(self.root, target_is_directory=True)
        guard = HARNESS.FixtureGuard(alias)
        for spelling in (alias, self.root):
            for kind in "RWDSL":
                guard.check("probe", spelling / "file", kind=kind)
        for left in (str(alias), str(self.root)):
            mutant = HARNESS.FixtureGuard(alias)
            mutant.entries = [e for e in mutant.entries if e[0] != left]
            with self.assertRaises(HARNESS.FixtureViolation): mutant.check("probe", Path(left) / "file")
        self.assertEqual({e[2] for e in guard.entries if "W" in e[2]}, {frozenset("RWDSL")})

    @unittest.skipUnless(sys.platform == "darwin", "native macOS /tmp and /var spellings")
    def test_tmp_var_scoped_alias(self):
        for prefix in ("/tmp", "/var"):
            lexical = prefix + "/ops327-scoped-fixture"
            canonical = os.path.realpath(lexical)
            guard = HARNESS.FixtureGuard(lexical)
            for root in (lexical, canonical):
                for kind in "RWDSL": guard.check("probe", root + "/data", kind=kind)
                with self.assertRaises(HARNESS.FixtureViolation): guard.check("probe", root + "-sibling/data")
            with self.assertRaises(HARNESS.FixtureViolation): guard.check("probe", prefix + "/other/data")

    def test_alias_retarget_rejects(self):
        alias = self.base / "alias"; alias.symlink_to(self.root, target_is_directory=True)
        guard = HARNESS.FixtureGuard(alias)
        guard.check("probe", alias / "file")
        # A retarget inside the old namespace must still invalidate this alias.
        child = self.root / "child"; child.mkdir()
        alias.unlink(); alias.symlink_to(child, target_is_directory=True)
        with self.assertRaises(HARNESS.FixtureViolation): guard.check("probe", alias / "file")
        alias.unlink(); alias.symlink_to(self.outside, target_is_directory=True)
        with self.assertRaises(HARNESS.FixtureViolation): guard.check("probe", alias / "file")

    def test_fixture_sibling(self):
        self.denies(str(self.root) + "-sibling/file")

    def test_raw_symlink_dotdot_resolution(self):
        (self.outside / "sub").mkdir()
        (self.root / "hop").symlink_to(self.outside / "sub", target_is_directory=True)
        self.denies(str(self.root / "hop") + "/../data")

    def test_bytes_pathlike(self):
        for value in (self.root / "file", os.fsencode(self.root / "file")):
            returns_normally(self.guard.check, "probe", value)
        self.denies(os.fsencode(self.outside / "file"))

    def test_invalid_path(self):
        for value in (None, object(), ("tuple",)):
            self.denies(value)

    def test_cwd_dirfd_fd(self):
        fd = os.open(self.root, os.O_RDONLY)
        outside = os.open(self.outside, os.O_RDONLY)
        try:
            self.guard.check("probe", fd)
            self.denies(outside)
            with mock.patch.object(os, "getcwd", return_value=str(self.root)):
                self.guard.check("probe", "file", dir_fd=fd)
                self.denies("file", dir_fd=outside)
            self.denies("file", dir_fd=fd)
            self.denies(-1000)
        finally:
            os.close(fd); os.close(outside)

    def test_symlink_destination_relative_target(self):
        (self.root / "sub").mkdir()
        self.guard.audit("os.symlink", ("../file", str(self.root / "sub/link"), -1))
        with self.assertRaises(HARNESS.FixtureViolation):
            self.guard.audit("os.symlink", ("../../outside/file", str(self.root / "sub/link"), -1))

    def test_two_path_second_operand(self):
        for event in ("os.rename", "os.replace", "os.link"):
            with self.assertRaises(HARNESS.FixtureViolation):
                self.guard.audit(event, (str(self.root / "a"), str(self.outside / "b"), -1, -1))

    def test_audit_event_os_listxattr_none_cwd(self):
        with mock.patch.object(os, "getcwd", return_value=str(self.root)):
            self.guard.audit("os.listxattr", (None,))
        with self.assertRaises(HARNESS.FixtureViolation): self.guard.audit("os.listxattr", (None,))

    def test_audit_event_defaults_and_nonpath_none(self):
        for event in ("os.listdir", "os.scandir", "os.listxattr"):
            with mock.patch.object(os, "getcwd", return_value=str(self.root)):
                self.guard.audit(event, (None,))
                self.guard.audit(event, ())
            with mock.patch.object(os, "getcwd", return_value=str(self.outside)):
                with self.assertRaises(HARNESS.FixtureViolation): self.guard.audit(event, (None,))
                with self.assertRaises(HARNESS.FixtureViolation): self.guard.audit(event, ())
        # None is a non-path for these two events, even at an unadmitted cwd.
        with mock.patch.object(os, "getcwd", return_value=str(self.outside)):
            self.guard.audit("import", ("unresolved_name", None))
        self.guard.audit("ctypes.dlopen", (None,))
        fd = os.open(self.outside, os.O_RDONLY)
        try:
            with mock.patch.object(os, "getcwd", return_value=str(self.root)):
                self.guard.audit("os.fwalk", ())
                with self.assertRaises(HARNESS.FixtureViolation): self.guard.audit("os.fwalk", (".", True, None, False, fd))
        finally: os.close(fd)

    def test_import_shadow(self):
        (self.outside / "fractions.py").write_text('raise AssertionError("shadow")')
        with mock.patch.object(sys, "path", [str(self.outside), *sys.path]):
            saved = {name: sys.modules.pop(name) for name in ("fractions", "decimal", "_decimal") if name in sys.modules}
            try:
                module = HARNESS.execute_source("import fractions\nvalue=fractions.Fraction(1,2)", self.root)
                self.assertEqual(module.value.numerator, 1)
            finally:
                for name in ("fractions", "decimal", "_decimal"): sys.modules.pop(name, None)
                sys.modules.update(saved)
        fake = types.ModuleType("fractions")
        fake.__spec__ = importlib.util.spec_from_file_location("fractions", self.outside / "fractions.py")
        with mock.patch.dict(sys.modules, {"fractions": fake}):
            with self.assertRaisesRegex(ValueError, "untrusted cached stdlib"):
                HARNESS.execute_source("import fractions", self.root)

    def test_import_cold_concurrent_fixture(self):
        saved_path = sys.path[:]
        trusted = HARNESS.TrustedImports(self.guard)
        for path in trusted.path: sys.path_importer_cache.pop(path, None)
        saved = {name: sys.modules.pop(name) for name in ("fractions", "decimal", "_decimal") if name in sys.modules}
        entered = threading.Event()
        def fixtures():
            entered.wait(5)
            for n in range(120): (self.outside / str(n)).mkdir()
        thread = threading.Thread(target=fixtures); thread.start()
        try:
            entered.set()
            module = HARNESS.execute_source(SCRIPT.read_text()+"\nimport fractions\n", self.root)
            self.assertEqual(module.fractions.Fraction(1, 2).denominator, 2)
        finally:
            thread.join(5)
            for name in ("fractions", "decimal", "_decimal"): sys.modules.pop(name, None)
            sys.modules.update(saved)
        self.assertEqual(len(list(self.outside.iterdir())), 120)
        self.assertEqual(sys.path, saved_path)

    def test_import_explicit_io_guard(self):
        module = HARNESS.execute_source("import fractions, os\ndef probe(path): return os.listdir(path)", self.root)
        with self.assertRaises(HARNESS.FixtureViolation): module.probe(str(self.outside))
        self.assertEqual(module.probe(str(self.root)), [])

    def test_import_scope_serializes_and_restores(self):
        trusted = HARNESS.TrustedImports(self.guard)
        previous = sys.path[:]
        with trusted.scope():
            with trusted.scope(): self.assertEqual(sys.path, list(trusted.path))
        self.assertEqual(sys.path, previous)
        with self.assertRaises(RuntimeError):
            with trusted.scope(): raise RuntimeError("control")
        self.assertEqual(sys.path, previous)


# Independent audit operands: direct dispatch never performs native side effects.
AUDIT9 = {
    "open": lambda a,b,fd: (b,"r",os.O_RDONLY),
    "sqlite3.connect": lambda a,b,fd: (b,),
    **{name: lambda a,b,fd: (None,b) for name in ("socket.connect","socket.bind","socket.sendto")},
    **{name: lambda a,b,fd: (fd,0,0) for name in ("fcntl.flock","fcntl.lockf","os.lockf","fcntl.fcntl")},
    **{name: lambda a,b,fd: (b,) for name in ("os.listdir","os.scandir","os.truncate","os.chdir","os.walk","os.getxattr","os.listxattr","os.chflags","os.setxattr","os.removexattr","os.startfile","os.startfile/2","os.add_dll_directory")},
    **{name: lambda a,b,fd: (b,-1) for name in ("os.remove","os.unlink","os.rmdir")},
    **{name: lambda a,b,fd: (b,0,-1) for name in ("os.mkdir","os.chmod","os.chown","os.utime")},
    **{name: lambda a,b,fd: (a,b,-1,-1) for name in ("os.rename","os.replace","os.link")},
    "os.symlink": lambda a,b,fd: (a,b,-1),
    "os.fwalk": lambda a,b,fd: (b,True,None,False,None),
    **{name: lambda a,b,fd: (a,b) for name in ("shutil.copyfile","shutil.copymode","shutil.copystat","shutil.move")},
    "shutil.rmtree": lambda a,b,fd: (b,None),
    "shutil.chown": lambda a,b,fd: (b,),
    "shutil.": lambda a,b,fd: (b,),
    "import": lambda a,b,fd: ("probe",b),
    "ctypes.dlopen": lambda a,b,fd: (b,),
    **{name: lambda a,b,fd: (b,) for name in ("subprocess.Popen","os.system","os.exec","os.posix_spawn","os.spawn","os.fork","os.forkpty")},
}


def audit9_test(event):
    def check(self, guard=None):
        guard = guard or self.guard
        fd = os.open(self.outside, os.O_RDONLY)
        try:
            with self.assertRaises(HARNESS.FixtureViolation) as caught:
                guard.audit(event, AUDIT9[event](str(self.root), str(self.outside), fd))
            self.assertEqual(caught.exception.event, event)
            if event.startswith("shutil.") and event != "shutil.": self.assertEqual(caught.exception.path, str(self.outside))
        finally: os.close(fd)
    return check


def audit9_mutant(event):
    def check(self):
        tree = ast.parse((REPO / "tests/docker-image-gc-harness.py").read_text())
        fn = next(n for n in ast.walk(tree) if isinstance(n,ast.FunctionDef) and n.name == "_audit")
        class Omit(ast.NodeTransformer):
            def visit_Constant(self, node):
                if node.value == event: node.value = "omitted.audit.branch"
                return node
        fn = Omit().visit(fn)
        namespace = dict(HARNESS.__dict__)
        exec(compile(ast.fix_missing_locations(ast.Module([fn], [])), "<audit-mutant>", "exec"), namespace)
        guard = HARNESS.FixtureGuard(self.root)
        guard._audit = types.MethodType(namespace["_audit"], guard)
        with self.assertRaises(AssertionError): audit9_test(event)(self,guard)
    return check


for _event in AUDIT9:
    _suffix = _event.replace(".", "_").replace("/", "_").rstrip("_")
    setattr(Isolation9PathTests, "test_audit_event_"+_suffix, audit9_test(_event))
    setattr(Isolation9PathTests, "test_mutant_omit_audit_"+_suffix, audit9_mutant(_event))


class Isolation9BindingTests(unittest.TestCase):
    setUp = Isolation9PathTests.setUp


for _inherited in dir(Isolation9PathTests):
    if _inherited.startswith("test_"): setattr(Isolation9BindingTests, _inherited, None)


def binding9_test(module, name, *, admission=False, mutant=False):
    def check(self):
        if not hasattr(module,name): self.skipTest("native API unavailable on this platform")
        facade = HARNESS.GuardedOS(self.guard, module)
        native = getattr(module,name)
        signature = HARNESS._NATIVE_SIGNATURES[(module is os,name)]
        path_names = {"path","s","filename","f1","f2"}
        values = {p: str(self.root) for p in path_names}
        values.update(flags=os.O_RDONLY,mode=os.F_OK,name="PC_NAME_MAX")
        kwargs = {p.name: values[p.name] for p in signature.parameters.values() if p.default is HARNESS.inspect.Parameter.empty}
        if admission:
            for operand in path_names & kwargs.keys():
                outside = {**kwargs,operand:str(self.outside)}
                with self.assertRaises(HARNESS.FixtureViolation): getattr(facade,name)(**outside)
            return
        sentinel = object()
        # Capture the wrapper before replacing the delegate: delegation is dynamic.
        wrapped = getattr(facade,name)
        for extras in ({}, {p.name:p.default for p in signature.parameters.values() if p.default is not HARNESS.inspect.Parameter.empty}):
            arguments = {**kwargs,**extras}
            with mock.patch.object(module,name,return_value=sentinel) as delegated:
                self.assertIs(wrapped(**arguments),sentinel)
                delegated.assert_called_once_with(**arguments)
        bads=[((),{}),((),{**kwargs,"unexpected_keyword":1}),((str(self.root),),kwargs)]
        bads += [((),{k:v for k,v in kwargs.items() if k!=missing}) for missing in kwargs]
        def error(fn,args,kw):
            try: fn(*args,**kw)
            except TypeError as exc: return str(exc)
            self.fail("native invalid arguments returned")
        for args,kw in bads:
            self.assertEqual(error(wrapped,args,kw),error(native,args,kw))
        if mutant:
            return
        # The named drop-bind mutant is checked by native missing-argument parity.
        helper = SocketIsolationTests.helper("docker-image-gc-harness", [('bound = signature.bind(*args, **kwargs)', 'bound = signature.bind_partial(*args, **kwargs)')])
        broken = getattr(helper.GuardedOS(helper.FixtureGuard(self.root), module),name)
        try: result = error(broken,(),{})
        except (KeyError,TypeError): result = "non-native argument binding"
        self.assertNotEqual(result,error(native,(),{}),"drop_bind_"+name+" survived")
    return check


for _module,_names in ((os,{"open":()} | HARNESS.GuardedOS.OS_METADATA | HARNESS.GuardedOS.OS_WRITES), (os.path,HARNESS.GuardedOS.PATH_METADATA)):
    for _name in _names:
        _label=("os_" if _module is os else "os_path_")+_name
        setattr(Isolation9BindingTests,"test_bind_"+_label,binding9_test(_module,_name))
        setattr(Isolation9BindingTests,"test_admit_"+_label,binding9_test(_module,_name,admission=True))


class Isolation9EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.r = SocketIsolationTests.helper("docker-image-gc-realtime")
        self.identity = dict(worker="worker-1",token="fixture-token",source="s"*64,manifest="m"*64)

    def state(self, phases=("main-entered","destructive-phase"), rc=None):
        state=self.r.EvidenceState(self.identity,1234)
        def send(kind,**kw): state.accept(dict(identity=self.identity,pid=1234,seq=len(state.records)+1,kind=kind,**kw))
        send("START");send("SETUP_BEGIN",id="setup");send("SETUP_END",id="setup");send("READY")
        for phase in phases: send("PHASE",label=phase)
        if rc is not None: send("END",rc=rc,violations=[],setup_error=None)
        return state,send

    def summary(self,state,rc=0):
        return dict(identity=self.identity,pid=1234,last_seq=len(state.records),rc=rc,violations=[],holds=[],attempts=[])

    def certificate(self,required=("main-entered","destructive-phase")):
        return dict(identity=self.identity,case="instance-and-sigkill",site="RT:468",required=list(required))

    def test_natural_exit_requires_end_and_report(self):
        for rc in (0,1,2):
            state,_=self.state(rc=rc);state.validate(rc,self.summary(state,rc),None)
            with self.assertRaises(self.r.EvidenceError): state.validate(rc,None,None)
            state,_=self.state()
            with self.assertRaises(self.r.EvidenceError): state.validate(rc,self.summary(state,rc),None)

    def test_final_summary_agrees(self):
        state,_=self.state(rc=0);summary=self.summary(state)
        for field,value in (("identity",{}),("last_seq",999),("pid",2),("rc",2),("violations",[{}]),("setup_error","failed")):
            with self.subTest(field=field),self.assertRaises(self.r.EvidenceError): state.validate(0,{**summary,field:value},None)

    def test_sigkill_validates_all_existing_end_and_summary_first(self):
        state,_=self.state();state.validate(-9,None,self.certificate())
        for report in ({},[],{"violations":[]},self.summary(state,0),{**self.summary(state,-9),"setup_error":"failure"}):
            with self.assertRaises(self.r.EvidenceError): state.validate(-9,report,self.certificate())
        for rc in (0,1,2):
            ended,send=self.state(rc=rc)
            ended.validate(-9,self.summary(ended,rc),self.certificate())
            with self.assertRaises(self.r.EvidenceError): ended.validate(-9,self.summary(ended,(rc+1)%3),self.certificate())
            with self.assertRaises(self.r.EvidenceError): send("END",rc=rc,violations=[],setup_error=None)
        for fields in ({"rc":-9,"violations":[],"setup_error":None},{"rc":0,"violations":[{}],"setup_error":None},{"rc":0,"violations":[],"setup_error":"bad"}):
            bad,send=self.state()
            with self.assertRaises(self.r.EvidenceError): send("END",**fields)

    def test_start_setup_scope_and_ready_required(self):
        state=self.r.EvidenceState(self.identity,1234)
        with self.assertRaises(self.r.EvidenceError): state.accept(dict(identity=self.identity,pid=1234,seq=1,kind="READY"))
        state,send=self.state();send("SETUP_BEGIN",id="late")
        with self.assertRaises(self.r.EvidenceError): state.validate(-9,None,self.certificate())

    def test_record_identity_sequence_eof(self):
        for field,value in (("identity",{}),("pid",999),("seq",9),("kind","bad")):
            state=self.r.EvidenceState(self.identity,1234)
            record=dict(identity=self.identity,pid=1234,seq=1,kind="START")
            with self.assertRaises(self.r.EvidenceError):state.accept({**record,field:value})

    def test_cleanup_sigkill_pending_denial_never_kills(self):
        for mode in ("pending","deny","setup","runtime","cleanup"):
            state,send=self.state()
            if mode in ("pending","deny"):send("GUARD_BEGIN",id="guard")
            if mode=="deny":send("DENY",event="open",path="/owned-outside")
            if mode in ("setup","runtime"):send("SETUP_ERROR" if mode=="setup" else "RUNTIME_ERROR",error="injected")
            with self.subTest(mode=mode),self.assertRaises(self.r.EvidenceError):state.validate(-9,None,None if mode=="cleanup" else self.certificate())

    def test_lazy_import_setup_error_is_sticky(self):
        records=[]
        publisher=object.__new__(self.r.EvidencePublisher)
        publisher.lock=threading.RLock();publisher.transaction_id=0
        publisher.send=lambda kind,**kw:records.append((kind,kw))
        with tempfile.TemporaryDirectory(dir=REPO) as root:
            module=HARNESS.execute_source("def probe():\n    try:\n        import random\n    except ValueError: return 0\n",root,evidence=publisher)
            records.clear()
            self.assertEqual(module.probe(),0)
        self.assertEqual([kind for kind,_ in records],["SETUP_BEGIN","SETUP_ERROR"])

    def test_evidence_begin_before_normalize(self):
        trace=[]
        class Evidence:
            @contextmanager
            def transaction(self,kind):
                trace.append(kind+"_BEGIN")
                yield
                trace.append("ALLOW")
            def send(self,kind,**kw):trace.append(kind)
        with tempfile.TemporaryDirectory(dir=REPO) as root:
            guard=HARNESS.FixtureGuard(root,evidence=Evidence())
            class Operand:
                def __fspath__(self):
                    trace.append("FSPATH")
                    return root+"/file"
            guard.check("probe",Operand())
            self.assertEqual(trace,["GUARD_BEGIN","FSPATH","ALLOW"])

    def test_violation_ack_before_raise(self):
        trace=[]
        evidence=mock.Mock()
        evidence.transaction.return_value=nullcontext()
        evidence.send.side_effect=lambda *a,**kw:trace.append(a[0])
        with tempfile.TemporaryDirectory(dir=REPO) as root:
            guard=HARNESS.FixtureGuard(root,evidence=evidence)
            try:guard.check("probe","/outside-owned-probe")
            except HARNESS.FixtureViolation:trace.append("RAISE")
        self.assertEqual(trace,["DENY","RAISE"])

    def test_endpoint_plan_all_35_cases(self):
        self.assertEqual(len(self.r.CASES),35)
        self.assertEqual(set(self.r.CASE_ENDPOINTS),set(self.r.CASES))
        self.assertEqual(set(self.r.STOP_PLAN),set(self.r.CASES))
        for case,site in self.r.CASE_ENDPOINTS.items():self.assertIn(site,self.r.STOP_PLAN[case])

    def missing_witness_controls(self,r=None):
        r=r or self.r
        for case,site,role in (("instance-and-sigkill","RT:468","third"),("never-switch-lock","RT:447","proc"),("four-acquisitions","RT:578","proc")):
            required=r.STOP_PLAN[case][site][role]
            for removed in required:
                phases=set(required)-{removed}
                state,_=self.state(phases=phases)
                with tempfile.TemporaryDirectory(dir=REPO) as root:
                    channel=object.__new__(r.WorkerEvidence)
                    channel.identity=self.identity;channel.state=state;channel.errors=[];channel.stop=None;channel.window_started=0.0
                    channel.lock=threading.RLock();channel.case=case;channel.journal=Path(root)/"journal.jsonl"
                    with self.assertRaises(r.EvidenceError, msg=f"{case}: missing {removed}"):channel.arm(site,required)
                    self.assertIsNone(channel.stop)

    def test_stop_requires_parent_observation_window(self):
        state,_=self.state()
        with tempfile.TemporaryDirectory(dir=REPO) as root:
            channel=object.__new__(self.r.WorkerEvidence)
            channel.identity=self.identity;channel.state=state;channel.errors=[];channel.stop=None
            channel.window_started=None;channel.case="instance-and-sigkill"
            channel.lock=threading.RLock();channel.journal=Path(root)/"journal.jsonl"
            with self.assertRaises(self.r.EvidenceError):channel.arm("RT:468",("main-entered","destructive-phase"))
            channel.open_window();channel.arm("RT:468",("main-entered","destructive-phase"))
            self.assertIsNotNone(channel.stop)

    def test_required_witness_removed_before_arm(self):
        self.missing_witness_controls()

    def test_mutant_fallback_witness_is_killed(self):
        r=SocketIsolationTests.helper("docker-image-gc-realtime", [
            ('not set(required) <= self.state.phases', 'not (set(required) & self.state.phases)')])
        with self.assertRaises(AssertionError):self.missing_witness_controls(r)

    def test_instance_third_endpoint_stop(self):
        self.assertEqual(self.r.STOP_PLAN["instance-and-sigkill"]["RT:468"]["third"],("main-entered","destructive-phase"))
        self.assertEqual(self.r.CASE_ENDPOINTS["instance-and-sigkill"],"RT:468")

    def test_live_assertion_stop_447_578(self):
        for case,site in (("never-switch-lock","RT:447"),("four-acquisitions","RT:578")):
            self.assertEqual(self.r.STOP_PLAN[case][site]["proc"],("main-entered","destructive-phase"))

    def test_instance_all_workers_certified(self):
        plan=self.r.STOP_PLAN["instance-and-sigkill"]
        self.assertEqual(set(plan["RT:457"]),{"first","second"})
        self.assertEqual(plan["RT:457"]["second"],("main-entered","instance-attempt"))

    def test_backlog_evidence_protocol_parity(self):
        for site,workers in self.r.STOP_PLAN["full-accept-queue"].items():
            if workers:self.assertIn("connect-start",workers["pid"])
        source=Path(self.r.__file__).read_text()
        self.assertIn('os._exit(worker(manifest, publisher, make_api))',source)

    def test_close_error_still_drains_all(self):
        checked=[]
        lane=object.__new__(self.r.Lane)
        proc=mock.Mock(returncode=0,stdout=None,stderr=None)
        proc.poll.return_value=0
        proc.wait.side_effect=RuntimeError("injected wait error")
        lane.processes=[proc];lane.engines=[mock.Mock()]
        lane.engines[0].close.side_effect=RuntimeError("injected close error")
        lane.check_workers=lambda:checked.append("drained")
        with self.assertRaises(self.r.EvidenceError):lane.close()
        self.assertEqual(checked,["drained"])

    def test_diagnostic_probe_never_overrides_setup(self):
        for mutant in (None,"probe"):
            self.assertFalse(self.r.classify_case("case",mutant,True,self.r.EvidenceError("pending"))[0])

class Isolation9TransportTests(unittest.TestCase):
    setUp = Isolation9EvidenceTests.setUp
    # Actual anonymous-pipe/SIGKILL probes use the implementation's collector.
    PRODUCER = r'''
import importlib.util,json,os,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("transport_rt",sys.argv[1])
r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)
p=r.EvidencePublisher(int(sys.argv[2]),int(sys.argv[3]),json.loads(sys.argv[4]))
mode=sys.argv[5];events=Path(sys.argv[6])
p.send("START")
if mode=="setup":
    p.send("SETUP_BEGIN",id="incomplete")
else:
    p.send("READY");p.send("PHASE",label="main-entered");p.send("PHASE",label="destructive-phase")
    if mode in ("pending","deny"):
        p.send("GUARD_BEGIN",id="incomplete")
        if mode=="deny":p.send("DENY",event="open",path="/fixture-owned-outside")
    elif mode=="runtime":p.send("RUNTIME_ERROR",error="injected")
    elif mode.startswith("end"):
        p.send("END",rc=0,violations=[{}] if mode=="end-violation" else [],setup_error="injected" if mode=="end-setup" else None)
    elif mode=="summary":events.write_text('{"violations":[]}')
    elif mode=="normal":
        r.finish_worker_report(events,{"violations":[],"holds":[],"attempts":[]},p,0)
        p.close();sys.exit(0)
# A harmless blocking syscall: SIGKILL cannot run final reporting.
os.read(int(sys.argv[7]),1)
'''

    def exercise_transport(self,mode,expected):
        r=self.r
        with tempfile.TemporaryDirectory(prefix="ops327-evidence-",dir=REPO) as root:
            root=Path(root);events=root/"events.json"
            channel=r.WorkerEvidence(root,"worker-1","s"*64,"m"*64,"instance-and-sigkill")
            block,release=os.pipe()
            proc=subprocess.Popen([sys.executable,"-B","-c",self.PRODUCER,str(REPO/"tests/docker-image-gc-realtime.py"),
                                   str(channel.send_fd),str(channel.ack_fd),json.dumps(channel.identity),mode,str(events),str(block)],
                                  pass_fds=(channel.send_fd,channel.ack_fd,block),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            proc.events=events;proc.evidence=channel
            channel.attach(proc.pid);os.close(block)
            try:
                if mode=="normal":proc.communicate(timeout=10)
                else:
                    wanted={"setup":"SETUP_BEGIN","pending":"GUARD_BEGIN","deny":"DENY","runtime":"RUNTIME_ERROR"}.get(mode,"END" if mode.startswith("end") else "PHASE")
                    until=time.monotonic()+10
                    while time.monotonic()<until:
                        with channel.lock:
                            seen=channel.state.records and channel.state.records[-1]["kind"]==wanted
                        if seen or channel.errors:break
                        time.sleep(.01)
                    self.assertTrue(seen or channel.errors,"producer never reached barrier")
                    if mode=="hang":
                        channel.open_window();channel.arm("RT:468",("main-entered","destructive-phase"))
                    proc.kill();proc.communicate(timeout=5)
                if expected=="pass":channel.validate(proc)
                else:
                    with self.assertRaises(RuntimeError):channel.validate(proc)
                if channel.journal.exists():
                    records=[json.loads(line) for line in channel.journal.read_text().splitlines()]
                    self.assertEqual(records,channel.state.records)
            finally:
                if proc.poll() is None:proc.kill();proc.communicate(timeout=5)
                os.close(release)
                channel.abort.set();channel.thread.join(2)

    def test_actual_sigkill_evidence_matrix(self):
        for mode in ("normal","hang","pending","deny","setup","runtime","summary","end-violation","end-setup","end-contradictory"):
            with self.subTest(mode=mode):self.exercise_transport(mode,"pass" if mode in ("normal","hang") else "setup")

    def test_parent_rejects_partial_frame_and_held_open_endpoint(self):
        for payload in (b'{"partial":',b'{"identity":{}}\n'):
            with tempfile.TemporaryDirectory(dir=REPO) as root:
                channel=self.r.WorkerEvidence(root,"worker-1","s","m","instance-and-sigkill")
                send,ack=os.dup(channel.send_fd),os.dup(channel.ack_fd)
                channel.attach(os.getpid())
                os.write(send,payload);os.close(send);os.close(ack)
                channel.thread.join(2)
                self.assertTrue(channel.errors)
                self.assertFalse(channel.eof.is_set())
        # A valid reaped worker is insufficient while a duplicate inherited
        # writer prevents EOF. Exercise the real bounded-drain failure too.
        with tempfile.TemporaryDirectory(dir=REPO) as root:
            root=Path(root);channel=self.r.WorkerEvidence(root,"worker-1","s","m","instance-and-sigkill")
            writer,ack=os.dup(channel.send_fd),os.dup(channel.ack_fd)
            channel.attach(os.getpid())
            publisher=self.r.EvidencePublisher(writer,ack,channel.identity)
            publisher.send("START");publisher.send("READY")
            events=root/"events.json"
            self.r.finish_worker_report(events,{"violations":[],"holds":[],"attempts":[]},publisher,0)
            proc=types.SimpleNamespace(events=events,poll=lambda:0,returncode=0)
            try:
                with self.assertRaisesRegex(self.r.EvidenceError,"EOF"):
                    channel.validate(proc)
                self.assertFalse(channel.eof.is_set())
            finally:
                publisher.close();channel.abort.set();channel.thread.join(2)

    def test_actual_registered_worker_natural_exit(self):
        with tempfile.TemporaryDirectory(prefix="ops327-lane-",dir=REPO) as root:
            args=types.SimpleNamespace(root=root,keep_dir=root+"/keep",store=root+"/store",instance_lock=root+"/instance",switch_lock=root+"/switch",compose_lock_dir=root+"/locks",engine_socket=root+"/engine.sock")
            lane=self.r.Lane(args,"000-instance-and-sigkill",SCRIPT.read_text()+"\ndef main(sleep=None): return 0\n")
            try:
                proc=lane.start();events,_=lane.finish(proc,10)
                self.assertEqual(events["rc"],0)
                self.assertTrue(proc.evidence.eof.is_set())
            finally:lane.close()


# Avoid repeating the inherited pure-state matrix in transport discovery.
for _name in dir(Isolation9EvidenceTests):
    if _name.startswith("test_") and _name not in Isolation9TransportTests.__dict__:
        setattr(Isolation9TransportTests,_name,None)


class Isolation9CasePathTests(unittest.TestCase):
    def setUp(self):
        self.r=SocketIsolationTests.helper("docker-image-gc-realtime")
        self.root=Path(self.enterContext(tempfile.TemporaryDirectory(prefix="ops327-case-",dir=REPO)))

    def instance_exclusion(self,mode):
        # Replay the note's source-extracted lock model against exact mutants.
        source=SCRIPT.read_text()
        if mode!="baseline":source=MUTANTS[mode][0][1](source)
        tree=ast.parse(source)
        lock=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=="instance_lock")
        main=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=="main")
        uses=any(isinstance(n,ast.With) and any(isinstance(i.context_expr,ast.Call) and isinstance(i.context_expr.func,ast.Name) and i.context_expr.func.id=="instance_lock" for i in n.items) for n in ast.walk(main))
        owner=[None];serial=[0]
        class Busy(Exception):pass
        def opened(*a):serial[0]+=1;return serial[0]
        def closed(fd):
            if owner[0]==fd:owner[0]=None
        def flock(fd,flags):
            if flags&fcntl.LOCK_UN:
                if owner[0]==fd:owner[0]=None
            else:
                if owner[0] not in (None,fd):raise BlockingIOError()
                owner[0]=fd
        ns=dict(contextmanager=contextmanager,Busy=Busy,INSTANCE_LOCK="owned-lock",os=types.SimpleNamespace(open=opened,close=closed,O_RDONLY=0,O_CREAT=64,O_CLOEXEC=128),fcntl=types.SimpleNamespace(flock=flock,LOCK_EX=fcntl.LOCK_EX,LOCK_NB=fcntl.LOCK_NB,LOCK_UN=fcntl.LOCK_UN))
        exec(compile(ast.Module([lock],[]),"<instance-model>","exec"),ns)
        make=ns["instance_lock"] if uses else nullcontext
        with make():
            try:
                with make():blocked=False
            except Busy:blocked=True
        return blocked, uses

    def case_path(self,case,mode="baseline",fault=None,*,aux_rc=143,close=False):
        r=self.r;root=self.root
        busy, uses_instance = self.instance_exclusion(mode) if case=="instance-and-sigkill" else (True, False)
        class Clock:
            now=0
            def monotonic(self):return self.now
            def sleep(clock,seconds):
                clock.now+=seconds
                for p in lane.processes:
                    if not hasattr(p,"evidence"):continue
                    if p.returncode is None and not p.sent and clock.now>=p.started+45:
                        lane.engine_object.destructive.append(("DELETE","fixture",p.started+45));p.sent=True;p.send("PHASE",label="destructive-phase")
        clock=Clock()
        class Process:
            stdout=stderr=None
            def __init__(p,role):
                p.pid=1234;p.role=role;p.started=clock.now;p.returncode=None;p.sent=False
                identity=dict(worker=role,token=role,source="s",manifest="m")
                channel=object.__new__(r.WorkerEvidence)
                channel.state=r.EvidenceState(identity,1234);channel.identity=identity;channel.errors=[];channel.stop=None;channel.window_started=clock.now;channel.case=case;channel.lock=threading.RLock();channel.journal=root/(role+str(len(lane.processes))+".journal")
                p.evidence=channel
                p.send("START");p.send("READY");p.send("PHASE",label="main-entered")
                # The source model actually executes instance_lock only when
                # main retains its with-statement. A Busy second worker exits
                # before reaching cooldown; bypassing the lock emits no attempt.
                if uses_instance:
                    p.send("PHASE",label="instance-attempt")
                if role != "second" or not busy:
                    p.send("PHASE",label="cooldown")
            def send(p,kind,**kw):p.evidence.state.accept(dict(identity=p.evidence.identity,pid=1234,seq=len(p.evidence.state.records)+1,kind=kind,**kw))
            def poll(p):return p.returncode
            def kill(p):p.returncode=-9
            def wait(p,timeout=5):return p.returncode
            def end(p,rc=0):
                p.returncode=rc;p.send("END",rc=rc,violations=[],setup_error=None)
        class Lane:
            def __init__(lane):lane.processes=[];lane.case=case;lane.stop_plan=r.STOP_PLAN[case];lane.root=root;lane.paths={"SWITCH_LOCK":str(root/"switch"),"LOCK_PATHS":[str(root/"lock")]}
            stop_at=r.Lane.stop_at
            def engine(lane,**kw):
                class Sent:
                    def wait(_,seconds):clock.sleep(max(0,lane.processes[-1].started+45-clock.now));return True
                lane.engine_object=types.SimpleNamespace(sent=Sent(),destructive=[]);return lane.engine_object
            def start(lane,constants=None):
                role=("first","second","third")[len(lane.processes)] if case=="instance-and-sigkill" else "proc"
                p=Process(role);lane.processes.append(p)
                if role=="second" and busy:p.end()
                return p
            def require(lane,site,condition,message="case assertion failed"):
                return r.Lane.require(lane,site,False if fault==site else condition,message)
            def wait_for(lane,site,predicate,seconds,label):
                if label.startswith("acquisition ") and label.endswith(" ready"):
                    n=label.split()[1];(root/"ready").write_text(n);(root/"count").write_text(n)
                elif label.startswith("handler acquisition "):
                    clock.sleep(29);(root/("got-"+label.split()[-1])).write_text(str(clock.now))
                until=clock.now+seconds
                while clock.now<=until:
                    result=predicate()
                    if result:return result
                    clock.sleep(.01)
                lane.stop_at(site);raise r.CaseFailure(label)
            def finish(lane,p,timeout=100,expected=0,*,site=None):
                if p.role=="second" and not busy:
                    clock.sleep(timeout);lane.stop_at(site);raise r.CaseFailure("instance exclusion missing")
                if p.returncode is None:clock.sleep(29);p.end(expected)
                return {"attempts":[],"holds":[(p.started+45,clock.now)]},"another run is in progress" if p.role=="second" else ""
        lane=Lane();aux=types.SimpleNamespace(pid=123,returncode=aux_rc,poll=lambda:aux_rc,
                                            wait=lambda timeout:aux_rc,stdout=None,stderr=None)
        failure=None
        with mock.patch.object(r,"time",clock),mock.patch.object(r,"subprocess",types.SimpleNamespace(Popen=lambda *a,**k:aux,run=lambda *a,**k:types.SimpleNamespace(returncode=0))),mock.patch.object(r.os,"killpg",lambda *a:None),mock.patch.object(r, 'SwitchLockObserver', return_value=types.SimpleNamespace(sample=lambda: [])):
            try:
                if case == 'never-switch-lock': invoke_switch_case(r, lane, r.CASES[case])
                else: r.CASES[case](lane)
            except r.CaseFailure as exc:failure=exc
        for p in lane.processes:
            if not hasattr(p,"evidence"):continue
            if p.returncode is None:p.kill()
            state=p.evidence.state
            summary=dict(identity=p.evidence.identity,pid=1234,last_seq=len(state.records),rc=p.returncode,violations=[]) if p.returncode>=0 else None
            state.validate(p.returncode,summary,p.evidence.stop)
        if close:r.Lane.close(lane)
        return failure

    def test_actual_instance_baseline_and_both_mutant_models(self):
        self.assertIsNone(self.case_path("instance-and-sigkill"))
        for mode,cases in self.r.REAL_MUTANTS.items():
            if "instance-and-sigkill" not in cases:continue
            # Fresh stop journals per modeled run.
            with tempfile.TemporaryDirectory(prefix="ops327-model-",dir=REPO) as root:
                original=self.root;self.root=Path(root)
                try:self.assertIsInstance(self.case_path("instance-and-sigkill",mode),self.r.CaseFailure)
                finally:self.root=original

    def test_actual_live_assertions_447_578(self):
        for case,site in (("never-switch-lock","RT:447"),("four-acquisitions","RT:578")):
            with tempfile.TemporaryDirectory(prefix="ops327-model-",dir=REPO) as root:
                original=self.root;self.root=Path(root)
                try:self.assertIsNone(self.case_path(case))
                finally:self.root=original
            with tempfile.TemporaryDirectory(prefix="ops327-model-",dir=REPO) as root:
                original=self.root;self.root=Path(root)
                try:self.assertIsInstance(self.case_path(case,"injected",site),self.r.CaseFailure)
                finally:self.root=original



def invoke_switch_case(r, lane, case=None):
    """Enter the case's sole guard before even a decorator wrapper executes."""
    with r.SwitchObservationGuard(lane.paths['SWITCH_LOCK']):
        return (r.never_switch_lock if case is None else case)(lane)


def validate_switch_observation_surface(source):
    """Closed observation surface, following every reachable local helper.

    Lane's declared Engine/start/require/finish controls and the runtime audit
    boundary are explicit capabilities. They are not observation helpers.
    Unknown calls (including aliases, computed callees and process execution)
    fail closed. Helpers may use only the same read/parse primitives.
    """
    tree = ast.parse(source)
    functions = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
    observer = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'SwitchLockObserver')
    methods = {n.name: n for n in observer.body if isinstance(n, ast.FunctionDef)}
    # Reviewed data only: callee -> (allowed positional counts, keyword names).
    # In particular, no key/default/cls callbacks or argument unpacking.
    signatures = {
        'Path': ((1,), ()), 'dict': ((0, 1), ('pid', 'relation', 'worker_or_descendant')),
        'int': ((1, 2), ()), 'len': ((1,), ()), 'max': ((1, 2), ()), 'min': ((1, 2), ()),
        'range': ((1, 2, 3), ()), 'set': ((0, 1), ()), 'str': ((1,), ()),
        'EvidenceError': ((1,), ()), 'os.stat': ((1,), ()), 'os.major': ((1,), ()),
        'os.minor': ((1,), ()), 're.fullmatch': ((2,), ()), 'json.dumps': ((1,), ()),
        'time.monotonic': ((0,), ()), 'time.sleep': ((1,), ()),
        'SwitchObservationGuard.active': ((1,), ()),
        'audit.create_fixture': ((0,), ()), 'audit.worker_launch': ((0,), ()),
        'lane.engine': ((0,), ('delay',)), 'lane.start': ((1,), ()),
        'lane.require': ((2, 3), ()), 'lane.finish': ((2,), ('site',)),
        'SwitchLockObserver': ((2,), ()), 'observer.sample': ((0,), ()),
        'engine.sent.wait': ((1,), ()), 'seen.add': ((1,), ()), 'holders.append': ((1,), ()),
        'line.split': ((0,), ()), 'fields.pop': ((1,), ()), 'fields[5].split': ((1,), ()),
        'self.locks_path.read_text': ((0,), ('encoding',)),
        "self.locks_path.read_text(encoding='ascii').splitlines": ((0,), ()),
        "(self.proc_path / str(pid) / 'stat').read_text": ((0,), ()),
        "(self.proc_path / str(pid) / 'stat').read_text().rpartition": ((1,), ()),
        "(self.proc_path / str(pid) / 'stat').read_text().rpartition(')')[2].split": ((0,), ()),
    }
    primitive = {'Path', 'dict', 'int', 'len', 'max', 'min', 'range', 'set', 'str', 'EvidenceError',
                 'os.stat', 'os.major', 'os.minor', 're.fullmatch', 'json.dumps', 'time.monotonic', 'time.sleep'}
    case_calls = {'SwitchObservationGuard.active', 'audit.create_fixture', 'audit.worker_launch',
                  'lane.engine', 'lane.start', 'lane.require', 'lane.finish',
                  'SwitchLockObserver', 'observer.sample', 'engine.sent.wait'}
    reader_calls = {'seen.add', 'holders.append', 'line.split', 'fields.pop', 'fields[5].split',
                    'self.locks_path.read_text', "self.locks_path.read_text(encoding='ascii').splitlines",
                    "(self.proc_path / str(pid) / 'stat').read_text",
                    "(self.proc_path / str(pid) / 'stat').read_text().rpartition",
                    "(self.proc_path / str(pid) / 'stat').read_text().rpartition(')')[2].split"}
    protected = {v.split('.')[0] for v in primitive | case_calls} | set(functions)
    imports = {'os': 'import os', 're': 'import re', 'json': 'import json', 'time': 'import time',
               'Path': 'from pathlib import Path'}
    builtin_bindings = {'dict', 'int', 'len', 'max', 'min', 'range', 'set', 'str'}
    for top in tree.body:
        # A syntactically approved call is resolved only while its module or
        # builtin binding is canonical. Module-level aliases cannot replace it.
        if isinstance(top, (ast.FunctionDef, ast.ClassDef)):
            assert top.name not in imports.keys() | builtin_bindings, 'rebound observation global: ' + top.name
            continue
        for binding in ast.walk(top):
            if isinstance(binding, (ast.Import, ast.ImportFrom)):
                for alias in binding.names:
                    name = alias.asname or alias.name.split('.')[0]
                    if name in imports:
                        assert ast.unparse(binding) == imports[name], 'rebound observation import: ' + name
                    assert name not in protected or name in imports, 'rebound observation import: ' + name
            if isinstance(binding, (ast.Name, ast.Attribute)) and isinstance(binding.ctx, ast.Store):
                root = ast.unparse(binding).split('.')[0]
                assert root not in protected, 'rebound observation global: ' + root
    visited = set()
    function_names = set(functions) | {
        name for name, value in vars(builtins).items() if callable(value)} | {
        'Path', 'EvidenceError', 'SwitchLockObserver'}
    aliases = {}
    for binding in ast.walk(tree):
        if isinstance(binding, (ast.Assign, ast.AnnAssign, ast.NamedExpr)):
            targets = binding.targets if isinstance(binding, ast.Assign) else [binding.target]
            for target in targets:
                if isinstance(target, (ast.Name, ast.Attribute)) and binding.value is not None:
                    aliases.setdefault(ast.unparse(target), []).append(binding.value)
    class_methods = {top.name: {n.name for n in top.body if isinstance(n, ast.FunctionDef)}
                     for top in tree.body if isinstance(top, ast.ClassDef)}
    def function_reference(arg, local_functions, seen=frozenset()):
        if isinstance(arg, ast.Lambda):
            return True
        if isinstance(arg, (ast.Name, ast.Attribute)):
            name = ast.unparse(arg)
            if name not in seen and any(function_reference(value, local_functions, seen | {name}) for value in aliases.get(name, ())):
                return True
        if isinstance(arg, ast.Name):
            return arg.id in function_names | local_functions
        if isinstance(arg, ast.Attribute):
            name = ast.unparse(arg)
            root = name.split('.')[0]
            if name in signatures or (root == 'self' and arg.attr in methods):
                return True
            if root in class_methods and arg.attr in class_methods[root]:
                return True
            value = globals().get(root)
            if isinstance(value, types.ModuleType):
                for part in name.split('.')[1:]:
                    value = getattr(value, part, None)
                return callable(value)
            return False
        return False
    def visit(node, role):
        if id(node) in visited:
            return
        visited.add(id(node))
        local_functions = {n.name for n in ast.walk(node)
                           if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n is not node}
        for child in ast.walk(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                assert not child.decorator_list, 'G.2.1 no decorators: ' + child.name
            if isinstance(child, (ast.Import, ast.ImportFrom, ast.Global, ast.Nonlocal, ast.Lambda)):
                raise AssertionError('unresolved observation binding: ' + ast.unparse(child))
            if isinstance(child, ast.arg) and child.arg in protected and not (role == 'case' and child.arg == 'lane'):
                raise AssertionError('shadowed observation capability: ' + child.arg)
            if isinstance(child, ast.Name) and isinstance(child.ctx, ast.Store) and child.id in protected:
                # These locals are bound only to their declared capabilities.
                if child.id not in ('observer', 'audit', 'engine'):
                    raise AssertionError('rebound observation capability: ' + child.id)
            if isinstance(child, ast.Attribute) and isinstance(child.ctx, ast.Store) and ast.unparse(child).split('.')[0] in protected:
                raise AssertionError('rebound observation attribute: ' + ast.unparse(child))
            if not isinstance(child, ast.Call):
                continue
            call = ast.unparse(child.func)
            assert not any(isinstance(arg, ast.Starred) for arg in child.args) and all(
                kw.arg is not None for kw in child.keywords), 'G.2.2 no argument unpacking: ' + call
            assert not any(function_reference(arg, local_functions) for arg in child.args + [kw.value for kw in child.keywords]), (
                'G.2.2 no function-reference arguments: ' + call)
            if call in primitive or (role == 'case' and call in case_calls) or (role == 'observer' and call in reader_calls):
                counts, keywords = signatures[call]
                assert len(child.args) in counts, 'G.2.2 primitive positional count: ' + call
                assert all(kw.arg in keywords for kw in child.keywords), 'G.2.2 primitive keyword: ' + call
                continue
            if isinstance(child.func, ast.Name) and call in functions:
                visit(functions[call], 'helper')
            elif role == 'observer' and call.startswith('self.') and call[5:] in methods:
                visit(methods[call[5:]], 'observer')
            else:
                raise AssertionError('unresolved or forbidden observation call: ' + call)
    case = functions['never_switch_lock']
    assert not observer.decorator_list, 'G.2.1 no decorators: SwitchLockObserver'
    visit(case, 'case')
    for method in methods.values():
        visit(method, 'observer')
    # The caller owns the sole guard, including decorator execution. The case
    # consumes that active object's capabilities and never enters another guard.
    assert ast.unparse(case.body[0]) == "audit = SwitchObservationGuard.active(lane.paths['SWITCH_LOCK'])", 'G.3.1 active guard'
    assert ast.unparse(case.body[1]) == 'audit.create_fixture()'
    assert ast.unparse(case.body[2]) == 'engine = lane.engine(delay=5)'
    launch = case.body[3]
    assert isinstance(launch, ast.With) and ast.unparse(launch.items[0].context_expr) == 'audit.worker_launch()'
    assert len(launch.body) == 1 and ast.unparse(launch.body[0]) == "proc = lane.start({'RUN_BUDGET_S': 55})"
    assert ast.unparse(case.body[4]) == "observer = SwitchLockObserver(lane.paths['SWITCH_LOCK'], proc.pid)"
    calls = [n for n in ast.walk(case) if isinstance(n, ast.Call)]
    for name in ('SwitchObservationGuard.active', 'audit.create_fixture', 'audit.worker_launch', 'lane.start', 'SwitchLockObserver'):
        assert sum(ast.unparse(n.func) == name for n in calls) == 1, 'repeated fixture/launch capability'
    for name in ('audit', 'engine', 'observer'):
        assert sum(isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store) and n.id == name
                   for n in ast.walk(case)) == 1, 'rebound observation local: ' + name
    for call in calls:
        if ast.unparse(call.func) not in case_calls:
            assert not any(isinstance(arg, ast.Name) and arg.id in ('audit', 'lane', 'observer')
                           for arg in call.args), 'observation capability escaped to a helper'


class Isolation12dRegressionTests(unittest.TestCase):
    setUp = Isolation9CasePathTests.setUp

    def observer(self, *, pid=1234):
        self.assertTrue(hasattr(self.r, 'SwitchLockObserver'), 'missing passive switch-lock observer')
        path = self.root / 'switch'; path.touch(exist_ok=True)
        table = self.root / 'locks'; table.touch(exist_ok=True)
        proc = self.root / 'proc'; proc.mkdir(exist_ok=True)
        return self.r.SwitchLockObserver(path, pid, locks_path=table, proc_path=proc)

    def row(self, pid, *, major=None, minor=None, inode=None, blocked=False):
        info = (self.root / 'switch').stat()
        major = os.major(info.st_dev) if major is None else major
        minor = os.minor(info.st_dev) if minor is None else minor
        inode = info.st_ino if inode is None else inode
        return f'1: {"-> " if blocked else ""}FLOCK ADVISORY WRITE {pid} {major:04X}:{minor:04x}:{inode:012d} 0 EOF\n'

    def test_passive_table_records_worker_descendant_and_other_holders(self):
        observer = self.observer()
        for pid, ppid in ((4321, 2222), (2222, 1234), (9876, 0)):
            path = self.root / 'proc' / str(pid); path.mkdir()
            (path / 'stat').write_text(f'{pid} (name with ) spaces) S {ppid} 0 0\n')
        (self.root / 'locks').write_text(self.row(1234) + self.row(4321, blocked=True) + self.row(9876) + self.row(-1))
        holders = observer.sample()
        self.assertEqual([h['pid'] for h in holders], [1234, 4321, 9876, -1])
        self.assertEqual([h['relation'] for h in holders], ['worker', 'descendant', 'other', 'other'])
        self.assertEqual([h['worker_or_descendant'] for h in holders], [True, True, False, False])
        (self.root / 'locks').write_text(self.row(9999))
        self.assertIsNone(observer.sample()[0]['worker_or_descendant'], 'vanished owner must still be reported')

    def test_passive_table_matches_whole_device_and_decimal_inode(self):
        observer = self.observer(); major, minor, inode = observer.token
        for row in (self.row(1234, major=major + 1), self.row(1234, minor=minor + 1), self.row(1234, inode=inode + 1)):
            (self.root / 'locks').write_text(row)
            self.assertEqual(observer.sample(), [])
        (self.root / 'locks').write_text(self.row(1234))
        self.assertEqual(observer.sample()[0]['pid'], 1234)
        for bad in ('1: FLOCK ADVISORY WRITE 1234 01:02:abcd 0 EOF\n', 'broken row\n'):
            (self.root / 'locks').write_text(bad)
            with self.assertRaises(self.r.EvidenceError): observer.sample()
        (self.root / 'locks').unlink()
        with self.assertRaises(FileNotFoundError): observer.sample()

    def test_production_parser_mutant_cannot_change_observer(self):
        observer = self.observer()
        with mock.patch.dict(globals(), OVERRIDE=('text', MUTANTS['match the inode only'][0][1])):
            gc = load(tmp=self.root)
        (self.root / 'locks').write_text(self.row(1234, major=observer.token[0] + 1))
        gc.SWITCH_LOCK = str(self.root / 'switch'); gc.PROC_LOCKS = str(self.root / 'locks')
        self.assertTrue(gc.switch_lock_used(gc.Budget(10)), 'registered production parser mutant must be active')
        self.assertEqual(observer.sample(), [], 'parent inherited the production parser mutant')
        (self.root / 'locks').write_text(self.row(1234))
        self.assertEqual(observer.sample()[0]['pid'], 1234)

    def test_static_observer_has_no_locking_or_production_dependencies(self):
        # Bind to the loaded code filename, including the old-source replay.
        validate_switch_observation_surface(Path(self.r.never_switch_lock.__code__.co_filename).read_text())

    @staticmethod
    def worker(root, send, ack, identity, mutant, real_proc):
        """Real main/batch in a separate process; only clocks/Engine are injected.

        Darwin has no /proc/locks. The modeled table reflects native successful
        acquisitions of the private inode; Linux's extra test uses real procfs.
        """
        r = SocketIsolationTests.helper('docker-image-gc-realtime')
        publisher = r.EvidencePublisher(send, ack, identity)
        fixture = Base(); fixture.tmp = Path(root)
        transform = MUTANTS['the GC takes the lock'][0][1] if mutant else lambda source: source
        global OVERRIDE
        OVERRIDE = ('text', transform)
        fixture.gc = load(tmp=fixture.tmp); fixture.world(); gc = fixture.gc
        gc.SWITCH_LOCK = str(fixture.tmp / 'switch')
        gc.PROC_LOCKS = '/proc/locks' if real_proc else str(fixture.tmp / 'locks')
        gc.PROC = '/proc' if real_proc else str(fixture.tmp / 'proc')
        clock = Clock(); started = clock.t
        gc.time = types.SimpleNamespace(**(vars(time) | {'monotonic': clock}))
        gc.RUN_BUDGET_S = 55
        durations = iter((2.6, 2.6, 0.2)); snapshot = gc.snapshot
        def delayed_snapshot(api, budget):
            snap = snapshot(api, budget)
            time.sleep(.06)  # allow real 20 ms parent samples during each retry
            clock.advance(next(durations, 0))
            return snap
        gc.snapshot = delayed_snapshot
        original_switch = gc.switch_lock_used
        checks = []
        def checked(budget):
            result = original_switch(budget)
            checks.append(result)
            (fixture.tmp / 'checked').touch()
            return result
        gc.switch_lock_used = checked
        native_flock = fcntl.flock
        switch_info = os.stat(gc.SWITCH_LOCK)
        def tracked_flock(fd, operation):
            native_flock(fd, operation)
            info = os.fstat(fd)
            if (info.st_dev, info.st_ino) == (switch_info.st_dev, switch_info.st_ino):
                r.publish_events(fixture.tmp / 'retained', dict(at=time.monotonic(), virtual_s=clock.t - started))
                if not real_proc:
                    (fixture.tmp / 'locks').write_text(f'1: FLOCK ADVISORY WRITE {os.getpid()} {os.major(info.st_dev):x}:{os.minor(info.st_dev):x}:{info.st_ino} 0 EOF\n')
        gc.fcntl = types.SimpleNamespace(flock=tracked_flock, LOCK_EX=fcntl.LOCK_EX, LOCK_NB=fcntl.LOCK_NB, LOCK_UN=fcntl.LOCK_UN)
        api = fixture.api(); requests = []
        def engine(method, path, **kw):
            if method != 'GET':
                publisher.send('PHASE', label='destructive-phase')
                requests.append((method, clock.t - started))
                (fixture.tmp / 'request').write_text(json.dumps(requests))
                time.sleep(5)  # real post-request observation overlaps this delay
                clock.advance(5)
            return api(method, path, **kw)
        original_main = gc.main
        def main(api, sleep):
            def pause(seconds):
                sleep(0)  # keep the real cooldown witness without a 45 s wall wait
                time.sleep(.06)
                clock.advance(seconds)
            return original_main(api, now=NOW, sleep=pause)
        gc.main = main
        output = io.StringIO()
        publisher.send('START')
        with mock.patch.dict(os.environ, {'INVOCATION_ID': 'ops327-12d', 'DOCKER_IMAGE_GC_DRY_RUN': '0'}), redirect_stdout(output), redirect_stderr(output):
            rc = r.run_worker_main(gc, publisher, engine)
        (fixture.tmp / 'result').write_text(json.dumps(dict(rc=rc, checks=checks, requests=requests, output=output.getvalue())))
        r.finish_worker_report(fixture.tmp / 'events.json', {'violations': gc.__ops327_fixture_guard__.violations}, publisher, rc)
        publisher.close()
        raise SystemExit(rc)

    def process_case(self, *, mutant=False, real_proc=False, post_holder=False):
        r = self.r; root = self.root
        switch = root / 'switch'; switch.touch()
        (root / 'locks').write_text('')
        (root / 'proc' / '9876').mkdir(parents=True)
        (root / 'proc' / '9876' / 'stat').write_text('9876 (unrelated holder) S 0 0 0\n')
        lane = object.__new__(r.Lane)
        lane.root = root; lane.paths = {'SWITCH_LOCK': str(switch)}
        lane.case = 'never-switch-lock'; lane.stop_plan = r.STOP_PLAN[lane.case]
        lane.processes = []; lane.engines = []
        samples, sampler_locks = [], []
        observer_type = getattr(r, 'SwitchLockObserver', None)
        def observer(path, pid):
            item = observer_type(path, pid, locks_path='/proc/locks' if real_proc else root / 'locks',
                                 proc_path='/proc' if real_proc else root / 'proc')
            sample = item.sample
            def record():
                result = sample(); samples.append((time.monotonic(), result)); return result
            item.sample = record
            return item
        def start(constants):
            self.assertEqual(constants, {'RUN_BUDGET_S': 55})
            channel = r.WorkerEvidence(root, 'worker', 's', 'm', lane.case)
            code = 'import sys,json; sys.path.insert(0,sys.argv[1]); import test_docker_image_gc as t; t.Isolation12dRegressionTests.worker(sys.argv[2],int(sys.argv[3]),int(sys.argv[4]),json.loads(sys.argv[5]),sys.argv[6]=="True",sys.argv[7]=="True")'
            proc = subprocess.Popen([sys.executable, '-B', '-c', code, str(REPO / 'tests'), str(root), str(channel.send_fd), str(channel.ack_fd), json.dumps(channel.identity), str(mutant), str(real_proc)], pass_fds=(channel.send_fd, channel.ack_fd), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            proc.events = root / 'events.json'; proc.evidence = channel; proc.role = 'proc'
            lane.processes.append(proc); channel.attach(proc.pid); lane.await_ready(proc)
            return proc
        lane.start = start
        def finish(proc, *args, **kwargs):
            try:
                return r.Lane.finish(lane, proc, *args, **kwargs)
            except r.EvidenceError as exc:
                out, err = proc.communicate(timeout=5)
                raise AssertionError(f'{exc}; rc={proc.returncode}; stdout={out}; stderr={err}') from exc
        lane.finish = finish
        class Sent:
            def observed_request(_):
                if not (root / 'request').exists():
                    return False
                if post_holder:
                    # Kept until sample acknowledges it by stopping the case.
                    (root / 'locks').write_text(self.row(9876))
                return True

            def wait(_, seconds):
                until = time.monotonic() + seconds
                while time.monotonic() < until:
                    if _.observed_request():
                        return True
                    if lane.processes and lane.processes[0].poll() is not None:
                        raise AssertionError('production worker ended without DELETE: ' + (root / 'result').read_text())
                    time.sleep(min(.001, max(0, until - time.monotonic())))
                return _.observed_request()
        lane.engine = lambda **kw: types.SimpleNamespace(sent=Sent())
        # Reproduce the old util-linux sampler using a native lock on Darwin,
        # and expose its held inode through the modeled kernel table. The
        # child acknowledges an actual production activation check before
        # this sampler releases; no clock-predicate flock result is substituted.
        def old_probe(command, **kwargs):
            self.assertEqual(command, ['flock', '-n', str(switch), 'true'])
            fd = os.open(switch, os.O_RDONLY)
            try:
                try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError: return types.SimpleNamespace(returncode=1)
                sampler_locks.append(time.monotonic())
                (root / 'locks').write_text(self.row(os.getpid()))
                until = time.monotonic() + 1
                while not (root / 'checked').exists() and time.monotonic() < until: time.sleep(.001)
                (root / 'locks').write_text('')
                return types.SimpleNamespace(returncode=0)
            finally: os.close(fd)
        failure = None; began = time.monotonic()
        try:
            with mock.patch.object(r, 'SwitchLockObserver', observer, create=True), mock.patch.object(r.subprocess, 'run', old_probe):
                try: invoke_switch_case(r, lane)
                except r.CaseFailure as exc: failure = exc
            elapsed = time.monotonic() - began
            if mutant or post_holder:
                self.assertIsInstance(failure, r.CaseFailure, 'lock holder was not stopped behaviourally')
                self.assertLess(elapsed, 5, 'next-sample kill missed the 55 s final-report boundary')
                self.assertFalse((root / 'events.json').exists(), 'mutant reached its final report before the behavioural stop')
                if mutant and not real_proc:
                    held = json.loads((root / 'retained').read_text())
                    self.assertEqual(held['virtual_s'], 45)
                    following = [rows for at, rows in samples if at >= held['at']]
                    self.assertTrue(following and following[0], 'holder was not detected on the next sample')
                self.assertEqual(sum(bool(rows) for _, rows in samples), 1)
                self.assertIn(str(9876 if post_holder else lane.processes[0].pid), str(failure))
                self.assertIn('"worker_or_descendant": ' + ('false' if post_holder else 'true'), str(failure))
                lane.processes[0].communicate(timeout=5)
                lane.processes[0].evidence.validate(lane.processes[0])
                if mutant:
                    passed, message = r.classify_case(lane.case, 'the GC takes the lock', True, failure)
                    self.assertTrue(passed, message)
                else:
                    self.assertEqual(lane.processes[0].evidence.stop['site'], 'RT:447')
            else:
                self.assertIsNone(failure, str(failure))
                result = json.loads((root / 'result').read_text())
                self.assertEqual(result['rc'], 0, result)
                self.assertEqual(result['checks'], [False] * 6, result)
                self.assertAlmostEqual(result['requests'][0][1], 50.4)
                self.assertEqual(result['output'].count('snapshot too slow'), 2, result)
                self.assertGreaterEqual(len(samples), 25)
                self.assertTrue(all(not rows for _, rows in samples))
            self.assertFalse(sampler_locks, 'observer acquired the inode it observes')
            print(f'OPS327_PASSIVE {"Linux real /proc/locks" if real_proc else "modeled /proc/locks"} mutant={mutant} post_holder={post_holder} samples={len(samples)} elapsed={elapsed:.3f}s')
        finally:
            try:
                lane.close()
            except r.EvidenceError as exc:
                details = [(p.returncode, p.communicate(timeout=5)) for p in lane.processes]
                raise AssertionError(f'{exc}; child diagnostics: {details}') from exc
            finally:
                lane.finalize_evidence()

    def test_passive_observer_correct_baseline_real_sampling_with_snapshot_retries(self):
        self.process_case()

    def test_retained_native_mutant_fd_is_killed_on_next_sample(self):
        self.process_case(mutant=True)

    def test_post_request_passive_sample_rejects_unrelated_holder(self):
        self.process_case(post_holder=True)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux-only: separate-process flock holder and real /proc/locks')
    def test_linux_real_proc_locks_holder_is_killed_on_next_sample(self):
        self.process_case(mutant=True, real_proc=True)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux-only: baseline production activation checks and real /proc/locks')
    def test_linux_passive_baseline_real_proc_locks(self):
        self.process_case(real_proc=True)


class Isolation12eRegressionTests(unittest.TestCase):
    setUp = Isolation9CasePathTests.setUp

    def static_guard(self, source):
        # Parse only: decorated source must reach the actual checker without
        # executing the decorator. Red replay installs the original checker.
        validate_switch_observation_surface(source)

    def test_static_guard_follows_helper_to_native_lock(self):
        source = Path(self.r.__file__).read_text()
        self.static_guard(source)
        helper = '\nimport fcntl\n\ndef hidden_probe(path):\n    fd = os.open(path, os.O_RDONLY)\n    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n    os.close(fd)\n'
        for anchor, injection in (
            ('until = time.monotonic() + 55', "hidden_probe(lane.paths['SWITCH_LOCK'])"),
            ('        holders = []', '        hidden_probe(self.locks_path)'),
        ):
            with self.subTest(anchor=anchor):
                line = next(line for line in source.splitlines() if anchor in line)
                injected = ' ' * (len(line) - len(line.lstrip())) + injection.lstrip() + '\n' + line
                variant = source.replace(line, injected, 1)
                self.static_guard(variant + '\ndef hidden_probe(path):\n    return os.stat(path)\n')
                with self.assertRaisesRegex(AssertionError, 'observation call: os.open'):
                    self.static_guard(variant + helper)

    def test_static_guard_rejects_computed_subprocess_argv(self):
        source = Path(self.r.__file__).read_text()
        self.static_guard(source)
        for target, fixture in (('engine = lane.engine(delay=5)', "lane.paths['SWITCH_LOCK']"),
                                ('holders = []', 'self.locks_path')):
            line = next(line for line in source.splitlines() if line.lstrip().startswith(target))
            indent = ' ' * (len(line) - len(line.lstrip()))
            injected = f"{indent}command = ['fl' + 'ock', '-n', {fixture}, 'true']\n{indent}subprocess.run(command)\n{line}"
            with self.subTest(target=target), self.assertRaisesRegex(AssertionError, 'observation call: subprocess.run'):
                self.static_guard(source.replace(line, injected, 1))

    def test_static_guard_rejects_unresolved_indirect_call(self):
        source = Path(self.r.__file__).read_text()
        self.static_guard(source)
        source = source.replace(
            '        holders = []\n', '        reader = os.stat\n        reader(self.locks_path)\n        holders = []\n', 1)
        with self.assertRaisesRegex(AssertionError, 'observation call: reader'): self.static_guard(source)
        source = Path(self.r.__file__).read_text()
        line = next(line for line in source.splitlines() if line.lstrip() == 'until = time.monotonic() + 55')
        indent = ' ' * (len(line) - len(line.lstrip()))
        source = source.replace(line, indent + 'hidden_probe(adapter)\n' + line, 1)
        with self.assertRaisesRegex(AssertionError, 'shadowed observation capability: os'):
            self.static_guard(source + '\ndef hidden_probe(os):\n    return os.stat(7, 6)\n')
        with self.assertRaisesRegex(AssertionError, 'rebound observation global: os'):
            self.static_guard(source + '\nos = adapter\n\ndef hidden_probe(adapter):\n    return os.stat(7, 6)\n')

    def guard(self):
        self.assertTrue(hasattr(self.r, 'SwitchObservationGuard'), 'missing parent runtime audit')
        return self.r.SwitchObservationGuard(self.root / 'switch')

    def test_runtime_guard_blocks_helper_open_in_actual_case(self):
        r = self.r
        def hidden_probe():
            fd = os.open(self.root / 'switch', os.O_RDONLY)
            try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally: os.close(fd)
            return []
        lane = types.SimpleNamespace(paths={'SWITCH_LOCK': str(self.root / 'switch')},
                                     engine=lambda **kw: types.SimpleNamespace(sent=types.SimpleNamespace(wait=lambda seconds: True)),
                                     start=lambda constants: types.SimpleNamespace(pid=1234), require=mock.Mock(), finish=mock.Mock())
        with mock.patch.object(r, 'SwitchLockObserver', return_value=types.SimpleNamespace(sample=hidden_probe)), \
             mock.patch.object(r.time, 'sleep'), self.assertRaises(r.EvidenceError):
            invoke_switch_case(r, lane)
        lane.finish.assert_not_called()

    def test_runtime_guard_blocks_native_process_in_actual_case(self):
        r = self.r
        def hidden_probe():
            subprocess.run(['/usr/bin/' + 'true'], check=True)
            return []
        lane = types.SimpleNamespace(paths={'SWITCH_LOCK': str(self.root / 'switch')},
                                     engine=lambda **kw: types.SimpleNamespace(sent=types.SimpleNamespace(wait=lambda seconds: True)),
                                     start=lambda constants: types.SimpleNamespace(pid=1234), require=mock.Mock(), finish=mock.Mock())
        with mock.patch.object(r, 'SwitchLockObserver', return_value=types.SimpleNamespace(sample=hidden_probe)), \
             mock.patch.object(r.time, 'sleep'), self.assertRaises(r.EvidenceError):
            invoke_switch_case(r, lane)
        lane.finish.assert_not_called()

    def test_runtime_guard_records_native_lock_calls_on_preopened_fd(self):
        guard = self.guard()
        with open(self.root / 'switch', 'w+') as fixture:
            for name, invoke in (
                ('fcntl.flock', lambda: fcntl.flock(fixture.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)),
                ('fcntl.lockf', lambda: fcntl.lockf(fixture.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)),
                ('fcntl.fcntl', lambda: fcntl.fcntl(fixture.fileno(), fcntl.F_GETLK, bytes(64))),
            ):
                with self.subTest(event=name):
                    guard = self.guard()
                    with self.assertRaises(self.r.EvidenceError):
                        with guard: invoke()
                    self.assertEqual(guard.calls[-1], dict(event=name, fixture=True, allowed=False))
        self.assertFalse(sys._ops327_switch_audit_guards, 'audit scope leaked')

    def test_runtime_guard_blocks_path_inode_and_descriptor_opens(self):
        guard = self.guard()
        with open(self.root / 'switch', 'w+') as fixture:
            os.link(self.root / 'switch', self.root / 'alias')
            for target in (self.root / 'switch', self.root / 'alias', fixture.fileno()):
                with self.subTest(target=str(target)):
                    guard = self.guard()
                    with self.assertRaises(self.r.EvidenceError):
                        with guard: open(target, 'r', closefd=False if isinstance(target, int) else True)
                    self.assertEqual(guard.calls[-1], dict(event='open', fixture=True, allowed=False))
        # CPython's open audit event omits dir_fd. Refuse unresolved relative
        # opens rather than guessing the inode using the parent's cwd.
        directory = os.open(self.root, os.O_RDONLY)
        try:
            guard = self.guard()
            with self.assertRaises(self.r.EvidenceError):
                with guard: os.open('switch', os.O_RDONLY, dir_fd=directory)
            self.assertEqual(guard.calls[-1]['event'], 'open')
            self.assertFalse(guard.calls[-1]['allowed'])
        finally: os.close(directory)

    def test_runtime_guard_records_all_process_events_and_sticky_attempts(self):
        def fork():
            pid = os.fork()
            if pid == 0: os._exit(0)
            os.waitpid(pid, 0)
        def spawn():
            pid = os.posix_spawn('/usr/bin/true', ['true'], {})
            os.waitpid(pid, 0)
        native = {'subprocess.Popen': lambda: subprocess.run(['/usr/bin/true'], check=True),
                  'os.posix_spawn': spawn, 'os.fork': fork}
        for event in ('subprocess.Popen', 'os.posix_spawn', 'os.fork', 'os.forkpty', 'os.system', 'os.exec'):
            with self.subTest(event=event):
                guard = self.guard()
                with self.assertRaises(self.r.EvidenceError):
                    with guard:
                        # Catching a rejected attempt cannot make the case pass.
                        try:
                            if event in native: native[event]()
                            else: sys.audit(event, 'computed-command')
                        except self.r.EvidenceError: pass
                self.assertEqual(guard.calls[-1], dict(event=event, fixture=False, allowed=False))

    def test_runtime_guard_allows_only_declared_creation_and_launch(self):
        guard = self.guard()
        with guard:
            guard.create_fixture()
            with guard.worker_launch():
                subprocess.run(['/usr/bin/true'], check=True)
            with open(self.root / 'other', 'w') as other:
                fcntl.flock(other.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertTrue(any(c['event'] == 'open' and c['fixture'] and c['allowed'] for c in guard.calls))
        self.assertTrue(any(c['event'] == 'subprocess.Popen' and c['allowed'] for c in guard.calls))
        self.assertTrue(any(c['event'] == 'fcntl.flock' and not c['fixture'] for c in guard.calls))
        self.assertFalse(guard.violations)
        with self.assertRaises(self.r.EvidenceError): guard.create_fixture()

    def preflight(self, mode):
        r = self.r
        self.assertTrue(hasattr(r, 'preflight_switch_filesystem'), 'missing filesystem lock identity preflight')
        fixture = self.root / 'switch'
        fixture.touch()
        identity = fixture.stat()
        locks = self.root / 'locks'
        locks.write_text('')
        acquired = []
        native = fcntl.flock
        def lock(fd, flags):
            info = os.fstat(fd)
            self.assertNotEqual((info.st_dev, info.st_ino), (identity.st_dev, identity.st_ino), 'preflight locked the switch fixture')
            acquired.append((info.st_dev, info.st_ino))
            native(fd, flags)
            major = os.major(info.st_dev) + (mode == 'device-mismatch')
            inode = info.st_ino + (mode == 'inode-mismatch')
            row = f'1: FLOCK ADVISORY WRITE {os.getpid()} {major:04x}:{os.minor(info.st_dev):04x}:{inode} 0 EOF\n'
            locks.write_text('' if mode == 'missing' else row * (2 if mode == 'ambiguous' else 1))
        with mock.patch.object(r.fcntl, 'flock', side_effect=lock):
            try: r.preflight_switch_filesystem(fixture, locks_path=locks)
            finally:
                self.assertEqual(len(acquired), 1)
                self.assertFalse(list(self.root.glob('.ops327-switch-preflight-*')), 'owned scratch file leaked')
                self.assertEqual(fixture.stat().st_ino, identity.st_ino)

    def test_filesystem_device_mismatch_refuses_setup(self):
        self.assertTrue(hasattr(self.r, 'preflight_switch_filesystem'), 'missing preflight')
        with self.assertRaisesRegex(self.r.EvidenceError, 'unsupported switch-lock filesystem'): self.preflight('device-mismatch')

    def test_filesystem_inode_mismatch_refuses_setup(self):
        self.assertTrue(hasattr(self.r, 'preflight_switch_filesystem'), 'missing preflight')
        with self.assertRaisesRegex(self.r.EvidenceError, 'unsupported switch-lock filesystem'): self.preflight('inode-mismatch')

    def test_filesystem_missing_or_ambiguous_row_refuses_setup(self):
        self.assertTrue(hasattr(self.r, 'preflight_switch_filesystem'), 'missing preflight')
        for mode in ('missing', 'ambiguous'):
            with self.subTest(mode=mode), self.assertRaisesRegex(self.r.EvidenceError, 'unsupported switch-lock filesystem'):
                self.preflight(mode)

    def test_filesystem_match_proceeds_without_touching_fixture_inode(self):
        self.preflight('match')

    def test_filesystem_refusal_precedes_workers_and_never_kills_mutant(self):
        r = self.r
        self.assertTrue(hasattr(r, 'preflight_switch_filesystem'), 'missing preflight')
        args = types.SimpleNamespace(root=str(self.root), keep_dir=str(self.root / 'keep'), store=str(self.root / 'store'),
                                     instance_lock=str(self.root / 'instance'), switch_lock=str(self.root / 'switch'),
                                     compose_lock_dir=str(self.root / 'compose'), engine_socket=str(self.root / 'engine.sock'))
        error = r.EvidenceError('unsupported switch-lock filesystem: modeled mismatch')
        output = io.StringIO()
        with mock.patch.object(r.sys, 'platform', 'linux'), mock.patch.object(r, 'preflight_switch_filesystem', side_effect=error) as preflight, \
             mock.patch.object(r.subprocess, 'Popen') as spawn, redirect_stdout(output):
            self.assertEqual(r.run_checks(args, [('never-switch-lock', None, SCRIPT.read_text()),
                                                 ('never-switch-lock', 'the GC takes the lock', SCRIPT.read_text())]), 1)
        self.assertEqual(preflight.call_count, 2)
        spawn.assert_not_called()
        self.assertEqual(output.getvalue().count('(setup: unsupported switch-lock filesystem:'), 2)
        self.assertNotIn('ok ', output.getvalue())


class Isolation12gRegressionTests(unittest.TestCase):
    setUp = Isolation9CasePathTests.setUp

    def preflight(self, mode):
        r = self.r
        fixture = self.root / 'switch'; fixture.touch(exist_ok=True)
        locks = self.root / 'locks'
        native = fcntl.flock
        with (self.root / 'unrelated').open('w') as holder:
            native(holder.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            def row(info, ordinal, *, major=None):
                major = os.major(info.st_dev) if major is None else major
                return f'{ordinal}: FLOCK ADVISORY WRITE {os.getpid()} {major:x}:{os.minor(info.st_dev):x}:{info.st_ino} 0 EOF\n'
            unrelated = os.fstat(holder.fileno())
            locks.write_text(row(unrelated, 1))
            acquired = []
            def lock(fd, flags):
                native(fd, flags)
                info = os.fstat(fd)
                self.assertNotEqual(info.st_ino, fixture.stat().st_ino)
                acquired.append(fd)
                scratch = row(info, 3, major=os.major(info.st_dev) + (mode == 'device-mismatch'))
                if mode == 'two-new': scratch += row(info, 4)
                if mode == 'no-new': scratch = ''
                # Kernel row ordinals can change between reads; identity cannot
                # include them. Duplicate new rows must still count separately.
                locks.write_text(row(unrelated, 2) + scratch)
            with mock.patch.object(r.fcntl, 'flock', side_effect=lock):
                try:
                    r.preflight_switch_filesystem(fixture, locks_path=locks)
                finally:
                    self.assertEqual(len(acquired), 1)
                    self.assertFalse(list(self.root.glob('.ops327-switch-preflight-*')))
                    with self.assertRaises(OSError): os.fstat(acquired[0])

    def test_unrelated_pid_flock_present_before_and_after_is_ignored(self):
        self.preflight('match')

    def test_two_new_pid_rows_still_refuse_setup(self):
        # Each refusal control first admits a valid delta with the same holder;
        # an unconditional refusal must not pass these fail-closed controls.
        self.preflight('match')
        with self.assertRaisesRegex(self.r.EvidenceError, 'missing or ambiguous scratch lock identity'):
            self.preflight('two-new')

    def test_no_new_pid_row_still_refuses_setup(self):
        self.preflight('match')
        with self.assertRaisesRegex(self.r.EvidenceError, 'missing or ambiguous scratch lock identity'):
            self.preflight('no-new')

    def test_new_row_device_mismatch_still_refuses_setup(self):
        self.preflight('match')
        with self.assertRaisesRegex(self.r.EvidenceError, 'scratch lock identity differs from fstat'):
            self.preflight('device-mismatch')

    def test_in_process_lock_mutant_leaves_no_descriptor_or_pid_flock(self):
        case = ActivationTests('test_switch_lock_is_never_locked')
        native_open = os.open
        opened = []
        def owned_rows():
            if not sys.platform.startswith('linux'): return None
            return sorted(tuple(fields[1:]) for line in Path('/proc/locks').read_text().splitlines()
                          if len(fields := line.split()) == 8 and fields[1] == 'FLOCK' and fields[4] == str(os.getpid()))
        def track(path, *args, **kwargs):
            fd = native_open(path, *args, **kwargs)
            if str(path) == getattr(getattr(case, 'gc', None), 'SWITCH_LOCK', None):
                info = os.fstat(fd)
                opened.append((fd, info.st_dev, info.st_ino))
            return fd
        before = owned_rows()
        retained = []
        try:
            with mock.patch.dict(globals(), OVERRIDE=MUTANTS['the GC takes the lock'][0]), \
                 mock.patch.object(os, 'open', track):
                result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(unittest.TestSuite([case]))
            self.assertEqual(result.testsRun, 1)
            self.assertFalse(result.errors, result.errors)
            self.assertFalse(result.skipped)
            self.assertEqual(len(result.failures), 1, 'registered lock-taking mutant must still be caught')
            self.assertTrue(opened, 'mutant must acquire an actual native descriptor')
            after = owned_rows()
        finally:
            # A red replay must release its own retained descriptors, too.
            for fd, device, inode in opened:
                try: info = os.fstat(fd)
                except OSError: continue
                if (info.st_dev, info.st_ino) == (device, inode):
                    retained.append(fd)
                    os.close(fd)
        self.assertFalse(retained, 'test cleanup left the mutant switch-lock descriptor open')
        self.assertEqual(after, before, 'test cleanup left a PID-owned FLOCK')

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux-only: real preflight alongside unrelated PID-owned FLOCK')
    def test_linux_preflight_with_unrelated_native_flock(self):
        with (self.root / 'unrelated').open('w') as holder:
            fcntl.flock(holder.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.r.preflight_switch_filesystem(self.root / 'switch')


class Isolation12fRegressionTests(unittest.TestCase):
    setUp = Isolation9CasePathTests.setUp
    static_guard = Isolation12eRegressionTests.static_guard
    row = Isolation12dRegressionTests.row

    def static_control(self, baseline, variant, rule):
        # In the red replay this is the actual c1e56dc3 checker. Both sources
        # differ only in the construct under test; baseline must always pass.
        self.static_guard(baseline)
        with self.assertRaisesRegex(AssertionError, rule):
            self.static_guard(variant)

    def inject(self, statement):
        source = Path(self.r.__file__).read_text()
        line = next(line for line in source.splitlines() if line.lstrip() == 'until = time.monotonic() + 55')
        indent = line[:len(line) - len(line.lstrip())]
        return source.replace(line, indent + statement + '\n' + line, 1)

    def decorator_control(self, decorator, target='helper'):
        source = self.inject('helper()')
        # The wrappers are intentionally outside the 12e walk: the bare and
        # attribute decorators aren't calls, and max is a 12e primitive.
        factory = """
def decorate(fn):
    def wrapper(*args, **kwargs):
        fd = os.open('/ordinary-edit-fixture', os.O_RDONLY)
        return fn(*args, **kwargs)
    return wrapper

class Decorators:
    wrap = decorate

decorators = Decorators

def helper():
    return 0
"""
        baseline = source + factory
        if target == 'helper':
            variant = baseline.replace('\ndef helper():', '\n' + decorator + '\ndef helper():')
        else:
            variant = baseline.replace(target, decorator + '\n' + target, 1)
        self.static_control(baseline, variant, 'G.2.1 no decorators')

    def test_static_bare_decorator_returns_unwalked_wrapper(self):
        self.decorator_control('@decorate')

    def test_static_attribute_decorator_returns_unwalked_wrapper(self):
        self.decorator_control('@decorators.wrap')

    def test_static_call_decorator_returns_unwalked_wrapper(self):
        self.decorator_control('@max([decorate])')

    def test_static_class_and_method_decorators_are_forbidden(self):
        for target in ('class SwitchLockObserver:', '    def sample(self):'):
            with self.subTest(target=target):
                indent = '    ' if target.startswith(' ') else ''
                self.decorator_control(indent + '@decorate', target)

    def callback_control(self, baseline, variant, rule):
        helper = '\ndef helper(value):\n    return os.open(value, os.O_RDONLY)\n'
        self.static_control(self.inject(baseline) + helper, self.inject(variant) + helper, rule)

    def test_static_max_key_function_is_forbidden(self):
        self.callback_control('max([0])', 'max([0], key=helper)', 'G.2.2 no function-reference arguments')

    def test_static_min_key_function_is_forbidden(self):
        self.callback_control('min([0])', 'min([0], key=helper)', 'G.2.2 no function-reference arguments')

    def test_static_json_default_function_is_forbidden(self):
        self.callback_control('json.dumps({})', 'json.dumps({}, default=helper)', 'G.2.2 no function-reference arguments')

    def test_static_max_star_arguments_are_forbidden(self):
        self.callback_control('xs = [0, 1]; max(xs)', 'xs = [0, 1]; max(*xs)', 'G.2.2 no argument unpacking')

    def test_static_dict_keyword_unpacking_is_forbidden(self):
        self.callback_control('kw = {}; dict(kw)', 'kw = {}; dict(**kw)', 'G.2.2 no argument unpacking')

    def test_static_positional_function_is_forbidden(self):
        self.callback_control('max(1, 0)', 'max(helper, 0)', 'G.2.2 no function-reference arguments')

    def test_static_attribute_method_and_builtin_function_arguments_are_forbidden(self):
        for function in ('os.path.realpath', 'SwitchLockObserver.sample', 'print'):
            with self.subTest(function=function):
                self.static_control(self.inject('max(1, 0)'), self.inject(f'max({function}, 0)'),
                                    'G.2.2 no function-reference arguments')

    def test_static_aliased_function_arguments_are_forbidden(self):
        self.callback_control('alias = helper; max(1, 0)', 'alias = helper; max(alias, 0)',
                              'G.2.2 no function-reference arguments')

    def test_static_primitive_signature_rejects_keywords_and_counts(self):
        for baseline, variant, rule in (
            ('json.dumps({})', 'json.dumps({}, indent=2)', 'G.2.2 primitive keyword'),
            ('len([])', 'len([], 0)', 'G.2.2 primitive positional count'),
        ):
            with self.subTest(rule=rule):
                self.static_control(self.inject(baseline), self.inject(variant), rule)

    def lane(self):
        return types.SimpleNamespace(paths={'SWITCH_LOCK': str(self.root / 'switch')},
            engine=lambda **kw: types.SimpleNamespace(sent=types.SimpleNamespace(wait=lambda seconds: True)),
            start=mock.Mock(return_value=types.SimpleNamespace(pid=1234)), require=mock.Mock(),
            finish=mock.Mock(), check_workers=mock.Mock(), close=mock.Mock(), finalize_evidence=mock.Mock())

    def test_runtime_case_wrapper_is_inside_single_caller_guard(self):
        r = self.r
        (self.root / 'switch').touch()
        original = r.never_switch_lock
        acquired = []
        def wrapper(lane):
            fd = os.open(lane.paths['SWITCH_LOCK'], os.O_RDONLY)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired.append(True)
            finally:
                os.close(fd)
            return original(lane)
        for direct in (False, True):
            with self.subTest(direct=direct):
                acquired.clear()
                lane = self.lane()
                with mock.patch.object(r, 'SwitchLockObserver', return_value=types.SimpleNamespace(sample=lambda: [])), \
                     mock.patch.object(r.time, 'sleep'), mock.patch.object(r, 'Lane', return_value=lane), \
                     mock.patch.dict(r.CASES, {'never-switch-lock': wrapper}), redirect_stdout(io.StringIO()) as output:
                    if direct:
                        with self.assertRaisesRegex(r.EvidenceError, 'parent switch observation audit'):
                            invoke_switch_case(r, lane, wrapper)
                    else:
                        self.assertEqual(r.run_checks(None, [('never-switch-lock', None, '')]), 1)
                        self.assertIn('(setup: parent switch observation audit:', output.getvalue())
                        self.assertNotIn('ok ', output.getvalue())
                self.assertFalse(acquired, 'G.3.1 wrapper ran before caller guard')
                lane.start.assert_not_called()

    def test_runtime_case_uses_exactly_one_guard_and_single_use_capabilities(self):
        r = self.r
        made, entered = [], []
        cls = r.SwitchObservationGuard
        init, enter = cls.__init__, cls.__enter__
        def record_init(guard, fixture):
            made.append(guard)
            init(guard, fixture)
        def record_enter(guard):
            entered.append(guard)
            return enter(guard)
        for direct in (False, True):
            with self.subTest(direct=direct):
                made.clear(); entered.clear()
                lane = self.lane()
                with mock.patch.object(cls, '__init__', record_init), mock.patch.object(cls, '__enter__', record_enter), \
                     mock.patch.object(r, 'SwitchLockObserver', return_value=types.SimpleNamespace(sample=lambda: [])), \
                     mock.patch.object(r.time, 'sleep'), mock.patch.object(r, 'Lane', return_value=lane), redirect_stdout(io.StringIO()):
                    if direct: invoke_switch_case(r, lane)
                    else: self.assertEqual(r.run_checks(None, [('never-switch-lock', None, '')]), 0)
                self.assertEqual(len(made), 1, 'G.3.1 one guard instance')
                self.assertEqual(entered, made, 'G.3.1 enter once')
                self.assertTrue(made[0].created and getattr(made[0], 'launched', False), 'G.3.1 same guard owns both capabilities')
                lane.start.assert_called_once_with({'RUN_BUDGET_S': 55})

    def test_runtime_nested_duplicate_and_reentered_guards_fail_setup(self):
        r = self.r
        for mode in ('nested', 'duplicate', 'reenter'):
            with self.subTest(mode=mode):
                guard = r.SwitchObservationGuard(self.root / 'switch')
                if mode == 'reenter':
                    with guard: pass
                    with self.assertRaisesRegex(r.EvidenceError, 'duplicate'):
                        with guard: pass
                else:
                    with self.assertRaisesRegex(r.EvidenceError, 'duplicate'):
                        with guard:
                            # Catching the nested refusal must remain sticky.
                            try:
                                with (guard if mode == 'duplicate' else r.SwitchObservationGuard(self.root / 'switch')): pass
                            except r.EvidenceError: pass
                self.assertFalse(sys._ops327_switch_audit_guards)

    def test_runtime_capabilities_require_active_guard_and_launch_is_single_use(self):
        r = self.r
        guard = r.SwitchObservationGuard(self.root / 'switch')
        with self.assertRaisesRegex(r.EvidenceError, 'active guard'): guard.create_fixture()
        with self.assertRaisesRegex(r.EvidenceError, 'active guard'):
            with guard.worker_launch(): pass
        with self.assertRaisesRegex(r.EvidenceError, 'active switch observation guard'):
            r.SwitchObservationGuard.active(self.root / 'switch')
        for capability in ('create_fixture', 'worker_launch'):
            guard = r.SwitchObservationGuard(self.root / 'switch')
            with self.subTest(capability=capability), self.assertRaisesRegex(r.EvidenceError, 'already consumed'):
                with guard:
                    guard.create_fixture()
                    with guard.worker_launch(): pass
                    try:
                        if capability == 'create_fixture': guard.create_fixture()
                        else:
                            with guard.worker_launch(): pass
                    except r.EvidenceError: pass
        with self.assertRaisesRegex(r.EvidenceError, 'active guard'):
            with guard.worker_launch(): pass

    def test_runtime_pathlike_audit_events_normalize_before_relative_check(self):
        r = self.r
        class Target:
            def __init__(self, value): self.value = value
            def __fspath__(self): return self.value
        for exists in (False, True):
            if exists: (self.root / 'switch').touch()
            for target in (Target('switch'), Target(b'switch'), Target(str(self.root / 'switch')), Target(os.fsencode(self.root / 'switch'))):
                with self.subTest(exists=exists, target_type=type(target.value).__name__, absolute=os.path.isabs(target.value)):
                    guard = r.SwitchObservationGuard(self.root / 'switch')
                    with self.assertRaisesRegex(r.EvidenceError, 'parent switch observation audit: open'):
                        with guard: sys.audit('open', target, 'r', os.O_RDONLY)
                    self.assertFalse(guard.calls[-1]['allowed'], 'G.3.2 PathLike normalization')
        directory = os.open(self.root, os.O_RDONLY)
        try:
            guard = r.SwitchObservationGuard(self.root / 'switch')
            with self.assertRaises(r.EvidenceError):
                with guard: os.open(Target('switch'), os.O_RDONLY, dir_fd=directory)
        finally: os.close(directory)

    def test_runtime_synthetic_spawn_event_is_sticky_setup_failure(self):
        r = self.r
        guard = r.SwitchObservationGuard(self.root / 'switch')
        with self.assertRaisesRegex(r.EvidenceError, 'parent switch observation audit: os.spawn'):
            with guard:
                try: sys.audit('os.spawn', os.P_WAIT, '/usr/bin/true', ['true'], {})
                except r.EvidenceError: pass
        self.assertEqual(guard.calls[-1], dict(event='os.spawn', fixture=False, allowed=False))
        passed, message = r.classify_case('never-switch-lock', 'the GC takes the lock', True, r.EvidenceError('os.spawn'))
        self.assertFalse(passed)
        self.assertIn('(setup:', message)

    def test_runtime_public_spawn_variants_record_native_rejection_event(self):
        r = self.r
        for name in ('spawnl', 'spawnle', 'spawnlp', 'spawnlpe', 'spawnv', 'spawnve', 'spawnvp', 'spawnvpe'):
            if not hasattr(os, name): continue
            with self.subTest(api=name):
                guard = r.SwitchObservationGuard(self.root / 'switch')
                argv = (['true'],) if name.startswith('spawnv') else ('true',)
                args = (os.P_WAIT, '/usr/bin/true', *argv, *([{}] if name.endswith('e') else []))
                with self.assertRaises(r.EvidenceError):
                    with guard: getattr(os, name)(*args)
                event = guard.calls[-1]['event']
                self.assertIn(event, ('os.spawn', 'os.fork'))
                self.assertFalse(guard.calls[-1]['allowed'])
                print(f'OPS327_SPAWN api={name} event={event} platform={sys.platform} python={sys.version.split()[0]}')

    def test_other_cases_start_workers_without_observation_guard(self):
        # Reach the first launch in each actual case through run_checks.
        # Stop there deliberately; no socket, real worker or wall-clock wait.
        r = self.r
        for case in ('instance-and-sigkill', 'r29'):
            with self.subTest(case=case):
                lane = self.lane()
                lane.start.side_effect = r.EvidenceError('positive launch witness')
                with mock.patch.object(r, 'SwitchObservationGuard', side_effect=AssertionError('unexpected guard')) as guard, \
                     mock.patch.object(r, 'Lane', return_value=lane), redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(r.run_checks(None, [(case, None, '')]), 1)
                guard.assert_not_called()
                lane.start.assert_called_once()
                self.assertIn('positive launch witness', output.getvalue())
        fixture = Isolation9CasePathTests()
        fixture.r, fixture.root = r, self.root
        with mock.patch.object(r, 'SwitchObservationGuard', side_effect=AssertionError('unexpected guard')) as guard:
            self.assertIsNone(fixture.case_path('four-acquisitions'))
        guard.assert_not_called()

    def test_request_holder_installation_precedes_sample_in_both_schedules(self):
        r = self.r
        # Compile the actual nested Sent class, including the c1e56dc3 one
        # during red replay. Only the clock schedule is injected; no sleeps.
        method = Isolation12dRegressionTests.process_case
        tree = ast.parse(Path(method.__code__.co_filename).read_text())
        owner = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'Isolation12dRegressionTests')
        body = next(n for n in owner.body if isinstance(n, ast.FunctionDef) and n.name == 'process_case')
        sent = next(n for n in ast.walk(body) if isinstance(n, ast.ClassDef) and n.name == 'Sent')
        for schedule in ('loop', 'timeout-fallback'):
            with self.subTest(schedule=schedule):
                (self.root / 'switch').touch(); (self.root / 'locks').write_text('')
                (self.root / 'request').touch(); (self.root / 'proc').mkdir(exist_ok=True)
                events = []
                clock = types.SimpleNamespace(monotonic=mock.Mock(side_effect=[0, .005 if schedule == 'loop' else 1]))
                namespace = dict(root=self.root, post_holder=True, self=self, time=clock)
                exec(compile(ast.Module([sent], []), '<actual-Sent>', 'exec'), namespace)
                receiver = namespace['Sent']()
                write = Path.write_text
                def record_write(path, *args, **kwargs):
                    result = write(path, *args, **kwargs)
                    if path == self.root / 'locks': events.append('holder installed')
                    return result
                lane = self.lane()
                lane.engine = lambda **kw: types.SimpleNamespace(sent=receiver)
                observer = r.SwitchLockObserver(self.root / 'switch', 1234, locks_path=self.root / 'locks', proc_path=self.root / 'proc')
                sample = observer.sample
                def record_sample():
                    rows = sample()
                    if rows: events.append('sample sees holder')
                    return rows
                observer.sample = record_sample
                def require(site, condition, message=''):
                    if not condition:
                        events.append(site + ' CaseFailure')
                        raise r.CaseFailure(message)
                lane.require = require
                with mock.patch.object(Path, 'write_text', record_write), mock.patch.object(r, 'SwitchLockObserver', return_value=observer), \
                     mock.patch.object(r.time, 'sleep'), self.assertRaises(r.CaseFailure, msg='G.4 every True wait installs holder'):
                    invoke_switch_case(r, lane)
                self.assertEqual(events, ['holder installed', 'sample sees holder', 'RT:447 CaseFailure'])
                self.assertEqual((self.root / 'locks').read_text(), self.row(9876), 'holder cleared before observation acknowledgement')
                lane.finish.assert_not_called()


class Isolation12cRegressionTests(unittest.TestCase):
    setUp = Isolation9CasePathTests.setUp

    def observe_switch(self, first_delete=None, locked_at=None):
        # Replay production's request time through the actual parent case.
        # Only scheduling, Engine delivery and the passive table samples are
        # modeled; require/stop_at and the persisted stop certificate are real.
        r = self.r
        clock = types.SimpleNamespace(now=0.0)
        clock.monotonic = lambda: clock.now
        clock.sleep = lambda seconds: setattr(clock, 'now', clock.now + seconds)
        channel = r.WorkerEvidence(self.root, 'switch-worker', 's', 'm', 'never-switch-lock')
        for fd in (channel.read, channel.send_fd, channel.ack_fd, channel.ack_write):
            os.close(fd)
        channel.state = r.EvidenceState(channel.identity, 1234)
        for kind, fields in (('START', {}), ('READY', {}),
                             ('PHASE', {'label': 'main-entered'}), ('PHASE', {'label': 'cooldown'})):
            channel.state.accept(dict(identity=channel.identity, pid=1234,
                                     seq=len(channel.state.records) + 1, kind=kind, **fields))
        channel.window_started = 0.0
        proc = types.SimpleNamespace(pid=1234, evidence=channel, role='proc', returncode=None)
        proc.poll = lambda: proc.returncode
        kills, waits, probes = [], [], []
        def kill():
            kills.append(clock.now)
            proc.returncode = -signal.SIGKILL
        proc.kill = kill
        def wait(seconds):
            waits.append(seconds)
            target = clock.now + seconds
            clock.now = min(target, first_delete) if first_delete is not None and clock.now < first_delete else target
            return first_delete is not None and clock.now >= first_delete
        def probe():
            probes.append(clock.now)
            return [dict(pid=1234, worker_or_descendant=True)] if locked_at is not None and clock.now >= locked_at else []
        lane = object.__new__(r.Lane)
        lane.case = 'never-switch-lock'; lane.stop_plan = r.STOP_PLAN[lane.case]
        lane.processes = [proc]; lane.paths = {'SWITCH_LOCK': str(self.root / 'switch')}
        lane.start = lambda constants: proc
        lane.engine = lambda **kw: types.SimpleNamespace(sent=types.SimpleNamespace(wait=wait))
        lane.finish = mock.Mock()
        error = None
        with mock.patch.object(r, 'time', clock), mock.patch.object(r, 'SwitchLockObserver', return_value=types.SimpleNamespace(sample=probe)):
            try:
                invoke_switch_case(r, lane)
            except r.CaseFailure as exc:
                error = exc
        if kills:
            channel.state.validate(proc.returncode, None, channel.stop)
        return error, kills, probes, lane.finish, waits

    def snapshot_retry(self, durations):
        # Actual production main -> batch -> snapshot -> plan, with a clock
        # and Engine response delay injected instead of a 55-second wall wait.
        fixture = Base(); fixture.setUp(); self.addCleanup(fixture.doCleanups)
        fixture.world(); gc = fixture.gc; clock = Clock(); started = clock.t
        remaining = iter(durations); requests = []
        original_snapshot = gc.snapshot
        def snapshot(api, budget):
            snap = original_snapshot(api, budget)
            clock.advance(next(remaining, 0))
            return snap
        api = fixture.api()
        def engine(method, path, **kwargs):
            if method != 'GET':
                requests.append((method, clock.t - started))
                clock.advance(5)
            return api(method, path, **kwargs)
        gc.RUN_BUDGET_S = 55
        with mock.patch.object(gc.time, 'monotonic', clock), \
             mock.patch.object(gc, 'snapshot', snapshot), \
             mock.patch.dict(os.environ, {'INVOCATION_ID': 'ops327-local', 'DOCKER_IMAGE_GC_DRY_RUN': '0'}), \
             redirect_stdout(io.StringIO()) as output:
            rc = gc.main(engine, now=NOW, sleep=clock.advance)
        self.assertEqual(rc, 0, output.getvalue())
        self.assertEqual(output.getvalue().count('snapshot too slow'), len(durations) - 1)
        first_delete = next(at for method, at in requests if method == 'DELETE')
        self.assertAlmostEqual(first_delete, 45 + sum(durations))
        error, kills, probes, finish, waits = self.observe_switch(first_delete)
        self.assertIsNone(error, str(error)); self.assertFalse(kills); finish.assert_called_once()
        self.assertTrue(any(at < first_delete for at in probes), 'switch lock was not observed during request wait')
        print(f'OPS327_RETRY durations={durations} first_DELETE={first_delete:.1f}s baseline=True')

    def test_snapshot_retry_2_6_2_6_0_2_preserves_baseline(self):
        self.snapshot_retry([2.6, 2.6, 0.2])

    def test_snapshot_retry_5_1_0_2_preserves_baseline(self):
        self.snapshot_retry([5.1, 0.2])

    def test_switch_lock_mutant_is_behaviourally_killed_before_final_report(self):
        error, kills, probes, finish, waits = self.observe_switch(locked_at=45)
        self.assertIsInstance(error, self.r.CaseFailure)
        self.assertIn('GC locked the switch lock', str(error))
        self.assertEqual(len(kills), 1); self.assertLess(kills[0], 46)
        finish.assert_not_called()
        passed, message = self.r.classify_case('never-switch-lock', 'the GC takes the lock', True, error)
        self.assertTrue(passed, message)
        print(f'OPS327_SWITCH_MUTANT kill={kills[0]:.3f}s before_final_report=True behavioural=True')

    @contextmanager
    def sidecar_channel(self, site):
        r = self.r
        with tempfile.TemporaryDirectory(prefix='ops327-sidecar-', dir=REPO) as root:
            channel = r.WorkerEvidence(root, 'worker', 's', 'm', 'maximal-hold-r34')
            writer, ack = os.dup(channel.send_fd), os.dup(channel.ack_fd)
            channel.attach(os.getpid())
            publisher = r.EvidencePublisher(writer, ack, channel.identity)
            publisher.send('START'); publisher.send('READY'); publisher.send('PHASE', label='main-entered')
            proc = types.SimpleNamespace(evidence=channel, events=Path(root) / 'events.json', role='proc',
                                         poll=lambda: None, kill=mock.Mock())
            lane = object.__new__(r.Lane)
            lane.case = channel.case; lane.stop_plan = r.STOP_PLAN[lane.case]; lane.processes = [proc]
            if site == 'arm':
                lane.await_ready(proc)
            try:
                yield channel, publisher, proc, (lambda: lane.await_ready(proc)) if site == 'open_window' else (lambda: lane.stop_at('RT:317'))
            finally:
                publisher.close(); channel.abort.set(); channel.thread.join(2)

    def slow_sidecar(self, site, *, overlap=False):
        r = self.r
        with self.sidecar_channel(site) as (channel, publisher, proc, operation):
            entered, release, delivered = threading.Event(), threading.Event(), threading.Event()
            errors, publisher_errors = [], []
            native_fsync = os.fsync
            def fsync(fd):
                entered.set()
                if not release.wait(3):
                    raise RuntimeError('test did not release sidecar fsync')
                native_fsync(fd)
            def call():
                try: operation()
                except Exception as exc: errors.append(exc)
            def publish():
                try:
                    if overlap:
                        publisher.begin_timed_window(r._MONOTONIC())
                    publisher.send('PHASE', label='during-sidecar')
                    if overlap:
                        publisher.end_timed_window()
                except Exception as exc: publisher_errors.append(exc)
                finally: delivered.set()
            with mock.patch.object(r.os, 'fsync', fsync):
                caller = threading.Thread(target=call); caller.start()
                producer = threading.Thread(target=publish)
                try:
                    self.assertTrue(entered.wait(2), 'sidecar fsync not reached')
                    began = time.monotonic()
                    producer.start()
                    unblocked = delivered.wait(.2)
                    # The 310 ms disk wait must neither hold the collector lock
                    # nor be charged to an already-open certified window.
                    time.sleep(max(0, .31 - (time.monotonic() - began)))
                finally:
                    release.set(); caller.join(3)
                    if producer.ident is not None: producer.join(3)
            self.assertFalse(caller.is_alive()); self.assertFalse(producer.is_alive())
            self.assertTrue(unblocked, f'{site}: collector blocked by sidecar fsync')
            self.assertFalse(publisher_errors, publisher_errors)
            if overlap:
                self.assertTrue(errors, 'window overlapping disk persistence was certified')
                self.assertIsInstance(errors[0], r.EvidenceError)
                self.assertIsNone(channel.stop); proc.kill.assert_not_called()
                self.assertTrue(channel.errors, 'disk/window failure must remain sticky')
            else:
                self.assertFalse(errors, errors)
                if site == 'arm': proc.kill.assert_called_once()
                publisher.begin_timed_window(r._MONOTONIC())
                publisher.send('PHASE', label='after-sidecar')
                publisher.end_timed_window(); publisher.close(); publisher.close = lambda: None
                channel.thread.join(2); channel.persist()
                totals = channel.certify_timing()
                self.assertEqual(len(totals), 1)
                self.assertLess(totals[0]['instrumentation_s'], .250)

    def test_open_window_slow_sidecar_does_not_block_collector(self):
        self.slow_sidecar('open_window')

    def test_arm_slow_sidecar_does_not_block_collector(self):
        self.slow_sidecar('arm')

    def test_open_window_disk_overlap_is_uncertifiable(self):
        self.slow_sidecar('open_window', overlap=True)

    def test_arm_disk_overlap_is_uncertifiable(self):
        self.slow_sidecar('arm', overlap=True)

    def active_sidecar(self, site):
        r = self.r
        with self.sidecar_channel(site) as (channel, publisher, proc, operation):
            publisher.begin_timed_window(r._MONOTONIC())
            publisher.send('PHASE', label='destructive-phase')
            # Ensure the confirmation is received before testing persistence.
            deadline = time.monotonic() + 1
            while channel.timing_pending is not None and time.monotonic() < deadline:
                time.sleep(.001)
            with mock.patch.object(r.os, 'fsync') as fsync:
                with self.assertRaises(r.EvidenceError): operation()
            fsync.assert_not_called(); self.assertIsNone(channel.stop); proc.kill.assert_not_called()
            publisher.end_timed_window()

    def test_open_window_rejects_active_window_before_any_disk_wait(self):
        self.active_sidecar('open_window')

    def test_arm_rejects_active_window_before_any_disk_wait(self):
        self.active_sidecar('arm')

    def persist_deadline(self, site):
        r = self.r
        with self.sidecar_channel(site) as (channel, publisher, proc, operation):
            finished = threading.Event()
            def fsync(fd):
                try: time.sleep(1.2)
                finally: finished.set()
            # stop_at has its real shared one-second budget; direct startup
            # persistence must also respect the caller's remaining budget.
            operation = operation if site == 'arm' else lambda: channel.open_window(r._MONOTONIC() + 1)
            try:
                with mock.patch.object(r.os, 'fsync', fsync):
                    started = time.monotonic()
                    with self.assertRaises(r.EvidenceError): operation()
                    elapsed = time.monotonic() - started
                    self.assertLess(elapsed, 1.15, 'persistence outlived the caller deadline')
                    self.assertIsNone(channel.stop); proc.kill.assert_not_called()
                    if site == 'open_window': self.assertIsNone(channel.window_started)
                    self.assertTrue(channel.errors, 'late persistence must remain infrastructure failure')
                    self.assertTrue(finished.wait(2), 'sidecar helper did not finish')
            finally:
                finished.wait(2)

    def test_open_window_persistence_deadline_grants_no_authority(self):
        self.persist_deadline('open_window')

    def test_arm_persistence_deadline_grants_no_stop_authority(self):
        self.persist_deadline('arm')

    def peer_window(self, site):
        r = self.r
        with self.sidecar_channel(site) as (channel, publisher, proc, _), \
             self.sidecar_channel('open_window') as (peer, peer_publisher, peer_proc, _):
            peer_publisher.begin_timed_window(r._MONOTONIC())
            lane = object.__new__(r.Lane)
            lane.case = channel.case; lane.stop_plan = r.STOP_PLAN[lane.case]
            lane.processes = [proc, peer_proc]
            with mock.patch.object(r.os, 'fsync') as fsync:
                with self.assertRaises(r.EvidenceError):
                    if site == 'arm': lane.stop_at('RT:317')
                    else: lane.await_ready(proc)
            fsync.assert_not_called(); proc.kill.assert_not_called(); peer_proc.kill.assert_not_called()
            self.assertIsNone(channel.stop); self.assertIsNone(peer.stop)
            peer_publisher.end_timed_window()

    def test_open_window_rejects_an_affected_peers_window(self):
        self.peer_window('open_window')

    def test_arm_rejects_an_affected_peers_window(self):
        self.peer_window('arm')

    def late_begin(self, site):
        r = self.r
        with self.sidecar_channel(site) as (channel, publisher, proc, operation):
            began = []
            native_fsync = os.fsync
            def fsync(fd):
                began.append(r._MONOTONIC()); native_fsync(fd)
            with mock.patch.object(r.os, 'fsync', fsync): operation()
            # Model a BEGIN timestamped during persistence but delivered only
            # after revalidation. Final certification must still see overlap.
            publisher.begin_timed_window(began[0])
            publisher.end_timed_window(); publisher.close(); publisher.close = lambda: None
            channel.thread.join(2); channel.persist()
            with self.assertRaisesRegex(r.EvidenceError, 'disk wait overlapped'):
                channel.certify_timing()

    def test_open_window_late_begin_cannot_conceal_disk_overlap(self):
        self.late_begin('open_window')

    def test_arm_late_begin_cannot_conceal_disk_overlap(self):
        self.late_begin('arm')

    def test_arm_revalidates_admission_after_disk_persistence(self):
        r = self.r
        with self.sidecar_channel('arm') as (channel, publisher, proc, operation):
            native_fsync = os.fsync
            def fsync(fd):
                # Inject the state transition here; the separate real-pipe
                # regressions prove the collector remains free to deliver it.
                with channel.locked(r._MONOTONIC() + 1):
                    channel.state.pending['during-sidecar'] = 'GUARD_BEGIN'
                native_fsync(fd)
            try:
                with mock.patch.object(r.os, 'fsync', fsync):
                    with self.assertRaises(r.EvidenceError): operation()
                self.assertIsNone(channel.stop); proc.kill.assert_not_called()
            finally:
                with channel.locked(): channel.state.pending.clear()


class Isolation12bRegressionTests(unittest.TestCase):
    setUp = Isolation9CasePathTests.setUp

    PRODUCER = r'''
import importlib.util,json,os,sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("transport_rt",sys.argv[1])
r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)
p=r.EvidencePublisher(int(sys.argv[2]),int(sys.argv[3]),json.loads(sys.argv[4]))
events=Path(sys.argv[5]);mode=sys.argv[6];notify=int(sys.argv[7]);block=int(sys.argv[8])
p.send("START");p.send("READY");p.send("PHASE",label="main-entered")
start=r.time.monotonic();p.begin_timed_window(start)
p.send("PHASE",label="destructive-phase");p.end_timed_window()
report={"violations":[],"holds":[[start,r.time.monotonic()]],"attempts":[]}
if mode=="partial":
    original=p.send
    def send(kind,**fields):
        if kind=="END":
            os.write(notify,b"+");os.read(block,1)
        original(kind,**fields)
    p.send=send
r.finish_worker_report(events,report,p,0)
if mode in ("last_seq","rc","identity","pid","violations","setup_error"):
    report[mode]={"last_seq":999,"rc":2,"identity":{},"pid":0,"violations":[{"event":"open","path":"/owned-denied"}],"setup_error":"injected"}[mode]
    r.publish_events(events,report)
os.write(notify,b"+")
os.read(block,1)
'''

    def stopped_report(self, mode="complete", *, case="never-switch-lock", planned=True):
        r=self.r
        with tempfile.TemporaryDirectory(prefix="ops327-stop-report-",dir=REPO) as root:
            root=Path(root);events=root/"events.json"
            channel=r.WorkerEvidence(root,"worker-1","s"*64,"m"*64,case)
            ready,notify=os.pipe();block,release=os.pipe()
            proc=subprocess.Popen([sys.executable,"-B","-c",self.PRODUCER,str(REPO/"tests/docker-image-gc-realtime.py"),
                                   str(channel.send_fd),str(channel.ack_fd),json.dumps(channel.identity),str(events),mode,str(notify),str(block)],
                                  pass_fds=(channel.send_fd,channel.ack_fd,notify,block),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            proc.events=events;proc.evidence=channel;proc.role="proc"
            channel.attach(proc.pid);os.close(notify);os.close(block)
            lane=object.__new__(r.Lane)
            lane.case=case;lane.stop_plan=r.STOP_PLAN[case];lane.processes=[proc];lane.engines=[]
            try:
                self.assertTrue(select.select([ready],[],[],10)[0],"producer did not reach report barrier")
                self.assertEqual(os.read(ready,1),b"+")
                channel.open_window()
                if planned:lane.stop_at('RT:444' if case=="never-switch-lock" else 'RT:565')
                else:proc.kill()
                proc.communicate(timeout=5)
                self.assertEqual(proc.returncode,-signal.SIGKILL)
                error=None
                try:lane.check_workers()
                except Exception as exc:error=exc
                lane.finalize_evidence()
                self.assertTrue(channel.journal_synced)
                self.assertTrue(channel.eof.is_set())
                records=[json.loads(line) for line in channel.journal.read_text().splitlines()]
                journal_records=[{key:value for key,value in record.items() if key!='_timing'}
                                 for record in records if 'kind' in record]
                self.assertEqual(journal_records,channel.state.records)
                if case.endswith('-r34'):
                    self.assertEqual(len(channel.certify_timing()),1)
                return error
            finally:
                if proc.poll() is None:proc.kill();proc.communicate(timeout=5)
                for fd in (ready,release):os.close(fd)
                channel.abort.set();channel.thread.join(2)

    def test_complete_summary_before_sigkill_preserves_behavioural_kill(self):
        error=self.stopped_report()
        self.assertIsNone(error)
        passed,message=self.r.classify_case('never-switch-lock','the GC takes the lock',True,
                                            self.r.CaseFailure('no destructive call'))
        self.assertTrue(passed,message)

    def test_complete_r34_summary_stop_retains_lifecycle_timing_and_fsync(self):
        self.assertIsNone(self.stopped_report(case='four-acquisitions-r34'))

    def test_incomplete_or_contradictory_summary_still_rejects_planned_kill(self):
        for mode in ('partial','last_seq','rc','identity','pid','violations','setup_error'):
            with self.subTest(mode=mode):
                self.assertIsNotNone(self.stopped_report(mode))

    def test_complete_summary_without_stop_authority_still_rejects_kill(self):
        self.assertIsNotNone(self.stopped_report(planned=False))

    def test_no_request_stop_precedes_the_worker_final_report(self):
        # Retain the reporting-race regression with the corrected observation:
        # the registered mutant locks at 45 s; no partial 55 s summary exists.
        error, kills, _, _, _ = Isolation12cRegressionTests.observe_switch(self, locked_at=45)
        self.assertIsInstance(error, self.r.CaseFailure)
        self.assertLess(kills[0], 55)
        self.assertIn('GC locked the switch lock', str(error))

    def test_case_declares_and_asserts_only_its_auxiliary_exit(self):
        # The real case with injected scheduling/processes, as in the existing
        # live-site regression, must declare 143 before it can reach teardown.
        original=self.r.Lane.close
        seen=[]
        def close(lane):
            aux=lane.processes[-1] if not hasattr(lane.processes[-1],'evidence') else next(
                p for p in lane.processes if not hasattr(p,'evidence'))
            seen.append(aux.expected_exits)
            lane.engines=[];lane.check_workers=lambda:None
            original(lane)
        with mock.patch.object(self.r.Lane,'close',close):
            self.assertIsNone(Isolation9CasePathTests.case_path(self,'four-acquisitions',aux_rc=143,close=True))
        self.assertEqual(seen,[frozenset({143,-signal.SIGKILL})])
        # A behavioural failure before iteration 2 leaves the handler live.
        # Its teardown SIGKILL must not turn the mutant kill into setup failure.
        with tempfile.TemporaryDirectory(prefix='ops327-aux-cleanup-',dir=REPO) as root:
            original_root=self.root;self.root=Path(root)
            try:
                with mock.patch.object(self.r.Lane,'close',close):
                    self.assertIsInstance(Isolation9CasePathTests.case_path(
                        self,'four-acquisitions',fault='RT:578',aux_rc=-signal.SIGKILL,close=True),self.r.CaseFailure)
            finally:self.root=original_root
        self.assertIsInstance(Isolation9CasePathTests.case_path(self,'four-acquisitions',aux_rc=0),self.r.CaseFailure)

    def test_real_shell_trapped_term_exit_requires_per_auxiliary_declaration(self):
        # A real shell/process group reproduces Linux's 128+SIGTERM result.
        proc=subprocess.Popen(['bash','-c',
                              "set -e; trap ':' TERM; \"$1\" -B -c 'import time; print(\"ready\",flush=True); time.sleep(30)'",
                              'auxiliary',sys.executable],
                              start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            self.assertEqual(proc.stdout.readline().strip(),'ready')
            # The foreground child published ready; the trap preserves its
            # signal exit status when set -e unwinds the shell.
            os.killpg(proc.pid,signal.SIGTERM)
            proc.communicate(timeout=5)
            self.assertEqual(proc.returncode,128+signal.SIGTERM)
            lane=object.__new__(self.r.Lane);lane.processes=[proc];lane.engines=[];lane.check_workers=lambda:None
            with self.assertRaisesRegex(self.r.EvidenceError,'auxiliary failed: 143'):lane.close()
            proc.expected_exits=frozenset({143,-signal.SIGKILL})
            lane.close()
            for code in (0,1,-signal.SIGTERM):
                lane.processes=[types.SimpleNamespace(returncode=code,poll=lambda:code,wait=lambda timeout:code,
                    stdout=None,stderr=None,expected_exits=proc.expected_exits)]
                with self.subTest(code=code),self.assertRaises(self.r.EvidenceError):lane.close()
            other=subprocess.Popen([sys.executable,'-B','-c','raise SystemExit(143)'])
            other.wait(timeout=5);lane.processes=[other]
            with self.assertRaisesRegex(self.r.EvidenceError,'auxiliary failed: 143'):lane.close()
            cleanup=subprocess.Popen([sys.executable,'-B','-c',
                                      'import time; print("ready",flush=True); time.sleep(30)'],
                                     start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            cleanup.owned_group=True;cleanup.expected_exits=proc.expected_exits
            try:
                self.assertEqual(cleanup.stdout.readline().strip(),'ready')
                lane.processes=[cleanup];lane.close()
                self.assertEqual(cleanup.returncode,-signal.SIGKILL)
            finally:
                if cleanup.poll() is None:os.killpg(cleanup.pid,signal.SIGKILL);cleanup.communicate(timeout=5)
        finally:
            if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL);proc.communicate(timeout=5)


class Isolation10StopPathTests(unittest.TestCase):
    setUp = Isolation9EvidenceTests.setUp

    def stop_model(self, case, site, phases, *, pending=False):
        r = self.r
        with tempfile.TemporaryDirectory(prefix="ops327-path-", dir=REPO) as root:
            lane = object.__new__(r.Lane)
            lane.case, lane.stop_plan, lane.processes = case, r.STOP_PLAN[case], []
            for role, witnesses in phases.items():
                state, send = Isolation9EvidenceTests.state(self, witnesses)
                if pending:
                    send("GUARD_BEGIN", id="unfinished")
                channel = object.__new__(r.WorkerEvidence)
                channel.state, channel.identity = state, self.identity
                channel.errors, channel.stop, channel.window_started = [], None, 0.0
                channel.sidecar_waits = []
                channel.lock, channel.case = threading.RLock(), case
                channel.journal = Path(root) / (role + ".journal")
                proc = types.SimpleNamespace(role=role, evidence=channel, returncode=None)
                proc.poll = lambda proc=proc: proc.returncode
                proc.kill = lambda proc=proc: setattr(proc, "returncode", -9)
                lane.processes.append(proc)
            lane.stop_at(site)
            for proc in lane.processes:
                self.assertEqual(proc.returncode, -9)
                proc.evidence.state.validate(-9, None, proc.evidence.stop)
            return [proc.evidence.stop for proc in lane.processes]

    def test_complete_predeclared_paths_all_35_cases(self):
        r = self.r
        self.assertEqual(set(r.STOP_PATHS), set(r.CASES))
        self.assertEqual(len(r.STOP_PATHS), 35)
        for case, sites in r.STOP_PATHS.items():
            self.assertEqual(set(sites), set(r.STOP_PLAN[case]))
            for site, paths in sites.items():
                self.assertEqual(paths[0], r.STOP_PLAN[case][site])
                for path in paths:
                    if not path:
                        continue
                    with self.subTest(case=case, site=site, path=path):
                        self.stop_model(case, site, path)
                        for role, required in path.items():
                            for removed in required:
                                incomplete = {**path, role: tuple(p for p in required if p != removed)}
                                with self.assertRaises(r.EvidenceError):
                                    self.stop_model(case, site, incomplete)

    def test_instance_bypass_requires_first_destructive_and_second_cooldown(self):
        primary, bypass = self.r.STOP_PATHS['instance-and-sigkill']['RT:457']
        self.assertEqual(bypass, {'first': ('main-entered', 'destructive-phase'),
                                  'second': ('main-entered', 'cooldown')})
        self.stop_model('instance-and-sigkill', 'RT:457', primary)
        stops = self.stop_model('instance-and-sigkill', 'RT:457', bypass)
        self.assertEqual(stops[1]['required'], ['main-entered', 'cooldown'])
        for incomplete in (
                {**bypass, 'first': ('main-entered',)},
                {**bypass, 'second': ('main-entered',)},
                {**bypass, 'second': ('cooldown', 'instance-attempt')}):
            with self.assertRaises(self.r.EvidenceError):
                self.stop_model('instance-and-sigkill', 'RT:457', incomplete)
        with self.assertRaises(self.r.EvidenceError):
            self.stop_model('instance-and-sigkill', 'RT:457', bypass, pending=True)

    def test_mutant_incomplete_path_intersection_is_killed(self):
        runner = SocketIsolationTests.helper('docker-image-gc-realtime', [
            ('set(required) <= phases[id(subjects[role])]',
             'bool(set(required) & phases[id(subjects[role])])'),
            ('set(path[process.role]) <= phases[id(process)]',
             'bool(set(path[process.role]) & phases[id(process)])')])
        probe = type(self)('test_instance_bypass_requires_first_destructive_and_second_cooldown')
        probe.setUp = lambda: None
        probe.r, probe.identity = runner, self.identity
        # Mutate arm too: path selection must independently reject an
        # incomplete path rather than relying on that later mandatory check.
        original = runner.WorkerEvidence.arm
        def weak_arm(channel, site, required, until=None, **kwargs):
            remaining = tuple(set(required) & channel.state.phases)
            return original(channel, site, remaining, until, **kwargs)
        with mock.patch.object(runner.WorkerEvidence, 'arm', weak_arm):
            result = unittest.TestResult()
            probe.run(result)
        self.assertFalse(result.errors, result.errors)
        self.assertTrue(result.failures, 'incomplete evidence path mutant survived')

    def test_stop_covers_every_live_worker_with_reused_role(self):
        lane = object.__new__(self.r.Lane)
        lane.case = 'fifo-keep'
        lane.stop_plan = self.r.STOP_PLAN[lane.case]
        lane.processes, trace = [], []
        for index in range(2):
            channel = types.SimpleNamespace(state=types.SimpleNamespace(phases={'main-entered'}), stop=None)
            channel.locked = lambda until: nullcontext()
            channel.arm = lambda site, required, until, index=index, **kwargs: trace.append(('arm', index))
            proc = types.SimpleNamespace(role='proc', evidence=channel, poll=lambda: None)
            proc.kill = lambda index=index: trace.append(('kill', index))
            lane.processes.append(proc)
        lane.stop_at('RT:431')
        self.assertEqual(trace, [('arm', 0), ('arm', 1), ('kill', 0), ('kill', 1)])


class Isolation10TimingTests(unittest.TestCase):
    setUp = Isolation9EvidenceTests.setUp

    def timed_window_model(self, runner=None):
        r = runner or self.r
        with tempfile.TemporaryDirectory(prefix='ops327-window-', dir=REPO) as root:
            root = Path(root)
            channel = r.WorkerEvidence(root, 'worker-1', 's'*64, 'm'*64, 'maximal-hold-r34')
            send, ack = os.dup(channel.send_fd), os.dup(channel.ack_fd)
            publisher = r.EvidencePublisher(send, ack, channel.identity)
            channel.attach(os.getpid())
            guard = HARNESS.FixtureGuard(root, evidence=publisher)
            report = dict(holds=[], attempts=[], violations=guard.violations)
            destructive = []
            @contextmanager
            def lock(*args):
                yield
            def call():
                destructive.append(time.monotonic())
                if len(destructive) == 1:
                    time.sleep(9)
            gc = types.SimpleNamespace(deploy_locks=lock, instance_lock=lock,
                                       destructive_call=call, STOP=types.SimpleNamespace(set=lambda: None))
            def main(sleep=None):
                with gc.instance_lock(), gc.deploy_locks(()):
                    # The review's 68 admissions: two snapshots, four records
                    # per admission, plus the two destructive phase records.
                    for _ in range(2):
                        for _ in range(34):
                            guard.audit('os.listdir', (str(root),))
                        gc.destructive_call()
                return 0
            gc.main = main
            original_fsync, syncs = os.fsync, []
            def slow_disk(fd):
                # A deterministic 4 ms durability latency exposes the previous
                # per-record fsync design. Baseline never pays it in a window.
                original_fsync(fd)
                time.sleep(.004)
                syncs.append(time.monotonic())
            error, rc = None, 0
            try:
                with mock.patch.dict(os.environ, {}), mock.patch.object(r.signal, 'signal'), mock.patch.object(r.os, 'fsync', slow_disk):
                    publisher.send('START')
                    r.instrument_worker(gc, report, publisher)
                    try:
                        rc = r.run_worker_main(gc, publisher)
                    except r.EvidenceError as exc:
                        error, rc = exc, 2
                        # Budget exhaustion can interrupt a guard transaction;
                        # lifecycle END then fails closed too. Keep diagnostic
                        # timing separately, without inventing a clean stream.
                        report['model_instrumentation_error'] = str(exc)
                    if error is None:
                        r.finish_worker_report(root/'events.json', report, publisher, rc)
                    else:
                        report['timing_windows'] = publisher.timing_windows
                        (root/'events.json').write_text(json.dumps(report))
                    publisher.close()
                    channel.thread.join(5)
                    proc = types.SimpleNamespace(events=root/'events.json', poll=lambda: rc, returncode=rc)
                    if error is None:
                        channel.validate(proc)
                    else:
                        with self.assertRaises(r.EvidenceError): channel.validate(proc)
                    for _ in range(2):
                        if error is None:
                            channel.persist()
                        else:
                            try: channel.persist()
                            except r.EvidenceError: pass
                            self.assertTrue(channel.journal_synced)
                    if error is None:
                        parent_totals = channel.certify_timing()
                        self.assertEqual(parent_totals[0]['round_trips'], 275)
                    else:
                        with self.assertRaises(r.EvidenceError):
                            channel.certify_timing()
                        parent_totals = None
                events = json.loads(proc.events.read_text())
                values = [window['instrumentation_s'] for window in events['timing_windows']]
                print('OPS327_TIMING_MODEL ' + json.dumps(dict(
                    mode='baseline' if error is None else 'per-record-fsync',
                    windows_s=values, parent_windows=parent_totals,
                    records=len(channel.state.records), fsyncs=len(syncs))), flush=True)
                return events, error, destructive, syncs
            finally:
                if channel.thread.is_alive():
                    publisher.close()
                    channel.abort.set()
                    channel.thread.join(2)

    def test_evidence_preserves_real_deadlines(self):
        events, error, destructive, syncs = self.timed_window_model()
        self.assertIsNone(error)
        self.r.check_timing_windows(events)
        self.assertEqual(len(events['timing_windows']), 1)
        window = events['timing_windows'][0]
        self.assertEqual(len(window['round_trips']), 275)
        self.assertLessEqual(window['instrumentation_s'], .250)
        self.assertTrue(8.9 <= destructive[1] - events['holds'][0][0] <= 10.1)
        self.assertEqual(len(syncs), 1, 'journal must fsync once, after the window')
        self.assertGreater(syncs[0], window['end'])

    def test_per_record_fsync_mutant_invalidates_timing_lane(self):
        runner = SocketIsolationTests.helper('docker-image-gc-realtime', [
            ('                            os.write(self.ack_write, b"+")',
             '                            os.fsync(journal.fileno())\n                            os.write(self.ack_write, b"+")')])
        events, error, _, _ = self.timed_window_model(runner)
        self.assertIsInstance(error, runner.EvidenceError)
        with self.assertRaises(runner.EvidenceError): runner.check_timing_windows(events)
        for mutant in (None, 'per-record fsync'):
            passed, message = runner.classify_case('maximal-hold-r34', mutant, True, error)
            self.assertFalse(passed)
            self.assertIn('setup:', message)

    def test_timing_summary_rejects_missing_contradictory_and_excessive_values(self):
        window = dict(start=1.0, end=2.0, instrumentation_s=.125, round_trips=[[1.0, 1.125]])
        events = dict(holds=[[1.0, 2.0]], timing_windows=[window])
        self.r.check_timing_windows(events)
        for values in ({}, {**events, 'timing_windows': []},
                       {**events, 'timing_windows': [{**window, 'instrumentation_s': 0}]},
                       {**events, 'timing_windows': [{**window, 'instrumentation_s': .5, 'round_trips': [[1.0, 1.5]]}]},
                       dict(holds=[[1.0, 2.0], [3.0, 4.0]], timing_windows=[window, dict(
                           start=3.0, end=4.0, instrumentation_s=.5, round_trips=[[3.0, 3.5]])])):
            with self.subTest(values=values), self.assertRaises(self.r.EvidenceError):
                self.r.check_timing_windows(values)

    def test_final_durability_failure_is_setup_and_drains_every_worker(self):
        r, trace = self.r, []
        lane_type = r.Lane
        def case(lane):
            trace.append(('case', lane.source))
            if lane.source == 'changed': raise r.CaseFailure('behaviour regressed')
        def lane_factory(args, name, source):
            lane = object.__new__(lane_type)
            lane.source, lane.case = source, 'r29'
            lane.processes = []
            lane.check_workers = lambda: trace.append(('check', source))
            lane.close = lambda: trace.append(('close', source))
            for role in ('first', 'second'):
                def persist(role=role):
                    trace.append(('persist', source, role))
                    if source == 'changed' and role == 'first': raise OSError('durability unavailable')
                lane.processes.append(types.SimpleNamespace(evidence=types.SimpleNamespace(persist=persist)))
            return lane
        output = io.StringIO()
        with mock.patch.dict(r.CASES, {'r29': case}), mock.patch.object(r, 'Lane', side_effect=lane_factory), redirect_stdout(output):
            self.assertEqual(r.run_checks(None, [('r29', None, 'base'), ('r29', 'mutant', 'changed')]), 1)
        self.assertIn('ok r29\n', output.getvalue())
        self.assertIn('(setup: durability unavailable)', output.getvalue())
        self.assertIn(('persist', 'changed', 'second'), trace)
        self.assertLess(trace.index(('close', 'base')), trace.index(('persist', 'base', 'first')))


class Isolation11FinalizationTests(unittest.TestCase):
    setUp = Isolation9EvidenceTests.setUp

    PRODUCER = r'''
import importlib.util,json,os,sys,time
from pathlib import Path
spec=importlib.util.spec_from_file_location("boundary_rt",sys.argv[1])
r=importlib.util.module_from_spec(spec);spec.loader.exec_module(r)
p=r.EvidencePublisher(int(sys.argv[2]),int(sys.argv[3]),json.loads(sys.argv[4]))
mode=sys.argv[5];barrier=Path(sys.argv[6]);block=int(sys.argv[7])
p.send("START");p.send("READY");p.send("PHASE",label="main-entered")
p.begin_timed_window(time.monotonic())
if mode=="first":
    time.sleep(.310);barrier.touch();os.read(block,1)
p.send("PHASE",label="destructive-phase");p.send("GUARD_BEGIN",id="last")
native_read=os.read
def delayed_read(fd,size):
    result=native_read(fd,size)
    if fd==p.ack_fd:
        if mode=="interrupted":
            barrier.touch();native_read(block,1)
        else:time.sleep(.300)
    return result
native_send=p.send
def send(kind,**fields):
    if kind=="RUNTIME_ERROR":
        # Reproduce the publication race, after ALLOW cleared pending state
        # and its complete 300 ms RTT was measured but before sticky error.
        barrier.touch();native_read(block,1)
    return native_send(kind,**fields)
if mode in ("excessive","interrupted"):
    r.os.read=delayed_read;p.send=send
p.send("ALLOW",id="last")
if mode=="clean":p.end_timed_window()
if mode=="unpublished":
    # Local closure alone is insufficient; prevent the dedicated END send.
    p.active_window["end"]=time.monotonic();p.active_window=None
barrier.touch();native_read(block,1)
'''

    def boundary_run(self, mode, mutant='candidate'):
        r, lane_type, channels, output = self.r, self.r.Lane, [], io.StringIO()
        with tempfile.TemporaryDirectory(prefix='ops327-boundary-', dir=REPO) as root:
            root = Path(root)
            def factory(args, name, source):
                lane = object.__new__(lane_type)
                lane.root = root/name; lane.root.mkdir()
                lane.source, lane.case = source, 'maximal-hold-r34'
                lane.processes, lane.engines = [], []
                lane.stop_plan = r.STOP_PLAN[lane.case]
                return lane
            def case(lane):
                channel = r.WorkerEvidence(lane.root, 'worker', 's', 'm', lane.case)
                channels.append(channel)
                block, release = os.pipe()
                barrier, events = lane.root/'barrier', lane.root/'events.json'
                process = subprocess.Popen([
                    sys.executable, '-B', '-c', self.PRODUCER,
                    str(REPO/'tests/docker-image-gc-realtime.py'), str(channel.send_fd),
                    str(channel.ack_fd), json.dumps(channel.identity),
                    'clean' if lane.source == 'base' else mode, str(barrier), str(block)],
                    pass_fds=(channel.send_fd, channel.ack_fd, block))
                process.events, process.evidence, process.role = events, channel, 'proc'
                lane.processes.append(process)
                channel.attach(process.pid)
                os.close(block)
                try:
                    r.wait_for(barrier.exists, 10, 'publication boundary')
                    self.assertEqual(channel.state.records[-1]['kind'],
                                     'WINDOW_END' if lane.source == 'base' or mode == 'clean' else
                                     'WINDOW_BEGIN' if mode == 'first' else 'ALLOW')
                    self.assertFalse(channel.state.pending)
                    self.assertFalse(channel.state.fatal)
                    self.assertFalse(events.exists())
                    channel.open_window()
                    if lane.source == 'base':
                        lane.stop_at('RT:319')
                    else:
                        lane.wait_for('RT:317' if mode == 'first' else 'RT:319',
                                      lambda: False, .01, 'maximal hold')
                finally:
                    os.close(release)
            with mock.patch.object(r, 'Lane', side_effect=factory), \
                 mock.patch.dict(r.CASES, {'maximal-hold-r34': case}), redirect_stdout(output):
                result = r.run_checks(None, [('maximal-hold-r34', None, 'base'),
                                             ('maximal-hold-r34', mutant, 'changed')])
            self.assertTrue(all(channel.journal_synced for channel in channels))
            self.assertIn('ok maximal-hold-r34\n', output.getvalue())
            return result, output.getvalue()

    def test_reportless_300ms_allow_at_rt319_cannot_kill_mutant(self):
        result, output = self.boundary_run('excessive')
        self.assertEqual(result, 1)
        self.assertIn('open window or unpublished window END', output)
        self.assertIn('FAIL maximal-hold-r34 [mutant: candidate] (setup:', output)

    def test_reportless_interrupted_ack_cannot_kill_mutant(self):
        result, output = self.boundary_run('interrupted')
        self.assertEqual(result, 1)
        self.assertIn('open window or unpublished window END forbids sidecar persistence', output)

    def test_reportless_certified_stop_can_kill_mutant(self):
        result, output = self.boundary_run('clean')
        self.assertEqual(result, 0)
        self.assertIn('ok maximal-hold-r34 [mutant: candidate]', output)

    def test_parent_timing_exact_boundary_and_each_window(self):
        channel = object.__new__(self.r.WorkerEvidence)
        channel.lock, channel.thread = threading.RLock(), mock.Mock()
        channel.thread.is_alive.return_value = False
        channel.errors, channel.timing_pending = [], None
        channel.eof = threading.Event(); channel.eof.set()
        channel.state = types.SimpleNamespace(records=[object()], current_window=None, windows={1.0: True})
        channel.timing_confirmed = 1
        channel.timing_windows = {1.0: [(1.0, 1.25)]}
        channel.sidecar_waits = []
        self.assertEqual(channel.certify_timing()[0]['instrumentation_s'], .250)
        for windows in ({1.0: [(1.0, 1.250001)]},
                        {1.0: [(1.0, 1.125)], 2.0: [(2.0, 2.250001)]}):
            channel.timing_windows = windows
            channel.state.windows = dict.fromkeys(windows, True)
            with self.assertRaisesRegex(self.r.EvidenceError, 'exceeds 250 ms'):
                channel.certify_timing()
        channel.timing_windows = {}
        channel.state.windows = {}
        self.assertEqual(channel.certify_timing(), [])  # certified pre-hold stop
        channel.timing_confirmed = 0
        with self.assertRaisesRegex(self.r.EvidenceError, 'missing parent timing'):
            channel.certify_timing()

    def collector_failure(self, injection):
        r, syncs, trace, output = self.r, [], [], io.StringIO()
        with tempfile.TemporaryDirectory(prefix='ops327-fsync-', dir=REPO) as root:
            root = Path(root)
            channel = r.WorkerEvidence(root, 'worker', 's', 'm', 'r29')
            send, ack = os.dup(channel.send_fd), os.dup(channel.ack_fd)
            publisher = r.EvidencePublisher(send, ack, channel.identity)
            native_open, native_write, native_fsync = Path.open, os.write, os.fsync
            writes = 0
            def broken_ack(fd, data):
                nonlocal writes
                if fd == channel.ack_write:
                    writes += 1
                    if writes == 2: raise BrokenPipeError('injected acknowledgement failure')
                return native_write(fd, data)
            class ShortJournal:
                def __init__(self, journal): self.journal, self.writes = journal, 0
                def __enter__(self): return self
                def __exit__(self, *args): self.journal.close()
                def write(self, data):
                    self.writes += 1
                    return self.journal.write(data if self.writes == 1 else data[:1])
            def open_journal(path, *args, **kwargs):
                journal = native_open(path, *args, **kwargs)
                return ShortJournal(journal) if path == channel.journal and args == ('xb',) else journal
            def fsync(fd):
                self.assertFalse(channel.thread.is_alive(), 'final fsync must follow collector stop')
                trace.append('fsync'); syncs.append(fd); native_fsync(fd)
            lane = object.__new__(r.Lane)
            lane.source, lane.case, lane.engines = 'changed', 'r29', []
            process = types.SimpleNamespace(events=root/'events.json', evidence=channel, role='proc',
                                            poll=lambda: -9, returncode=-9, wait=lambda timeout: -9)
            lane.processes = [process]
            def case(lane):
                channel.attach(os.getpid())
                publisher.send('START')  # one valid appended/acknowledged record
                if injection == 'malformed':
                    os.write(send, b'{malformed\n')
                else:
                    with self.assertRaises(r.EvidenceError): publisher.send('READY')
                publisher.close()
                channel.thread.join(5)
                self.assertFalse(channel.thread.is_alive())
                self.assertTrue(channel.errors)
                raise r.CaseFailure('observed mutant behaviour')
            with ExitStack() as stack:
                stack.enter_context(mock.patch.object(r.os, 'fsync', fsync))
                if injection == 'short': stack.enter_context(mock.patch.object(Path, 'open', open_journal))
                if injection == 'ack': stack.enter_context(mock.patch.object(r.os, 'write', broken_ack))
                stack.enter_context(mock.patch.object(r, 'Lane', return_value=lane))
                stack.enter_context(mock.patch.dict(r.CASES, {'r29': case}))
                stack.enter_context(redirect_stdout(output))
                self.assertEqual(r.run_checks(None, [('r29', 'candidate', 'changed')]), 1)
            self.assertEqual(len(syncs), 1)
            self.assertTrue(channel.journal_synced)
            self.assertIn('FAIL r29 [mutant: candidate] (setup:', output.getvalue())
            self.assertIn('cannot persist an incomplete evidence journal', output.getvalue())

    def test_malformed_collector_frame_still_final_fsync_before_setup_score(self):
        self.collector_failure('malformed')

    def test_short_collector_append_still_final_fsync_before_setup_score(self):
        self.collector_failure('short')

    def test_broken_collector_ack_still_final_fsync_before_setup_score(self):
        self.collector_failure('ack')

    def test_all_scoring_paths_finalize_durability_and_timing_first(self):
        r, lane_type = self.r, self.r.Lane
        probe = next(iter(r.REAL_PROBES))
        # outcome, mutant, failure site, case exception, expected success
        routes = [
            ('baseline pass', None, None, None, True),
            ('baseline assertion', None, None, r.CaseFailure('bound'), False),
            ('mutant kill', 'candidate', None, r.CaseFailure('bound'), True),
            ('mutant survives', 'candidate', None, None, False),
            ('probe killed', probe, None, r.CaseFailure('bound'), True),
            ('probe survives', probe, None, None, True),
            ('runtime exception', 'candidate', None, OSError('case failed'), False),
            ('fixture violation', 'candidate', None, r.h.FixtureViolation('open', '/fixture-outside'), False),
            ('initial worker validation', 'candidate', 'initial', r.CaseFailure('bound'), False),
            ('cleanup failure', 'candidate', 'close', r.CaseFailure('bound'), False),
            ('final worker validation', 'candidate', 'final', r.CaseFailure('bound'), False),
            ('final fsync failure', 'candidate', 'fsync', r.CaseFailure('bound'), False),
            ('parent certification failure', 'candidate', 'timing', r.CaseFailure('bound'), False),
            ('probe fsync failure', probe, 'fsync', r.CaseFailure('bound'), False),
            ('probe timing failure', probe, 'timing', r.CaseFailure('bound'), False),
        ]
        for label, mutant, failure, case_error, success in routes:
            with self.subTest(route=label):
                trace, output = [], io.StringIO()
                def factory(args, name, source):
                    lane = object.__new__(lane_type)
                    lane.source, lane.case, lane.processes = source, 'maximal-hold-r34', []
                    checks = 0
                    def step(site):
                        trace.append((source, site))
                        if source == 'changed' and failure == site: raise r.EvidenceError(site)
                    def check():
                        nonlocal checks
                        checks += 1
                        step('initial' if checks == 1 else 'final')
                    lane.check_workers, lane.close = check, lambda: step('close')
                    channel = types.SimpleNamespace(persist=lambda: step('fsync'),
                                                    certify_timing=lambda: step('timing') or [])
                    lane.processes = [types.SimpleNamespace(evidence=channel, role='proc',
                                                           events=types.SimpleNamespace(exists=lambda: False))]
                    return lane
                def case(lane):
                    if lane.source == 'changed' and case_error is not None: raise case_error
                classify = r.classify_case
                def score(*args, **kwargs):
                    trace.append(('score', args[1]))
                    return classify(*args, **kwargs)
                with mock.patch.object(r, 'Lane', side_effect=factory), \
                     mock.patch.dict(r.CASES, {'maximal-hold-r34': case}), \
                     mock.patch.object(r, 'classify_case', side_effect=score), redirect_stdout(output):
                    result = r.run_checks(None, [('maximal-hold-r34', None, 'base'),
                                                 ('maximal-hold-r34', mutant, 'changed')])
                self.assertEqual(result, int(not success), output.getvalue())
                self.assertLess(trace.index(('changed', 'close')), trace.index(('changed', 'fsync')))
                if failure == 'fsync':
                    self.assertNotIn(('changed', 'timing'), trace)
                else:
                    self.assertLess(trace.index(('changed', 'fsync')), trace.index(('changed', 'timing')))
                    self.assertLess(trace.index(('changed', 'timing')), len(trace)-1)
                self.assertEqual(trace[-1], ('score', mutant))
                if failure or isinstance(case_error, (OSError, r.h.FixtureViolation)):
                    self.assertIn('(setup:', output.getvalue())

    def test_constructor_failure_has_no_worker_journal_to_finalize(self):
        output = io.StringIO()
        with mock.patch.object(self.r, 'Lane', side_effect=OSError('fixture construction')), redirect_stdout(output):
            self.assertEqual(self.r.run_checks(None, [('maximal-hold-r34', None, 'base')]), 1)
        self.assertIn('(setup: fixture construction)', output.getvalue())

    def test_live_collector_after_cleanup_failure_stops_before_final_fsync(self):
        r, output, trace = self.r, io.StringIO(), []
        with tempfile.TemporaryDirectory(prefix='ops327-drain-', dir=REPO) as root:
            channel = r.WorkerEvidence(root, 'worker', 's', 'm', 'r29')
            send, ack = os.dup(channel.send_fd), os.dup(channel.ack_fd)
            publisher = r.EvidencePublisher(send, ack, channel.identity)
            channel.attach(os.getpid())
            publisher.send('START')
            native_join, native_fsync = channel.thread.join, os.fsync
            def bounded_join(timeout):
                trace.append(('join', timeout))
                # Model expiration of the first drain wait; the real collector
                # must then receive abort and stop during the second join.
                if timeout != 5: native_join(timeout)
            def fsync(fd):
                self.assertFalse(channel.thread.is_alive())
                trace.append('fsync'); native_fsync(fd)
            lane = object.__new__(r.Lane)
            lane.case, lane.processes = 'r29', [types.SimpleNamespace(evidence=channel)]
            lane.check_workers = lambda: None
            lane.close = mock.Mock(side_effect=OSError('cleanup could not reap worker'))
            try:
                with mock.patch.object(channel.thread, 'join', side_effect=bounded_join), \
                     mock.patch.object(r.os, 'fsync', side_effect=fsync), \
                     mock.patch.object(r, 'Lane', return_value=lane), \
                     mock.patch.dict(r.CASES, {'r29': lambda lane: None}), redirect_stdout(output):
                    self.assertEqual(r.run_checks(None, [('r29', 'candidate', 'changed')]), 1)
                self.assertTrue(channel.journal_synced)
                self.assertTrue(channel.abort.is_set())
                self.assertEqual(trace, [('join', 5), ('join', 1), 'fsync'])
                self.assertIn('evidence drain timeout', output.getvalue())
                self.assertIn('(setup:', output.getvalue())
            finally:
                publisher.close(); channel.abort.set(); native_join(2)


class Isolation12LifecycleTests(unittest.TestCase):
    setUp = Isolation9EvidenceTests.setUp

    def test_first_in_window_stop_is_infrastructure(self):
        result, output = Isolation11FinalizationTests.boundary_run(self, 'first')
        self.assertEqual(result, 1)
        self.assertIn('open window or unpublished window END', output)

    def test_between_records_stop_is_infrastructure(self):
        result, output = Isolation11FinalizationTests.boundary_run(self, 'between')
        self.assertEqual(result, 1)
        self.assertIn('open window or unpublished window END', output)

    def test_unpublished_window_end_cannot_score(self):
        result, output = Isolation11FinalizationTests.boundary_run(self, 'unpublished', 'BatchOver sleeps 5 s')
        self.assertEqual(result, 1)
        self.assertIn('open window or unpublished window END', output)
        self.assertNotIn('KILLED probe', output)
        self.assertNotIn('SURVIVED probe', output)

    PRODUCER = Isolation11FinalizationTests.PRODUCER

    def test_lifecycle_ordering_and_phase_cannot_close_window(self):
        for mode in ('phase', 'duplicate', 'overlap', 'wrong-end', 'pending', 'nan', 'infinite'):
            with self.subTest(mode=mode):
                state, send = Isolation9EvidenceTests.state(self)
                if mode in ('nan', 'infinite'):
                    with self.assertRaises(self.r.EvidenceError):
                        send('WINDOW_BEGIN', window=float(mode if mode == 'nan' else 'inf'))
                    continue
                send('WINDOW_BEGIN', window=1.0)
                if mode == 'phase':
                    send('PHASE', label='WINDOW_END')
                    self.assertEqual(state.current_window, 1.0)
                    self.assertFalse(state.windows[1.0])
                elif mode == 'duplicate':
                    send('WINDOW_END', window=1.0)
                    with self.assertRaises(self.r.EvidenceError): send('WINDOW_BEGIN', window=1.0)
                elif mode == 'overlap':
                    with self.assertRaises(self.r.EvidenceError): send('WINDOW_BEGIN', window=2.0)
                elif mode == 'wrong-end':
                    with self.assertRaises(self.r.EvidenceError): send('WINDOW_END', window=2.0)
                else:
                    send('GUARD_BEGIN', id='pending')
                    with self.assertRaises(self.r.EvidenceError): send('WINDOW_END', window=1.0)

    def test_clock_identity_guard_is_sticky_without_io(self):
        r = self.r
        publisher = r.EvidencePublisher(-1, -1, {'case': 'maximal-hold-r34'})
        publisher.active_window = dict(start=1.0, end=None, instrumentation_s=0.0, round_trips=[])
        with mock.patch.object(r.os, 'write') as write, mock.patch.object(r.os, 'read') as read, \
             mock.patch.object(r.os, 'fsync') as fsync, mock.patch.object(r.select, 'select') as select_call:
            with mock.patch.object(r.time, 'monotonic', lambda: 0):
                with self.assertRaisesRegex(r.EvidenceError, 'clock identity') as first:
                    publisher.send('PHASE', label='destructive-phase')
            with self.assertRaises(r.EvidenceError) as restored:
                publisher.send('PHASE', label='destructive-phase')
            self.assertIs(first.exception, restored.exception)
            self.assertEqual(publisher.sequence, 0)
            self.assertEqual(publisher.active_window['round_trips'], [])
            for operation in (write, read, fsync, select_call): operation.assert_not_called()

    def test_post_end_12s_shape_and_four_window_budget(self):
        r = self.r
        for count in (1, 4):
            with self.subTest(windows=count), tempfile.TemporaryDirectory(dir=REPO) as root:
                channel = r.WorkerEvidence(root, 'worker', 's', 'm', 'maximal-hold-r34')
                publisher = r.EvidencePublisher(os.dup(channel.send_fd), os.dup(channel.ack_fd), channel.identity)
                channel.attach(os.getpid())
                clock, calls, syncs = [0.0], [], []
                read_clock = lambda: clock[0]
                def confirmed():
                    until = time.monotonic()+2
                    while time.monotonic() < until:
                        with channel.locked():
                            if channel.timing_pending is None and channel.timing_confirmed == len(channel.state.records): return
                        time.sleep(.001)
                    self.fail('confirmation did not drain')
                @contextmanager
                def held(*args): yield
                def destructive():
                    confirmed()
                    clock[0] += 9 if len(calls) % 2 == 0 else 29
                    calls.append(clock[0])
                gc = types.SimpleNamespace(deploy_locks=held, instance_lock=held, destructive_call=destructive,
                                           STOP=types.SimpleNamespace(set=lambda: None))
                report = dict(holds=[], attempts=[])
                native_fsync = os.fsync
                def fsync(fd):
                    self.assertFalse(channel.thread.is_alive())
                    self.assertIsNone(publisher.active_window)
                    syncs.append(fd); native_fsync(fd)
                try:
                    with mock.patch.object(r, 'time', types.SimpleNamespace(monotonic=read_clock)), \
                         mock.patch.object(r, '_MONOTONIC', read_clock), \
                         mock.patch.dict(os.environ, {}), mock.patch.object(r.signal, 'signal'), \
                         mock.patch.object(r.os, 'fsync', fsync):
                        publisher.send('START'); publisher.send('READY'); publisher.send('PHASE', label='main-entered')
                        r.instrument_worker(gc, report, publisher)
                        for _ in range(count):
                            with gc.deploy_locks([]):
                                gc.destructive_call(); gc.destructive_call()
                                confirmed()
                                self.assertIsNone(channel.state.current_window)
                            clock[0] += 7  # original 45s watchdog, while a 12s handler wakes at 50
                        publisher.close(); channel.thread.join(2)
                        channel.persist()
                        totals = channel.certify_timing()
                    self.assertEqual(calls[:2], [9, 38])
                    self.assertEqual(len(totals), count)
                    self.assertTrue(all(item['round_trips'] == 3 for item in totals))
                    boundaries = [record['kind'] for record in channel.state.records if record['kind'].startswith('WINDOW_')]
                    self.assertEqual(boundaries, ['WINDOW_BEGIN', 'WINDOW_END']*count)
                    self.assertEqual(len(syncs), 1)
                    stop = dict(identity=channel.identity, case=channel.case, site='RT:319',
                                required=['main-entered', 'destructive-phase'])
                    channel.state.validate(-signal.SIGKILL, None, stop)
                    self.assertTrue(r.classify_case(channel.case, 'BatchOver sleeps 12 s', True,
                                                  r.CaseFailure('45s watchdog'))[0])
                    print(f'OPS327_POST_END windows={count} calls=9,38 end=38 stop=45 wake=50 scoreable=True fsyncs=1')
                finally:
                    if channel.thread.is_alive():
                        publisher.close(); channel.abort.set(); channel.thread.join(2)

    @contextmanager
    def stalled_pair(self):
        """Real collectors; the first stalls in write while owning its real lock."""
        r = self.r
        with tempfile.TemporaryDirectory(prefix='ops327-stalled-', dir=REPO) as root:
            root = Path(root)
            first = r.WorkerEvidence(root, 'first', 's', 'm', 'maximal-hold-r34')
            second = r.WorkerEvidence(root, 'second', 's', 'm', 'maximal-hold-r34')
            blocked, release, stall = threading.Event(), threading.Event(), threading.Event()
            native_open, native_fsync = Path.open, os.fsync
            events, publishers = [], []
            class Journal:
                def __init__(self, journal): self.journal = journal
                def __enter__(self): return self
                def __exit__(self, *args): self.journal.close()
                def write(self, data):
                    if stall.is_set():
                        blocked.set()
                        if not release.wait(60): raise TimeoutError('probe release missing')
                        events.append('first:append')
                    return self.journal.write(data)
            def opened(path, *args, **kwargs):
                journal = native_open(path, *args, **kwargs)
                return Journal(journal) if path == first.journal and args == ('xb',) else journal
            def synced(fd):
                events.append('fsync')
                return native_fsync(fd)
            lane = object.__new__(r.Lane)
            lane.case, lane.engines, lane.stop_plan = 'maximal-hold-r34', [], r.STOP_PLAN['maximal-hold-r34']
            processes = []
            for index, channel in enumerate((first, second)):
                process = types.SimpleNamespace(evidence=channel, events=root/(str(index)+'.events'),
                    role='proc' if index == 0 else 'later', returncode=None if index == 0 else -9)
                process.poll = lambda p=process: p.returncode
                process.kill = lambda p=process: setattr(p, 'returncode', -9)
                process.send_signal = lambda sig: None
                process.wait = lambda timeout, p=process: p.returncode
                processes.append(process)
            lane.processes = processes
            def timed_out(signum, frame): raise TimeoutError('bounded collector probe expired')
            previous = signal.signal(signal.SIGALRM, timed_out)
            try:
                with mock.patch.object(Path, 'open', opened):
                    for channel in (first, second):
                        publisher = r.EvidencePublisher(os.dup(channel.send_fd), os.dup(channel.ack_fd), channel.identity)
                        publishers.append(publisher)
                        channel.attach(os.getpid())
                        publisher.send('START'); publisher.send('READY'); publisher.send('PHASE', label='main-entered')
                    publishers[1].close(); publishers[1] = None
                    second.thread.join(2)
                    self.assertFalse(second.thread.is_alive())
                    stall.set()
                    record = dict(identity=first.identity, pid=os.getpid(), seq=4, kind='PHASE',
                                  label='destructive-phase', _timing=dict(started=r._MONOTONIC(), window=None))
                    os.write(publishers[0].send_fd, json.dumps(record).encode()+b'\n')
                    self.assertTrue(blocked.wait(2))
                    signal.setitimer(signal.ITIMER_REAL, 38)
                    with mock.patch.object(first, 'certify_timing', wraps=first.certify_timing) as certify, \
                         mock.patch.object(second, 'persist', wraps=second.persist) as later, \
                         mock.patch.object(r.os, 'fsync', synced):
                        yield lane, first, second, events, certify, later, release
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
                signal.signal(signal.SIGALRM, previous)
                release.set()
                for channel, publisher in zip((first, second), publishers):
                    if publisher is not None: publisher.close()
                    channel.abort.set(); channel.thread.join(2)

    def test_real_two_worker_finalizer_skips_unsynced_certification(self):
        with self.stalled_pair() as (lane, first, second, events, certify, later, release):
            began = time.monotonic()
            with self.assertRaisesRegex(self.r.EvidenceError, 'unsynced'):
                lane.finalize_evidence()
            self.assertLess(time.monotonic()-began, 8)
            self.assertTrue(first.thread.is_alive())
            self.assertFalse(first.journal_synced)
            certify.assert_not_called(); later.assert_called_once()
            self.assertTrue(second.journal_synced)
            self.assertEqual(events, ['fsync'])  # second only; no live-writer fsync
            print('OPS327_REAL_FINALIZER later_worker_finalized=True first_synced=False fsyncs=1 bounded=True')
            release.set(); first.thread.join(2)
            self.assertIn('first:append', events)
            self.assertFalse(first.journal_synced)

    def test_direct_parent_lock_paths_fail_closed(self):
        channel = object.__new__(self.r.WorkerEvidence)
        channel.lock = threading.RLock()
        with self.assertRaisesRegex(self.r.EvidenceError, 'collector state lock timeout'):
            with channel.locked(self.r._MONOTONIC()-1):
                self.fail('expired deadline granted state access')
        with self.stalled_pair() as (lane, first, second, events, certify, later, release):
            for operation in (first.open_window, lambda: first.arm('RT:319', ['main-entered'])):
                began = time.monotonic()
                with self.assertRaisesRegex(self.r.EvidenceError, 'collector state lock timeout'):
                    operation()
                self.assertLess(time.monotonic()-began, 2)
            with self.assertRaisesRegex(self.r.EvidenceError, 'collector still alive'):
                first.certify_timing()
            self.assertIsNone(first.stop)
            self.assertFalse(first.journal.with_suffix('.stop.json').exists())
            self.assertFalse(first.journal.with_suffix('.window.json').exists())

    def test_unsynced_handoff_cannot_claim_a_late_append_was_synced(self):
        with self.stalled_pair() as (lane, first, second, events, certify, later, release):
            native_fsync = self.r.os.fsync
            def handoff(fd):
                native_fsync(fd)
                release.set(); first.thread.join(2)
            with mock.patch.object(self.r.os, 'fsync', handoff):
                with self.assertRaisesRegex(self.r.EvidenceError, 'unsynced'):
                    lane.finalize_evidence()
            self.assertFalse(first.thread.is_alive())
            self.assertFalse(first.journal_synced)
            self.assertTrue(second.journal_synced)
            certify.assert_not_called(); later.assert_called_once()
            self.assertEqual(events, ['fsync', 'first:append'])

    def test_contradictory_window_membership_is_sticky_infrastructure(self):
        r = self.r
        with tempfile.TemporaryDirectory(dir=REPO) as root:
            channel = r.WorkerEvidence(root, 'worker', 's', 'm', 'maximal-hold-r34')
            publisher = r.EvidencePublisher(os.dup(channel.send_fd), os.dup(channel.ack_fd), channel.identity)
            channel.attach(os.getpid())
            try:
                publisher.send('START'); publisher.send('READY')
                publisher.begin_timed_window(r._MONOTONIC())
                record = dict(identity=channel.identity, pid=os.getpid(), seq=publisher.sequence+1,
                              kind='PHASE', label='destructive-phase',
                              _timing=dict(started=r._MONOTONIC(), window=None))
                os.write(publisher.send_fd, json.dumps(record).encode()+b'\n')
                publisher.close(); channel.thread.join(2)
                self.assertFalse(channel.thread.is_alive())
                self.assertIn('timing membership contradicts', ';'.join(channel.errors))
                with self.assertRaises(r.EvidenceError): channel.persist()
                self.assertTrue(channel.journal_synced)
                with self.assertRaises(r.EvidenceError): channel.certify_timing()
            finally:
                if channel.thread.is_alive():
                    publisher.close(); channel.abort.set(); channel.thread.join(2)

    def stalled_parent_path(self, startup):
        r, output, path_errors = self.r, io.StringIO(), []
        with self.stalled_pair() as (lane, first, second, events, certify, later, release):
            # Use the real runner, teardown, joins and finalizer; neither a fake
            # finalizer nor shortened joins can hide a lock wait here.
            def case(current):
                try:
                    if startup: current.await_ready(current.processes[0])
                    else: current.wait_for('RT:319', lambda: False, .01, 'watchdog')
                except r.EvidenceError as exc:
                    path_errors.append(str(exc))
                    raise
            began = time.monotonic()
            with mock.patch.object(r, 'Lane', return_value=lane), \
                 mock.patch.dict(r.CASES, {'maximal-hold-r34': case}), redirect_stdout(output):
                result = r.run_checks(None, [('maximal-hold-r34', 'candidate', 'changed')])
            self.assertLess(time.monotonic()-began, 36)
            self.assertEqual(result, 1)
            self.assertIn('(setup:', output.getvalue())
            self.assertEqual(path_errors, ['collector state lock timeout'])
            self.assertIn('unsynced', output.getvalue())
            self.assertIsNone(first.stop)
            self.assertFalse(first.journal_synced)
            certify.assert_not_called(); later.assert_called_once()
            self.assertTrue(second.journal_synced)
            self.assertEqual(events, ['fsync'])
            print('OPS327_PARENT_PATH '+('startup' if startup else 'watchdog')+
                  ' finalization_reached=True later_worker_finalized=True bounded=True')

    def test_watchdog_stop_with_stalled_collector_reaches_finalization(self):
        self.stalled_parent_path(False)

    def test_startup_wait_with_stalled_collector_reaches_finalization(self):
        self.stalled_parent_path(True)


ALLOW9 = {
    "root": lambda self: str(self.root),
    "sys_prefix": lambda self: sys.prefix,
    "sys_base_prefix": lambda self: sys.base_prefix,
    "sysconfig_get_path_stdlib": lambda self: HARNESS.sysconfig.get_path("stdlib"),
    "sysconfig_get_path_platstdlib": lambda self: HARNESS.sysconfig.get_path("platstdlib"),
    "nix_store": lambda self: "/nix/store",
    "proc": lambda self: "/proc",
    "dev_null": lambda self: "/dev/null",
}


def allow9_test(entry,kind="R",mutant=False):
    def check(self):
        path=ALLOW9[entry](self)
        guard=HARNESS.FixtureGuard(self.root)
        if mutant:
            guard.entries=[(left,right,frozenset("RWDSL"),exact,anchor) for left,right,kinds,exact,anchor in guard.entries]
        for spelling in dict.fromkeys((path,os.path.realpath(path))):
            if entry=="root" or kind=="R":guard.check("allow",spelling,kind=kind)
            else:
                for denied in "WDSL":
                    with self.assertRaises(HARNESS.FixtureViolation):guard.check("readonly",spelling,kind=denied)
    return check


for _entry in ALLOW9:
    setattr(Isolation9PathTests,"test_allow_"+_entry,allow9_test(_entry))
    setattr(Isolation9PathTests,"test_read_exception_never_writes_"+_entry,allow9_test(_entry,"W"))
    if _entry!="root":
        def mutant(self,entry=_entry):
            with self.assertRaises(AssertionError):allow9_test(entry,"W",True)(self)
        setattr(Isolation9PathTests,"test_mutant_read_exception_"+_entry,mutant)


class Isolation9MutationTests(unittest.TestCase):
    def setUp(self):
        self.base=Path(self.enterContext(tempfile.TemporaryDirectory(prefix="ops327-mutant-",dir=REPO)))
        self.root=self.base/"fixture";self.root.mkdir()
        self.outside=self.base/"outside";self.outside.mkdir()

    def guard_mutant(self,pairs,method):
        helper=SocketIsolationTests.helper("docker-image-gc-harness",pairs)
        probe=Isolation9PathTests(method)
        probe.guard=helper.FixtureGuard(self.root);probe.base=self.base;probe.root=self.root;probe.outside=self.outside
        # FixtureViolation is BaseException; expose only its trusted class to
        # assertRaises while keeping mutation failures as ordinary assertions.
        with mock.patch.object(sys.modules[__name__],"HARNESS",helper):
            try:getattr(probe,method)()
            except helper.FixtureViolation as exc:raise AssertionError("mutant rejected a required positive control") from exc

    def assert_path_mutant_killed(self, pairs, method):
        result = unittest.TestResult()
        unittest.FunctionTestCase(lambda: self.guard_mutant(pairs, method)).run(result)
        self.assertFalse(result.errors, f"path mutant produced setup error: {result.errors}")
        self.assertTrue(result.failures, "surviving path mutant: " + repr(pairs))

    def test_mutant_defaults_fwalk_drops_argument_4(self):
        self.assert_path_mutant_killed([
            ('dir_fd=args[4] if event == "os.fwalk" and len(args) > 4 else None', 'dir_fd=None')
        ], 'test_audit_event_defaults_and_nonpath_none')

    def test_mutant_defaults_import_none_is_cwd(self):
        self.assert_path_mutant_killed([
            ('elif event == "import" and args[1] is not None:\n            self.check(event, args[1])',
             'elif event == "import":\n            self.check(event, args[1] if args[1] is not None else ".")')
        ], 'test_audit_event_defaults_and_nonpath_none')

    def test_mutant_defaults_listdir_scandir_none_omitted(self):
        # Each individual branch must kill too; a shared mutation alone could
        # conceal a missing negative control for the other event.
        for event in ('os.listdir', 'os.scandir', None):
            condition = 'args and args[0] is not None'
            if event is not None:
                condition = f'event != {event!r} or ({condition})'
            with self.subTest(event=event):
                self.assert_path_mutant_killed([
                    ('            self.check(event, args[0] if args and args[0] is not None else ".")',
                     f'            if {condition}:\n                self.check(event, args[0] if args and args[0] is not None else ".")')
                ], 'test_audit_event_defaults_and_nonpath_none')

    def test_mutant_defaults_dlopen_none_is_path(self):
        self.assert_path_mutant_killed([
            ('and args[0] is not None:', 'and True:')
        ], 'test_audit_event_defaults_and_nonpath_none')

    def test_named_path_mutants(self):
        mutations=[
            ([("resolved = _REALPATH(path)","resolved = _REALPATH(lexical)")],"test_raw_symlink_dotdot_resolution"),
            ([("if not self.inside(cwd, self.root):","if False:")],"test_cwd_dirfd_fd"),
            ([("return path == root or path.startswith(root.rstrip(os.sep) + os.sep)","return path.startswith(root)")],"test_fixture_sibling"),
            ([("os.fsdecode(os.fspath(path))","os.fspath(path)")],"test_bytes_pathlike"),
            ([("if event == \"os.listxattr\" and path is None:","if False:")],"test_audit_event_os_listxattr_none_cwd"),
            ([("self.inside(lexical, left) and self.inside(resolved, right)","self.inside(resolved, right)")],"test_nixos_etc_hosts_store_chain"),
        ]
        for pairs,method in mutations:
            # Execute the named test against a source-copy helper. Catch test
            # assertion failures explicitly; unrelated exceptions are not kills.
            with self.subTest(mutant=pairs):
                result=unittest.TestResult()
                probe=unittest.FunctionTestCase(lambda:self.guard_mutant(pairs,method))
                probe.run(result)
                # Mutants producing a Python type error are setup failures and
                # deliberately do not count as kills here.
                if result.errors:
                    self.fail(f"path mutant produced setup error: {pairs}: {result.errors}")
                self.assertTrue(result.failures,"surviving path mutant: "+repr(pairs))

    def test_stale_alias_anchor_mutant_is_killed(self):
        pairs=[('kind in kinds and _REALPATH(left) == anchor and', 'kind in kinds and True and')]
        result=unittest.TestResult()
        probe=unittest.FunctionTestCase(lambda:self.guard_mutant(pairs,"test_alias_retarget_rejects"))
        probe.run(result)
        self.assertFalse(result.errors,result.errors)
        self.assertTrue(result.failures,"stale alias anchor mutant survived")

    def test_fallback_witness_mutant_named_controls(self):
        probe=Isolation9EvidenceTests("test_mutant_fallback_witness_is_killed")
        result=unittest.TestResult();probe.run(result)
        self.assertFalse(result.errors);self.assertFalse(result.failures)

    def test_two_operands_are_one_pending_transaction(self):
        r=SocketIsolationTests.helper("docker-image-gc-realtime")
        log=[]
        class Evidence:
            @contextmanager
            def transaction(self,kind):
                log.append("BEGIN");yield;log.append("ALLOW")
            def send(self,kind,**kw):log.append(kind)
        guard=HARNESS.FixtureGuard(self.root,evidence=Evidence())
        with self.assertRaises(HARNESS.FixtureViolation):guard.audit("os.rename",(str(self.root/"a"),str(self.outside/"b"),-1,-1))
        self.assertEqual(log[0],"BEGIN")
        self.assertEqual(log[-1],"DENY")
        self.assertGreater(log.count("BEGIN"),log.count("ALLOW"))

    def test_f_getpath_resolution_metadata_control(self):
        guard=HARNESS.FixtureGuard(self.root)
        with mock.patch.object(fcntl,"F_GETPATH",99999,create=True):
            guard.audit("fcntl.fcntl",(-1000,99999,0))
        self.assertEqual(guard.violations,[])

    def test_cached_package_origin_rejected(self):
        fake=types.ModuleType("urllib")
        fake.__spec__=importlib.util.spec_from_file_location("urllib",self.outside/"urllib/__init__.py")
        fake.__path__=[str(self.outside)]
        with mock.patch.dict(sys.modules,{"urllib":fake}):
            with self.assertRaisesRegex(ValueError,"untrusted cached stdlib"):
                HARNESS.execute_source("import urllib",self.root)



def facade9_admit_mutant(module,name):
    def check(self):
        if not hasattr(module,name):self.skipTest("native API unavailable on this platform")
        # A removed admission check delegates successfully; the named negative
        # test must fail an assertion rather than touch an external path.
        with mock.patch.object(self.guard,"check"),mock.patch.object(module,name,return_value=object()):
            with self.assertRaises(AssertionError):binding9_test(module,name,admission=True)(self)
    return check


def facade9_cached_mutant(module,name):
    def check(self):
        if not hasattr(module,name):self.skipTest("native API unavailable on this platform")
        helper=SocketIsolationTests.helper("docker-image-gc-harness",[
            ('        signature = _NATIVE_SIGNATURES[(self.module is os, name)]',
             '        signature = _NATIVE_SIGNATURES[(self.module is os, name)]\n        cached_delegate = getattr(self.module, name)'),
            ('\n            return getattr(self.module, name)(*args, **kwargs)','\n            return cached_delegate(*args, **kwargs)')])
        signature=HARNESS._NATIVE_SIGNATURES[(module is os,name)]
        values={key:str(self.root) for key in ("path","s","filename","f1","f2")}
        values.update(flags=os.O_RDONLY,mode=os.F_OK,name="PC_NAME_MAX")
        kw={p.name:values[p.name] for p in signature.parameters.values() if p.default is HARNESS.inspect.Parameter.empty}
        first,second=object(),object()
        facade=helper.GuardedOS(helper.FixtureGuard(self.root),module)
        with mock.patch.object(module,name,return_value=first):wrapped=getattr(facade,name)
        with mock.patch.object(module,name,return_value=second):
            with self.assertRaises(AssertionError):self.assertIs(wrapped(**kw),second)
    return check


for _module,_names in ((os,{"open":()} | HARNESS.GuardedOS.OS_METADATA | HARNESS.GuardedOS.OS_WRITES),(os.path,HARNESS.GuardedOS.PATH_METADATA)):
    for _name in _names:
        _label=("os_" if _module is os else "os_path_")+_name
        setattr(Isolation9BindingTests,"test_mutant_drop_admit_"+_label,facade9_admit_mutant(_module,_name))
        setattr(Isolation9BindingTests,"test_mutant_cached_delegate_"+_label,facade9_cached_mutant(_module,_name))


def evidence9_mutant(pairs,method):
    def check(self):
        runner=SocketIsolationTests.helper("docker-image-gc-realtime",pairs)
        probe=Isolation9EvidenceTests(method)
        probe.r=runner;probe.identity=dict(worker="worker-1",token="fixture-token",source="s"*64,manifest="m"*64)
        probe.setUp=lambda:None
        result=unittest.TestResult();probe.run(result)
        self.assertFalse(result.errors,result.errors)
        self.assertTrue(result.failures,"evidence mutant survived: "+repr(pairs))
    return check


EVIDENCE9_MUTANTS = {
    "sigkill_bypasses_existing_summary": ([('if summary is not None:', 'if summary is not None and rc >= 0:')], "test_sigkill_validates_all_existing_end_and_summary_first"),
    "summary_not_validated": ([('if summary is not None:', 'if False:')], "test_final_summary_agrees"),
    "natural_report_not_required": ([('if self.end is None or summary is None:', 'if False:')], "test_natural_exit_requires_end_and_report"),
    "missing_start_allowed": ([('not self.records and kind != "START"', 'False')], "test_start_setup_scope_and_ready_required"),
    "missing_ready_or_pending_allowed": ([('if not self.records or not self.ready or self.pending or self.fatal:', 'if False:')], "test_start_setup_scope_and_ready_required"),
    "pending_denial_cleanup_allowed": ([('if not self.records or not self.ready or self.pending or self.fatal:', 'if False:')], "test_cleanup_sigkill_pending_denial_never_kills"),
    "wrong_identity_allowed": ([('record["identity"] != self.identity', 'False')], "test_record_identity_sequence_eof"),
    "wrong_sequence_allowed": ([('record["seq"] != len(self.records) + 1', 'False')], "test_record_identity_sequence_eof"),
    "end_errors_allowed": ([('if type(record["rc"]) is not int or record["rc"] < 0 or record["violations"] != [] or record["setup_error"] is not None:', 'if False:')], "test_sigkill_validates_all_existing_end_and_summary_first"),
    "mandatory_witness_fallback": ([('not set(required) <= self.state.phases', 'not (set(required) & self.state.phases)')], "test_required_witness_removed_before_arm"),
}
for _label,(_pairs,_method) in EVIDENCE9_MUTANTS.items():
    setattr(Isolation9EvidenceTests,"test_mutant_"+_label,evidence9_mutant(_pairs,_method))


class Isolation9LinuxLaneTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "linux", "Linux AF_UNIX backlog and both native connect mutants are coordinator lane")
    def test_accept_queue_sigkill_preserves_kill(self):
        # The coordinator's full real-time invocation exercises these exact
        # predeclared cases; this unit check guards their assignment.
        runner=SocketIsolationTests.helper("docker-image-gc-realtime")
        for name in ("the timeout update dropped from `connect`","the wrapper bypassed for connection setup"):
            self.assertIn("full-accept-queue",runner.REAL_MUTANTS[name])


if __name__ == "__main__":
    unittest.main()
