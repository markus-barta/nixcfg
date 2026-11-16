"""HTTP-faked queue, delivery and credential-safety tests for OPS-604."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import ssl
import sys
import tempfile
import traceback
import types
import unittest
import urllib.error
import urllib.parse
from pathlib import Path
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
CHECKS = REPO / "hosts" / "csb1" / "garage-bot-watch-checks.py"
ENGINE = REPO / "modules" / "shared" / "fleet-alerts" / "engine.py"

SPEC = importlib.util.spec_from_file_location("engine", ENGINE)
engine = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["engine"] = engine
SPEC.loader.exec_module(engine)

# Entirely synthetic credentials. No production env file or API is accessed.
TOKEN = "12345:SYNTHETIC_ops604_token"
TARGET = f"telegram://{TOKEN}@telegram?chats=1"
API_URL = f"https://api.telegram.org/bot{TOKEN}/getWebhookInfo"
POLLING_KEY = "garage-bot:not-polling"
UNREADABLE_KEY = "garage-bot:unreadable"


def load_checks(notification_path: str):
    source = CHECKS.read_text().replace("@NOTIFICATION_ENV@", notification_path)
    module = types.ModuleType("garage_bot_watch_checks")
    module.__dict__["__file__"] = str(CHECKS)
    exec(compile(source, str(CHECKS), "exec"), module.__dict__)  # noqa: S102
    return module


class GarageBotWatchTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.notification = Path(self.tmp.name) / "notification-env"
        self.notification.write_text(f'WATCHTOWER_NOTIFICATION_URL="{TARGET}"\n')
        self.checks = load_checks(str(self.notification))
        self.checks.STATE_PATH = str(Path(self.tmp.name) / "state.json")
        self.now = 1_800_000_000.0
        self.payload = {"ok": True, "result": {"pending_update_count": 0}}
        self.http_error = None
        self.delivery_error = None
        self.sent = []
        self.requests = []
        self.output = io.StringIO()
        clock = patch.object(self.checks.time, "time", side_effect=lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)
        http = patch.object(self.checks.urllib.request, "urlopen", side_effect=self.http)
        self.urlopen = http.start()
        self.addCleanup(http.stop)
        self.addCleanup(self.assert_redacted)

    def http(self, request, *, timeout, context):
        self.requests.append(request)
        url = urllib.parse.urlsplit(request.full_url)
        self.assertEqual((url.scheme, url.netloc), ("https", "api.telegram.org"))
        self.assertEqual(timeout, self.checks.engine.NETWORK_TIMEOUT_SECONDS)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)
        if url.path.endswith("/getWebhookInfo"):
            self.assertEqual(request.get_method(), "GET")
            self.assertEqual(request.full_url, API_URL)
            self.assertIsNone(request.data)
            if self.http_error is not None:
                raise self.http_error
            body = self.payload if isinstance(self.payload, bytes) else json.dumps(self.payload).encode()
            return io.BytesIO(body)
        self.assertEqual(url.path, f"/bot{TOKEN}/sendMessage")
        self.assertEqual(request.get_method(), "POST")
        message = urllib.parse.parse_qs(request.data.decode())["text"][0]
        if self.delivery_error is not None:
            raise self.delivery_error
        self.sent.append(message)
        return io.BytesIO(b'{"ok":true}')

    def cycle(self) -> int:
        with contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output):
            result = self.checks.main()
        self.now += 300
        return result

    def state(self) -> dict:
        return self.checks.engine.load_state(self.checks.STATE_PATH)

    def queued(self, count) -> None:
        self.payload = {"ok": True, "result": {"pending_update_count": count}}

    def confirm_polling_alarm(self) -> None:
        self.queued(3)
        self.assertEqual(self.cycle(), engine.EXIT_PROBLEMS)
        self.assertEqual(self.sent, [])
        self.assertEqual(self.cycle(), engine.EXIT_PROBLEMS)
        self.assertEqual(len(self.sent), 1)

    def assert_redacted(self) -> None:
        state_path = Path(self.checks.STATE_PATH)
        observable = self.output.getvalue() + repr(self.sent)
        if state_path.exists():
            observable += state_path.read_text()
        for credential in (TOKEN, TARGET, API_URL, urllib.parse.quote(TOKEN, safe="")):
            self.assertNotIn(credential, observable)

    def test_zero_is_clean_and_only_observes_queue(self):
        self.assertEqual(self.cycle(), engine.EXIT_CLEAN)
        self.assertEqual(self.state(), {"seen": {}, "pending": None})
        self.assertEqual(self.sent, [])
        self.assertEqual(len(self.requests), 1)

    def test_positive_count_twice_pages_once_with_latest_count(self):
        self.queued(2)
        self.assertEqual(self.cycle(), engine.EXIT_PROBLEMS)
        self.assertEqual(self.sent, [])
        self.assertFalse(self.state()["seen"][POLLING_KEY]["alerted"])
        self.queued(7)
        self.assertEqual(self.cycle(), engine.EXIT_PROBLEMS)
        self.assertTrue(self.state()["seen"][POLLING_KEY]["alerted"])
        self.assertEqual(len(self.sent), 1)
        self.assertIn("7 messages waiting", self.sent[0])
        self.assertIn("Node-RED on csb0 is not polling (OPS-603)", self.sent[0])
        self.assertIn("restart csb0-nodered-1 after dropping stale updates", self.sent[0])
        self.cycle()
        self.assertEqual(len(self.sent), 1)

    def test_zero_after_announced_backlog_sends_one_recovery(self):
        self.confirm_polling_alarm()
        self.queued(0)
        self.assertEqual(self.cycle(), engine.EXIT_CLEAN)
        self.assertEqual(len(self.sent), 2)
        self.assertIn("queue empty — either Node-RED resumed", self.sent[-1])
        self.assertIn("messages expired after Telegram's 24 h retention", self.sent[-1])
        self.assertIn("confirm the bot answers", self.sent[-1])
        self.assertNotIn("no longer failing", self.sent[-1])
        self.assertEqual(self.state()["seen"], {})
        self.cycle()
        self.assertEqual(len(self.sent), 2)

    def test_backlog_blip_never_pages_or_recovers(self):
        self.queued(1)
        self.cycle()
        self.queued(0)
        self.cycle()
        self.queued(1)
        self.cycle()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.state()["seen"][POLLING_KEY]["count"], 1)

    def test_polling_alarm_reminds_at_six_hours_then_stops_when_queue_empties(self):
        self.confirm_polling_alarm()
        announced_at = self.state()["seen"][POLLING_KEY]["last_announced_at"]
        self.now = announced_at + 6 * 3600 - 300
        self.cycle()
        self.assertEqual(len(self.sent), 1)
        self.cycle()
        self.assertEqual(len(self.sent), 2)
        self.assertIn("Reminder — still failing", self.sent[-1])
        self.assertIn("3 messages waiting", self.sent[-1])
        self.cycle()
        self.assertEqual(len(self.sent), 2)
        self.queued(0)
        self.cycle()
        self.assertEqual(len(self.sent), 3)
        self.now += 6 * 3600
        self.cycle()
        self.assertEqual(len(self.sent), 3)

    def test_unreadable_alarm_has_no_periodic_reminder(self):
        self.http_error = TimeoutError(API_URL)
        self.cycle()
        self.cycle()
        self.now += 6 * 3600
        self.cycle()
        self.assertEqual(len(self.sent), 1)
        self.assertNotIn("last_announced_at", self.state()["seen"][UNREADABLE_KEY])

    def test_api_failure_needs_two_runs_and_then_recovers(self):
        self.http_error = urllib.error.URLError(API_URL)
        self.assertEqual(self.cycle(), engine.EXIT_PROBLEMS)
        self.assertEqual(self.sent, [])
        self.assertEqual(self.cycle(), engine.EXIT_PROBLEMS)
        self.assertEqual(len(self.sent), 1)
        self.assertIn("queue unreadable", self.sent[0])
        self.assertTrue(self.state()["seen"][UNREADABLE_KEY]["alerted"])
        self.http_error = None
        self.assertEqual(self.cycle(), engine.EXIT_CLEAN)
        self.assertEqual(len(self.sent), 2)
        self.assertIn("Telegram queue readable again", self.sent[-1])
        self.assertNotIn("queue empty", self.sent[-1])

    def test_transient_api_failure_is_silent(self):
        self.http_error = TimeoutError(API_URL)
        self.cycle()
        self.http_error = None
        self.cycle()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.state()["seen"], {})

    def test_unreadable_evidence_preserves_announced_polling_problem(self):
        self.confirm_polling_alarm()
        self.http_error = urllib.error.HTTPError(API_URL, 401, TARGET, {}, None)
        self.addCleanup(self.http_error.close)
        self.cycle()
        self.assertEqual(len(self.sent), 1)
        self.assertTrue(self.state()["seen"][POLLING_KEY]["alerted"])
        self.cycle()
        self.assertEqual(len(self.sent), 2)
        self.assertNotIn("Cleared", self.sent[-1])
        self.http_error = None
        self.queued(0)
        self.cycle()
        self.assertEqual(len(self.sent), 3)
        self.assertIn("queue empty — either Node-RED resumed", self.sent[-1])
        self.assertIn("Telegram queue readable again", self.sent[-1])
        self.assertEqual(self.state()["seen"], {})

    def test_readable_api_with_backlog_clears_only_the_unreadable_observation(self):
        self.http_error = TimeoutError(API_URL)
        self.cycle()
        self.cycle()
        self.http_error = None
        self.queued(2)
        self.cycle()
        self.assertIn("Telegram queue readable again", self.sent[-1])
        self.assertNotIn("queue empty", self.sent[-1])
        self.assertNotIn("no longer failing", self.sent[-1])
        self.cycle()
        self.assertIn("2 messages waiting", self.sent[-1])

    def test_failure_breaks_unconfirmed_backlog_sequence(self):
        self.queued(2)
        self.cycle()
        self.http_error = OSError(TARGET)
        self.cycle()
        self.http_error = None
        self.cycle()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.state()["seen"][POLLING_KEY]["count"], 1)

    def test_invalid_api_responses_are_unreadable_without_leaking_body(self):
        for payload in (
            b"not JSON: " + TOKEN.encode(),
            [], None, {}, {"ok": False, "description": TARGET},
            {"ok": 1, "result": {"pending_update_count": 0}},
            {"ok": True, "result": None},
            {"ok": True, "result": []},
            {"ok": True, "result": {}},
            *({"ok": True, "result": {"pending_update_count": count}}
              for count in (True, False, -1, 1.5, "0", TOKEN, None)),
        ):
            with self.subTest(payload=payload):
                self.payload = payload
                problems = self.checks.collect(TOKEN)
                self.assertEqual([p.key for p in problems], [UNREADABLE_KEY])
                self.assertNotIn(TOKEN, repr(problems))
                self.assertNotIn(TARGET, repr(problems))

    def test_delivery_failure_is_redacted_and_retries_durably(self):
        self.queued(1)
        self.cycle()
        self.delivery_error = urllib.error.URLError(TARGET)
        self.assertEqual(self.cycle(), engine.EXIT_UNDELIVERED)
        pending = self.state()["pending"]
        self.assertIsNotNone(pending)
        self.assertEqual(self.sent, [])
        self.delivery_error = None
        self.cycle()
        self.assertEqual(self.sent, [pending["text"]])
        self.assertIsNone(self.state()["pending"])

    def test_malformed_notification_files_do_not_crash_or_leak(self):
        for contents in (
            "", "# no target\n", f"OTHER={TARGET}\n",
            f"WATCHTOWER_NOTIFICATION_URL {TARGET}\n",
            f'WATCHTOWER_NOTIFICATION_URL="{TARGET}\n',
            f"WATCHTOWER_NOTIFICATION_URL=telegram://[{TOKEN}@telegram?chats=1\n",
            f"WATCHTOWER_NOTIFICATION_URL=telegram://{TOKEN}@telegram\n",
        ):
            with self.subTest(contents=contents):
                self.notification.write_text(contents)
                self.assertEqual(self.cycle(), engine.EXIT_UNDELIVERED)
        self.notification.write_bytes(b"WATCHTOWER_NOTIFICATION_URL=\xff" + TOKEN.encode())
        self.assertEqual(self.cycle(), engine.EXIT_UNDELIVERED)
        self.urlopen.assert_not_called()

    def test_missing_notification_file_is_an_undeliverable_unit(self):
        self.checks.NOTIFICATION_ENV = str(Path(self.tmp.name) / "absent")
        self.assertEqual(self.cycle(), engine.EXIT_UNDELIVERED)
        self.urlopen.assert_not_called()

    def test_notification_sender_setup_errors_are_redacted(self):
        with patch.object(self.checks.engine, "shoutrrr_telegram_sender", side_effect=ValueError(TARGET)):
            self.assertEqual(self.cycle(), engine.EXIT_UNDELIVERED)
        self.urlopen.assert_not_called()

    def test_token_parser_errors_have_redacted_exception_text(self):
        for target in (
            "", f"telegram://[{TOKEN}@telegram?chats=1",
            f"https://{TOKEN}@telegram?chats=1",
            f"telegram://{TOKEN}@other?chats=1",
            f"telegram://{TOKEN}@telegram/path?chats=1",
            f"telegram://{TOKEN}@telegram?chats=1#fragment",
            f"telegram://{TOKEN}/injection@telegram?chats=1",
            f"telegram://{TOKEN}%0a@telegram?chats=1",
        ):
            with self.subTest(target=target):
                try:
                    self.checks.notification_token(target)
                except ValueError as error:
                    exposed = "".join(traceback.format_exception(error))
                    self.assertNotIn(TOKEN, exposed)
                    self.assertNotIn(TARGET, exposed)
                    self.assertEqual(str(error), "unsupported notification target")
                else:
                    self.fail("malformed target accepted")

    def test_percent_encoded_token_and_exported_quoted_env_are_supported(self):
        encoded = urllib.parse.quote(TOKEN, safe="")
        self.notification.write_text(
            f"# ignored\nexport WATCHTOWER_NOTIFICATION_URL='telegram://{encoded}@telegram?chats=1'\n"
        )
        self.confirm_polling_alarm()

    def test_notification_url_with_trailing_slash_is_supported(self):
        self.notification.write_text(f"WATCHTOWER_NOTIFICATION_URL=telegram://{TOKEN}@telegram/?chats=1\n")
        self.confirm_polling_alarm()


class GarageBotRecoveryRunbookTest(unittest.TestCase):
    def setUp(self):
        runbook = (REPO / "hosts/csb1/docs/RUNBOOK.md").read_text()
        section = runbook.split("### Garage Telegram Bot Watch", 1)[1].split("### HAUSV", 1)[0]
        source = section.split("sudo python3 - <<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        self.procedure = compile(source, "garage-bot-recovery-runbook", "exec")
        self.requests = []

    def run_procedure(self, responses, *, contents=f"WATCHTOWER_NOTIFICATION_URL='{TARGET}'\n", read_error=None):
        replies = iter(responses)

        def http(request, *, timeout, context):
            self.requests.append(request.full_url)
            self.assertEqual(request.get_method(), "GET")
            self.assertEqual(timeout, engine.NETWORK_TIMEOUT_SECONDS)
            self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
            self.assertTrue(context.check_hostname)
            response = next(replies)
            if isinstance(response, Exception):
                raise response
            body = response if isinstance(response, bytes) else json.dumps(response).encode()
            return io.BytesIO(body)

        output = io.StringIO()
        code = 0
        with (
            patch.object(Path, "read_text", autospec=True, return_value=contents, side_effect=read_error) as read,
            patch("urllib.request.urlopen", side_effect=http),
            contextlib.redirect_stdout(output), contextlib.redirect_stderr(output),
        ):
            try:
                exec(self.procedure, {})  # noqa: S102 -- exact documented heredoc, all I/O faked
            except SystemExit as error:
                code = error.code
        read.assert_called_once_with(Path("/run/agenix/csb1-watchtower-env"), encoding="utf-8")
        self.assertNotIn(TOKEN, output.getvalue())
        self.assertNotIn(TARGET, output.getvalue())
        self.assertEqual(output.getvalue(), "ok\n" if code == 0 else "failure\n")
        return code

    def test_drop_then_verify_zero_before_reporting_ok(self):
        self.assertEqual(self.run_procedure([
            {"ok": True, "result": True},
            {"ok": True, "result": {"pending_update_count": 0}},
        ]), 0)
        self.assertEqual(self.requests, [
            f"https://api.telegram.org/bot{TOKEN}/deleteWebhook?drop_pending_updates=true",
            API_URL,
        ])

    def test_failed_drop_stops_before_verification(self):
        for response in (
            {"ok": False, "description": TARGET},
            {"ok": True, "result": False}, {"ok": True, "result": 1},
            OSError(API_URL), b"invalid JSON " + TOKEN.encode(),
        ):
            with self.subTest(response=response):
                self.requests.clear()
                self.assertEqual(self.run_procedure([response]), 1)
                self.assertEqual(len(self.requests), 1)

    def test_nonzero_or_invalid_counts_never_report_ok(self):
        for count in (1, -1, True, False, 0.0, "0", None, TOKEN):
            with self.subTest(count=count):
                self.assertEqual(self.run_procedure([
                    {"ok": True, "result": True},
                    {"ok": True, "result": {"pending_update_count": count}},
                ]), 1)

    def test_verification_errors_are_redacted(self):
        for response in (
            TimeoutError(API_URL), b"invalid JSON " + TOKEN.encode(),
            {"ok": False, "description": TARGET}, {"ok": True, "result": None},
        ):
            with self.subTest(response=response):
                self.assertEqual(self.run_procedure([{"ok": True, "result": True}, response]), 1)

    def test_unusable_credentials_fail_without_http(self):
        for contents, error in (
            ("", None), (f"WATCHTOWER_NOTIFICATION_URL=https://{TOKEN}@telegram\n", None),
            (f"WATCHTOWER_NOTIFICATION_URL='telegram://[{TOKEN}@telegram'\n", None),
            ("", OSError(TARGET)),
        ):
            with self.subTest(contents=contents, error=error):
                self.assertEqual(self.run_procedure([], contents=contents, read_error=error), 1)
                self.assertEqual(self.requests, [])


if __name__ == "__main__":
    unittest.main()
