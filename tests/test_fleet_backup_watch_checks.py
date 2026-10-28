"""Unit tests for the fleet backup watch (OPS-485) on csb1.

Pins what pages and what does not: a fresh healthy backup is silent, an old
success pages on age whatever the state says, warning/missing/unknown page as a
state problem, failed/stale are left to pharosd (only age can page them),
not-configured and disabled are ignored, a schedule sets the limit, a silent
beacon is named in the text, and an unusable store or host entry is loud and
never reads as a recovery (gate r1).
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
CHECKS = REPO / "hosts" / "csb1" / "fleet-backup-watch-checks.py"
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
    }.items():
        source = source.replace(k, v)
    module = types.ModuleType("fleet_backup_watch_checks")
    module.__dict__["__file__"] = str(CHECKS)
    exec(compile(source, str(CHECKS), "exec"), module.__dict__)  # noqa: S102
    return module


NOW = 1_800_000_000.0
HOUR = 3600


def obs(*, state="healthy", success=NOW - 7 * HOUR, schedule="daily", configured="enabled", ident="restic-cron-hetzner"):
    item = {"id": ident, "label": "Restic Hetzner", "engine": "restic", "state": state,
            "configured": configured, "summary": f"summary for {state}", "schedule": schedule}
    if success is not None:
        item["last_success_at"] = success
    return item


def host(name, *observations, seen=NOW - 60):
    return {"name": name, "is_nix": True, "last_seen": seen, "backup_observations": list(observations)}


class BackupWatchTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.store = str(Path(self.tmp.name) / "pharos.json")
        self.checks = load_checks(self.store)
        self.checks.time.time = lambda: NOW
        self.state = str(Path(self.tmp.name) / "state.json")
        self.checks.STATE_PATH = self.state

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def write(self, hosts):
        Path(self.store).write_text(json.dumps(hosts))

    def test_fresh_healthy_backups_are_silent(self):
        self.write([host("hsb8", obs()), host("hsb9", obs(success=NOW - 25 * HOUR)), host("nobackup")])
        self.assertEqual(self.checks.collect(), [])

    def test_old_success_pages_even_when_healthy(self):
        self.write([host("hsb8", obs(success=NOW - 30 * HOUR))])
        problems = self.checks.collect()
        self.assertEqual([p.key for p in problems], ["backup:hsb8:restic-cron-hetzner:age"])
        self.assertIn("30.0 h ago (limit 26 h)", problems[0].text)
        self.assertNotIn("Pharos has not heard", problems[0].text)

    def test_failed_and_stale_are_left_to_pharosd_until_age(self):
        self.write([host("a", obs(state="failed")), host("b", obs(state="stale"))])
        self.assertEqual(self.checks.collect(), [])
        self.write([host("a", obs(state="failed", success=NOW - 28 * HOUR))])
        self.assertEqual([p.key for p in self.checks.collect()], ["backup:a:restic-cron-hetzner:age"])

    def test_states_pharosd_does_not_page(self):
        self.write([host("w", obs(state="warning")), host("m", obs(state="missing")), host("u", obs(state="unknown"))])
        problems = self.checks.collect()
        self.assertEqual([p.key for p in problems],
                         ["backup:m:restic-cron-hetzner:state", "backup:u:restic-cron-hetzner:state",
                          "backup:w:restic-cron-hetzner:state"])
        self.assertIn("reports missing (summary for missing)", problems[0].text)

    def test_never_succeeded_pages(self):
        self.write([host("new", obs(success=None))])
        self.assertEqual([p.key for p in self.checks.collect()], ["backup:new:restic-cron-hetzner:age"])

    def test_not_configured_and_disabled_are_ignored(self):
        self.write([host("x", obs(state="not-configured", success=None), obs(configured="disabled", success=None, ident="off"))])
        self.assertEqual(self.checks.collect(), [])

    def test_weekly_schedule_gets_a_week(self):
        self.write([host("w", obs(schedule="weekly", success=NOW - 6 * 24 * HOUR))])
        self.assertEqual(self.checks.collect(), [])
        self.write([host("w", obs(schedule="weekly", success=NOW - 9 * 24 * HOUR))])
        self.assertEqual([p.key for p in self.checks.collect()], ["backup:w:restic-cron-hetzner:age"])

    def test_silent_beacon_is_named(self):
        self.write([host("hsb9", obs(success=NOW - 40 * HOUR), seen=NOW - 3 * HOUR)])
        problems = self.checks.collect()
        self.assertEqual(len(problems), 1)
        self.assertIn("Pharos has not heard from hsb9 for 180 min", problems[0].text)

    def test_unreadable_store_is_one_loud_problem(self):
        problems = self.checks.collect()  # nothing written
        self.assertEqual([p.key for p in problems], ["backup:store"])
        self.assertIn("unwatched", problems[0].text)

    def test_malformed_hosts_do_not_hide_the_rest(self):
        self.write([
            {"name": "bad", "last_seen": "bad", "backup_observations": [obs(success=NOW - 30 * HOUR)]},
            {"name": "odd", "last_seen": NOW, "backup_observations": 42},
            "not-a-host",
            host("hsb8", obs(success=NOW - 30 * HOUR)),
        ])
        problems = self.checks.collect()
        self.assertEqual(sorted(p.key for p in problems), [
            "backup:bad:restic-cron-hetzner:age",
            "backup:hsb8:restic-cron-hetzner:age",
            "backup:odd:malformed",
            "backup:store:entry",
        ])
        bad = next(p for p in problems if p.key.startswith("backup:bad:"))
        self.assertIn("Pharos has no last-seen time for bad", bad.text)

    def test_bool_and_string_timestamps_are_not_times(self):
        self.write([host("x", obs(success=True)), host("y", obs(success="1799990000"))])
        self.assertEqual(sorted(p.key for p in self.checks.collect()),
                         ["backup:x:restic-cron-hetzner:age", "backup:y:restic-cron-hetzner:age"])

    def test_invalid_store_shapes_are_loud(self):
        for payload in ({"unexpected": []}, {"hosts": "invalid"}, "text", 42, [], [host("x")]):
            with self.subTest(payload=payload):
                Path(self.store).write_text(json.dumps(payload))
                self.assertEqual([p.key for p in self.checks.collect()], ["backup:store"])

    def run_cycle(self, stamp, sent):
        return engine.run_cycle(self.state, stamp, self.checks.collect, self.checks.render,
                                lambda t, _i: sent.append(t) or True)

    def test_unusable_store_never_reads_as_recovery(self):
        sent = []
        self.write([host("hsb8", obs(success=NOW - 30 * HOUR))])
        self.run_cycle(NOW, sent)
        self.run_cycle(NOW + HOUR, sent)
        self.assertEqual(len(sent), 1)
        for n, payload in enumerate(({"unexpected": []}, {"hosts": "invalid"}, [])):
            Path(self.store).write_text(json.dumps(payload))
            self.run_cycle(NOW + (2 + n) * HOUR, sent)
        self.assertEqual(len(sent), 2)
        self.assertNotIn("Cleared", sent[1])
        self.assertIn("unwatched", sent[1])

    def test_malformed_host_keeps_its_open_alert(self):
        sent = []
        self.write([host("hsb8", obs(success=NOW - 30 * HOUR)), host("hsb9", obs())])
        self.run_cycle(NOW, sent)
        self.run_cycle(NOW + HOUR, sent)
        self.write([{"name": "hsb8", "last_seen": NOW, "backup_observations": 42}, host("hsb9", obs())])
        self.run_cycle(NOW + 2 * HOUR, sent)
        self.run_cycle(NOW + 3 * HOUR, sent)
        self.assertEqual(len(sent), 2)
        self.assertNotIn("Cleared", sent[1])
        self.assertIn("hsb8: Pharos backup data could not be judged", sent[1])

    def test_judge_exception_is_contained(self):
        def boom(host, now):
            if host["name"] == "x":
                raise RuntimeError("boom")
            return []
        self.checks.judge = boom
        self.write([host("x", obs()), host("y", obs())])
        self.assertEqual([p.key for p in self.checks.collect()], ["backup:x:malformed"])

    def test_engine_debounce_page_then_clear(self):
        state = str(Path(self.tmp.name) / "state.json")
        sent = []
        self.write([host("hsb8", obs(success=NOW - 30 * HOUR))])
        for stamp in (NOW, NOW + HOUR):
            engine.run_cycle(state, stamp, self.checks.collect, self.checks.render, lambda t, _i: sent.append(t) or True)
        self.assertEqual(len(sent), 1)
        self.assertIn("Fleet backups", sent[0])
        self.assertIn("hsb8", sent[0])
        self.write([host("hsb8", obs(success=NOW - HOUR))])
        engine.run_cycle(state, NOW + 2 * HOUR, self.checks.collect, self.checks.render, lambda t, _i: sent.append(t) or True)
        self.assertEqual(len(sent), 2)
        self.assertIn("Cleared", sent[1])


if __name__ == "__main__":
    unittest.main()
