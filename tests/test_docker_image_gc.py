"""OPS-327 r34 portable unit and source-mutation tests.

Protection, release baseline, grammar, bounded reads, store/specialisation
closure, fresh snapshots, switch observations, every socket method's absolute
deadline, cooldown/run budgets, signals, status codes and buffered output.
Real Unix trickle tests skip only when this sandbox refuses bind; the injected
29/58-second cases and every source mutant still run without a socket server.
"""

from __future__ import annotations

import atexit
import fcntl
import io
import json
import os
import shutil
import signal
import socket
import sys
import tempfile
import threading
import time
import types
import unittest
import urllib.parse
import http.client
from contextlib import ExitStack, contextmanager, redirect_stderr, redirect_stdout, nullcontext
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "hosts" / "csb1" / "docker-image-gc.py"
NOW = 1_800_000_000
DAY = 86400
AEON = "ghcr.io/inspr-at/aeon"

# MutantTests sets this to ("text", source -> source), always on a source copy.
OVERRIDE = None

# Keep each absent socket's private parent alive until this process exits.
# Even a mutant that bypasses the wrapper must never connect to host Docker.
SOCKET_DIRS = ExitStack()
atexit.register(SOCKET_DIRS.close)


def load(declared=(), tmp: Path | None = None):
    source = SCRIPT.read_text()
    if OVERRIDE and OVERRIDE[0] == "text":
        source = OVERRIDE[1](source)
    source = source.replace("@DECLARED_REFS@", json.dumps(list(declared)))
    module = types.ModuleType("docker_image_gc")
    exec(compile(source, str(SCRIPT), "exec"), module.__dict__)
    socket_dir = SOCKET_DIRS.enter_context(tempfile.TemporaryDirectory(prefix="ops327-unit-"))
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
        rc = gc.main(api=api, now=NOW, sleep=fake_sleep)
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
        self.assertEqual(p.reasons[r["Id"]], "tagged :rollback")
        self.assertEqual(p.reasons[prev_new["Id"]], "newest prev-* of its repository")
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
        self.assertEqual(p.reasons[staged["Id"]], "declared by a NixOS system on disk")

    def test_keep_d_refs_are_kept(self):
        held = img(1, 30, digests=["x@" + dg(1)])
        newer = [img(10 + k, 20, digests=[f"x@{dg(10 + k)}"]) for k in range(3)]
        p = self.plan([ctr(img(99, 1))], [held, *newer], keep={"hold.refs": ["x@" + dg(1)]})
        self.assertEqual(p.reasons[held["Id"]], "listed in keep.d")

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
        self.assertEqual(p.reasons[old["Id"]], "declared by a NixOS system on disk")

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
        p = gc.plan(snap, NOW, gc.Budget(1e6))
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
            return real_open(path, *args, **kwargs)

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
                        self.assertEqual(self.gc.switch_lock_used(self.gc.Budget(10)), expected)

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
        snap, p = self.decision()
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
                        outside = Path(tempfile.mkdtemp())
                        self.addCleanup(shutil.rmtree, outside)
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
                            shutil.rmtree(target)
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
        ns = {"BlockingSocket": BlockingSocket}
        exec(compile(source, str(SCRIPT), "exec"), ns)
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
                ns = {"BlockingSocket": BlockingSocket}
                exec(compile(source, str(SCRIPT), "exec"), ns)
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
        # Same 29/58 schedule as the real Unix fixtures, below, without a socket
        # syscall. Each synthetic parser frame selects the corresponding mutant.
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
                ns = {"TrickleSocket": TrickleSocket}
                exec(compile(source, str(SCRIPT), "exec"), ns)
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
        code = f"        import inspect\n        if any(f.function in {frames!r} for f in inspect.stack()): return CALL_DEADLINE_S\n        return left\n"
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


class SocketIsolationTests(unittest.TestCase):
    @staticmethod
    def helper(name):
        import importlib.util
        spec = importlib.util.spec_from_file_location(name, REPO / "tests" / (name + ".py"))
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
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


class MutantTests(unittest.TestCase):
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
                    OVERRIDE = override
                    try:
                        suite = unittest.TestSuite([test_class(method_name)])
                        result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(suite)
                    finally:
                        OVERRIDE = None
                    self.assertEqual(result.testsRun, 1, test)
                    self.assertFalse(result.wasSuccessful(), f"mutant {name!r} passed {test}")
                print(f"ok mutant: {name}", file=sys.stderr)


if __name__ == "__main__":
    unittest.main()
