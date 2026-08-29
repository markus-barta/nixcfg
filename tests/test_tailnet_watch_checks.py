"""Unit + engine-integration tests for the shared tailnet witness (OPS-181 csb1, OPS-185 hsb1).

Why this poller exists: on 2026-08-21 headscale served an EMPTY DERP map after a
failed scheduled refresh, every node lost its relay, and nothing paged for ~57
minutes. These tests pin the decisions that make it page (or not):

  * an empty DERP map is a problem; a populated one is not
  * every `.Health` entry pages, keyed by a digest of the message (so reordering
    never re-pages and two different messages never collide) — except exact
    entries in SUPPRESSED_HEALTH
  * "cannot read tailscale" and "tailscale says it is broken" read differently
  * BackendState other than Running is a problem on its own
  * through the real engine: one run does NOT page (confirm-before-alert), the
    second does, and recovery announces a clear — the 10-minute cadence makes
    that ~10–20 min after onset
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CHECKS = REPO / "modules" / "shared" / "fleet-alerts" / "tailnet-watch-checks.py"
ENGINE = REPO / "modules" / "shared" / "fleet-alerts" / "engine.py"

SPEC = importlib.util.spec_from_file_location("engine", ENGINE)
engine = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["engine"] = engine  # dataclasses resolve the module by name at class creation
SPEC.loader.exec_module(engine)


def load_checks():
    """Render the poller the way lib.nix does, then import it against the real engine."""
    source = CHECKS.read_text()
    source = source.replace("@NOTIFICATION_ENV@", "/nonexistent/notify.env")
    source = source.replace("@TAILSCALE_BIN@", "/nonexistent/tailscale")
    source = source.replace("@HOSTNAME@", "csb1")
    assert "@NOTIFICATION_ENV@" not in source and "@TAILSCALE_BIN@" not in source
    assert "@HOSTNAME@" not in source
    module = types.ModuleType("tailnet_watch_checks")
    module.__dict__["__file__"] = str(CHECKS)
    exec(compile(source, str(CHECKS), "exec"), module.__dict__)  # noqa: S102
    return module


checks = load_checks()

RUNNING = {"BackendState": "Running", "Health": [], "Version": "1.98.8"}
RELAY_DOWN = {
    "BackendState": "Running",
    "Health": ["Tailscale could not connect to any relay server. Check your Internet connection."],
}
FULL_MAP = {"Regions": {"4": {"RegionID": 4, "RegionCode": "fra"}, "26": {"RegionID": 26}}}
EMPTY_MAP = {"Regions": {}}


class FakeTailscale:
    """Stands in for run_json: answers per subcommand, or raises."""

    def __init__(self, status, derp):
        self.status = status
        self.derp = derp
        self.calls: list[list[str]] = []

    def __call__(self, args):
        self.calls.append(args)
        answer = self.status if args[0] == "status" else self.derp
        if isinstance(answer, Exception):
            raise answer
        return answer


class CollectTest(unittest.TestCase):
    def tearDown(self) -> None:
        checks.run_json = checks.__dict__["_real_run_json"]

    def setUp(self) -> None:
        checks.__dict__.setdefault("_real_run_json", checks.run_json)

    def collect_with(self, status, derp):
        fake = FakeTailscale(status, derp)
        checks.run_json = fake
        problems = checks.collect()
        return fake, problems

    def test_clean(self):
        fake, problems = self.collect_with(RUNNING, FULL_MAP)
        self.assertEqual(problems, [])
        self.assertEqual([c[0] for c in fake.calls], ["status", "debug"])

    def test_empty_derp_map_pages(self):
        _, problems = self.collect_with(RUNNING, EMPTY_MAP)
        self.assertEqual([p.key for p in problems], ["tailnet:derpmap"])
        self.assertIn("EMPTY", problems[0].text)

    def test_relay_health_pages_with_digest_key(self):
        _, problems = self.collect_with(RELAY_DOWN, FULL_MAP)
        self.assertEqual(len(problems), 1)
        key = problems[0].key
        self.assertTrue(key.startswith("tailnet:health:"))
        self.assertEqual(key, checks.health_key(RELAY_DOWN["Health"][0]))
        self.assertNotEqual(key, checks.health_key("something else"))
        self.assertIn("could not connect to any relay", problems[0].text)

    def test_health_order_does_not_change_keys(self):
        a = {"BackendState": "Running", "Health": ["alpha", "beta"]}
        b = {"BackendState": "Running", "Health": ["beta", "alpha"]}
        _, pa = self.collect_with(a, FULL_MAP)
        _, pb = self.collect_with(b, FULL_MAP)
        self.assertEqual(sorted(p.key for p in pa), sorted(p.key for p in pb))

    def test_suppressed_health_is_silent(self):
        original = checks.SUPPRESSED_HEALTH
        try:
            checks.SUPPRESSED_HEALTH = frozenset({"intentional advisory"})
            status = {"BackendState": "Running", "Health": ["intentional advisory"]}
            _, problems = self.collect_with(status, FULL_MAP)
            self.assertEqual(problems, [])
        finally:
            checks.SUPPRESSED_HEALTH = original

    def test_backend_not_running_pages(self):
        status = {"BackendState": "NeedsLogin", "Health": []}
        _, problems = self.collect_with(status, FULL_MAP)
        self.assertEqual([p.key for p in problems], ["tailnet:backend"])
        self.assertIn("NeedsLogin", problems[0].text)

    def test_status_command_failure_reads_as_unknown(self):
        err = subprocess.TimeoutExpired(cmd="tailscale", timeout=15)
        _, problems = self.collect_with(err, FULL_MAP)
        self.assertEqual([p.key for p in problems], ["tailnet:status"])
        self.assertIn("unreadable", problems[0].text)
        self.assertIn("TimeoutExpired", problems[0].text)

    def test_derp_command_failure_reads_differently_from_empty(self):
        _, problems = self.collect_with(RUNNING, json.JSONDecodeError("x", "", 0))
        self.assertEqual([p.key for p in problems], ["tailnet:derpmap"])
        self.assertIn("unreadable", problems[0].text)
        self.assertNotIn("EMPTY", problems[0].text)


class EngineIntegrationTest(unittest.TestCase):
    """The real engine: one run debounces, the second pages, recovery clears."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.state = str(Path(self.tmp.name) / "state.json")
        self.sent: list[str] = []
        checks.__dict__.setdefault("_real_run_json", checks.run_json)

    def tearDown(self) -> None:
        checks.run_json = checks.__dict__["_real_run_json"]
        self.tmp.cleanup()

    def run_once(self, stamp, status, derp):
        checks.run_json = FakeTailscale(status, derp)
        return engine.run_cycle(
            self.state, stamp, checks.collect, checks.render, lambda text, _id: self.sent.append(text) or True
        )

    def test_debounce_then_page_then_clear(self):
        self.assertEqual(self.run_once(1000, RUNNING, EMPTY_MAP), engine.EXIT_PROBLEMS)
        self.assertEqual(self.sent, [], "first sighting must not page")
        self.assertEqual(self.run_once(1600, RUNNING, EMPTY_MAP), engine.EXIT_PROBLEMS)
        self.assertEqual(len(self.sent), 1, "second consecutive sighting pages")
        self.assertIn("Tailnet (csb1 view)", self.sent[0])  # HOSTNAME substitution reaches the page text
        self.assertIn("DERP map is EMPTY", self.sent[0])
        self.assertEqual(self.run_once(2200, RUNNING, FULL_MAP), engine.EXIT_CLEAN)
        self.assertEqual(len(self.sent), 2, "recovery announces a clear")
        self.assertIn("Cleared", self.sent[1])

    def test_one_blip_never_pages(self):
        self.run_once(1000, RELAY_DOWN, FULL_MAP)
        self.run_once(1600, RUNNING, FULL_MAP)
        self.assertEqual(self.sent, [])


if __name__ == "__main__":
    unittest.main()
