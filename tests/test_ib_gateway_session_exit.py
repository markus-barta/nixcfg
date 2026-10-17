"""OPS-377 process exits and disabled-alert retirement; fixtures only."""

from contextlib import redirect_stdout
from dataclasses import replace
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import test_ib_gateway_session_supervisor as fixture
import notification_delivery
import notification_state

sup = fixture.sup
engine = sup.engine


class SessionExitTests(unittest.TestCase):
    def setUp(self):
        scratch = fixture.REPO / "tests" / ".tmp"
        scratch.mkdir(exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(dir=scratch)
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config = replace(
            sup.Config(), state_path=str(self.root / "supervisor.json"),
            alert_state_path=str(self.root / "alerts.json"),
            operator_clear_path=str(self.root / "operator-clear"),
        )
        self.healthy = fixture.obs(
            api_listening=True, login_state=sup.LOGIN_LOGGED_IN,
            pusher=fixture.pusher(gateway=True),
        )

    def main(self, config=None, observation=None):
        output = io.StringIO()
        with mock.patch.object(sup, "config_from_env", return_value=config or self.config), \
                mock.patch.object(sup, "observe_runtime", return_value=observation or self.healthy), \
                mock.patch.object(sup.subprocess, "run", side_effect=AssertionError("external process forbidden")), \
                mock.patch.object(sup.subprocess, "Popen", side_effect=AssertionError("external process forbidden")), \
                redirect_stdout(output):
            code = sup.main()
        lines = output.getvalue().splitlines()
        return code, lines[:-1], json.loads(lines[-1])

    def seed_alerts(self, kind="problem"):
        directory = str(Path(self.config.alert_state_path).with_suffix(".channels"))
        sent = mock.Mock(return_value=kind != "problem")
        notification_state.run_notifications(
            directory, fixture.NOW - 600, False, True, "Synthetic session unavailable.",
            {"email": sent, "grok": sent},
        )
        if kind == "recovery":
            sent.return_value = False
            notification_state.run_notifications(
                directory, fixture.NOW - 300, True, False, "", {"email": sent, "grok": sent},
            )
        engine.atomic_write_state(self.config.alert_state_path, {
            "seen": {sup.PROBLEM_KEY: {"text": "Synthetic session unavailable.", "alerted": True}},
            "pending": {"text": "Synthetic transition.", "event_id": "fixture-event",
                        "next_state": {"seen": {}, "pending": None}},
        })
        return [Path(directory) / channel / "state.json" for channel in ("email", "grok")]

    def test_healthy_disabled_retires_problem_recovery_and_announced_outage(self):
        cases = [
            ({"alert_enable": False, "alert_transport": "email-agent-bus"}, "alert-enable-false"),
            ({"alert_enable": True, "alert_transport": "none"}, "transport-none"),
            ({"alert_enable": True, "alert_transport": "agent-bus"}, "receiver-parked"),
            ({"alert_enable": True, "alert_transport": "shoutrrr"}, "receiver-not-declared"),
        ]
        for overrides, reason in cases:
            for kind in ("problem", "recovery", "announced"):
                with self.subTest(reason=reason, kind=kind):
                    paths = self.seed_alerts(kind)
                    config = replace(self.config, **overrides)
                    with mock.patch.object(notification_delivery, "declared_senders") as senders:
                        code, warnings, summary = self.main(config)
                    self.assertEqual(code, 0)
                    self.assertEqual(warnings, [f"warning: alert adapter disabled; reason={reason}"])
                    self.assertEqual(summary["phase"], sup.PHASE_API_READY)
                    self.assertEqual(summary["alert"], f"not-sent:{reason}")
                    senders.assert_not_called()
                    for path in paths:
                        state = json.loads(path.read_text())
                        self.assertIsNone(state["pending"])
                        self.assertIsNone(state["outage"])
                        self.assertEqual(state["retired"]["reason"], reason)
                        self.assertNotIn("text", path.read_text())
                        self.assertNotIn("event_id", path.read_text())
                    legacy = json.loads(Path(config.alert_state_path).read_text())
                    self.assertIsNone(legacy["pending"])
                    self.assertEqual(legacy["seen"], {})
                    before = [path.read_bytes() for path in paths]
                    self.assertEqual(self.main(config)[0], 0)
                    self.assertEqual([path.read_bytes() for path in paths], before)

    def test_disabled_unhealthy_cases_remain_process_failures(self):
        cases = [
            (fixture.obs(lock_available=False), sup.SupervisorState()),
            (fixture.obs(manual_action="operator-auth", auth_failure_class="invalid_credentials"),
             sup.SupervisorState()),
            (fixture.obs(), sup.SupervisorState(restarts_this_outage=1, operator_clear_required=True)),
            (self.healthy, None),  # Corrupt state remains halted even with healthy API probes.
        ]
        for observation, state in cases:
            with self.subTest(state=state, observation=observation):
                paths = self.seed_alerts()
                before = [path.read_bytes() for path in paths]
                if state is None:
                    Path(self.config.state_path).write_text("{")
                else:
                    sup.save_supervisor_state(self.config.state_path, state)
                code, warnings, summary = self.main(observation=observation)
                self.assertEqual(code, sup.EXIT_SESSION_PROBLEM)
                self.assertEqual(warnings, ["warning: alert adapter disabled; reason=alert-enable-false"])
                self.assertNotEqual(summary["phase"], sup.PHASE_API_READY)
                self.assertEqual([path.read_bytes() for path in paths], before)

    def test_disabled_unknown_preserves_pending_state(self):
        paths = self.seed_alerts()
        before = [path.read_bytes() for path in paths]
        _, warnings, summary = self.main(observation=fixture.obs(probe_unknown=True))
        self.assertEqual(summary["phase"], sup.PHASE_UNKNOWN)
        self.assertEqual(len(warnings), 1)
        self.assertEqual([path.read_bytes() for path in paths], before)

    def test_enabled_failed_channel_retries_original_problem_before_recovery(self):
        paths = self.seed_alerts()
        original = json.loads(paths[1].read_text())["pending"]["event_id"]
        sender = mock.Mock(return_value=False)
        config = replace(self.config, alert_enable=True, alert_transport="email-agent-bus")
        with mock.patch.object(notification_delivery, "declared_senders", return_value={"grok": sender}):
            code, _, summary = self.main(config)
            self.assertEqual(code, engine.EXIT_UNDELIVERED)
            self.assertEqual(summary["alert"], "undelivered")
            self.assertEqual(json.loads(paths[1].read_text())["pending"]["event_id"], original)
            sender.assert_called_once_with("Synthetic session unavailable.", original)
            # The retry clock and original event survive a healthy poll.
            self.assertEqual(self.main(config)[0], engine.EXIT_UNDELIVERED)
            self.assertEqual(sender.call_count, 1)
            sender.return_value = True
            later = replace(self.healthy, now=fixture.NOW + 300)
            self.assertEqual(self.main(config, later)[0], 0)
            self.assertEqual(sender.call_args.args[1], original)
            self.assertEqual(self.main(config, later)[0], 0)
            self.assertIn("recovered", sender.call_args.args[0])
            self.assertIsNone(json.loads(paths[1].read_text())["outage"])

    def test_enabled_missing_declared_receiver_is_a_failure(self):
        for transport in ("shoutrrr", "email-agent-bus"):
            with self.subTest(transport=transport):
                config = replace(
                    self.config, alert_enable=True, alert_transport=transport,
                    notification_env=str(self.root / "missing-declared-notification"),
                    notification_config=str(self.root / "missing-declared-destinations"),
                )
                self.seed_alerts()
                code, _, summary = self.main(config)
                self.assertEqual(code, engine.EXIT_UNDELIVERED)
                self.assertEqual(summary["alert"], "undelivered")

    def test_healthy_email_only_retires_unenrolled_chat_without_dropping_email(self):
        paths = self.seed_alerts()
        config = replace(self.config, alert_enable=True, alert_transport="email-agent-bus")
        email = mock.Mock(return_value=False)
        with mock.patch.object(notification_delivery, "declared_senders", return_value={"email": email}):
            # A failed configured email stays red even while absent chat retires.
            self.assertEqual(self.main(config)[0], engine.EXIT_UNDELIVERED)
            self.assertIsNotNone(json.loads(paths[0].read_text())["pending"])
            chat = json.loads(paths[1].read_text())
            self.assertIsNone(chat["pending"])
            self.assertEqual(chat["retired"]["reason"], "receiver-not-enrolled")
            self.assertIsNotNone(json.loads(Path(config.alert_state_path).read_text())["pending"])
            email.return_value = True
            later = replace(self.healthy, now=fixture.NOW + 300)
            self.assertEqual(self.main(config, later)[0], 0)
            self.assertEqual(self.main(config, later)[0], 0)
            self.assertIn("recovered", email.call_args.args[0])

    def test_enabled_ineligible_failure_is_not_hidden_by_clean_delivery(self):
        config = replace(self.config, alert_enable=True, alert_transport="email-agent-bus")
        with mock.patch.object(notification_delivery, "declared_senders", return_value={}):
            code, _, _ = self.main(config, fixture.obs(lock_available=False))
        self.assertEqual(code, sup.EXIT_SESSION_PROBLEM)


if __name__ == "__main__":
    unittest.main()
