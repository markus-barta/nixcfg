"""Unit tests for the csb1 Docker image GC (OPS-327, design round 5).

Pins the protection rules (one snapshot: containers, every NixOS system's compose spec,
keep.d, newest N per repository incl. digest-only refs, keep window, :rollback / newest
prev-* / Janus, the Nix-declared spec), the release baseline (keep.d contract v2: nothing
is deleted unless aeon-live.refs and aeon-previous.refs hold), that every DELETE is decided
on its own fresh snapshot taken at most SNAPSHOT_MAX_AGE_S before it, the batch budget and
deadline checks, the input caps (and the slowest single step at the caps), the
non-blocking locks, SIGTERM, delete-by-ID without untagging, and that only a run under
systemd deletes. MutantTests re-runs targeted tests against harmful edits of the script.
"""

from __future__ import annotations

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
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "hosts" / "csb1" / "docker-image-gc.py"
NOW = 1_800_000_000
DAY = 86400
AEON = "ghcr.io/inspr-at/aeon"

# MutantTests sets this to ("text", source -> source) or ("hook", module -> None).
OVERRIDE = None


def load(declared=(), tmp: Path | None = None):
    source = SCRIPT.read_text()
    if OVERRIDE and OVERRIDE[0] == "text":
        source = OVERRIDE[1](source)
    source = source.replace("@DECLARED_REFS@", json.dumps(list(declared)))
    module = types.ModuleType("docker_image_gc")
    exec(compile(source, str(SCRIPT), "exec"), module.__dict__)
    if tmp is not None:
        module.PROFILES_DIR = str(tmp / "profiles")
        (tmp / "profiles").mkdir(exist_ok=True)
        module.CURRENT_SYSTEM = str(tmp / "current-system")
        module.BOOTED_SYSTEM = str(tmp / "booted-system")
        module.KEEP_DIR = str(tmp / "keep.d")
        (tmp / "keep.d").mkdir(exist_ok=True)
        module.LOCK_PATHS = tuple(str(tmp / f"{n}.lock") for n in ("a", "b", "c"))
    if OVERRIDE and OVERRIDE[0] == "hook":
        OVERRIDE[1](module)
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


def system(path: Path, services: dict[str, str], stack="csb1") -> Path:
    """A NixOS system at path whose compose spec for stack runs services (name -> image)."""
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
    """A tiny Engine: the two list endpoints, DELETE by ID (stateful), build prune."""

    def __init__(self, containers, images, delete=None, on_get=None, after_delete=None):
        self.containers = containers
        self.images = images
        self.delete = delete or {}
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
        if method == "POST" and path.startswith("/build/prune"):
            return 200, json.dumps({"SpaceReclaimed": 0}).encode()
        return 500, b"unexpected"

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

    def fake_sleep(seconds):
        # A run that never ends is a failure, not a hang.
        pauses.append(seconds)
        if len(pauses) > 200:
            raise AssertionError("more than 200 pauses")

    with mock.patch.dict(os.environ, environ, clear=False), redirect_stdout(out), redirect_stderr(err):
        if manual:
            del os.environ["INVOCATION_ID"]
        rc = gc.main(api=api, now=NOW, sleep=sleep or fake_sleep)
    return rc, out.getvalue(), err.getvalue()


def locks_free(gc) -> bool:
    for path in gc.LOCK_PATHS:
        fd = os.open(path, os.O_RDONLY | os.O_CREAT, 0o666)
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
        self.tmp = Path(tempfile.mkdtemp())
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
        roles(self.tmp, [pin(self.L)], [pin(self.P)])

    def api(self, **kwargs):
        return FakeApi(self.containers, self.images, **kwargs)

    def candidates(self) -> list[str]:
        return [self.apps[3]["Id"], self.apps[4]["Id"]]


class PlanTests(unittest.TestCase):
    """The rules on one snapshot, without the release baseline."""

    def setUp(self):
        self.gc = load([])

    def plan(self, containers, images, refs=(), keep=None, days=2, newest=3):
        snap = self.gc.Snapshot(0.0, containers, images, [("sys", {f"s{k}": r for k, r in enumerate(refs)})], keep or {})
        return self.gc.plan(snap, NOW, days, newest, self.gc.Budget(1e6))

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
        self.assertEqual(self.gc.repo_of_tag("reg:5000/app:1"), "reg:5000/app")
        self.assertEqual(self.gc.repo_of_tag("reg:5000/app"), "reg:5000/app")

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

    def test_declared_ref_without_container_is_kept(self):
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
        index = self.gc.Index([a, b, c, d])
        for ref, image in (("redis", a), ("postgres:16-alpine", b), (c["Id"], c), ("any/name:v1@" + dg(4), d)):
            self.assertEqual(index.resolve(ref), {image["Id"]}, ref)
        self.assertEqual(index.resolve("redis:7"), set())

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
        ):
            with self.assertRaises(self.gc.Fatal):
                self.plan(containers, images)

    def test_null_names_are_a_legitimate_untagged_image(self):
        untagged = {**img(1, 30), "RepoTags": None, "RepoDigests": None}
        self.assertEqual(self.ids(self.plan([ctr(img(9, 1))], [untagged])), {untagged["Id"]})


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
        (self.tmp / "current-system").unlink()
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertIn("no compose spec", err)
        self.assertEqual(api.deleted(), [])

    def test_keep_d_missing_or_broken_refuses(self):
        for breakage in ("missing", "bad line", "not utf-8", "short digest"):
            with self.subTest(breakage):
                self.setUp()
                self.world()
                if breakage == "missing":
                    shutil.rmtree(self.tmp / "keep.d")
                elif breakage == "bad line":
                    keep(self.tmp, "x.refs", ["app:3"])
                elif breakage == "not utf-8":
                    (self.tmp / "keep.d" / "x.refs").write_bytes(b"\xff\xfe\n")
                else:
                    keep(self.tmp, "x.refs", ["x@sha256:abc"])
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

            def slow_index(images):
                clock.advance(61)
                return real_index(images)

            self.gc.Index = slow_index
            api = self.api()
            rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(api.deleted(), [])
        self.assertEqual(holds, [61])
        self.assertTrue(locks_free(self.gc))

    def test_stalled_local_read_starts_no_new_operation(self):
        self.world()
        real_read = self.gc.Reader.read
        with fake_clock(self.gc) as clock:

            def stalled(reader, path, cap):
                clock.advance(70)
                return real_read(reader, path, cap)

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
        self.gc.plan(snap, NOW, 2, 3, budget)
        marks.append(time.perf_counter())
        self.total = marks[-1] - marks[0]
        return max(b - a for a, b in zip(marks, marks[1:]))

    def report(self, shape, seconds):
        if os.environ.get("OPS327_TIMING"):
            print(f"\n  {shape}: slowest step {seconds:.3f} s, snapshot + plan {self.total:.2f} s", file=sys.stderr)

    def base(self):
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
                d = gen(self.tmp, g) / "etc" / "compose" / f"s{s}"
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
            d = gen(self.tmp, 1) / "etc" / "compose" / f"s{s}"
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
        server.bind(path)
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

    def test_gets_have_a_watchdog_and_deletes_no_timeout(self):
        self.world()
        api = self.api()
        run(self.gc, api)
        for method, timeout in api.timeouts:
            if method == "GET":
                self.assertLessEqual(timeout, self.gc.GET_WATCHDOG_S)
            elif method == "DELETE":
                self.assertIsNone(timeout)
        self.assertIn("DELETE", [m for m, _ in api.timeouts])


class LockTests(Base):
    """Non-blocking, all or nothing: a deploy that holds one lock and waits on another never deadlocks."""

    def hold(self, path):
        fd = os.open(path, os.O_RDONLY | os.O_CREAT, 0o666)
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
            if threading.current_thread() is main:
                gc_took_a.set()  # the GC takes a first

        def contender():
            fb = os.open(b, os.O_RDONLY | os.O_CREAT, 0o666)
            fa = os.open(a, os.O_RDONLY | os.O_CREAT, 0o666)
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

    def test_other_errors_fail_the_run(self):
        self.world()
        api = self.api(delete={self.apps[3]["Id"]: (500, b"boom")})
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 1, out + err)
        self.assertIn("1 removed, 0 kept, 1 failed", out)


class RunTests(Base):
    """Only a run under systemd deletes; build cache after the images."""

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

    def test_build_cache_is_pruned_after_the_images(self):
        self.world()
        api = self.api()
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(api.calls[-1][0], "POST")
        self.assertIn(urllib.parse.quote(json.dumps({"until": ["48h"]})), api.calls[-1][1])

    def test_bad_env_refuses(self):
        self.world()
        api = self.api()
        rc, out, err = run(self.gc, api, env={"DOCKER_IMAGE_GC_KEEP_DAYS": "0"})
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(api.calls, [])


# Harmful edits of the script. Each must make every listed test fail.
def swap(*pairs):
    def apply(source):
        for old, new in pairs:
            source = source.replace(old, new)
        return source

    apply.pairs = pairs
    return ("text", apply)


def hook(fn):
    return ("hook", fn)


def _reuse_plan(m):
    real, memo = m.plan, {}

    def plan(snap, now, keep_days, keep_newest, budget):
        if id(budget) not in memo:
            memo[id(budget)] = (budget, real(snap, now, keep_days, keep_newest, budget))
        return memo[id(budget)][1]

    m.plan = plan


def _keep_by_metadata(m):
    real, memo = m.Reader.keep, {}

    def keep_(reader):
        sig = tuple(sorted((e.name, e.stat().st_size, e.stat().st_mtime_ns) for e in os.scandir(m.KEEP_DIR)))
        if memo.get("sig") != sig:
            memo["sig"], memo["value"] = sig, real(reader)
        return memo["value"]

    m.Reader.keep = keep_


def _cache_generations(m):
    real, memo = m.Reader.systems, {}

    def systems(reader):
        if id(reader.budget) not in memo:
            memo[id(reader.budget)] = (reader.budget, real(reader))
        return memo[id(reader.budget)][1]

    m.Reader.systems = systems


RESOLVE = "        for ref in refs:\n            for image_id in index.resolve(ref):\n"


def _stale(why):
    return swap(
        ('SOCKET_PATH = "/var/run/docker.sock"', 'STALE = {}\nSOCKET_PATH = "/var/run/docker.sock"'),
        (
            RESOLVE,
            f"        stale = STALE.setdefault((id(budget), why), index) if why == {why!r} else index\n"
            "        for ref in refs:\n            for image_id in stale.resolve(ref):\n",
        ),
    )


FRESH = "FreshSnapshotTests.test_"
MUTANTS = {
    "reuse the batch plan": (
        hook(_reuse_plan),
        [FRESH + "generation_published_before_t0", FRESH + "container_created_before_t0", FRESH + "rank_promotion_is_seen"],
    ),
    "selective staleness (keep.d against the batch listing)": (
        _stale("listed in keep.d"),
        [FRESH + "stale_reference_regression"],
    ),
    "keep.d by metadata": (hook(_keep_by_metadata), [FRESH + "keep_d_content_change_with_identical_metadata"]),
    "newest-N over tags only": (
        swap(("        repos = repositories(image)\n", "        repos = {repo_of_tag(t) for t in tags_of(image)}\n")),
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
                "        self.deletable = [i for i in candidates if AEON_REPO not in repositories(i)] if baseline else candidates\n",
            ),
            (
                '            if p.baseline:\n                print(f"docker-image-gc: release baseline not met ({p.baseline}); nothing deleted")\n                return BASELINE\n',
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
        swap(("KEEP_DIR, name), CAP_KEEP_FILE_BYTES)", "KEEP_DIR, name), 10**9)")),
        ["CapTests.test_keep_file_cap"],
    ),
    "drop an aggregate cap (spec bytes)": (
        swap(("if self.spec_bytes > CAP_SPEC_BYTES_TOTAL:", "if False:")),
        ["CapTests.test_spec_bytes_total_cap"],
    ),
    "cache generation protection": (
        hook(_cache_generations),
        [
            FRESH + "generation_published_before_t0",
            FRESH + "current_system_retargeted_before_t0",
            FRESH + "booted_system_retargeted_before_t0",
        ],
    ),
    "cache spec reference resolution": (
        _stale("declared by a NixOS system on disk"),
        [FRESH + "generation_by_digest_published_before_t0"],
    ),
    "remove the watchdog": (
        swap(("    with watchdog(seconds):\n", "    if True:\n")),
        ["WatchdogTests.test_trickling_get_is_ended_by_the_watchdog"],
    ),
    "give DELETE a timeout": (
        swap(("?noprune=1\", timeout=None,", '?noprune=1", timeout=30,')),
        ["WatchdogTests.test_gets_have_a_watchdog_and_deletes_no_timeout"],
    ),
    "a blocking lock": (
        swap(("fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)", "fcntl.flock(fd, fcntl.LOCK_EX)")),
        ["LockTests.test_lock_contender_is_never_deadlocked"],
    ),
    "untag a multi-repository image": (
        swap(
            (
                '            result = classify(status, body.decode("utf-8", "replace"), image["Id"])\n',
                '            if status == 409 and b"referenced in" in body:\n'
                '                for name in tags_of(image):\n'
                '                    api("DELETE", "/images/" + urllib.parse.quote(name, safe="/:@") + "?noprune=1", timeout=None, limit=CAP_RESPONSE_BYTES)\n'
                '            result = classify(status, body.decode("utf-8", "replace"), image["Id"])\n',
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
}


class MutantTests(unittest.TestCase):
    def test_every_mutant_is_caught(self):
        global OVERRIDE
        source = SCRIPT.read_text()
        module = sys.modules[__name__]
        for name, (override, tests) in MUTANTS.items():
            with self.subTest(mutant=name):
                for old, _ in getattr(override[1], "pairs", ()):
                    self.assertEqual(source.count(old), 1, f"mutant {name!r} does not apply: {old!r}")
                for test in tests:
                    OVERRIDE = override
                    try:
                        suite = unittest.defaultTestLoader.loadTestsFromName(test, module)
                        result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(suite)
                    finally:
                        OVERRIDE = None
                    self.assertEqual(result.testsRun, 1, test)
                    self.assertFalse(result.wasSuccessful(), f"mutant {name!r} passed {test}")


if __name__ == "__main__":
    unittest.main()
