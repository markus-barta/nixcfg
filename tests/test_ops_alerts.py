"""Unit tests for the OPS-104 fleet alert poller state machine.

The behaviour under test exists because of a specific incident: on 2026-07-30 the
csb0 switch restarted tailscaled, one poll saw all three Home Assistant instances
as unreachable, and the poller fired a false alarm followed by a "recovered"
message 15 minutes later. Nothing had been wrong with any of the houses.

A watchdog that cries wolf gets muted, and a muted watchdog is how NIX-135's UPS
ran broken for seven weeks. So the rules these tests pin down are:

  * a problem seen on a single run is never announced
  * a problem seen on CONFIRM_RUNS consecutive runs is announced exactly once
  * nothing is repeated while the problem persists
  * clearing is announced only for problems that were actually announced
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "hosts" / "csb0" / "ops-alerts-poll.py"

# The shipped script carries a @TARGETS_JSON@ placeholder that ops-alerts.nix
# substitutes at build time. Do the same substitution here so the tests exercise
# the file that actually ships, rather than a copy that can drift from it.
_TMP = tempfile.mkdtemp()
_MODULE = Path(_TMP) / "ops_alerts_poll.py"
_MODULE.write_text(SCRIPT.read_text().replace("@TARGETS_JSON@", "[]"))

SPEC = importlib.util.spec_from_file_location("ops_alerts_poll", _MODULE)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load the ops-alerts poller")
poller = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = poller
SPEC.loader.exec_module(poller)

PROBLEM = {"hsb1:api": "hsb1: HA unreachable (URLError)"}


class PollerStateMachine(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.mkdtemp()
        poller.STATE_PATH = str(Path(self.tmp) / "state.json")
        self.sent: list[str] = []
        poller.telegram = self._capture
        poller.TARGETS = [{"name": "hsb1"}]

    def _capture(self, text: str) -> bool:
        self.sent.append(text)
        return True

    def run_once(self, problems: dict[str, str]) -> list[str]:
        poller.check = lambda _target: dict(problems)
        self.sent = []
        poller.telegram = self._capture
        poller.main()
        return list(self.sent)

    def test_single_run_blip_is_never_announced(self) -> None:
        """The 2026-07-30 false alarm: one bad run, then fine."""
        self.assertEqual(self.run_once(PROBLEM), [])
        self.assertEqual(self.run_once({}), [])

    def test_sustained_problem_announced_once_then_cleared(self) -> None:
        self.assertEqual(self.run_once(PROBLEM), [], "must not alert on first sighting")

        second = self.run_once(PROBLEM)
        self.assertEqual(len(second), 1)
        self.assertIn("Fleet problem", second[0])
        self.assertIn("hsb1: HA unreachable", second[0])

        self.assertEqual(self.run_once(PROBLEM), [], "must not repeat while it persists")

        cleared = self.run_once({})
        self.assertEqual(len(cleared), 1)
        self.assertIn("Cleared", cleared[0])

        self.assertEqual(self.run_once({}), [], "must stay silent once cleared")

    def test_confirm_runs_is_at_least_two(self) -> None:
        """A threshold of 1 would reintroduce the false-alarm class."""
        self.assertGreaterEqual(poller.CONFIRM_RUNS, 2)

    def test_legacy_state_format_is_migrated(self) -> None:
        """State written before CONFIRM_RUNS existed was {key: message}."""
        Path(poller.STATE_PATH).write_text(json.dumps({"hsb1:api": "hsb1: HA unreachable"}))
        cleared = self.run_once({})
        self.assertEqual(len(cleared), 1)
        self.assertIn("Cleared", cleared[0])

    def test_state_file_never_contains_credentials(self) -> None:
        self.run_once(PROBLEM)
        body = Path(poller.STATE_PATH).read_text().lower()
        for forbidden in ("bearer", "token", "telegram", "chat_id"):
            self.assertNotIn(forbidden, body)


class TargetUrlAllowlist(unittest.TestCase):
    """Only tailnet Home Assistant addresses may ever be requested."""

    def test_accepts_the_real_fleet(self) -> None:
        for url in ("http://100.64.0.7:8123", "http://100.64.0.3:8123", "http://100.64.0.12:8123"):
            self.assertRegex(url, poller.ALLOWED_BASE)

    def test_rejects_everything_else(self) -> None:
        for url in (
            "http://192.168.1.101:8123",  # LAN address, not the tailnet
            "http://100.64.0.7:9999",  # wrong port
            "https://evil.example.com:8123",  # external host
            "http://100.63.0.1:8123",  # just below the CGNAT range
            "http://100.128.0.1:8123",  # just above it
        ):
            self.assertIsNone(poller.ALLOWED_BASE.match(url), url)

    def test_paths_are_confined_to_the_api(self) -> None:
        with self.assertRaises(ValueError):
            poller.ha_get("http://100.64.0.7:8123", "t", "/lovelace")


if __name__ == "__main__":
    unittest.main()
