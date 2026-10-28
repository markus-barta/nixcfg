"""Unit tests for the csb1 Docker image GC (OPS-327).

Pins what is protected (container use, the running compose spec, every NixOS
generation's compose spec, the current/previous pin per service from the
persisted history, :rollback / :prestaged tags, Janus repositories, newest N
per repository incl. digest-only refs, keep window), that a broken listing or
history removes nothing, that removal deletes by ID without pruning parents
and re-checks names before untagging, that batches hold the deploy locks and
re-plan, and that the dry run changes nothing.
"""

from __future__ import annotations

import fcntl
import io
import json
import os
import tempfile
import types
import unittest
import urllib.parse
from contextlib import redirect_stderr, redirect_stdout
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
        module.PROFILE_GLOB = str(tmp / "profiles" / "system-*-link")
        module.SYSTEM_LINKS = ()
        module.HISTORY_PATH = str(tmp / "history.json")
        module.LOCK_PATHS = (str(tmp / "a.lock"), str(tmp / "b.lock"))
    return module


def generations(tmp: Path, specs: list[dict[str, str]], first: int = 1) -> None:
    """One NixOS system per spec (services -> image), numbered from first."""
    for n, services in enumerate(specs, start=first):
        d = tmp / "profiles" / f"system-{n}-link" / "etc" / "compose" / "csb1"
        d.mkdir(parents=True)
        spec = {"services": {k: {"image": v} for k, v in services.items()}}
        spec["services"]["builder"] = {"build": {"context": "."}}
        (d / "docker-compose.yml").write_text(json.dumps(spec))


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

    def drop(self, ref):
        for image in list(self.images):
            if image["Id"] == ref:
                self.images.remove(image)
            for key in ("RepoTags", "RepoDigests"):
                if ref in image[key]:
                    image[key].remove(ref)

    def __call__(self, method, path):
        self.calls.append((method, path))
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


def run(gc, api, dry=False, env=None):
    out, err = io.StringIO(), io.StringIO()
    environ = {"DOCKER_IMAGE_GC_DRY_RUN": "1" if dry else "0", **(env or {})}
    with mock.patch.dict(os.environ, environ, clear=False), redirect_stdout(out), redirect_stderr(err):
        rc = gc.main(api=api, now=NOW, sleep=lambda s: None)
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

    def test_rollback_and_prestaged_tags_are_kept(self):
        r = img(1, 40, tags=["site:rollback"])
        p = img(2, 40, tags=["ghcr.io/inspr-at/aeon:prestaged-143"])
        q = img(3, 40, tags=["site:notprestaged"])
        newer = [img(10 + k, 30, tags=[f"site:v{k}", f"ghcr.io/inspr-at/aeon:v{k}"]) for k in range(3)]
        reasons, remove = self.plan([ctr(img(99, 1))], [r, p, q, *newer])
        self.assertEqual(reasons[r["Id"]], "tagged :rollback / :prestaged")
        self.assertEqual(reasons[p["Id"]], "tagged :rollback / :prestaged")
        self.assertIn(q["Id"], self.ids(remove))

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


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.gc = load([], self.tmp)

    def replay(self, history, pins):
        return self.gc.update_history(history, [(str(i), {"csb1/aeon": p}) for i, p in enumerate(pins)])

    def test_keeps_current_and_previous_pin(self):
        h = self.replay({"services": {}}, ["v1", "v1", "v2", "v3", "v3"])
        self.assertEqual(h["services"]["csb1/aeon"], ["v2", "v3"])
        self.assertEqual(self.replay(h, ["v1", "v2", "v3"]), h, "replaying the same generations is stable")

    def test_rollback_generation_makes_the_rolled_back_pin_previous(self):
        h = self.replay({"services": {}}, ["v1", "v2", "v3", "v2"])
        self.assertEqual(h["services"]["csb1/aeon"], ["v3", "v2"])

    def test_previous_pin_survives_generation_gc(self):
        h = self.replay({"services": {"csb1/aeon": ["v2", "v3"]}}, ["v3"])
        self.assertEqual(h["services"]["csb1/aeon"], ["v2", "v3"])

    def test_generations_are_read_in_numeric_order(self):
        generations(self.tmp, [{"aeon": f"aeon:v{n}"} for n in range(1, 12)], first=1)
        specs = self.gc.generation_specs()
        self.assertEqual([s["csb1/aeon"] for _, s in specs], [f"aeon:v{n}" for n in range(1, 12)])
        self.assertNotIn("csb1/builder", specs[0][1], "build-only services carry no image")

    def test_no_or_broken_compose_spec_refuses(self):
        with self.assertRaises(self.gc.Fatal):
            self.gc.generation_specs()
        generations(self.tmp, [{"aeon": "aeon:v1"}])
        (self.tmp / "profiles/system-1-link/etc/compose/csb1/docker-compose.yml").write_text("{not json")
        with self.assertRaises(ValueError):
            self.gc.generation_specs()

    def test_broken_history_refuses_missing_history_is_empty(self):
        self.assertEqual(self.gc.load_history(self.gc.HISTORY_PATH), {"version": 1, "services": {}})
        Path(self.gc.HISTORY_PATH).write_text(json.dumps({"services": {"csb1/aeon": "v1"}}))
        with self.assertRaises(self.gc.Fatal):
            self.gc.load_history(self.gc.HISTORY_PATH)


class RemoveTests(unittest.TestCase):
    def setUp(self):
        self.gc = load([])

    def test_deletes_by_id_without_pruning_parents(self):
        a = img(1, 40, tags=["app:1"], digests=["app@sha256:" + "1" * 64])
        api = FakeApi([], [a])
        self.assertEqual(self.gc.remove_image(api, a), "removed")
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
        self.assertEqual(self.gc.remove_image(api, a), "removed")
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

    def test_name_moved_to_another_image_is_never_deleted(self):
        a = img(1, 40, tags=["app:1", "mirror/app:1"])
        moved = img(2, 0, tags=["app:1"])  # a deploy re-tagged app:1 since the plan
        listed_a = {**a, "RepoTags": ["mirror/app:1"]}
        conflict = (409, b"conflict: image is referenced in multiple repositories")
        api = FakeApi([], [listed_a, moved], delete={a["Id"]: conflict})
        self.assertEqual(self.gc.remove_image(api, a), "kept")
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
                self.assertEqual(self.gc.remove_image(api, a), want, resp)


class MainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.gc = load([], self.tmp)

    def test_dry_run_changes_nothing(self):
        generations(self.tmp, [{"app": "app:9"}])
        used = img(1, 1, tags=["app:9"])
        old = [img(10 + k, 30 + k, tags=[f"app:{k}"]) for k in range(5)]
        api = FakeApi([ctr(used)], [used, *old])
        rc, out, _ = run(self.gc, api, dry=True)
        self.assertEqual(rc, 0)
        self.assertFalse([c for c in api.calls if c[0] != "GET"])
        self.assertIn("would remove", out)
        self.assertIn("3 images would go", out)
        self.assertFalse(Path(self.gc.HISTORY_PATH).exists(), "dry run writes no history")
        self.assertFalse(Path(self.gc.LOCK_PATHS[0]).exists(), "dry run takes no lock")

    def aeon_images(self):
        # v0..v3 by pin; a newer rehearsal build is the newest of the repository.
        v = [img(k, 40 - k, tags=[f"aeon:v{k}"]) for k in range(4)]
        rehearsal = img(50, 10, digests=["aeon@sha256:" + "5" * 64])
        return v, [*v, rehearsal]

    def test_every_generation_pin_is_kept(self):
        generations(self.tmp, [{"aeon": "aeon:v1"}, {"aeon": "aeon:v2"}, {"aeon": "aeon:v3"}], first=5)
        v, images = self.aeon_images()
        api = FakeApi([ctr(v[3])], images)
        rc, out, _ = run(self.gc, api, env={"DOCKER_IMAGE_GC_KEEP_NEWEST": "1"})
        self.assertEqual(rc, 0, out)
        self.assertEqual(api.deletes(), [f"/images/{v[0]['Id']}?noprune=1"], "only the undeclared pin goes")
        self.assertIn("2 declared in a NixOS generation", out)

    def test_previous_pin_survives_generation_gc(self):
        # The generations declaring v1 and v2 were collected; only v3 (running) is left.
        Path(self.gc.HISTORY_PATH).write_text(json.dumps({"version": 1, "services": {"csb1/aeon": ["aeon:v1", "aeon:v2"]}}))
        generations(self.tmp, [{"aeon": "aeon:v3"}], first=8)
        v, images = self.aeon_images()
        api = FakeApi([ctr(v[3])], images)
        rc, out, _ = run(self.gc, api, env={"DOCKER_IMAGE_GC_KEEP_NEWEST": "1"})
        self.assertEqual(rc, 0, out)
        self.assertEqual(sorted(api.deletes()), sorted(f"/images/{v[k]['Id']}?noprune=1" for k in (0, 1)))
        self.assertIn("1 current/previous pin of its service", out)
        history = json.loads(Path(self.gc.HISTORY_PATH).read_text())
        self.assertEqual(history["services"]["csb1/aeon"], ["aeon:v2", "aeon:v3"])

    def test_run_deletes_by_id_and_prunes_old_build_cache(self):
        generations(self.tmp, [{"app": "app:9"}])
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
        generations(self.tmp, [{"app": "app:9"}])
        self.gc.BATCH_S = 0  # one image per batch
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

        api = FakeApi([ctr(used)], [used, *old], after_delete=deploy_starts_using)
        rc, out, _ = run(self.gc, api)
        self.assertEqual(rc, 0, out)
        self.assertEqual(held, [], "no lock was free while deleting")
        self.assertNotIn(f"/images/{old[4]['Id']}?noprune=1", api.deletes())
        self.assertEqual(len(api.deletes()), 2)

    def test_lock_held_by_a_deploy_stops_the_run(self):
        generations(self.tmp, [{"app": "app:9"}])
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
        generations(self.tmp, [{"app": "app:9"}])

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
        generations(self.tmp, [{"app": "app:9"}])
        api = FakeApi([ctr(img(1, 1))], [img(1, 1)])
        rc, _, _ = run(self.gc, api, env={"DOCKER_IMAGE_GC_KEEP_NEWEST": "0"})
        self.assertEqual(rc, 2)
        self.assertEqual(api.calls, [])


if __name__ == "__main__":
    unittest.main()
