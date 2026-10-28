"""Unit tests for the csb1 Docker image GC (OPS-327).

Pins what is protected (container use, the running compose spec, every NixOS
generation's compose spec, the current/previous pin per service in activation
order, keep.d refs, :rollback and the newest prev-* tag, Janus repositories, newest N
per repository incl. digest-only refs, keep window), that a broken or unreadable listing,
generation or activation record removes nothing, that rollbacks, unnumbered and re-numbered
activations keep the previous running release, that removal deletes by ID without pruning
parents and re-checks names and protection before every DELETE, that batches hold the deploy
locks for at most BATCH_S (a real timer interrupts a call that overruns) and re-plan, and that
the dry run changes nothing.
"""

from __future__ import annotations

import fcntl
import io
import json
import os
import shutil
import socket
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


def load(declared: list[str], tmp: Path | None = None):
    source = SCRIPT.read_text().replace("@DECLARED_REFS@", json.dumps(declared))
    module = types.ModuleType("docker_image_gc")
    exec(compile(source, str(SCRIPT), "exec"), module.__dict__)
    if tmp is not None:
        module.PROFILES_DIR = str(tmp / "profiles")
        (tmp / "profiles").mkdir(exist_ok=True)
        module.CURRENT_SYSTEM = str(tmp / "current-system")
        module.SYSTEM_LINKS = (module.CURRENT_SYSTEM,)
        module.RECORDS_DIR = str(tmp / "activations")
        (tmp / "activations").mkdir(exist_ok=True)
        module.LOCK_PATHS = (str(tmp / "a.lock"), str(tmp / "b.lock"))
        module.KEEP_DIR = str(tmp / "keep.d")
        (tmp / "keep.d").mkdir(exist_ok=True)
    return module


def system(path: Path, services: dict[str, str]) -> Path:
    """A NixOS system at path whose csb1 compose spec runs services (name -> image)."""
    d = path / "etc" / "compose" / "csb1"
    d.mkdir(parents=True, exist_ok=True)
    spec = {"services": {k: {"image": v} for k, v in services.items()}}
    spec["services"]["builder"] = {"build": {"context": "."}}
    (d / "docker-compose.yml").write_text(json.dumps(spec))
    return path


def generations(tmp: Path, specs: list[dict[str, str]], first: int = 1) -> None:
    """One NixOS system generation per spec (services -> image), numbered from first."""
    for n, services in enumerate(specs, start=first):
        system(tmp / "profiles" / f"system-{n}-link", services)


def activate(gc, tmp: Path, path: Path, record: bool = True) -> None:
    """What the activation script does: record the system, then make it the running one."""
    if record:
        gc.record(str(path))
    link = tmp / "current-system"
    if link.is_symlink():
        link.unlink()
    link.symlink_to(path)


def gen(tmp: Path, n: int) -> Path:
    return tmp / "profiles" / f"system-{n}-link"


def drop_generation(tmp: Path, n: int) -> None:
    shutil.rmtree(gen(tmp, n))


def img(n: int, age_days: float, tags=(), digests=(), size=1_000_000_000):
    return {
        "Id": f"sha256:{n:064x}",
        "Created": int(NOW - age_days * DAY),
        "RepoTags": list(tags),
        "RepoDigests": list(digests),
        "Size": size,
    }


def ctr(image: dict):
    return {"Id": "c" + image["Id"][-6:], "ImageID": image["Id"]}


class FakeApi:
    """A tiny Engine: list endpoints, DELETE by ID or name (stateful), build prune."""

    def __init__(self, containers, images, delete=None, after_delete=None):
        self.containers = containers
        self.images = images
        self.delete = delete or {}
        self.after_delete = after_delete
        self.calls: list[tuple[str, str]] = []
        self.timeouts: list[tuple[str, float | None]] = []

    def drop(self, ref):
        for image in list(self.images):
            if image["Id"] == ref:
                self.images.remove(image)
            for key in ("RepoTags", "RepoDigests"):
                if ref in image[key]:
                    image[key].remove(ref)

    def __call__(self, method, path, timeout=None):
        self.calls.append((method, path))
        self.timeouts.append((method, timeout))
        if method == "GET" and path.startswith("/containers/json"):
            return 200, json.dumps(self.containers).encode()
        if method == "GET" and path.startswith("/images/json"):
            return 200, json.dumps(self.images).encode()
        if method == "GET" and path.startswith("/system/df"):
            return 200, json.dumps({"BuildCache": []}).encode()
        if method == "DELETE":
            ref = urllib.parse.unquote(path[len("/images/") :].split("?")[0])
            resp = self.delete.get(ref)
            if callable(resp):
                resp = resp(self)
            if resp is None:
                self.drop(ref)
                resp = (200, b"[]")
            if self.after_delete:
                self.after_delete(self, ref)
            return resp
        if method == "POST" and path.startswith("/build/prune"):
            return 200, json.dumps({"SpaceReclaimed": 0}).encode()
        return 500, b"unexpected"

    def deletes(self):
        return [p for m, p in self.calls if m == "DELETE"]


@contextmanager
def clocked(gc, api, per_delete: float):
    """A fake monotonic clock that every DELETE advances by per_delete; yields the lock hold times."""
    clock = [1000.0]
    holds: list[float] = []
    real_locks = gc.deploy_locks

    @contextmanager
    def tracked(*args, **kwargs):
        with real_locks(*args, **kwargs):
            start = clock[0]
            try:
                yield
            finally:
                holds.append(clock[0] - start)

    def after_delete(fake, ref):
        clock[0] += per_delete

    api.after_delete = after_delete
    gc.deploy_locks = tracked
    with mock.patch.object(gc.time, "monotonic", lambda: clock[0]):
        yield holds


def run(gc, api, dry=False, env=None):
    out, err = io.StringIO(), io.StringIO()
    environ = {"DOCKER_IMAGE_GC_DRY_RUN": "1" if dry else "0", **(env or {})}
    pauses = []

    def sleep(seconds):
        # main sleeps between batches; a run that never ends is a failure, not a hang.
        pauses.append(seconds)
        if len(pauses) > 50:
            raise AssertionError("more than 50 batches")

    with mock.patch.dict(os.environ, environ, clear=False), redirect_stdout(out), redirect_stderr(err):
        rc = gc.main(api=api, now=NOW, sleep=sleep)
    return rc, out.getvalue(), err.getvalue()


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.gc = load([])

    def plan(self, containers, images, refs=(), days=2, newest=3):
        return self.gc.plan(containers, images, {"declared": list(refs)}, NOW, days, newest)

    def ids(self, remove):
        return {i["Id"] for i in remove}

    def test_used_by_any_container_is_kept(self):
        a = img(1, 30, tags=["app:1"])
        b = img(2, 30, tags=["other:1"])
        filler = [img(10 + k, 1, tags=[f"other:{k + 2}"]) for k in range(3)]
        reasons, remove = self.plan([ctr(a)], [a, b, *filler])
        self.assertEqual(reasons[a["Id"]], "used by a container")
        self.assertIn(b["Id"], self.ids(remove))

    def test_newest_n_per_repository_including_digest_only_refs(self):
        aeon = [img(k, 10 + k, digests=[f"ghcr.io/inspr-at/aeon@sha256:{k:064x}"]) for k in range(1, 6)]
        reasons, remove = self.plan([ctr(img(99, 1))], aeon)
        kept = {i["Id"] for i in aeon[:3]}
        self.assertTrue(kept.isdisjoint(self.ids(remove)))
        self.assertEqual(self.ids(remove), {aeon[3]["Id"], aeon[4]["Id"]})

    def test_registry_port_is_not_a_tag(self):
        self.assertEqual(self.gc.repo_of_tag("reg:5000/app:1"), "reg:5000/app")
        self.assertEqual(self.gc.repo_of_tag("reg:5000/app"), "reg:5000/app")

    def test_rollback_tag_and_newest_prev_tag_are_kept(self):
        r = img(1, 40, tags=["site:rollback"])
        live = img(2, 30, tags=["hausvogt:live", "hausvogt:release-3"])
        prev_new = img(3, 31, tags=["hausvogt:prev-2", "hausvogt:release-2"])
        prev_old = img(4, 32, tags=["hausvogt:prev-1", "hausvogt:release-1"])
        newer = [img(10 + k, 20, tags=[f"site:v{k}", f"hausvogt:build-{k}"]) for k in range(3)]
        reasons, remove = self.plan([ctr(live)], [r, live, prev_new, prev_old, *newer])
        self.assertEqual(reasons[r["Id"]], "tagged :rollback")
        self.assertEqual(reasons[prev_new["Id"]], "newest prev-* of its repository")
        self.assertIn(prev_old["Id"], self.ids(remove))

    def test_janus_repositories_are_always_kept(self):
        engines = [
            img(k, 50 + k, digests=[f"ghcr.io/inspr-at/janus/janus-engine@sha256:{k:064x}"]) for k in range(1, 7)
        ]
        _, remove = self.plan([ctr(img(99, 1))], engines)
        self.assertEqual(remove, [])

    def test_keep_window_protects_young_images(self):
        young = [img(k, 1, tags=[f"hausv-next:{k}"]) for k in range(1, 6)]
        _, remove = self.plan([ctr(img(99, 1))], young)
        self.assertEqual(remove, [])

    def test_declared_ref_without_container_is_kept(self):
        staged = img(1, 30, tags=["ghcr.io/inspr-at/x:v0.1.44"], digests=["ghcr.io/inspr-at/x@sha256:" + "a" * 64])
        newer = [img(10 + k, 20, tags=[f"ghcr.io/inspr-at/x:v{k}"]) for k in range(3)]
        reasons, _ = self.plan(
            [ctr(img(99, 1))], [staged, *newer], refs=["ghcr.io/inspr-at/x:v0.1.44@sha256:" + "a" * 64]
        )
        self.assertEqual(reasons[staged["Id"]], "declared")

    def test_declared_forms(self):
        a = img(1, 30, tags=["redis:latest"])
        b = img(2, 30, tags=["postgres:16-alpine"])
        c = img(3, 30)
        ids = self.gc.declared_ids([a, b, c], ["redis", "postgres:16-alpine", c["Id"]])
        self.assertEqual(ids, {a["Id"], b["Id"], c["Id"]})

    def test_no_containers_refuses(self):
        with self.assertRaises(self.gc.Fatal):
            self.plan([], [img(1, 30, tags=["a:1"])])

    def test_malformed_listing_refuses(self):
        ok = ctr(img(9, 1))
        no_tags = img(1, 30, digests=["ghcr.io/inspr-at/janus/janus-engine@sha256:" + "1" * 64])
        del no_tags["RepoTags"]
        no_digests = img(2, 30, tags=["ghcr.io/inspr-at/janus/janus-engine:v1"])
        del no_digests["RepoDigests"]
        for containers, images in (
            ([{"Id": "c1"}], [img(1, 30)]),
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
        _, remove = self.plan([ctr(img(9, 1))], [untagged])
        self.assertEqual(self.ids(remove), {untagged["Id"]})


class RecordTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.gc = load([], self.tmp)

    def pins(self):
        return sorted(self.gc.release_pins())

    def records(self):
        return [self.gc.load_record(p)["csb1/aeon"] for _, p in self.gc.record_paths()]

    def test_keeps_current_and_previous_pin_in_activation_order(self):
        generations(self.tmp, [{"aeon": f"aeon:v{n}"} for n in (1, 2, 3)])
        for n in (1, 1, 2, 3, 3):
            activate(self.gc, self.tmp, gen(self.tmp, n))
        self.assertEqual(self.records(), ["aeon:v1", "aeon:v2", "aeon:v3"], "a repeated activation is one record")
        self.assertEqual(self.pins(), ["aeon:v2", "aeon:v3"])

    def test_rollback_makes_the_rolled_back_release_previous(self):
        # B, C, rollback to B (an existing generation, no new number), then D.
        generations(self.tmp, [{"aeon": "aeon:B"}, {"aeon": "aeon:C"}, {"aeon": "aeon:D"}])
        for n in (1, 2, 1, 3):
            activate(self.gc, self.tmp, gen(self.tmp, n))
        self.assertEqual(self.pins(), ["aeon:B", "aeon:D"])

    def test_unnumbered_activation_is_a_release(self):
        # `nixos-rebuild test` activates B without a generation; C is switched to later.
        generations(self.tmp, [{"aeon": "aeon:A"}])
        activate(self.gc, self.tmp, gen(self.tmp, 1))
        activate(self.gc, self.tmp, system(self.tmp / "store" / "test-B", {"aeon": "aeon:B"}))
        generations(self.tmp, [{"aeon": "aeon:C"}], first=2)
        activate(self.gc, self.tmp, gen(self.tmp, 2))
        self.assertEqual(self.pins(), ["aeon:B", "aeon:C"])

    def test_generation_numbers_play_no_part(self):
        # The gate's scenario: v2, v3; the profile is recreated, generation 1 is v9, then 2 is v10.
        generations(self.tmp, [{"aeon": "aeon:v2"}, {"aeon": "aeon:v3"}])
        activate(self.gc, self.tmp, gen(self.tmp, 1))
        activate(self.gc, self.tmp, gen(self.tmp, 2))
        drop_generation(self.tmp, 1)
        drop_generation(self.tmp, 2)
        generations(self.tmp, [{"aeon": "aeon:v9"}])
        activate(self.gc, self.tmp, gen(self.tmp, 1))
        generations(self.tmp, [{"aeon": "aeon:v10"}], first=2)
        activate(self.gc, self.tmp, gen(self.tmp, 2))
        drop_generation(self.tmp, 1)
        self.assertEqual(self.pins(), ["aeon:v10", "aeon:v9"])

    def test_first_record_seeds_the_outgoing_system(self):
        generations(self.tmp, [{"aeon": "aeon:v1"}, {"aeon": "aeon:v2"}])
        activate(self.gc, self.tmp, gen(self.tmp, 1), record=False)  # running before the GC module existed
        activate(self.gc, self.tmp, gen(self.tmp, 2))
        self.assertEqual(self.records(), ["aeon:v1", "aeon:v2"])
        self.assertEqual(self.pins(), ["aeon:v1", "aeon:v2"])

    def test_records_are_pruned_and_never_overwritten(self):
        self.gc.RECORDS_KEEP = 3
        generations(self.tmp, [{"aeon": f"aeon:v{n}"} for n in range(1, 6)])
        activate(self.gc, self.tmp, gen(self.tmp, 1))
        real_link, raced = os.link, []

        def link(src, dst):
            if not raced:
                # A concurrent writer takes the number between the listing and the link.
                raced.append(dst)
                Path(dst).write_text(json.dumps({"services": {"csb1/aeon": "aeon:x"}}))
            return real_link(src, dst)

        with mock.patch.object(self.gc.os, "link", link):
            activate(self.gc, self.tmp, gen(self.tmp, 2))
        self.assertEqual(Path(raced[0]).name, f"{2:012d}.json")
        self.assertEqual(self.records(), ["aeon:v1", "aeon:x", "aeon:v2"])
        for n in range(3, 6):
            activate(self.gc, self.tmp, gen(self.tmp, n))
        self.assertEqual([n for n, _ in self.gc.record_paths()], [4, 5, 6])
        self.assertEqual(self.records(), ["aeon:v3", "aeon:v4", "aeon:v5"])
        self.assertEqual(sorted(os.listdir(self.tmp / "activations")), [f"{n:012d}.json" for n in (4, 5, 6)])

    def test_newest_record_must_be_the_running_system(self):
        generations(self.tmp, [{"aeon": "aeon:v1"}, {"aeon": "aeon:v2"}])
        with self.assertRaises(self.gc.Fatal, msg="no record at all"):
            self.gc.release_pins()
        activate(self.gc, self.tmp, gen(self.tmp, 1))
        activate(self.gc, self.tmp, gen(self.tmp, 2), record=False)  # its record failed
        with self.assertRaisesRegex(self.gc.Fatal, "not the running system"):
            self.gc.release_pins()
        # An activation under way: recorded, not yet running.
        activate(self.gc, self.tmp, gen(self.tmp, 1), record=False)
        self.gc.record(str(gen(self.tmp, 2)))
        with self.assertRaisesRegex(self.gc.Fatal, "not the running system"):
            self.gc.release_pins()

    def test_broken_or_missing_records_refuse(self):
        generations(self.tmp, [{"aeon": "aeon:v1"}, {"aeon": "aeon:v2"}])
        activate(self.gc, self.tmp, gen(self.tmp, 1))
        activate(self.gc, self.tmp, gen(self.tmp, 2))
        older = self.gc.record_paths()[0][1]  # not the newest: the running-system check cannot catch it
        for broken in ("{not json", json.dumps({"services": {"csb1/aeon": ["v1"]}}), json.dumps(["v1"])):
            Path(older).write_text(broken)
            with self.assertRaises((self.gc.Fatal, ValueError)):
                self.gc.release_pins()
        shutil.rmtree(self.tmp / "activations")
        with self.assertRaises(FileNotFoundError):
            self.gc.release_pins()

    def test_cli_runs_the_gc_only_without_arguments(self):
        generations(self.tmp, [{"aeon": "aeon:v1"}])
        with mock.patch.object(self.gc, "main", side_effect=AssertionError("GC run")), redirect_stderr(io.StringIO()):
            self.assertEqual(self.gc.cli(["record"]), 64)
            self.assertEqual(self.gc.cli(["--dry-run"]), 64)
            self.assertEqual(self.gc.cli(["record", str(gen(self.tmp, 1))]), 0)
            shutil.rmtree(self.tmp / "activations")
            (self.tmp / "activations").write_text("not a directory")
            self.assertEqual(self.gc.cli(["record", str(gen(self.tmp, 1))]), 1)

    def test_generations_are_read_in_numeric_order(self):
        generations(self.tmp, [{"aeon": f"aeon:v{n}"} for n in range(1, 12)], first=1)
        specs, running = self.gc.generation_specs()
        self.assertEqual([s["csb1/aeon"] for _, s in specs], [f"aeon:v{n}" for n in range(1, 12)])
        self.assertEqual(running, [])
        self.assertNotIn("csb1/builder", specs[0][1], "build-only services carry no image")

    def test_booted_system_is_protected(self):
        # v1 -> v2 -> v3 deployed, the host still booted into v1, v3 running.
        generations(self.tmp, [{"aeon": "aeon:v1"}, {"aeon": "aeon:v2"}, {"aeon": "aeon:v3"}])
        for n in (1, 2, 3):
            activate(self.gc, self.tmp, gen(self.tmp, n))
        drop_generation(self.tmp, 1)
        self.gc.SYSTEM_LINKS = (str(self.tmp / "booted-system"), self.gc.CURRENT_SYSTEM)
        system(self.tmp / "booted-system", {"aeon": "aeon:v1"})
        systems, refsets = self.gc.protection()
        self.assertEqual(systems, 4)
        self.assertIn("aeon:v1", refsets["declared in a NixOS generation"])
        self.assertEqual(sorted(refsets["current/previous pin of its service"]), ["aeon:v2", "aeon:v3"])

    def test_unreadable_generation_refuses(self):
        generations(self.tmp, [{"aeon": "aeon:v1"}, {"aeon": "aeon:v2"}])
        real_listdir = os.listdir

        def listdir(path):
            if "system-1-link" in str(path):
                raise PermissionError(13, "Permission denied", str(path))
            return real_listdir(path)

        with mock.patch.object(self.gc.os, "listdir", listdir), self.assertRaises(PermissionError):
            self.gc.generation_specs()
        with mock.patch.object(self.gc.os, "scandir", side_effect=PermissionError(13, "Permission denied")):
            with self.assertRaises(PermissionError):
                self.gc.generation_specs()
        (self.tmp / "profiles/system-2-link/etc/compose/csb1/docker-compose.yml").unlink()
        with self.assertRaises(FileNotFoundError, msg="a stack without its compose file is not 'no services'"):
            self.gc.generation_specs()

    def test_no_or_broken_compose_spec_refuses(self):
        with self.assertRaises(self.gc.Fatal):
            self.gc.generation_specs()
        generations(self.tmp, [{"aeon": "aeon:v1"}])
        (self.tmp / "profiles/system-1-link/etc/compose/csb1/docker-compose.yml").write_text("{not json")
        with self.assertRaises(ValueError):
            self.gc.generation_specs()


def unprotected() -> bool:
    return False


class RemoveTests(unittest.TestCase):
    def setUp(self):
        self.gc = load([])

    def test_deletes_by_id_without_pruning_parents(self):
        a = img(1, 40, tags=["app:1"], digests=["app@sha256:" + "1" * 64])
        api = FakeApi([], [a])
        self.assertEqual(self.gc.remove_image(api, a, unprotected), "removed")
        self.assertEqual(api.deletes(), [f"/images/{a['Id']}?noprune=1"])

    def test_multi_repository_image_is_untagged_after_a_fresh_check(self):
        a = img(1, 40, tags=["app:1", "mirror/app:1"])
        conflict = (409, b"conflict: unable to delete 123 (must be forced) - image is referenced in multiple repositories")
        state = {"first": True}

        def by_id(api):
            if state.pop("first", False):
                return conflict
            return None

        api = FakeApi([], [a], delete={a["Id"]: by_id})
        self.assertEqual(self.gc.remove_image(api, a, unprotected), "removed")
        self.assertEqual(
            api.calls,
            [
                ("DELETE", f"/images/{a['Id']}?noprune=1"),
                ("GET", "/images/json"),
                ("DELETE", "/images/app:1?noprune=1"),
                ("GET", "/images/json"),
                ("DELETE", "/images/mirror/app:1?noprune=1"),
                ("DELETE", f"/images/{a['Id']}?noprune=1"),
            ],
        )

    def test_protection_is_checked_before_every_delete(self):
        a = img(1, 40, tags=["app:1", "mirror/app:1"])
        conflict = (409, b"conflict: image is referenced in multiple repositories")
        state = {"first": True}

        def by_id(api):
            return conflict if state.pop("first", False) else None

        api = FakeApi([], [a], delete={a["Id"]: by_id})
        checks = []

        def protected():
            checks.append(len(api.deletes()))
            return False

        self.assertEqual(self.gc.remove_image(api, a, protected), "removed")
        self.assertEqual(checks, [0, 1, 2, 3], "one check right before each of the four DELETEs")

        # A kit lists the image after the first untag: the second name and the ID stay.
        b = img(2, 40, tags=["app:2", "mirror/app:2"])
        state["first"] = True
        api = FakeApi([], [b], delete={b["Id"]: by_id})
        self.assertEqual(self.gc.remove_image(api, b, lambda: len(api.deletes()) >= 2), "kept")
        self.assertEqual(api.deletes(), [f"/images/{b['Id']}?noprune=1", "/images/app:2?noprune=1"])
        self.assertEqual(b["RepoTags"], ["mirror/app:2"])

    def test_name_moved_to_another_image_is_never_deleted(self):
        a = img(1, 40, tags=["app:1", "mirror/app:1"])
        moved = img(2, 0, tags=["app:1"])  # a deploy re-tagged app:1 since the plan
        listed_a = {**a, "RepoTags": ["mirror/app:1"]}
        conflict = (409, b"conflict: image is referenced in multiple repositories")
        api = FakeApi([], [listed_a, moved], delete={a["Id"]: conflict})
        self.assertEqual(self.gc.remove_image(api, a, unprotected), "kept")
        self.assertNotIn("/images/app:1?noprune=1", api.deletes())
        self.assertEqual(moved["RepoTags"], ["app:1"])

    def test_classification(self):
        cases = {
            (409, b"conflict: unable to delete x (cannot be forced) - image is being used by running container c"): "skipped",
            (409, b"conflict: unable to delete x (cannot be forced) - image has dependent child images"): "kept",
            (404, b"no such image"): "removed",
            (500, b"boom"): "failed",
        }
        for resp, want in cases.items():
            a = img(1, 40, tags=["app:1"])
            api = FakeApi([], [a], delete={a["Id"]: resp})
            with redirect_stderr(io.StringIO()):
                self.assertEqual(self.gc.remove_image(api, a, unprotected), want, resp)


class MainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.gc = load([], self.tmp)

    def keep(self, name, *lines):
        (self.tmp / "keep.d" / name).write_text("".join(line + "\n" for line in lines))

    def deploy(self, specs, first=1):
        """Generations for specs, each activated in turn (the last one runs)."""
        generations(self.tmp, specs, first)
        for n in range(first, first + len(specs)):
            activate(self.gc, self.tmp, gen(self.tmp, n))

    def app_images(self, n=5):
        used = img(1, 1, tags=["app:9"], digests=["app@sha256:" + "9" * 64])
        old = [img(10 + k, 30 + k, tags=[f"app:{k}"], digests=[f"app@sha256:{10 + k:064x}"]) for k in range(n)]
        return used, old

    def test_keep_d_refs_are_kept(self):
        self.deploy([{"app": "app:9"}])
        used, old = self.app_images()
        self.keep("r143.refs", "# prestaged by the r143 kit", "", f"app@sha256:{12:064x}", f"app:3@sha256:{13:064x}")
        api = FakeApi([ctr(used)], [used, *old])
        rc, out, _ = run(self.gc, api)
        self.assertEqual(rc, 0, out)
        self.assertEqual(api.deletes(), [f"/images/{old[4]['Id']}?noprune=1"])

    def test_keep_d_broken_or_missing_removes_nothing(self):
        self.deploy([{"app": "app:9"}])
        used, old = self.app_images()
        for bad in ("app:3", "app@sha256:short", f"app @sha256:{1:064x}"):
            self.keep("bad.refs", bad)
            api = FakeApi([ctr(used)], [used, *old])
            rc, _, err = run(self.gc, api)
            self.assertEqual((rc, api.deletes()), (2, []), bad)
            self.assertIn("bad.refs:1", err)
        (self.tmp / "keep.d" / "bad.refs").unlink()
        (self.tmp / "keep.d").rmdir()
        api = FakeApi([ctr(used)], [used, *old])
        rc, _, err = run(self.gc, api, dry=True)
        self.assertEqual((rc, api.deletes()), (2, []))
        self.assertIn("keep.d is missing", err)

    def test_keep_d_is_reread_before_every_delete(self):
        self.deploy([{"app": "app:9"}])
        used, old = self.app_images()

        def kit_lists_the_next_candidate(api, ref):
            # After the first delete of the batch a kit lists old[3] (planned, not yet deleted).
            self.keep("r143.refs", f"app@sha256:{13:064x}")

        api = FakeApi([ctr(used)], [used, *old], after_delete=kit_lists_the_next_candidate)
        rc, out, _ = run(self.gc, api)
        self.assertEqual(rc, 0, out)
        self.assertNotIn(f"/images/{old[3]['Id']}?noprune=1", api.deletes())
        self.assertIn("1 kept", out)

    def test_unreadable_older_generation_removes_nothing(self):
        self.deploy([{"app": "app:2"}, {"app": "app:9"}])
        used, old = self.app_images()
        real_listdir = os.listdir

        def listdir(path):
            if "system-1-link" in str(path):
                raise PermissionError(13, "Permission denied", str(path))
            return real_listdir(path)

        api = FakeApi([ctr(used)], [used, *old])
        with mock.patch.object(self.gc.os, "listdir", listdir):
            rc, _, err = run(self.gc, api)
        self.assertEqual((rc, api.deletes()), (2, []))
        self.assertIn("Permission denied", err)

    def test_previous_pin_survives_a_booted_old_system(self):
        # Booted into v1, running v3; v2's generation was collected.
        self.deploy([{"aeon": "aeon:v1"}, {"aeon": "aeon:v2"}, {"aeon": "aeon:v3"}])
        self.gc.SYSTEM_LINKS = (str(gen(self.tmp, 1)), self.gc.CURRENT_SYSTEM)
        drop_generation(self.tmp, 2)
        v, images = self.aeon_images()
        api = FakeApi([ctr(v[3])], images)
        rc, out, _ = run(self.gc, api, env={"DOCKER_IMAGE_GC_KEEP_NEWEST": "1"})
        self.assertEqual(rc, 0, out)
        self.assertEqual(api.deletes(), [f"/images/{v[0]['Id']}?noprune=1"], "v2 stays the previous pin")

    def test_rollback_then_deploy_keeps_the_rolled_back_release(self):
        # v1, v2, rollback to v1, v3; then the generations of v1 and v2 are collected.
        generations(self.tmp, [{"aeon": f"aeon:v{n}"} for n in (1, 2, 3)])
        for n in (1, 2, 1, 3):
            activate(self.gc, self.tmp, gen(self.tmp, n))
        drop_generation(self.tmp, 1)
        drop_generation(self.tmp, 2)
        v, images = self.aeon_images()
        api = FakeApi([ctr(v[3])], images)
        rc, out, _ = run(self.gc, api, env={"DOCKER_IMAGE_GC_KEEP_NEWEST": "1"})
        self.assertEqual(rc, 0, out)
        self.assertEqual(sorted(api.deletes()), sorted(f"/images/{v[k]['Id']}?noprune=1" for k in (0, 2)))

    def test_activation_between_deletes_is_honoured(self):
        self.deploy([{"app": "app:9"}])
        used, old = self.app_images()

        def test_activation_declares_an_old_image(api, ref):
            # `nixos-rebuild test` (no generation) activates a system that runs old[4].
            if not (self.tmp / "store" / "t").exists():
                activate(self.gc, self.tmp, system(self.tmp / "store" / "t", {"app": "app:4"}))

        api = FakeApi([ctr(used)], [used, *old], after_delete=test_activation_declares_an_old_image)
        rc, out, _ = run(self.gc, api)
        self.assertEqual(rc, 0, out)
        self.assertNotIn(f"/images/{old[4]['Id']}?noprune=1", api.deletes())
        self.assertIn("1 kept", out)

    def test_activation_under_way_removes_nothing(self):
        self.deploy([{"app": "app:9"}])
        generations(self.tmp, [{"app": "app:8"}], first=2)
        self.gc.record(str(gen(self.tmp, 2)))  # recorded; /run/current-system not switched yet
        used, old = self.app_images()
        api = FakeApi([ctr(used)], [used, *old])
        rc, _, err = run(self.gc, api)
        self.assertEqual((rc, api.deletes()), (2, []))
        self.assertIn("not the running system", err)

    def test_keep_d_published_between_untags_is_honoured(self):
        self.deploy([{"app": "app:9"}])
        used, old = self.app_images()
        target = old[2]  # the first (newest) candidate, named in two repositories
        for image, tag in ((used, "mirror/app:9"), (old[0], "mirror/app:0"), (old[1], "mirror/app:1"), (target, "mirror/app:2")):
            image["RepoTags"].append(tag)  # target is not among the newest 3 of mirror/app either
        state = {"first": True}

        def by_id(api):
            return (409, b"conflict: image is referenced in multiple repositories") if state.pop("first", False) else None

        def kit_lists_it(api, ref):
            if ref == "app:2":
                self.keep("r150.refs", f"app@sha256:{12:064x}")

        api = FakeApi([ctr(used)], [used, *old], delete={target["Id"]: by_id}, after_delete=kit_lists_it)
        rc, out, _ = run(self.gc, api)
        self.assertEqual(rc, 0, out)
        sent = api.deletes()
        self.assertEqual(sent[:2], [f"/images/{target['Id']}?noprune=1", "/images/app:2?noprune=1"])
        self.assertNotIn("/images/mirror/app:2?noprune=1", sent)
        self.assertEqual(sent.count(f"/images/{target['Id']}?noprune=1"), 1)
        self.assertIn(f"kept {target['Id'][7:19]}", out)

    def test_generation_declared_between_deletes_is_honoured(self):
        self.deploy([{"app": "app:9"}])
        used, old = self.app_images()

        def boot_declares_an_old_image(api, ref):
            # `nixos-rebuild boot` publishes a generation that declares old[4] (planned, not yet deleted).
            generations(self.tmp, [{"app": "app:4"}], first=2)

        api = FakeApi([ctr(used)], [used, *old], after_delete=boot_declares_an_old_image)
        rc, out, _ = run(self.gc, api)
        self.assertEqual(rc, 0, out)
        self.assertNotIn(f"/images/{old[4]['Id']}?noprune=1", api.deletes())
        self.assertEqual(len(api.deletes()), 2)
        self.assertIn("1 kept", out)

    def test_batch_budget_bounds_the_lock_hold(self):
        self.deploy([{"app": "app:9"}])
        used = img(1, 1, tags=["app:9"])
        old = [img(10 + k, 30 + k, tags=[f"app:{k}"]) for k in range(6)]
        api = FakeApi([ctr(used)], [used, *old])
        with clocked(self.gc, api, per_delete=30) as holds:
            rc, out, _ = run(self.gc, api, env={"DOCKER_IMAGE_GC_KEEP_NEWEST": "1"})
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(api.deletes()), 6)
        self.assertLessEqual(max(holds), self.gc.BATCH_S)
        self.assertEqual(holds, [60, 60, 60, 0])
        self.assertEqual([t for m, t in api.timeouts if m == "DELETE"], [60, 30] * 3)
        in_batch = [t for m, t in api.timeouts[2:] if m != "POST"]  # the build prune runs after the locks
        self.assertTrue(all(t is not None and t <= self.gc.BATCH_S for t in in_batch), api.timeouts)

    def test_call_timeout_stops_the_run(self):
        self.deploy([{"app": "app:9"}])
        used, old = self.app_images()
        # old[2] is the first (newest) candidate.
        api = FakeApi([ctr(used)], [used, *old], delete={old[2]["Id"]: lambda fake: (_ for _ in ()).throw(socket.timeout("timed out"))})
        rc, out, err = run(self.gc, api)
        self.assertEqual(rc, 2)
        self.assertEqual(len(api.deletes()), 1)
        self.assertIn("nothing more removed", err)

    def test_no_image_fitting_a_batch_stops_the_run(self):
        self.deploy([{"app": "app:9"}])
        self.gc.DELETE_NEED_S = self.gc.BATCH_S + 1
        used, old = self.app_images()
        api = FakeApi([ctr(used)], [used, *old])
        rc, _, err = run(self.gc, api)
        self.assertEqual((rc, api.deletes()), (2, []))
        self.assertIn("not one image fit", err)

    def test_dry_run_changes_nothing(self):
        self.deploy([{"app": "app:9"}])
        used = img(1, 1, tags=["app:9"])
        old = [img(10 + k, 30 + k, tags=[f"app:{k}"]) for k in range(5)]
        api = FakeApi([ctr(used)], [used, *old])
        before = sorted(os.listdir(self.tmp / "activations"))
        rc, out, _ = run(self.gc, api, dry=True)
        self.assertEqual(rc, 0)
        self.assertFalse([c for c in api.calls if c[0] != "GET"])
        self.assertIn("would remove", out)
        self.assertIn("3 images would go", out)
        self.assertEqual(sorted(os.listdir(self.tmp / "activations")), before, "dry run writes no record")
        self.assertFalse(Path(self.gc.LOCK_PATHS[0]).exists(), "dry run takes no lock")

    def aeon_images(self):
        # v0..v3 by pin; a newer rehearsal build is the newest of the repository.
        v = [img(k, 40 - k, tags=[f"aeon:v{k}"]) for k in range(4)]
        rehearsal = img(50, 10, digests=["aeon@sha256:" + "5" * 64])
        return v, [*v, rehearsal]

    def test_every_generation_pin_is_kept(self):
        self.deploy([{"aeon": "aeon:v1"}, {"aeon": "aeon:v2"}, {"aeon": "aeon:v3"}], first=5)
        v, images = self.aeon_images()
        api = FakeApi([ctr(v[3])], images)
        rc, out, _ = run(self.gc, api, env={"DOCKER_IMAGE_GC_KEEP_NEWEST": "1"})
        self.assertEqual(rc, 0, out)
        self.assertEqual(api.deletes(), [f"/images/{v[0]['Id']}?noprune=1"], "only the undeclared pin goes")
        self.assertIn("2 declared in a NixOS generation", out)

    def test_previous_pin_survives_generation_gc(self):
        # The generations declaring v1 and v2 were collected; only v3 (running) is left.
        self.deploy([{"aeon": "aeon:v1"}, {"aeon": "aeon:v2"}, {"aeon": "aeon:v3"}], first=6)
        drop_generation(self.tmp, 6)
        drop_generation(self.tmp, 7)
        v, images = self.aeon_images()
        api = FakeApi([ctr(v[3])], images)
        rc, out, _ = run(self.gc, api, env={"DOCKER_IMAGE_GC_KEEP_NEWEST": "1"})
        self.assertEqual(rc, 0, out)
        self.assertEqual(sorted(api.deletes()), sorted(f"/images/{v[k]['Id']}?noprune=1" for k in (0, 1)))
        self.assertIn("1 current/previous pin of its service", out)

    def test_run_deletes_by_id_and_prunes_old_build_cache(self):
        self.deploy([{"app": "app:9"}])
        used = img(1, 1, tags=["app:9"])
        old = [img(10 + k, 30 + k, tags=[f"app:{k}"]) for k in range(5)]
        api = FakeApi([ctr(used)], [used, *old])
        rc, out, _ = run(self.gc, api)
        self.assertEqual(rc, 0, out)
        self.assertEqual(api.deletes(), [f"/images/{i['Id']}?noprune=1" for i in old[2:]])
        self.assertIn("3 removed, 0 skipped, 0 kept, 0 failed", out)
        prune = [p for m, p in api.calls if m == "POST"]
        self.assertEqual(len(prune), 1)
        self.assertIn(urllib.parse.quote(json.dumps({"until": ["48h"]})), prune[0])

    def test_every_batch_replans_under_the_lock(self):
        self.deploy([{"app": "app:9"}])
        self.gc.BATCH_S = 45  # a delete takes 30 s below: one image per batch
        used = img(1, 1, tags=["app:9"])
        old = [img(10 + k, 30 + k, tags=[f"app:{k}"]) for k in range(5)]
        held = []

        def deploy_starts_using(api, ref):
            # The locks are held while deleting; after the first delete a deploy
            # starts a container on the oldest candidate.
            for path in self.gc.LOCK_PATHS:
                fd = os.open(path, os.O_RDONLY)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    held.append(path)
                except BlockingIOError:
                    pass
                finally:
                    os.close(fd)
            if not any(c["ImageID"] == old[4]["Id"] for c in api.containers):
                api.containers.append(ctr(old[4]))

        api = FakeApi([ctr(used)], [used, *old])
        with clocked(self.gc, api, per_delete=30) as holds:
            ticking = api.after_delete
            api.after_delete = lambda fake, ref: (ticking(fake, ref), deploy_starts_using(fake, ref))
            rc, out, _ = run(self.gc, api)
        self.assertEqual(rc, 0, out)
        self.assertEqual(holds, [30, 30, 0], "one image per batch, then an empty re-plan")
        self.assertEqual(held, [], "no lock was free while deleting")
        self.assertNotIn(f"/images/{old[4]['Id']}?noprune=1", api.deletes())
        self.assertEqual(len(api.deletes()), 2)

    def test_lock_held_by_a_deploy_stops_the_run(self):
        self.deploy([{"app": "app:9"}])
        self.gc.LOCK_WAIT_S = 0
        fd = os.open(self.gc.LOCK_PATHS[1], os.O_RDONLY | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            used = img(1, 1, tags=["app:9"])
            old = [img(10 + k, 30 + k, tags=[f"app:{k}"]) for k in range(5)]
            api = FakeApi([ctr(used)], [used, *old])
            rc, out, _ = run(self.gc, api)
        finally:
            os.close(fd)
        self.assertEqual(rc, 0)
        self.assertEqual(api.deletes(), [])
        self.assertIn("held by a deploy", out)
        # the other lock was released again, not kept while waiting
        probe = os.open(self.gc.LOCK_PATHS[0], os.O_RDONLY)
        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.close(probe)

    def test_listing_failure_removes_nothing(self):
        self.deploy([{"app": "app:9"}])

        def api(method, path):
            if path.startswith("/containers/json"):
                return 500, b"daemon down"
            raise AssertionError("no further call expected")

        rc, _, err = run(self.gc, api)
        self.assertEqual(rc, 2)
        self.assertIn("nothing removed", err)

    def test_no_generation_removes_nothing(self):
        api = FakeApi([ctr(img(1, 1))], [img(1, 1)])
        rc, _, err = run(self.gc, api)
        self.assertEqual(rc, 2)
        self.assertEqual(api.calls, [])
        self.assertIn("no compose spec", err)

    def test_bad_env_refuses(self):
        self.deploy([{"app": "app:9"}])
        api = FakeApi([ctr(img(1, 1))], [img(1, 1)])
        rc, _, _ = run(self.gc, api, env={"DOCKER_IMAGE_GC_KEEP_NEWEST": "0"})
        self.assertEqual(rc, 2)
        self.assertEqual(api.calls, [])


class TimerTests(unittest.TestCase):
    """The batch bound in real time: the timer interrupts what a socket timeout lets run on."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.gc = load([], self.tmp)

    def trickling_engine(self, path: str) -> None:
        """An Engine on a unix socket whose 200-byte answer arrives one byte every 50 ms."""
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(1)
        stop = threading.Event()

        def serve():
            conn, _ = server.accept()
            with conn:
                conn.recv(65536)
                try:
                    conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 200\r\n\r\n[")
                    for _ in range(199):
                        if stop.wait(0.05):
                            break
                        conn.sendall(b" ")
                except OSError:
                    pass

        threading.Thread(target=serve, daemon=True).start()
        self.addCleanup(server.close)
        self.addCleanup(stop.set)

    def test_timer_interrupts_an_answer_that_keeps_trickling(self):
        path = str(self.tmp / "d.sock")
        self.trickling_engine(path)
        self.gc.SOCKET_PATH = path
        start = time.monotonic()
        with self.assertRaises(self.gc.Interrupted):
            with self.gc.batch_timer(0.3):
                self.gc.docker_api("GET", "/images/json", timeout=60)  # the socket timeout never fires
        self.assertLess(time.monotonic() - start, 1.5)

    def test_lock_hold_is_bounded_when_a_delete_overruns(self):
        generations(self.tmp, [{"app": "app:9"}])
        activate(self.gc, self.tmp, gen(self.tmp, 1))
        self.gc.BATCH_S = 0.4
        self.gc.DELETE_NEED_S = self.gc.GET_NEED_S = 0
        used = img(1, 1, tags=["app:9"])
        old = [img(10 + k, 30 + k, tags=[f"app:{k}"]) for k in range(4)]  # old[2] and old[3] are candidates
        holds: list[float] = []
        real_locks = self.gc.deploy_locks

        @contextmanager
        def timed(*args, **kwargs):
            with real_locks(*args, **kwargs):
                start = time.monotonic()
                try:
                    yield
                finally:
                    holds.append(time.monotonic() - start)

        self.gc.deploy_locks = timed
        api = FakeApi([ctr(used)], [used, *old], delete={old[2]["Id"]: lambda fake: time.sleep(30)})
        start = time.monotonic()
        rc, out, err = run(self.gc, api)
        self.assertLess(time.monotonic() - start, 5)
        self.assertEqual(rc, 1, out + err)
        self.assertLess(max(holds), self.gc.BATCH_S + 0.3, holds)
        self.assertIn(f"timed out {old[2]['Id'][7:19]}", err)
        self.assertEqual(
            api.deletes(), [f"/images/{old[2]['Id']}?noprune=1", f"/images/{old[3]['Id']}?noprune=1"], "not retried"
        )
        self.assertIn("1 removed, 0 skipped, 0 kept, 1 failed", out)


if __name__ == "__main__":
    unittest.main()
