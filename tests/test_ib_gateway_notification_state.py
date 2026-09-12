"""Focused tests for HOSTD-59's independent per-channel notification WAL."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ENGINE_DIR = REPO / "modules" / "shared" / "fleet-alerts"
MODULE = REPO / "modules" / "ib-gateway-session" / "notification_state.py"
sys.path.insert(0, str(ENGINE_DIR))

engine_spec = importlib.util.spec_from_file_location("engine", ENGINE_DIR / "engine.py")
if engine_spec is None or engine_spec.loader is None:
    raise RuntimeError("unable to load fleet engine")
engine = importlib.util.module_from_spec(engine_spec)
sys.modules["engine"] = engine
engine_spec.loader.exec_module(engine)

state_spec = importlib.util.spec_from_file_location("notification_state", MODULE)
if state_spec is None or state_spec.loader is None:
    raise RuntimeError("unable to load notification state")
notification_state = importlib.util.module_from_spec(state_spec)
sys.modules[state_spec.name] = notification_state
state_spec.loader.exec_module(notification_state)


class Harness:
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp()) / "alerts.channels"
        self.calls: dict[str, list[tuple[str, str]]] = {"email": [], "grok": []}
        self.fail: set[str] = set()
        self.inspect_before_send: set[str] = set()
        self.pre_send_state: dict[str, dict] = {}
        self.now = 1_800_000_000.0
        self.problem = "Paper Gateway remains unavailable. Automatic recovery attempted one allowed restart(s)."

    def sender(self, name: str):
        def send(text: str, identifier: str) -> bool:
            self.calls[name].append((text, identifier))
            if name in self.inspect_before_send:
                self.pre_send_state[name] = json.loads(
                    (self.directory / name / "state.json").read_text()
                )
            return name not in self.fail

        return send

    @property
    def senders(self):
        return {name: self.sender(name) for name in self.calls}

    def run(self, *, health: bool | None, eligible: bool = False, advance: float = 0) -> int:
        self.now += advance
        return notification_state.run_notifications(
            str(self.directory), self.now, health, eligible, self.problem, self.senders
        )

    def state(self, channel: str) -> dict:
        return json.loads((self.directory / channel / "state.json").read_text())


class NotificationStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.h = Harness()
        self.h.setUp()

    def test_ineligible_grace_does_not_create_or_clear_alert(self) -> None:
        self.assertEqual(self.h.run(health=False), engine.EXIT_PROBLEMS)
        self.assertEqual(self.h.calls, {"email": [], "grok": []})
        self.assertFalse(self.h.directory.exists())

        self.assertEqual(self.h.run(health=False, eligible=True), engine.EXIT_PROBLEMS)
        outage_id = self.h.state("email")["outage"]["event_id"]
        self.assertEqual(self.h.run(health=False, eligible=False), engine.EXIT_PROBLEMS)
        self.assertEqual(self.h.state("email")["outage"]["event_id"], outage_id)
        self.assertEqual(len(self.h.calls["email"]), 1)
        self.assertEqual(len(self.h.calls["grok"]), 1)

    def test_email_success_is_not_resent_when_grok_fails(self) -> None:
        self.h.fail = {"grok"}
        self.assertEqual(self.h.run(health=False, eligible=True), engine.EXIT_UNDELIVERED)
        self.assertEqual(len(self.h.calls["email"]), 1)
        self.assertEqual(len(self.h.calls["grok"]), 1)
        self.assertEqual(self.h.state("email")["outage"]["event_id"], self.h.state("grok")["pending"]["event_id"])
        self.assertEqual(self.h.state("email")["pending"], None)

        # The failed channel is rate-limited independently; email is never called.
        self.assertEqual(self.h.run(health=False, eligible=False, advance=60), engine.EXIT_UNDELIVERED)
        self.assertEqual(len(self.h.calls["email"]), 1)
        self.assertEqual(len(self.h.calls["grok"]), 1)

        self.h.fail.clear()
        self.assertEqual(
            self.h.run(health=False, eligible=False, advance=notification_state.RETRY_INTERVAL_SECONDS),
            engine.EXIT_PROBLEMS,
        )
        self.assertEqual(len(self.h.calls["email"]), 1)
        self.assertEqual(len(self.h.calls["grok"]), 2)
        self.assertIsNone(self.h.state("grok")["pending"])

    def test_retry_reservation_is_persisted_before_sender(self) -> None:
        self.h.inspect_before_send = {"email"}
        self.h.fail = {"email"}
        self.assertEqual(self.h.run(health=False, eligible=True), engine.EXIT_UNDELIVERED)
        pending = self.h.pre_send_state["email"]["pending"]
        self.assertEqual(pending["attempts"], 1)
        self.assertEqual(pending["next_attempt_at"], self.h.now + notification_state.RETRY_INTERVAL_SECONDS)

    def test_unknown_health_preserves_announced_outage(self) -> None:
        self.assertEqual(self.h.run(health=False, eligible=True), engine.EXIT_PROBLEMS)
        before = self.h.state("email")
        self.assertEqual(self.h.run(health=None), engine.EXIT_CLEAN)
        after = self.h.state("email")
        self.assertEqual(after["outage"]["event_id"], before["outage"]["event_id"])
        self.assertIsNone(after["pending"])
        self.assertEqual(len(self.h.calls["email"]), 1)
        self.assertEqual(len(self.h.calls["grok"]), 1)

    def test_recovery_is_sent_once_per_channel_and_clears(self) -> None:
        self.assertEqual(self.h.run(health=False, eligible=True), engine.EXIT_PROBLEMS)
        self.assertEqual(self.h.run(health=True), engine.EXIT_CLEAN)
        self.assertEqual(len(self.h.calls["email"]), 2)
        self.assertEqual(len(self.h.calls["grok"]), 2)
        self.assertIn("recovered", self.h.calls["email"][1][0])
        self.assertIsNone(self.h.state("email")["outage"])
        self.assertIsNone(self.h.state("grok")["outage"])

        self.assertEqual(self.h.run(health=True), engine.EXIT_CLEAN)
        self.assertEqual(len(self.h.calls["email"]), 2)
        self.assertEqual(len(self.h.calls["grok"]), 2)

    def test_email_clear_is_independent_of_failed_grok_alert(self) -> None:
        self.h.fail = {"grok"}
        self.assertEqual(self.h.run(health=False, eligible=True), engine.EXIT_UNDELIVERED)
        self.assertEqual(self.h.run(health=True), engine.EXIT_UNDELIVERED)
        self.assertEqual(len(self.h.calls["email"]), 2)
        self.assertEqual(len(self.h.calls["grok"]), 1)
        self.assertIn("recovered", self.h.calls["email"][1][0])
        self.assertIsNone(self.h.state("email")["outage"])
        self.assertIsNotNone(self.h.state("grok")["pending"])

        # A later retry still targets only Grok; successful email is never repeated.
        self.assertEqual(
            self.h.run(health=True, advance=notification_state.RETRY_INTERVAL_SECONDS),
            engine.EXIT_UNDELIVERED,
        )
        self.assertEqual(len(self.h.calls["email"]), 2)
        self.assertEqual(len(self.h.calls["grok"]), 2)

    def test_recovery_failure_retries_only_failed_channel(self) -> None:
        self.assertEqual(self.h.run(health=False, eligible=True), engine.EXIT_PROBLEMS)
        self.h.fail = {"grok"}
        self.assertEqual(self.h.run(health=True), engine.EXIT_UNDELIVERED)
        self.assertEqual(len(self.h.calls["email"]), 2)
        self.assertEqual(len(self.h.calls["grok"]), 2)

        self.h.fail.clear()
        self.assertEqual(self.h.run(health=None, advance=notification_state.RETRY_INTERVAL_SECONDS), engine.EXIT_CLEAN)
        self.assertEqual(len(self.h.calls["email"]), 2)
        self.assertEqual(len(self.h.calls["grok"]), 2)
        self.assertIsNotNone(self.h.state("grok")["pending"])

        self.assertEqual(self.h.run(health=True, advance=notification_state.RETRY_INTERVAL_SECONDS), engine.EXIT_CLEAN)
        self.assertEqual(len(self.h.calls["email"]), 2)
        self.assertEqual(len(self.h.calls["grok"]), 3)
        self.assertIsNone(self.h.state("grok")["outage"])


if __name__ == "__main__":
    unittest.main()
