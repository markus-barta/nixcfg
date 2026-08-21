"""Unit tests for the fleet drift watch (OPS-187) on csb1.

Pins what pages and what does not: behind+old pages, behind+young+few does not,
diverged/ahead pages as its own problem, current/no-evidence/non-nix/stale hosts
are ignored, an unreadable store is one loud problem, and commit age comes from
a stubbed git lookup (no network).
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CHECKS = REPO / "hosts" / "csb1" / "fleet-drift-checks.py"
ENGINE = REPO / "modules" / "shared" / "fleet-alerts" / "engine.py"

SPEC = importlib.util.spec_from_file_location("engine", ENGINE)
engine = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["engine"] = engine
SPEC.loader.exec_module(engine)


def load_checks(store_path: str):
    source = CHECKS.read_text()
    for k, v in {
        "@NOTIFICATION_ENV@": "/nonexistent/notify.env",
        "@STORE_PATH@": store_path,
        "@NIXCFG_CHECKOUT@": "/nonexistent/nixcfg",
        "@GIT_BIN@": "/nonexistent/git",
    }.items():
        source = source.replace(k, v)
    assert "@" not in source.split("json.load")[0].split("STORE_PATH")[0][-40:]
    module = types.ModuleType("fleet_drift_checks")
    module.__dict__["__file__"] = str(CHECKS)
    exec(compile(source, str(CHECKS), "exec"), module.__dict__)  # noqa: S102
    return module


NOW = 1_800_000_000.0


def host(name, *, relation="current", behind=0, rev="abcdef1234", seen=NOW - 60, is_nix=True, evidence=True):
    fresh = {"nixcfg_comparison": {"relation": relation, "commits_behind": behind, "upstream_revision": "ffff"} if relation else {},
             "deployment_evidence": {"source_revision": rev} if evidence else None}
    return {"name": name, "is_nix": is_nix, "last_seen": seen, "freshness": fresh}


class DriftTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.store = str(Path(self.tmp.name) / "pharos.json")
        self.checks = load_checks(self.store)
        self.ages: dict[str, float | None] = {}
        self.checks.commit_age_days = lambda rev, now: self.ages.get(rev)
        self.checks.time.time = lambda: NOW

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, hosts):
        Path(self.store).write_text(json.dumps(hosts))

    def test_current_hosts_are_silent(self):
        self.write([host("a"), host("b", relation="current", behind=0)])
        self.assertEqual(self.checks.collect(), [])

    def test_behind_and_old_pages(self):
        self.write([host("csb0", relation="behind", behind=3, rev="old00000")])
        self.ages["old00000"] = 9.5
        problems = self.checks.collect()
        self.assertEqual([p.key for p in problems], ["drift:csb0"])
        self.assertIn("3 commits behind", problems[0].text)
        self.assertIn("9 d old", problems[0].text)

    def test_behind_but_young_and_few_is_silent(self):
        self.write([host("hsb1", relation="behind", behind=4, rev="young000")])
        self.ages["young000"] = 1.0
        self.assertEqual(self.checks.collect(), [])

    def test_many_commits_behind_pages_even_without_age(self):
        self.write([host("hsb8", relation="behind", behind=99, rev="d23b1814")])
        problems = self.checks.collect()
        self.assertEqual([p.key for p in problems], ["drift:hsb8"])
        self.assertIn("age unknown", problems[0].text)

    def test_diverged_is_its_own_problem(self):
        self.write([host("x", relation="diverged", behind=None)])
        problems = self.checks.collect()
        self.assertEqual([p.key for p in problems], ["drift:x:relation"])
        self.assertIn("diverged", problems[0].text)

    def test_stale_nonnix_and_no_evidence_are_skipped(self):
        self.write([
            host("gone", relation="behind", behind=999, seen=NOW - 3 * 3600),
            host("mac", relation="behind", behind=999, is_nix=False),
            host("blank", relation=None, evidence=False),
        ])
        self.assertEqual(self.checks.collect(), [])

    def test_unreadable_store_is_one_loud_problem(self):
        problems = self.checks.collect()  # nothing written
        self.assertEqual([p.key for p in problems], ["drift:store"])
        self.assertIn("unwatched", problems[0].text)

    def test_engine_debounce_then_page(self):
        self.write([host("hsb9", relation="behind", behind=99, rev="d23b1814")])
        sent = []
        state = str(Path(self.tmp.name) / "state.json")
        for stamp in (NOW, NOW + 3600):
            engine.run_cycle(state, stamp, self.checks.collect, self.checks.render, lambda t, _i: sent.append(t) or True)
        self.assertEqual(len(sent), 1)
        self.assertIn("Fleet drift", sent[0])
        self.assertIn("hsb9", sent[0])


if __name__ == "__main__":
    unittest.main()
