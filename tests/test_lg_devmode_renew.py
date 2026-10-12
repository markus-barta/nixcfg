"""OPS-309: offline HTTP, durable daily streaks and credential non-disclosure."""
from __future__ import annotations

import contextlib
import datetime as dt
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from email.parser import BytesParser
from email.policy import default
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
        constants = mock.patch.multiple(
            renew, TOKEN_PATH=self.credential, STATE_PATH=self.state_path,
            DESTINATIONS_FILE="", NOTIFICATION_ENV_FILE="",
            CURL_BIN="/fixture/curl", DOCKER_BIN="/fixture/docker",
            SENDMAIL_BIN="/usr/sbin/sendmail",
        )
        constants.start()
        self.addCleanup(constants.stop)

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

        with contextlib.redirect_stdout(self.output), \
                mock.patch.object(renew.subprocess, "run", http), \
                mock.patch.object(renew, "TOKEN_PATH", self.credential):
            return renew.run_cycle({"email": self.sender} if senders is None else senders,
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

    def test_recovery_is_dropped_after_three_later_retries(self):
        self.failing()
        self.failing(day=1)
        sender = mock.Mock(return_value=False)
        for attempt in range(renew.RECOVERY_RETRIES + 1):
            expected = 1 if attempt < renew.RECOVERY_RETRIES else 0
            self.assertEqual(self.run_cycle(day=attempt + 2, senders={"email": sender}), expected)
            if expected:
                self.assertEqual(self.state()["recoveries"][0]["attempts"], {"email": attempt + 1})
        self.assertEqual(sender.call_count, 4)
        self.assertEqual(self.state()["recoveries"], [])
        self.assertIn("recovery notification dropped channel=email reason=retry-limit", self.output.getvalue())
        self.assertEqual(self.run_cycle(day=6, senders={"email": sender}), 0)
        self.assertEqual(sender.call_count, 4)

    def test_recovery_attempt_is_saved_before_send_and_resumes_at_limit(self):
        self.failing()
        self.failing(day=1)

        def interrupted(_text, _identifier):
            self.assertEqual(self.state()["recoveries"][0]["attempts"], {"email": 1})
            raise RuntimeError("synthetic interruption")

        with self.assertRaises(RuntimeError):
            self.run_cycle(day=2, senders={"email": interrupted})
        state = self.state()
        state["recoveries"][0]["attempts"]["email"] = renew.RECOVERY_RETRIES + 1
        renew.save_state(self.state_path, state)
        sender = mock.Mock(return_value=False)
        self.assertEqual(self.run_cycle(day=3, senders={"email": sender}), 0)
        sender.assert_not_called()
        self.assertEqual(self.state()["recoveries"], [])
        self.assertIn("reason=retry-limit", self.output.getvalue())

    def test_removed_recovery_transport_is_dropped(self):
        self.failing()
        self.failing(day=1)
        self.assertEqual(self.run_cycle(day=2, senders={}), 0)
        self.assertEqual(self.state()["recoveries"], [])
        self.assertIn("recovery notification dropped channel=email reason=no-existing-transport", self.output.getvalue())

    def test_recovery_retries_are_per_channel(self):
        self.failing(senders={"email": self.sender, "telegram": self.sender})
        self.failing(day=1, senders={"email": self.sender, "telegram": self.sender})
        email = mock.Mock(return_value=True)
        telegram = mock.Mock(return_value=False)
        senders = {"email": email, "telegram": telegram}
        self.assertEqual(self.run_cycle(day=2, senders=senders), 1)
        self.assertEqual(self.state()["recoveries"][0]["attempts"], {"telegram": 1})
        for day in range(3, 6):
            self.run_cycle(day=day, senders=senders)
        self.assertEqual(email.call_count, 1)
        self.assertEqual(telegram.call_count, 4)
        self.assertEqual(self.state()["recoveries"], [])

    def test_legacy_pending_recovery_keeps_its_identity(self):
        self.failing()
        self.failing(day=1)
        state = self.state()
        identifier = state["streak_id"]
        state["recoveries"] = [{"id": identifier, "channels": ["email"]}]
        state.update(consecutive_failed_days=0, last_failed_day=None, streak_id=None, failure_notified=[])
        renew.save_state(self.state_path, state)
        self.assertEqual(self.run_cycle(day=2), 0)
        self.assertEqual(self.alerts[-1][1], f"lgdevmode-{identifier}-recovery")
        self.assertEqual(self.state()["recoveries"], [])
        self.assertNotIn("state-reset", self.output.getvalue())

    def test_only_one_queued_recovery_is_sent_per_run(self):
        state = renew.fresh_state()
        state["recoveries"] = [{"id": str(renew.uuid.uuid4()), "channels": ["email"],
                                "attempts": {"email": 0}} for _ in range(5)]
        renew.save_state(self.state_path, state)
        sender = mock.Mock(return_value=True)
        for day in range(5):
            self.assertEqual(self.run_cycle(day=day, senders={"email": sender}), 0 if day == 4 else 1)
            self.assertEqual(sender.call_count, day + 1)
            self.assertEqual(len(self.state()["recoveries"]), 4 - day)

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
        self.credential = self.root / "absent"
        self.assertEqual(self.run_cycle(), 3)
        self.assertEqual(self.requests, [])
        self.assertEqual(self.sleeps, [])
        self.assertEqual(self.state()["consecutive_failed_days"], 1)
        self.assertIn("reason=credential-missing", self.output.getvalue())

    def test_cli_checks_declared_agenix_token_path_and_exits_distinctly(self):
        for arguments in ([], ["--renew"]):
            with self.subTest(arguments=arguments), \
                    mock.patch.object(sys, "argv", [str(SCRIPT), *arguments]), \
                    mock.patch.object(renew, "TOKEN_PATH", self.root / "absent-agenix-token"), \
                    mock.patch.object(renew, "request") as request, \
                    contextlib.redirect_stdout(self.output):
                self.assertEqual(renew.main(), 3)
                request.assert_not_called()
        self.assertIn("reason=credential-missing", self.output.getvalue())

    def test_missing_declared_notification_config_still_renews_and_exits_distinctly(self):
        with mock.patch.object(sys, "argv", [str(SCRIPT), "--renew"]), \
                mock.patch.object(renew, "DESTINATIONS_FILE", str(self.root / "absent-agenix-config")), \
                mock.patch.object(renew, "request", return_value=renew.Outcome(True, "success")) as request, \
                contextlib.redirect_stdout(self.output):
            self.assertEqual(renew.main(), 3)
        self.assertEqual([call.args[1] for call in request.call_args_list], [True, False])
        self.assertIsNotNone(self.state()["last_success_time"])
        self.assertIn("reason=credential-missing kind=email-config", self.output.getvalue())

    def test_no_notification_config_reports_unavailable_transport_after_two_failed_days(self):
        senders = renew.existing_senders()
        self.assertEqual(senders, {})
        self.assertEqual(self.failing(senders=senders), 1)
        self.assertEqual(self.failing(day=1, senders=senders), 1)
        self.assertIn("failure notification unavailable: no existing transport", self.output.getvalue())
        self.assertEqual(self.state()["failure_notified"], [])

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
        with self.assertRaises(ValueError):
            renew.read_token(self.root)

    def test_traversal_and_relative_paths_are_rejected_before_file_access(self):
        (self.root / "nested").mkdir()
        for path in (self.root / "nested" / ".." / "token", Path("token")):
            with self.subTest(path=str(path)), mock.patch.object(renew.os, "open") as opened:
                with self.assertRaises(ValueError):
                    renew.read_token(path)
                opened.assert_not_called()
            with self.subTest(state=str(path)), mock.patch.object(Path, "rename") as quarantine:
                with self.assertRaises(ValueError):
                    renew.load_or_reset_state(path)
                with self.assertRaises(ValueError):
                    renew.save_state(path, renew.fresh_state())
                quarantine.assert_not_called()

    def test_notification_paths_require_absolute_regular_files_without_traversal(self):
        (self.root / "nested").mkdir()
        for path in (Path("token"), self.root / "nested" / ".." / "token", self.root):
            for constant, reader in (("DESTINATIONS_FILE", "private_config"),
                                     ("NOTIFICATION_ENV_FILE", "env_file_value")):
                owner = renew if reader == "private_config" else renew.engine
                with self.subTest(path=str(path), constant=constant), \
                        mock.patch.object(renew, constant, str(path)), \
                        mock.patch.object(owner, reader) as read, \
                        contextlib.redirect_stdout(self.output):
                    self.assertEqual(renew.existing_senders(), {})
                    read.assert_not_called()

    def test_state_reader_rejects_non_regular_files(self):
        with self.assertRaises(ValueError):
            renew.load_state(self.root)

    def test_environment_cannot_override_build_time_paths_or_executables(self):
        # These old overrides must never affect reads, writes, or child argv.
        overrides = {
            "CREDENTIALS_DIRECTORY": str(self.root / "nested" / ".."),
            "STATE_DIRECTORY": str(self.root / "unwanted-state"),
            "LG_DEVMODE_TOKEN_FILE": str(self.root / "absent-token"),
            "LG_DEVMODE_DESTINATIONS_FILE": str(self.credential),
            "LG_DEVMODE_NOTIFICATION_ENV_FILE": str(self.credential),
            "LG_DEVMODE_CURL": "/unwanted/curl",
            "LG_DEVMODE_DOCKER": "/unwanted/docker",
        }
        with mock.patch.dict(os.environ, overrides), \
                mock.patch.object(sys, "argv", [str(SCRIPT), "--renew"]), \
                mock.patch.object(renew.subprocess, "run", return_value=response()) as child, \
                contextlib.redirect_stdout(self.output):
            self.assertEqual(renew.main(), 0)
        self.assertEqual(child.call_count, 2)
        self.assertTrue(all(call.args[0][0] == "/fixture/curl" for call in child.call_args_list))
        self.assertIsNotNone(self.state()["last_success_time"])
        self.assertFalse((self.root / "unwanted-state").exists())
        self.assertEqual(renew.existing_senders(), {})

    def test_corrupt_state_is_quarantined_and_renewal_continues(self):
        self.state_path.write_text("{}")
        self.assertEqual(self.run_cycle(), 0)
        self.assertEqual(len(self.requests), 2)
        quarantines = list(self.root.glob("state.json.corrupt-*"))
        self.assertEqual(len(quarantines), 1)
        self.assertEqual(quarantines[0].read_text(), "{}")
        self.assertIn("state-reset", self.output.getvalue())
        self.assertIsNotNone(self.state()["last_success_time"])
        self.assertEqual(self.alerts, [])

    def test_parse_and_shape_errors_reset_state_without_disclosing_bad_bytes(self):
        cases = [b"", b"invalid-json", b"[]", b"x" * 65537, b"[" * 2000 + b"]" * 2000]
        for field, invalid in (("streak_id", 42), ("last_failed_day", {}),
                               ("last_success_time", []), ("failure_notified", ["email", "email"])):
            cases.append(json.dumps({**renew.fresh_state(), field: invalid}).encode())
        for pending in ({"id": 42, "channels": ["email"]},
                        {"id": str(renew.uuid.uuid4()), "channels": ["email"], "attempts": {"email": -1}}):
            cases.append(json.dumps({**renew.fresh_state(), "recoveries": [pending]}).encode())
        for bad in cases:
            with self.subTest(size=len(bad)):
                self.state_path.write_bytes(bad)
                before = len(self.requests)
                self.assertEqual(self.run_cycle(), 0)
                self.assertEqual(len(self.requests), before + 2)
                self.assertIsNotNone(self.state()["last_success_time"])
        quarantines = list(self.root.glob("state.json.corrupt-*"))
        self.assertEqual(len(quarantines), len(cases))
        self.assertEqual(sorted(path.read_bytes() for path in quarantines), sorted(cases))
        self.assertNotIn("invalid-json", self.output.getvalue())

    def test_unreadable_state_is_quarantined_and_renewal_continues(self):
        self.state_path.write_text("opaque refused state")
        with mock.patch.object(renew, "load_state", side_effect=PermissionError(self.token)):
            self.assertEqual(self.run_cycle(), 0)
        self.assertEqual(len(self.requests), 2)
        quarantines = list(self.root.glob("state.json.corrupt-*"))
        self.assertEqual(len(quarantines), 1)
        self.assertEqual(quarantines[0].read_text(), "opaque refused state")
        self.assertTrue(self.token not in self.output.getvalue(), "exception disclosed credential")

    def test_quarantine_failure_does_not_block_http_renewal(self):
        self.state_path.write_text("{}")
        with mock.patch.object(Path, "rename", side_effect=PermissionError(self.token)):
            self.assertEqual(self.run_cycle(), 0)
        self.assertEqual(len(self.requests), 2)
        self.assertIn("state-reset quarantine=unavailable", self.output.getvalue())
        self.assertTrue(self.token not in self.output.getvalue(), "exception disclosed credential")

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
        # Render the same quoted constants as Nix; the child cannot configure
        # runtime paths/executables through argv or environment anymore.
        rendered = SCRIPT.read_text()
        substitutions = {
            "TOKEN_FILE": str(self.credential), "STATE_DIRECTORY": str(self.root),
            "DESTINATIONS_FILE": "", "NOTIFICATION_ENV_FILE": "",
            "CURL_BIN": str(fake_curl), "DOCKER_BIN": "/fixture/docker",
            "SENDMAIL_BIN": "/usr/sbin/sendmail",
        }
        for key, value in substitutions.items():
            rendered = rendered.replace('"@' + key + '@"', json.dumps(value))
        self.assertNotRegex(rendered, r"@[A-Z_]+@")
        helper = self.root / "renew.py"
        helper.write_text(rendered)
        environment = os.environ.copy()
        environment.update(PYTHONDONTWRITEBYTECODE="1",
                           PYTHONPATH=os.pathsep.join(sys.path[:2]))
        result = subprocess.run([sys.executable, str(helper), "--renew"], env=environment,
                                capture_output=True, timeout=10, check=False)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(self.token.encode() not in result.stdout + result.stderr,
                        "credential disclosed in process output")
        self.assertTrue(self.token not in capture.read_text(), "credential disclosed in argv or ps")
        self.assertTrue(self.token not in self.state_path.read_text(), "credential disclosed in state")

    def test_default_cli_checks_without_renewing_or_writing_state(self):
        with mock.patch.object(sys, "argv", [str(SCRIPT)]), \
                mock.patch.object(renew, "request", return_value=renew.Outcome(True, "success")) as request, \
                contextlib.redirect_stdout(self.output):
            self.assertEqual(renew.main(), 0)
        self.assertFalse(request.call_args.args[1])
        self.assertFalse(self.state_path.exists())

    def test_test_notify_uses_real_mail_path_once_without_token_state_or_lg_access(self):
        destinations = self.root / "destinations.json"
        destinations.write_text(json.dumps({"schema_version": 1, "email": {
            "from": "monitor@example.invalid", "to": "recipient@example.invalid"}}))
        destinations.chmod(0o600)
        self.state_path.write_text("opaque existing state")
        with mock.patch.object(sys, "argv", [str(SCRIPT), "--test-notify"]), \
                mock.patch.object(renew, "DESTINATIONS_FILE", str(destinations)), \
                mock.patch.object(renew, "TOKEN_PATH", self.root / "absent-token"), \
                mock.patch.object(renew, "read_token") as token, \
                mock.patch.object(renew, "load_or_reset_state") as load, \
                mock.patch.object(renew, "save_state") as save, \
                mock.patch.object(renew, "request") as request, \
                mock.patch.object(renew.subprocess, "run", return_value=response()) as send, \
                contextlib.redirect_stdout(self.output):
            self.assertEqual(renew.main(), 0)
        token.assert_not_called()
        load.assert_not_called()
        save.assert_not_called()
        request.assert_not_called()
        send.assert_called_once()
        self.assertEqual(send.call_args.args[0][:5],
                         ["/fixture/docker", "exec", "-i", "docker-smtp-1", "/usr/sbin/sendmail"])
        self.assertEqual(send.call_args.kwargs["timeout"], 20)
        message = BytesParser(policy=default).parsebytes(send.call_args.kwargs["input"])
        self.assertEqual(str(message["Subject"]), "[TEST] LG Developer Mode renew alert path check")
        self.assertEqual(message.get_content().strip(), renew.TEST_ALERT)
        self.assertEqual(self.state_path.read_text(), "opaque existing state")
        self.assertIn("TEST notification accepted channel=email", self.output.getvalue())

    def test_test_notify_sends_only_one_alert_and_returns_delivery_status(self):
        for accepted, status in ((True, 0), (False, 2)):
            email, telegram = mock.Mock(return_value=accepted), mock.Mock(return_value=True)
            with self.subTest(accepted=accepted), \
                    mock.patch.object(sys, "argv", [str(SCRIPT), "--test-notify"]), \
                    mock.patch.object(renew, "existing_senders", return_value={"email": email, "telegram": telegram}), \
                    mock.patch.object(renew, "run_cycle") as run, \
                    contextlib.redirect_stdout(self.output):
                self.assertEqual(renew.main(), status)
                run.assert_not_called()
            email.assert_called_once()
            self.assertEqual(email.call_args.args[0], renew.TEST_ALERT)
            telegram.assert_not_called()
        with mock.patch.object(sys, "argv", [str(SCRIPT), "--test-notify"]), \
                mock.patch.object(renew, "existing_senders", return_value={}), \
                contextlib.redirect_stdout(self.output):
            self.assertEqual(renew.main(), 2)
        self.assertIn("TEST notification unavailable: no existing transport", self.output.getvalue())
        self.assertFalse(self.state_path.exists())

    def test_start_timeout_covers_bounded_work_and_five_minute_margin(self):
        module = (REPO / "hosts/hsb0/lg-devmode-renew.nix").read_text()
        match = re.search(r'TimeoutStartSec = "([0-9]+)min";', module)
        self.assertIsNotNone(match)
        timeout = int(match[1]) * 60
        renewal_and_check = (len(renew.BACKOFF) + 2) * renew.TIMEOUT + sum(renew.BACKOFF)
        # Existing email sender allows 20s each: one queued recovery and one failure.
        self.assertGreaterEqual(timeout, renewal_and_check + 2 * 20 + 5 * 60)

    def test_existing_email_helper_uses_private_destination_and_lg_subject(self):
        document = {"schema_version": 1, "email": {"from": "monitor@example.invalid",
                    "to": "recipient@example.invalid"}}
        destinations = self.root / "destinations.json"
        destinations.write_text(json.dumps(document))
        destinations.chmod(0o600)
        with mock.patch.object(renew, "DESTINATIONS_FILE", str(destinations)), \
                mock.patch.object(renew, "SENDMAIL_BIN", "/fixture/sendmail"):
            senders = renew.existing_senders()
        self.assertEqual(set(senders), {"email"})
        with mock.patch.object(renew.subprocess, "run", return_value=response()) as send:
            self.assertTrue(senders["email"](renew.failure_message(2), "lgdevmode-fixture-failure"))
        self.assertEqual(send.call_args.args[0][:5],
                         ["/fixture/docker", "exec", "-i", "docker-smtp-1", "/fixture/sendmail"])
        message = send.call_args.kwargs["input"]
        self.assertIn(b"Subject: LG beamer Developer Mode", message)
        self.assertIn(b"To: recipient@example.invalid", message)

    def test_existing_shoutrrr_env_is_supported_without_new_secret(self):
        notification_env = self.root / "notification-env"
        notification_env.write_text("WATCHTOWER_NOTIFICATION_URL=telegram://fixture@telegram?chats=-123\n")
        notification_env.chmod(0o600)
        with mock.patch.object(renew, "NOTIFICATION_ENV_FILE", str(notification_env)):
            senders = renew.existing_senders()
        self.assertEqual(set(senders), {"telegram"})


if __name__ == "__main__":
    unittest.main()
