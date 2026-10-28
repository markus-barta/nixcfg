"""Unit tests for the csb1 Docker image GC (OPS-327).

Pins what is protected (container use, declared refs, :rollback, Janus
repositories, newest N per repository incl. digest-only refs, keep window),
that a broken listing removes nothing, how removal results are classified,
and that the dry run changes nothing.
"""

from __future__ import annotations

import io
import json
import os
import types
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "hosts" / "csb1" / "docker-image-gc.py"
NOW = 1_800_000_000
DAY = 86400


def load(declared: list[str]):
    source = SCRIPT.read_text().replace("@DECLARED_REFS@", json.dumps(declared))
    module = types.ModuleType("docker_image_gc")
    exec(compile(source, str(SCRIPT), "exec"), module.__dict__)
    return module


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
    def __init__(self, containers, images, delete=None):
        self.containers = containers
        self.images = images
        self.delete = delete or {}
        self.calls: list[tuple[str, str]] = []

    def __call__(self, method, path):
        self.calls.append((method, path))
        if method == "GET" and path.startswith("/containers/json"):
            return 200, json.dumps(self.containers).encode()
        if method == "GET" and path.startswith("/images/json"):
            return 200, json.dumps(self.images).encode()
        if method == "GET" and path.startswith("/system/df"):
            return 200, json.dumps({"BuildCache": []}).encode()
        if method == "DELETE":
            ref = path[len("/images/") :].split("?")[0]
            return self.delete.get(ref, (200, b"[]"))
        if method == "POST" and path.startswith("/build/prune"):
            return 200, json.dumps({"SpaceReclaimed": 0}).encode()
        return 500, b"unexpected"


def run(gc, api, dry=False):
    out, err = io.StringIO(), io.StringIO()
    env = {"DOCKER_IMAGE_GC_DRY_RUN": "1" if dry else "0"}
    with mock.patch.dict(os.environ, env, clear=False), redirect_stdout(out), redirect_stderr(err):
        rc = gc.main(api=api, now=NOW)
    return rc, out.getvalue(), err.getvalue()


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.gc = load([])

    def plan(self, containers, images, refs=(), days=2, newest=3):
        return self.gc.plan(containers, images, list(refs), NOW, days, newest)

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

    def test_rollback_tag_is_kept(self):
        r = img(1, 40, tags=["site:rollback"])
        newer = [img(10 + k, 30, tags=[f"site:v{k}"]) for k in range(3)]
        reasons, remove = self.plan([ctr(img(99, 1))], [r, *newer])
        self.assertEqual(reasons[r["Id"]], "tagged :rollback")

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
        self.assertEqual(reasons[staged["Id"]], "declared in the compose spec")

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
        for containers, images in (
            ([{"Id": "c1"}], [img(1, 30)]),
            ([ctr(img(9, 1))], [{"Id": "sha256:" + "1" * 64, "Created": "yesterday"}]),
            ({"oops": 1}, []),
        ):
            with self.assertRaises(self.gc.Fatal):
                self.plan(containers, images)


class MainTests(unittest.TestCase):
    def test_dry_run_deletes_nothing(self):
        gc = load([])
        used = img(1, 1, tags=["app:9"])
        old = [img(10 + k, 30 + k, tags=[f"app:{k}"]) for k in range(5)]
        api = FakeApi([ctr(used)], [used, *old])
        rc, out, _ = run(gc, api, dry=True)
        self.assertEqual(rc, 0)
        self.assertFalse([c for c in api.calls if c[0] != "GET"])
        self.assertIn("would remove", out)
        self.assertIn("3 images would go", out)

    def test_removal_untags_then_deletes_and_classifies(self):
        gc = load([])
        used = img(1, 1, tags=["app:9"])
        multi = img(2, 40, tags=["app:1", "mirror/app:1"])
        busy = img(3, 41, tags=["app:2"])
        parent = img(4, 42, tags=["app:3"])
        broken = img(5, 43, tags=["app:4"])
        newest = [img(20 + k, 10, tags=[f"app:n{k}", f"mirror/app:n{k}"]) for k in range(3)]
        api = FakeApi(
            [ctr(used)],
            [used, multi, busy, parent, broken, *newest],
            delete={
                "app:2": (409, b"conflict: unable to remove repository reference \"app:2\" (must force) - container c is using its referenced image"),
                "app:3": (409, b"conflict: unable to delete x (cannot be forced) - image has dependent child images"),
                "app:4": (500, b"boom"),
            },
        )
        rc, out, err = run(gc, api)
        deletes = [p for m, p in api.calls if m == "DELETE"]
        self.assertIn("/images/app:1?noprune=0", deletes)
        self.assertIn("/images/mirror/app:1?noprune=0", deletes)
        self.assertIn(f"/images/{multi['Id']}?noprune=0", deletes)
        self.assertIn("1 removed, 1 skipped, 1 kept, 1 failed", out)
        self.assertEqual(rc, 1)
        self.assertIn("boom", err)
        self.assertTrue(any(m == "POST" and p.startswith("/build/prune?all=1") for m, p in api.calls))

    def test_listing_failure_removes_nothing(self):
        gc = load([])

        def api(method, path):
            if path.startswith("/containers/json"):
                return 500, b"daemon down"
            raise AssertionError("no further call expected")

        rc, _, err = run(gc, api)
        self.assertEqual(rc, 2)
        self.assertIn("nothing removed", err)

    def test_bad_env_refuses(self):
        gc = load([])
        api = FakeApi([ctr(img(1, 1))], [img(1, 1)])
        with mock.patch.dict(os.environ, {"DOCKER_IMAGE_GC_KEEP_NEWEST": "0"}):
            rc, _, err = run(gc, api)
        self.assertEqual(rc, 2)
        self.assertEqual(api.calls, [])


if __name__ == "__main__":
    unittest.main()
