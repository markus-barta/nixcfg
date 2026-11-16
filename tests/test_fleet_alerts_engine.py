"""Unit tests for the shared fleet-alert engine — OPS-107.

Each rule here exists because of a specific incident:

  * confirm-before-alert — the csb0 switch on 2026-07-30 restarted tailscaled; one
    run saw all three Home Assistant instances unreachable and paged instantly,
    then "recovered" 15 minutes later. Nothing had been wrong.
  * durable delivery — the first ops-alerts implementation marked a problem
    announced and *then* sent, ignoring the result. A Telegram outage therefore
    lost the alert permanently: state said announced, nothing was delivered,
    nothing retried. In a tool built to catch silent failures.
  * atomic state — a plain json.dump over the live file corrupts it on a crash,
    after which the loader falls back to empty and every problem re-announces.
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "modules" / "shared" / "fleet-alerts" / "engine.py"
SPEC = importlib.util.spec_from_file_location("fleet_engine", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load the fleet alert engine")
engine = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = engine
SPEC.loader.exec_module(engine)

PROBLEM = engine.Problem("hsb1:api", "hsb1: HA unreachable (URLError)")


class Harness:
    """Drives run_cycle with a scriptable check and a controllable sender."""

    def __init__(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.state = str(self.dir / "state.json")
        self.problems: list[engine.Problem] = []
        self.sent: list[tuple[str, str]] = []
        self.deliver = True
        self.clock = 1_800_000_000.0

    def send(self, text: str, identifier: str) -> bool:
        if not self.deliver:
            return False
        self.sent.append((text, identifier))
        return True

    def render(self, announced: list[str], cleared: list[str]) -> str:
        parts = [f"NEW {a}" for a in announced] + [f"CLEARED {c}" for c in cleared]
        return " | ".join(parts)

    def run(self, *, clear_confirm_runs: int = 1, reminder_interval=None, elapsed: float = 900) -> int:
        self.clock += elapsed
        return engine.run_cycle(
            self.state, self.clock, lambda: list(self.problems), self.render, self.send,
            clear_confirm_runs=clear_confirm_runs,
            reminder_interval=reminder_interval,
        )

    def stored(self) -> dict:
        return json.loads(Path(self.state).read_text())


class ConfirmBeforeAlert(unittest.TestCase):
    def setUp(self) -> None:
        self.h = Harness()

    def test_single_run_blip_is_never_announced(self) -> None:
        self.h.problems = [PROBLEM]
        self.assertEqual(self.h.run(), engine.EXIT_PROBLEMS)
        self.h.problems = []
        self.h.run()
        self.assertEqual(self.h.sent, [], "a one-run blip must never page anyone")

    def test_sustained_problem_announced_once_then_cleared_once(self) -> None:
        self.h.problems = [PROBLEM]
        self.h.run()
        self.assertEqual(self.h.sent, [])
        self.h.run()
        self.assertEqual(len(self.h.sent), 1)
        self.assertIn("NEW", self.h.sent[0][0])
        self.h.run()
        self.assertEqual(len(self.h.sent), 1, "must not repeat while it persists")
        self.h.problems = []
        self.h.run()
        self.assertEqual(len(self.h.sent), 2)
        self.assertIn("CLEARED", self.h.sent[1][0])
        self.h.run()
        self.assertEqual(len(self.h.sent), 2, "must stay silent once cleared")

    def test_confirm_runs_is_at_least_two(self) -> None:
        self.assertGreaterEqual(engine.CONFIRM_RUNS, 2)


class ConfirmRecovery(unittest.TestCase):
    def setUp(self) -> None:
        self.h = Harness()
        self.h.problems = [PROBLEM]
        self.h.run(clear_confirm_runs=2)
        self.h.run(clear_confirm_runs=2)

    def test_requires_two_clean_runs_when_opted_in(self) -> None:
        self.h.problems = []
        self.h.run(clear_confirm_runs=2)
        self.assertEqual(len(self.h.sent), 1)
        self.assertEqual(self.h.stored()["seen"][PROBLEM.key]["clean_count"], 1)
        self.h.run(clear_confirm_runs=2)
        self.assertEqual(len(self.h.sent), 2)
        self.assertIn("CLEARED", self.h.sent[-1][0])
        self.h.run(clear_confirm_runs=2)
        self.assertEqual(len(self.h.sent), 2)

    def test_relapse_requires_two_new_clean_runs_without_realerting(self) -> None:
        self.h.problems = []
        self.h.run(clear_confirm_runs=2)
        self.h.problems = [PROBLEM]
        self.h.run(clear_confirm_runs=2)
        self.assertEqual(len(self.h.sent), 1)
        self.assertNotIn("clean_count", self.h.stored()["seen"][PROBLEM.key])
        self.h.problems = []
        self.h.run(clear_confirm_runs=2)
        self.assertEqual(len(self.h.sent), 1)
        self.h.run(clear_confirm_runs=2)
        self.assertEqual(len(self.h.sent), 2)

    def test_old_state_without_clean_count_defaults_to_zero(self) -> None:
        previous = {"seen": {PROBLEM.key: {"text": PROBLEM.text, "count": 2, "alerted": True}}}
        state, announce, cleared = engine.advance(previous, [], clear_confirm_runs=2)
        self.assertEqual((announce, cleared), ([], []))
        self.assertEqual(state["seen"][PROBLEM.key]["clean_count"], 1)
        _, announce, cleared = engine.advance(state, [], clear_confirm_runs=2)
        self.assertEqual((announce, cleared), ([], [PROBLEM.text]))

    def test_invalid_clear_confirmation_is_rejected(self) -> None:
        for invalid in [0, -1]:
            with self.subTest(invalid=invalid):
                with self.assertRaisesRegex(ValueError, "clear_confirm_runs must be positive"):
                    engine.advance({}, [], clear_confirm_runs=invalid)
                with self.assertRaisesRegex(ValueError, "clear_confirm_runs must be positive"):
                    self.h.run(clear_confirm_runs=invalid)


class DurableDelivery(unittest.TestCase):
    """The write-ahead log: an alert must never be lost, nor announced twice."""

    def setUp(self) -> None:
        self.h = Harness()

    def test_failed_send_is_retried_and_not_lost(self) -> None:
        self.h.problems = [PROBLEM]
        self.h.run()  # first sighting, silent
        self.h.deliver = False
        self.assertEqual(self.h.run(), engine.EXIT_UNDELIVERED)
        self.assertEqual(self.h.sent, [], "nothing was delivered")
        self.assertIsNotNone(self.h.stored()["pending"], "pending must survive on disk")

        # Channel returns. The identical text must go out before anything commits.
        self.h.deliver = True
        self.h.run()
        self.assertEqual(len(self.h.sent), 1)
        self.assertIn("NEW", self.h.sent[0][0])
        self.assertIsNone(self.h.stored()["pending"], "pending must clear after delivery")

    def test_undelivered_alert_is_not_announced_twice(self) -> None:
        self.h.problems = [PROBLEM]
        self.h.run()
        self.h.deliver = False
        self.h.run()
        self.h.deliver = True
        self.h.run()  # delivers the retry
        self.h.run()  # steady state
        self.assertEqual(len(self.h.sent), 1, "exactly one announcement for one problem")

    def test_exit_code_signals_undeliverable_distinctly(self) -> None:
        self.h.problems = [PROBLEM]
        self.h.run()
        self.h.deliver = False
        # 2 must differ from 1 (problems found) so SuccessExitStatus can let 0/1
        # pass while an undeliverable alert fails the unit.
        self.assertEqual(self.h.run(), engine.EXIT_UNDELIVERED)
        self.assertNotEqual(engine.EXIT_UNDELIVERED, engine.EXIT_PROBLEMS)
        self.assertNotEqual(engine.EXIT_UNDELIVERED, engine.EXIT_CLEAN)


class Reminders(unittest.TestCase):
    INTERVAL = 12 * 3600
    SILENT = engine.Problem("silent:server", "server: no beacon report for 30.5 h")

    def setUp(self) -> None:
        self.h = Harness()
        self.h.problems = [self.SILENT]

    def cycle(self, elapsed=900):
        return self.h.run(
            elapsed=elapsed,
            reminder_interval=lambda key: self.INTERVAL if key.startswith("silent:") else None,
        )

    def confirm(self):
        for _ in range(engine.CONFIRM_RUNS - 1):
            self.assertEqual(self.cycle(), engine.EXIT_PROBLEMS)
            self.assertEqual(self.h.sent, [])
        self.cycle()
        self.assertEqual(len(self.h.sent), 1)
        self.assertNotIn("Reminder", self.h.sent[0][0])
        self.assertEqual(self.h.stored()["seen"][self.SILENT.key]["last_announced_at"], self.h.clock)

    def test_reminds_every_twelve_hours_with_current_text(self):
        self.confirm()
        self.cycle(self.INTERVAL - 1)
        self.assertEqual(len(self.h.sent), 1)
        self.h.problems = [engine.Problem(self.SILENT.key, "server: no beacon report for 42.5 h")]
        self.cycle(1)
        self.assertEqual(len(self.h.sent), 2)
        self.assertIn("Reminder — still failing", self.h.sent[-1][0])
        self.assertIn("42.5 h", self.h.sent[-1][0])
        self.cycle(self.INTERVAL - 1)
        self.assertEqual(len(self.h.sent), 2)
        self.cycle(61)  # first poll after the next deadline
        self.assertEqual(len(self.h.sent), 3)
        self.assertEqual(self.h.stored()["seen"][self.SILENT.key]["last_announced_at"], self.h.clock)

    def test_recovery_clears_once_and_drops_reminder_state(self):
        self.confirm()
        self.cycle(self.INTERVAL)
        self.h.problems = []
        self.assertEqual(self.cycle(), engine.EXIT_CLEAN)
        self.assertIn("CLEARED", self.h.sent[-1][0])
        self.assertEqual(self.h.stored(), {"seen": {}, "pending": None})
        self.cycle(self.INTERVAL * 3)
        self.assertEqual(len(self.h.sent), 3)
        self.h.problems = [self.SILENT]
        self.cycle()
        self.assertEqual(len(self.h.sent), 3, "a new outage must be confirmed again")
        self.cycle()
        self.assertEqual(len(self.h.sent), 4)
        self.assertNotIn("Reminder", self.h.sent[-1][0])

    def test_non_opted_key_never_reminds_or_gains_timestamp(self):
        self.h.problems = [PROBLEM]
        self.cycle()
        self.cycle()
        self.cycle(self.INTERVAL * 10)
        self.assertEqual(len(self.h.sent), 1)
        self.assertEqual(self.h.stored()["seen"][PROBLEM.key], {
            "text": PROBLEM.text, "count": 3, "alerted": True,
        })

    def test_default_policy_preserves_old_state_shape_and_silence(self):
        self.h.run()
        self.h.run()
        self.h.run(elapsed=self.INTERVAL * 10)
        self.assertEqual(len(self.h.sent), 1)
        self.assertEqual(self.h.stored()["seen"][self.SILENT.key], {
            "text": self.SILENT.text, "count": 3, "alerted": True,
        })

    def test_old_formats_start_timer_on_load_and_persist_it(self):
        for old in [
            {self.SILENT.key: self.SILENT.text},
            {self.SILENT.key: {"msg": self.SILENT.text, "count": 2, "alerted": True}},
            {"seen": {self.SILENT.key: {"text": self.SILENT.text, "count": 2, "alerted": True}}, "pending": None},
        ]:
            with self.subTest(old=old):
                self.h = Harness()
                self.h.problems = [self.SILENT]
                Path(self.h.state).write_text(json.dumps(old))
                self.cycle()
                baseline = self.h.clock
                self.assertEqual(self.h.sent, [])
                self.assertEqual(self.h.stored()["seen"][self.SILENT.key]["last_announced_at"], baseline)
                self.cycle(self.INTERVAL - 1)
                self.assertEqual(self.h.sent, [])
                self.assertEqual(self.h.stored()["seen"][self.SILENT.key]["last_announced_at"], baseline)
                self.cycle(1)
                self.assertEqual(len(self.h.sent), 1)
                self.assertIn("Reminder", self.h.sent[0][0])

    def test_failed_reminder_replays_verbatim_before_check_and_restarts_timer(self):
        self.confirm()
        last_announced = self.h.clock
        self.h.deliver = False
        self.assertEqual(self.cycle(self.INTERVAL), engine.EXIT_UNDELIVERED)
        pending = self.h.stored()["pending"]
        self.assertIn("Reminder", pending["text"])
        self.assertEqual(self.h.stored()["seen"][self.SILENT.key]["last_announced_at"], last_announced)
        self.assertEqual(pending["next_state"]["seen"][self.SILENT.key]["last_announced_at"], self.h.clock)
        with patch.object(engine, "advance", side_effect=AssertionError("must retry before evaluation")):
            self.assertEqual(self.cycle(self.INTERVAL * 2), engine.EXIT_UNDELIVERED)
        self.assertEqual(self.h.stored()["pending"], pending)
        self.h.problems = [engine.Problem(self.SILENT.key, "server: updated outage duration")]
        self.h.deliver = True
        send = self.h.send

        def inspect_pending(text, identifier):
            self.assertEqual(self.h.stored()["pending"], pending, "write-ahead record must precede send")
            return send(text, identifier)

        with patch.object(self.h, "send", side_effect=inspect_pending):
            self.cycle(self.INTERVAL)
        self.assertEqual(len(self.h.sent), 2, "replay must not produce a second reminder immediately")
        self.assertEqual(self.h.sent[-1], (pending["text"], pending["event_id"]))
        self.assertIsNone(self.h.stored()["pending"])
        self.assertEqual(self.h.stored()["seen"][self.SILENT.key]["last_announced_at"], self.h.clock)
        self.cycle(self.INTERVAL - 1)
        self.assertEqual(len(self.h.sent), 2)
        self.cycle(1)
        self.assertEqual(len(self.h.sent), 3)
        self.assertIn("updated outage duration", self.h.sent[-1][0])

    def test_recovery_after_failed_reminder_delivers_reminder_then_one_clear(self):
        self.confirm()
        self.h.deliver = False
        self.cycle(self.INTERVAL)
        pending = self.h.stored()["pending"]
        self.h.problems = []
        self.h.deliver = True
        self.cycle(self.INTERVAL * 2)
        self.assertEqual(self.h.sent[1], (pending["text"], pending["event_id"]))
        self.assertIn("CLEARED", self.h.sent[2][0])
        self.assertEqual(self.h.stored(), {"seen": {}, "pending": None})
        self.cycle(self.INTERVAL)
        self.assertEqual(len(self.h.sent), 3)

    def test_failed_initial_page_also_starts_timer_on_delivery(self):
        self.cycle()
        self.h.deliver = False
        self.assertEqual(self.cycle(), engine.EXIT_UNDELIVERED)
        pending = self.h.stored()["pending"]
        self.h.deliver = True
        self.cycle(self.INTERVAL * 2)
        self.assertEqual(self.h.sent, [(pending["text"], pending["event_id"])])
        self.assertEqual(self.h.stored()["seen"][self.SILENT.key]["last_announced_at"], self.h.clock)

    def test_invalid_policy_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "reminders require a timestamp"):
            engine.advance({}, [self.SILENT], reminder_interval=lambda key: self.INTERVAL)
        for interval in [0, -1]:
            with self.subTest(interval=interval), self.assertRaisesRegex(ValueError, "reminder interval must be positive"):
                engine.advance({}, [self.SILENT], stamp=self.h.clock, reminder_interval=lambda key: interval)


class StateHandling(unittest.TestCase):
    def setUp(self) -> None:
        self.h = Harness()

    def test_atomic_write_leaves_no_temp_files(self) -> None:
        self.h.problems = [PROBLEM]
        self.h.run()
        leftovers = [p.name for p in Path(self.h.state).parent.iterdir() if p.name.startswith(".state-")]
        self.assertEqual(leftovers, [])

    def test_corrupt_state_does_not_crash(self) -> None:
        Path(self.h.state).write_text("{ this is not json")
        self.h.problems = [PROBLEM]
        self.assertEqual(self.h.run(), engine.EXIT_PROBLEMS)

    def test_migrates_v1_flat_format(self) -> None:
        Path(self.h.state).write_text(json.dumps({"hsb1:api": "hsb1: HA unreachable"}))
        self.h.problems = []
        self.h.run()
        self.assertEqual(len(self.h.sent), 1, "a previously announced problem clears once")
        self.assertIn("CLEARED", self.h.sent[0][0])

    def test_migrates_v2_msg_count_format(self) -> None:
        Path(self.h.state).write_text(
            json.dumps({"hsb1:api": {"msg": "hsb1: down", "count": 2, "alerted": True}})
        )
        self.h.problems = []
        self.h.run()
        self.assertEqual(len(self.h.sent), 1)

    def test_state_never_contains_credentials(self) -> None:
        self.h.problems = [PROBLEM]
        self.h.run()
        self.h.run()
        body = Path(self.h.state).read_text().lower()
        for forbidden in ("bearer", "token", "telegram", "chat_id"):
            self.assertNotIn(forbidden, body)


class ShoutrrrTarget(unittest.TestCase):
    """csb1 reuses its existing WATCHTOWER_NOTIFICATION_URL — no new secret."""

    def test_parses_a_valid_telegram_url(self) -> None:
        sender = engine.shoutrrr_telegram_sender("telegram://12345:AAbb--cc_ddeeffgghhiijj@telegram?chats=-100123")
        self.assertTrue(callable(sender))

    def test_rejects_unsupported_targets(self) -> None:
        for bad in (
            "https://example.com/hook",  # webhook form not supported by this sender
            "telegram://notoken@telegram",  # no chats
            "telegram://12345:AAbbccddeeffgghhiijjkk@elsewhere?chats=1",  # wrong host
            "slack://whatever",
        ):
            with self.assertRaises(ValueError, msg=bad):
                engine.shoutrrr_telegram_sender(bad)

    def test_env_file_value_reads_one_key_only(self) -> None:
        path = Path(tempfile.mkdtemp()) / "env"
        path.write_text('# comment\nexport OTHER=nope\nWATCHTOWER_NOTIFICATION_URL="telegram://t@telegram?chats=1"\n')
        self.assertEqual(
            engine.env_file_value(str(path), "WATCHTOWER_NOTIFICATION_URL"),
            "telegram://t@telegram?chats=1",
        )
        self.assertEqual(engine.env_file_value(str(path), "MISSING"), "")

    def test_env_file_value_rejects_traversal_before_opening(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            allowed = root / "credentials"
            allowed.mkdir()
            (root / "notification-env").write_text("TARGET=synthetic\n")
            traversal = allowed / ".." / "notification-env"
            for strict in [False, True]:
                with self.subTest(strict=strict), patch("builtins.open") as opening:
                    self.assertEqual(engine.env_file_value(str(traversal), "TARGET", require_canonical_path=strict), "")
                    opening.assert_not_called()

    def test_env_file_value_requires_an_absolute_regular_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            credential = root / "notification-env"
            credential.write_text("TARGET=synthetic\n")
            fifo = root / "fifo"
            os.mkfifo(fifo)
            for bad in ["notification-env", "", str(root), str(root / "missing"), str(fifo)]:
                with self.subTest(path=bad), patch("builtins.open") as opening:
                    self.assertEqual(engine.env_file_value(bad, "TARGET"), "")
                    opening.assert_not_called()
            self.assertEqual(engine.env_file_value(str(credential), "TARGET", require_canonical_path=True), "synthetic")

    def test_env_file_value_preserves_agenix_symlinks_but_credentials_reject_them(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            credential = root / "notification-env"
            credential.write_text("TARGET=synthetic\n")
            alias = root / "alias"
            alias.symlink_to(credential)
            self.assertEqual(engine.env_file_value(str(alias), "TARGET"), "synthetic")
            with patch("builtins.open") as opening:
                self.assertEqual(engine.env_file_value(str(alias), "TARGET", require_canonical_path=True), "")
                opening.assert_not_called()


if __name__ == "__main__":
    unittest.main()
