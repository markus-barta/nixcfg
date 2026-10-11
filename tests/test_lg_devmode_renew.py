"""OPS-309: offline HTTP, durable daily streaks and credential non-disclosure."""
from __future__ import annotations

import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "hosts/hsb0/lg-devmode-renew.py"
sys.path.insert(0, str(REPO / "modules/shared/fleet-alerts"))
sys.path.insert(0, str(REPO / "modules/ib-gateway-session"))
SPEC = importlib.util.spec_from_file_location("lg_devmode_renew", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load LG Developer Mode renewal helper")
renew = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = renew
SPEC.loader.exec_module(renew)


def response(document=None, status=200, returncode=0, stderr=b""):
    if document is None:
        document = {"result": "success", "errorCode": "200", "errorMsg": "999:59:40"}
    body = document if isinstance(document, bytes) else json.dumps(document).encode()
    return subprocess.CompletedProcess([], returncode, body + f"\n{status}".encode(), stderr)


class RenewalTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.token = "a" * 64  # Synthetic fixture only.
        self.credential = self.root / "token"
        self.credential.write_text("LG_DEVMODE_TOKEN=" + self.token + "\n")
        self.credential.chmod(0o600)
        self.state_path = self.root / "state.json"
        self.now = dt.datetime(2026, 10, 10, 0, 30, tzinfo=dt.timezone(dt.timedelta(hours=2)))
        self.alerts = []
        self.requests = []
        self.sleeps = []
        self.output = io.StringIO()

    def sender(self, text, identifier):
        self.alerts.append((text, identifier))
        return True

    def run_cycle(self, replies=None, day=0, senders=None, check=None):
        queue = list(replies or [response()])

        def http(command, **kwargs):
            self.requests.append((command, kwargs))
            if b"CheckDevModeSession.dev" in kwargs["input"]:
                item = check if check is not None else response()
            else:
                item = queue.pop(0) if len(queue) > 1 else queue[0]
            if isinstance(item, Exception):
                raise item
            return item

        with contextlib.redirect_stdout(self.output), mock.patch.object(renew.subprocess, "run", http):
            return renew.run_cycle(self.credential, self.state_path, "curl-fixture",
                                   {"email": self.sender} if senders is None else senders,
                                   sleep=self.sleeps.append,
                                   clock=lambda: self.now + dt.timedelta(days=day))

    def state(self):
        return json.loads(self.state_path.read_text())

    def failing(self, day=0, senders=None):
        return self.run_cycle([response({"result": "fail", "errorCode": "401"})],
                              day=day, senders=senders)

    def test_success_and_remaining_time(self):
        self.assertEqual(self.run_cycle(), 0)
        self.assertEqual(self.state()["consecutive_failed_days"], 0)
        self.assertEqual(self.state()["last_success_time"], "2026-10-09T22:30:00+00:00")
        self.assertIn("renewal success", self.output.getvalue())
        self.assertIn("remaining_session_time=999:59:40", self.output.getvalue())
        self.assertEqual(self.sleeps, [])
        self.assertEqual(len(self.requests), 2)
        self.assertEqual(self.alerts, [])
        self.assertEqual(self.state_path.stat().st_mode & 0o777, 0o600)

    def test_lg_error_json(self):
        self.assertEqual(self.failing(), 1)
        self.assertIn("reason=lg-error HTTP=200 LG_errorCode=401", self.output.getvalue())
        self.assertEqual(self.sleeps, [60, 300, 900])
        self.assertEqual(len(self.requests), 5)
        self.assertEqual(self.state()["consecutive_failed_days"], 1)

    def test_http_500_is_not_success_even_with_success_json(self):
        self.assertEqual(self.run_cycle([response(status=500)]), 1)
        self.assertIn("reason=http HTTP=500 LG_errorCode=200", self.output.getvalue())
        self.assertEqual(self.state()["consecutive_failed_days"], 1)

    def test_http_500_with_html_reports_status(self):
        self.run_cycle([response(b"<html>upstream down</html>", status=500)])
        self.assertIn("HTTP=500 LG_errorCode=unavailable", self.output.getvalue())

    def test_success_result_requires_lg_code_200(self):
        self.assertEqual(self.run_cycle([response({"result": "success", "errorCode": "403"})]), 1)
        self.assertIn("reason=lg-error HTTP=200 LG_errorCode=403", self.output.getvalue())

    def test_invalid_or_oversized_json_does_not_succeed(self):
        for body, reason in ((b"not-json", "invalid-json"), (b"[]", "invalid-json"),
                             (b"x" * (renew.MAX_RESPONSE + 1), "response-too-large")):
            with self.subTest(reason=reason):
                self.assertEqual(self.run_cycle([response(body)]), 1)
                self.assertIn("reason=" + reason, self.output.getvalue())

    def test_timeout_exception_does_not_echo_argv_or_response(self):
        error = subprocess.TimeoutExpired(self.token, 20, output=self.token, stderr=self.token)
        self.assertEqual(self.run_cycle([error]), 1)
        self.assertIn("reason=timeout", self.output.getvalue())
        self.assertEqual(self.sleeps, [60, 300, 900])
        self.assertTrue(self.token not in self.output.getvalue(), "credential disclosed in logs")

    def test_curl_network_and_timeout_exit_codes(self):
        for code, reason in ((6, "network"), (28, "timeout")):
            with self.subTest(code=code):
                self.run_cycle([response(returncode=code)])
                self.assertIn("reason=" + reason, self.output.getvalue())

    def test_retry_then_success_resets_streak(self):
        self.failing()
        self.sleeps.clear()
        self.assertEqual(self.run_cycle([response(status=500), response()], day=1), 0)
        self.assertEqual(self.sleeps, [60])
        self.assertEqual(self.state()["consecutive_failed_days"], 0)
        self.assertIsNone(self.state()["last_failed_day"])

    def test_same_day_manual_runs_count_once(self):
        self.failing()
        self.failing()
        self.assertEqual(self.state()["consecutive_failed_days"], 1)
        self.assertEqual(self.alerts, [])
        self.failing(day=1)
        self.failing(day=1)
        self.assertEqual(self.state()["consecutive_failed_days"], 2)
        self.assertEqual(len(self.alerts), 1)

    def test_alert_once_per_streak_and_recovery_once(self):
        for day in range(4):
            self.failing(day=day)
        self.assertEqual(len(self.alerts), 1)
        self.assertEqual(self.alerts[0][0], renew.failure_message(2))
        self.assertEqual(self.state()["consecutive_failed_days"], 4)
        self.assertEqual(self.run_cycle(day=4), 0)
        self.run_cycle(day=4)
        self.run_cycle(day=5)
        self.assertEqual(len(self.alerts), 2)
        self.assertIn("recovered", self.alerts[1][0])
        self.assertTrue(self.alerts[0][1].endswith("-failure"))
        self.assertTrue(self.alerts[1][1].endswith("-recovery"))
        self.assertEqual(self.state()["recoveries"], [])

    def test_new_streak_can_alert_again(self):
        self.failing()
        self.failing(day=1)
        self.run_cycle(day=2)
        self.failing(day=3)
        self.failing(day=4)
        self.assertEqual(len(self.alerts), 3)
        self.assertNotEqual(self.alerts[0][1], self.alerts[2][1])

    def test_gap_does_not_invent_failed_days(self):
        self.failing()
        self.failing(day=3)
        self.assertEqual(self.state()["consecutive_failed_days"], 1)
        self.assertEqual(self.alerts, [])
        self.failing(day=4)
        self.assertEqual(len(self.alerts), 1)

    def test_clock_rollback_does_not_increment_or_reannounce(self):
        self.failing(day=1)
        self.failing()
        self.assertEqual(self.state()["consecutive_failed_days"], 1)
        self.assertEqual(self.state()["last_failed_day"], "2026-10-11")

    def test_delivery_retries_without_resending_successful_channel(self):
        mail = mock.Mock(return_value=True)
        telegram = mock.Mock(side_effect=[False, True])
        senders = {"email": mail, "telegram": telegram}
        self.failing(senders=senders)
        self.failing(day=1, senders=senders)
        self.failing(day=1, senders=senders)
        self.failing(day=2, senders=senders)
        self.assertEqual(mail.call_count, 1)
        self.assertEqual(telegram.call_count, 2)
        self.assertEqual(set(self.state()["failure_notified"]), {"email", "telegram"})

    def test_failed_recovery_is_durable_and_retried_once(self):
        self.failing()
        self.failing(day=1)
        sender = mock.Mock(side_effect=[False, True])
        self.assertEqual(self.run_cycle(day=2, senders={"email": sender}), 1)
        self.assertEqual(len(self.state()["recoveries"]), 1)
        self.assertEqual(self.run_cycle(day=3, senders={"email": sender}), 0)
        self.run_cycle(day=3, senders={"email": sender})
        self.assertEqual(sender.call_count, 2)
        self.assertEqual(self.state()["recoveries"], [])

    def test_no_recovery_for_an_undelivered_failure(self):
        sender = mock.Mock(return_value=False)
        self.failing(senders={"email": sender})
        self.failing(day=1, senders={"email": sender})
        self.run_cycle(day=2, senders={"email": sender})
        self.assertEqual(sender.call_count, 1)
        self.assertEqual(self.state()["recoveries"], [])

    def test_optional_check_failure_does_not_undo_success(self):
        self.assertEqual(self.run_cycle(check=response(status=500)), 0)
        self.assertIn("check failed", self.output.getvalue())
        self.assertIn("remaining_session_time=unavailable", self.output.getvalue())
        self.assertIsNotNone(self.state()["last_success_time"])

    def test_missing_credential_records_failure_without_requests(self):
        absent = self.root / "absent"
        with mock.patch.object(renew, "read_token", side_effect=FileNotFoundError(absent)):
            self.assertEqual(self.run_cycle(), 1)
        self.assertEqual(self.requests, [])
        self.assertEqual(self.sleeps, [])
        self.assertEqual(self.state()["consecutive_failed_days"], 1)

    def test_credential_custody_and_format(self):
        self.credential.chmod(0o644)
        with self.assertRaises(ValueError):
            renew.read_token(self.credential)
        self.credential.chmod(0o600)
        self.credential.write_text("LG_DEVMODE_TOKEN=invalid\n")
        with self.assertRaises(ValueError):
            renew.read_token(self.credential)
        link = self.root / "link"
        link.symlink_to(self.credential)
        with self.assertRaises(OSError):
            renew.read_token(link)

    def test_corrupt_state_fails_closed_without_http_or_alert(self):
        self.state_path.write_text("{}")
        with self.assertRaises(ValueError):
            self.run_cycle()
        self.assertEqual(self.requests, [])
        self.assertEqual(self.alerts, [])

    def test_reflected_credentials_never_reach_logs_state_messages_or_argv(self):
        reflected = response({"result": self.token, "errorCode": self.token, "errorMsg": self.token},
                             stderr=self.token.encode())
        self.run_cycle([reflected], check=reflected)
        self.run_cycle([reflected], day=1, check=reflected)
        artifacts = self.output.getvalue() + self.state_path.read_text() + json.dumps(self.alerts)
        self.assertTrue(self.token not in artifacts, "credential disclosed in output/state/notification")
        for command, kwargs in self.requests:
            self.assertTrue(self.token not in json.dumps(command), "credential disclosed in argv")
            self.assertTrue(self.token.encode() in kwargs["input"], "credential must travel via stdin")
            self.assertEqual(kwargs["timeout"], 20)
            self.assertEqual(command[1], "--disable")
            self.assertEqual(command[-2:], ["--config", "-"])
            self.assertNotIn("--location", command)

    def test_real_child_argv_and_ps_exclude_token(self):
        fake_curl = self.root / "curl-fixture"
        capture = self.root / "argv.json"
        fake_curl.write_text(
            f"#!{sys.executable}\n"
            "import json, os, subprocess, sys\n"
            "raw = sys.stdin.read()\n"
            f"with open({str(capture)!r}, 'w') as handle:\n"
            "    json.dump({'argv': sys.argv, 'ps': subprocess.check_output(\n"
            "        ['ps', '-o', 'command=', '-p', str(os.getpid())]).decode()}, handle)\n"
            "print(raw, file=sys.stderr)\n"
            "print(json.dumps({'result': 'success', 'errorCode': '200', 'errorMsg': raw}))\n"
            "print('200', end='')\n"
        )
        fake_curl.chmod(0o700)
        environment = os.environ.copy()
        environment.update(CREDENTIALS_DIRECTORY=str(self.root), STATE_DIRECTORY=str(self.root),
                           LG_DEVMODE_CURL=str(fake_curl), PYTHONDONTWRITEBYTECODE="1",
                           PYTHONPATH=os.pathsep.join(sys.path[:2]))
        result = subprocess.run([sys.executable, str(SCRIPT), "--renew"], env=environment,
                                capture_output=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(self.token.encode() not in result.stdout + result.stderr,
                        "credential disclosed in process output")
        self.assertTrue(self.token not in capture.read_text(), "credential disclosed in argv or ps")
        self.assertTrue(self.token not in self.state_path.read_text(), "credential disclosed in state")

    def test_default_cli_checks_without_renewing_or_writing_state(self):
        with mock.patch.object(sys, "argv", [str(SCRIPT)]), \
                mock.patch.dict(os.environ, {"CREDENTIALS_DIRECTORY": str(self.root)}), \
                mock.patch.object(renew, "request", return_value=renew.Outcome(True, "success")) as request, \
                contextlib.redirect_stdout(self.output):
            self.assertEqual(renew.main(), 0)
        self.assertFalse(request.call_args.args[1])
        self.assertFalse(self.state_path.exists())

    def test_existing_email_helper_uses_private_destination_and_lg_subject(self):
        document = {"schema_version": 1, "email": {"from": "monitor@example.invalid",
                    "to": "recipient@example.invalid"}}
        destinations = self.root / "destinations.json"
        destinations.write_text(json.dumps(document))
        destinations.chmod(0o600)
        senders = renew.existing_senders(self.root, "docker-fixture")
        self.assertEqual(set(senders), {"email"})
        with mock.patch.object(renew.subprocess, "run", return_value=response()) as send:
            self.assertTrue(senders["email"](renew.failure_message(2), "lgdevmode-fixture-failure"))
        self.assertEqual(send.call_args.args[0][:4], ["docker-fixture", "exec", "-i", "docker-smtp-1"])
        message = send.call_args.kwargs["input"]
        self.assertIn(b"Subject: LG beamer Developer Mode", message)
        self.assertIn(b"To: recipient@example.invalid", message)

    def test_existing_shoutrrr_env_is_supported_without_new_secret(self):
        notification_env = self.root / "notification-env"
        notification_env.write_text("WATCHTOWER_NOTIFICATION_URL=telegram://fixture@telegram?chats=-123\n")
        notification_env.chmod(0o600)
        senders = renew.existing_senders(self.root, "docker-fixture")
        self.assertEqual(set(senders), {"telegram"})


if __name__ == "__main__":
    unittest.main()
