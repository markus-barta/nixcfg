"""OPS-675: HTTP fixtures and the real fleet engine; no live delivery or app writes."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import ssl
import sys
import tempfile
import types
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import Mock, patch

REPO = Path(__file__).resolve().parents[1]
CHECKS = REPO / "hosts/csb1/hausvogt-health-watch-checks.py"
ENGINE = REPO / "modules/shared/fleet-alerts/engine.py"
SPEC = importlib.util.spec_from_file_location("engine", ENGINE)
engine = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["engine"] = engine
SPEC.loader.exec_module(engine)

TOKEN = "12345:SYNTHETIC_ops675_token"
TARGET = f"telegram://{TOKEN}@telegram?chats=1"
PRIVATE_BODY = "SYNTHETIC_response_must_stay_private"
GOOD = b'{"status":"ok"}'
BAD = b'{"status":"wrong"}'


def load_checks(source: str | None = None):
    source = CHECKS.read_text() if source is None else source
    source = source.replace(
        "@NOTIFICATION_ENV@",
        "/run/credentials/hausvogt-health-watch.service/notification-env",
    )
    module = types.ModuleType("hausvogt_health_watch_checks")
    module.__file__ = str(CHECKS)
    exec(compile(source, str(CHECKS), "exec"), module.__dict__)
    return module


class Response(io.BytesIO):
    def __init__(self, body=GOOD, status=200):
        super().__init__(body)
        self.status = status
        self.read_limits = []

    def read(self, size=-1):
        self.read_limits.append(size)
        return super().read(size)


class HausvogtHealthWatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.checks = load_checks()
        self.checks.STATE_PATH = str(Path(self.tmp.name) / "state.json")
        self.body = GOOD
        self.status = 200
        self.probe_error = None
        self.delivery_error = None
        self.now = 1_800_000_000.0
        self.sent = []
        self.delivery_attempts = []
        self.responses = []
        self.output = io.StringIO()
        self.opener = Mock()
        self.opener.open.side_effect = self.open_health
        self.builder = self.enterContext(patch.object(
            self.checks.urllib.request, "build_opener", return_value=self.opener,
        ))
        self.credential = self.enterContext(patch.object(
            self.checks.engine, "env_file_value", return_value=TARGET,
        ))
        self.enterContext(patch.object(self.checks.time, "time", side_effect=lambda: self.now))
        self.enterContext(patch.object(
            self.checks.engine.urllib.request, "urlopen", side_effect=self.deliver,
        ))
        self.addCleanup(self.assert_redacted)

    def open_health(self, request, *, timeout):
        self.assertEqual(request.full_url, "https://hausv.org/healthz")
        self.assertEqual(request.get_method(), "GET")
        self.assertIsNone(request.data)
        self.assertEqual(timeout, 10)
        if self.probe_error is not None:
            raise self.probe_error
        response = Response(self.body, self.status)
        self.responses.append(response)
        return response

    def deliver(self, request, *, timeout, context):
        self.assertEqual(request.full_url, f"https://api.telegram.org/bot{TOKEN}/sendMessage")
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(timeout, engine.NETWORK_TIMEOUT_SECONDS)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)
        text = self.checks.engine.urllib.parse.parse_qs(request.data.decode())["text"][0]
        self.delivery_attempts.append(text)
        if self.delivery_error is not None:
            raise self.delivery_error
        self.sent.append(text)
        return io.BytesIO(b'{"ok":true}')

    def cycle(self):
        with contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output):
            result = self.checks.main()
        self.now += 300
        return result

    def state(self):
        return engine.load_state(self.checks.STATE_PATH)

    def assert_redacted(self):
        visible = self.output.getvalue() + repr(self.sent)
        path = Path(self.checks.STATE_PATH)
        if path.exists():
            visible += path.read_text()
        for forbidden in (TOKEN, TARGET, PRIVATE_BODY):
            self.assertNotIn(forbidden, visible)

    def confirm_alarm(self):
        self.body = BAD
        self.assertEqual(self.cycle(), engine.EXIT_PROBLEMS)
        self.assertEqual(self.sent, [])
        self.assertEqual(self.cycle(), engine.EXIT_PROBLEMS)
        self.assertEqual(len(self.sent), 1)

    def test_healthy_marker_is_clean(self):
        for body in (GOOD, b' { "status": "ok" }\n'):
            with self.subTest(body=body):
                self.body = body
                self.assertEqual(self.cycle(), engine.EXIT_CLEAN)
                self.assertEqual(self.state(), {"seen": {}, "pending": None})
        self.assertEqual(self.sent, [])

    def test_wrong_marker_is_a_problem_even_with_http_200(self):
        for body in (BAD, b'{}', b'{"ok":true}', b'{"status":true}',
                     b'{"status":"OK"}', b'{"status":"ok","service":"hausv-org"}'):
            with self.subTest(body=body):
                self.body = body
                problems = self.checks.collect()
                self.assertEqual(len(problems), 1)
                self.assertEqual(problems[0].key, self.checks.PROBLEM_KEY)

    def test_malformed_empty_and_nonobject_bodies_fail(self):
        for body in (b'', b'<html>ok</html>', b'null', b'[]', b'"ok"', b'\xff',
                     b'{"status":"ok"}\ntrailing', PRIVATE_BODY.encode()):
            with self.subTest(body=body):
                self.body = body
                self.assertEqual(len(self.checks.collect()), 1)

    def test_non_200_status_fails_even_with_healthy_marker(self):
        for status in (201, 204, 301, 302, 307, 401, 403, 404, 500, 503):
            with self.subTest(status=status):
                self.status = status
                self.assertEqual(len(self.checks.collect()), 1)

    def test_timeout_tls_http_and_connection_errors_fail_without_details(self):
        errors = [
            TimeoutError(PRIVATE_BODY),
            ssl.SSLError(PRIVATE_BODY),
            urllib.error.URLError(PRIVATE_BODY),
            urllib.error.HTTPError("https://hausv.org/healthz", 503, PRIVATE_BODY, {}, None),
        ]
        for error in errors:
            with self.subTest(error=type(error).__name__):
                self.probe_error = error
                self.assertEqual(len(self.checks.collect()), 1)

    def test_body_is_bounded_and_oversized_json_fails(self):
        self.body = GOOD + b' ' * (512 - len(GOOD))
        self.assertEqual(self.checks.collect(), [])
        self.body += b' '
        self.assertEqual(len(self.checks.collect()), 1)
        self.assertTrue(all(response.read_limits == [513] for response in self.responses))
        self.assertTrue(all(response.closed for response in self.responses))

    def test_fixed_read_only_request_verifies_tls_and_disables_proxies(self):
        self.assertEqual(self.cycle(), engine.EXIT_CLEAN)
        request = self.opener.open.call_args.args[0]
        self.assertEqual(request.get_header("Accept"), "application/json")
        self.assertEqual(request.get_header("User-agent"), "hausvogt-health-watch/1 (OPS-675)")
        proxy, redirects, https = self.builder.call_args.args
        self.assertEqual(proxy.proxies, {})
        self.assertIsInstance(redirects, self.checks.NoRedirectHandler)
        self.assertEqual(https._context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(https._context.check_hostname)
        self.credential.assert_called_once_with(
            "/run/credentials/hausvogt-health-watch.service/notification-env",
            "WATCHTOWER_NOTIFICATION_URL", require_canonical_path=True,
        )

    def test_redirects_are_rejected_instead_of_followed(self):
        # Exercise urllib's error-processing chain with an in-memory HTTPS
        # transport: returning None from redirect_request must become HTTPError.
        class Transport(self.checks.urllib.request.BaseHandler):
            calls = 0

            def https_open(inner, request):
                inner.calls += 1
                response = self.checks.urllib.request.addinfourl(
                    io.BytesIO(GOOD), {"location": "https://other.invalid/healthz"},
                    request.full_url, 302,
                )
                response.msg = "redirect"
                return response

        transport = Transport()
        opener = self.checks.urllib.request.OpenerDirector()
        for handler in (transport, self.checks.NoRedirectHandler(),
                        self.checks.urllib.request.HTTPErrorProcessor(),
                        self.checks.urllib.request.HTTPDefaultErrorHandler()):
            opener.add_handler(handler)
        request = self.checks.urllib.request.Request("https://hausv.org/healthz")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            opener.open(request)
        caught.exception.close()
        self.assertEqual(transport.calls, 1)

    def test_two_failures_alert_once_and_healthy_check_recovers_once(self):
        self.confirm_alarm()
        self.assertIn("🔴 Hausvogt health watch (csb1):", self.sent[0])
        self.assertEqual(self.cycle(), engine.EXIT_PROBLEMS)
        self.assertEqual(len(self.sent), 1)
        self.body = GOOD
        self.assertEqual(self.cycle(), engine.EXIT_CLEAN)
        self.assertEqual(len(self.sent), 2)
        self.assertIn("🟢 Hausvogt health watch (csb1) recovered:", self.sent[1])
        self.assertEqual(self.cycle(), engine.EXIT_CLEAN)
        self.assertEqual(len(self.sent), 2)
        self.assertEqual(self.state(), {"seen": {}, "pending": None})

    def test_single_failure_and_nonconsecutive_failures_stay_silent(self):
        for body in (BAD, GOOD, BAD, GOOD):
            self.body = body
            self.cycle()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.state()["seen"], {})

    def test_different_failure_modes_still_confirm_the_same_problem(self):
        self.probe_error = TimeoutError(PRIVATE_BODY)
        self.assertEqual(self.cycle(), engine.EXIT_PROBLEMS)
        self.probe_error = None
        self.body = BAD
        self.assertEqual(self.cycle(), engine.EXIT_PROBLEMS)
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(list(self.state()["seen"]), [self.checks.PROBLEM_KEY])

    def test_failed_delivery_retries_identical_pending_alarm_then_recovers(self):
        self.body = BAD
        self.cycle()
        self.delivery_error = urllib.error.URLError(TOKEN)
        self.assertEqual(self.cycle(), engine.EXIT_UNDELIVERED)
        pending = self.state()["pending"]
        self.assertTrue(pending["text"])
        self.assertEqual(self.cycle(), engine.EXIT_UNDELIVERED)
        self.assertEqual(self.state()["pending"], pending)
        self.delivery_error = None
        self.assertEqual(self.cycle(), engine.EXIT_PROBLEMS)
        self.assertEqual(self.delivery_attempts, [pending["text"]] * 3)
        self.assertEqual(self.sent, [pending["text"]])
        self.assertIsNone(self.state()["pending"])
        self.body = GOOD
        self.assertEqual(self.cycle(), engine.EXIT_CLEAN)
        self.assertEqual(len(self.sent), 2)

    def test_failed_recovery_delivery_is_retried_once_then_stays_silent(self):
        self.confirm_alarm()
        self.body = GOOD
        self.delivery_error = TimeoutError(TOKEN)
        self.assertEqual(self.cycle(), engine.EXIT_UNDELIVERED)
        pending = self.state()["pending"]
        self.assertIn("recovered", pending["text"])
        self.delivery_error = None
        self.assertEqual(self.cycle(), engine.EXIT_CLEAN)
        self.assertEqual(self.sent[-1], pending["text"])
        self.cycle()
        self.assertEqual(len(self.sent), 2)

    def test_missing_or_bad_notification_target_fails_unit_without_probing(self):
        for value in ("", "invalid", "https://other.invalid/"):
            with self.subTest(value=value):
                self.credential.return_value = value
                self.assertEqual(self.cycle(), engine.EXIT_UNDELIVERED)
        self.opener.open.assert_not_called()

    def test_unexpected_state_failure_is_redacted_and_fails_unit(self):
        with patch.object(self.checks.engine, "run_cycle", side_effect=OSError(TOKEN)):
            self.assertEqual(self.cycle(), engine.EXIT_UNDELIVERED)
        self.assertIn("watch crashed (OSError)", self.output.getvalue())

    def test_alert_state_is_private(self):
        self.cycle()
        self.assertEqual(Path(self.checks.STATE_PATH).stat().st_mode & 0o777, 0o600)


def marker_mutant() -> None:
    """Remove content validation in memory; the HTTP-200/wrong-marker test MUST fail."""
    source = CHECKS.read_text()
    predicate = 'json.loads(body) != {"status": "ok"}'
    assert source.count(predicate) == 1, "content mutant no longer matches the implementation"
    mutant = source.replace(predicate, "False")
    real_loader = load_checks
    with patch(__name__ + ".load_checks", side_effect=lambda: real_loader(mutant)):
        suite = unittest.TestSuite([
            HausvogtHealthWatchTest("test_wrong_marker_is_a_problem_even_with_http_200"),
        ])
        output = io.StringIO()
        result = unittest.TextTestRunner(stream=output).run(suite)
    if result.wasSuccessful() or result.errors or not result.failures:
        raise AssertionError("wrong-marker mutant was not killed by a content assertion")
    print("Content mutant: expected failure observed (HTTP 200 with wrong marker rejected by tests)")


if __name__ == "__main__":
    if sys.argv[1:] == ["--marker-mutant"]:
        marker_mutant()
    else:
        unittest.main()
