"""OPS-307: fixture traffic, public probes and durable two-way debounce."""

from __future__ import annotations

import contextlib
import http.client
import importlib.util
import io
import json
import re
import subprocess
import sys
import tempfile
import types
import unittest
import urllib.error
from collections import deque
from pathlib import Path
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
CHECKS = REPO / "hosts/csb1/aeon-watch-checks.py"
FIXTURES = REPO / "tests/fixtures/aeon-watch"
SPEC = importlib.util.spec_from_file_location("engine", REPO / "modules/shared/fleet-alerts/engine.py")
engine = importlib.util.module_from_spec(SPEC)
sys.modules["engine"] = engine
SPEC.loader.exec_module(engine)


def load_checks():
    source = CHECKS.read_text().replace("@DOCKER_BIN@", "/fixture/docker")
    source = source.replace("@PROBE_TENANT@", "5d32191b252c4ef4a406788316a5ccb7")
    module = types.ModuleType("aeon_watch_checks")
    exec(compile(source, str(CHECKS), "exec"), module.__dict__)
    return module


checks = load_checks()


def fixture(name):
    return (FIXTURES / (name + ".jsonl")).read_text()


def request_line(status=200, path="GET /api/me", method="GET"):
    return json.dumps({"msg": "request", "method": method, "path": path, "status": status}) + "\n"


class TrafficTest(unittest.TestCase):
    def test_below_and_above_threshold_fixtures(self):
        self.assertEqual(checks.traffic_problems(fixture("below-threshold")), [])
        found = checks.traffic_problems(fixture("above-threshold"))
        self.assertEqual(len(found), 1)
        self.assertIn("6/20 API requests 5xx in 60 s", found[0].text)
        self.assertIn("top: GET /api/me 3, GET /api/health 1, GET /api/tasks 1", found[0].text)
        self.assertNotIn("/api/nodes", found[0].text)

    def test_all_three_thresholds_and_exact_boundaries(self):
        for total, failed, alarm in [(19, 5, False), (20, 4, False), (20, 5, True), (50, 5, True), (51, 5, False)]:
            with self.subTest(total=total, failed=failed):
                logs = request_line(500) * failed + request_line() * (total - failed)
                self.assertEqual(bool(checks.traffic_problems(logs)), alarm)

    def test_webhook_excluded_from_numerator_and_denominator(self):
        webhook = fixture("webhook-excluded")
        self.assertEqual(checks.traffic_problems(fixture("below-threshold") + webhook), [])
        found = checks.traffic_problems(fixture("above-threshold") + webhook * 20)
        self.assertIn("6/20 API", found[0].text)
        self.assertNotIn("webhook", found[0].text)
        # Other methods on the same route remain eligible.
        self.assertTrue(checks.traffic_problems(request_line(502, "GET /api/github/webhook") * 5 + request_line() * 15))

    def test_noise_and_malformed_lines_do_not_crash_or_affect_counts(self):
        noise = fixture("unparsable")
        self.assertEqual(checks.traffic_problems(noise), [])
        self.assertIn("6/20 API", checks.traffic_problems(fixture("above-threshold") + noise * 30)[0].text)
        self.assertEqual(checks.traffic_problems(""), [])

    def test_sanitized_unmatched_api_routes_use_method_field(self):
        logs = request_line(500, "/api/{redacted}") * 5 + request_line() * 15
        self.assertIn("GET /api/{redacted} 5", checks.traffic_problems(logs)[0].text)

    def test_docker_stderr_logs_and_exact_read_commands(self):
        responses = [subprocess.CompletedProcess([], 0, "aeon\n", ""),
                     subprocess.CompletedProcess([], 0, "", fixture("above-threshold"))]
        with patch.object(checks.subprocess, "run", side_effect=responses) as run:
            self.assertIn("6/20 API", checks.check_traffic()[0].text)
        self.assertEqual(run.call_args_list[0].args[0], [
            "/fixture/docker", "--host", "unix:///run/docker.sock", "ps", "--filter", "name=^aeon$",
            "--filter", "status=running", "--format", "{{.Names}}"
        ])
        self.assertEqual(run.call_args_list[1].args[0][-4:], ["logs", "--since", "60s", "aeon"])
        for call in run.call_args_list:
            self.assertEqual(call.kwargs["timeout"], 5)
            self.assertTrue(call.kwargs["check"])

    def test_stopped_unreadable_and_timed_out_docker(self):
        with patch.object(checks, "docker_command", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            self.assertIn("not running", checks.check_traffic()[0].text)
            self.assertEqual(run.call_count, 1)
        for error in [OSError("raw diagnostic"), subprocess.TimeoutExpired("docker", 5),
                      subprocess.CalledProcessError(1, "docker", stderr="raw log diagnostic")]:
            with patch.object(checks, "docker_command", side_effect=error):
                text = checks.check_traffic()[0].text
                self.assertIn("unreadable", text)
                self.assertNotIn("raw", text)

    def test_log_failure_after_container_check(self):
        with patch.object(checks, "docker_command", side_effect=[
            subprocess.CompletedProcess([], 0, "aeon\n", ""), OSError("raw log diagnostic")
        ]):
            self.assertIn("unreadable", checks.check_traffic()[0].text)


class Response:
    def __init__(self, status=200, body=b'{"db":"ok"}'):
        self.status, self.body = status, body

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def read(self, limit):
        return self.body[:limit]


def status_error(status, body=b"never log body"):
    return urllib.error.HTTPError("https://aeon.barta.cm/api/me", status, "synthetic", {}, io.BytesIO(body))


class ProbeTest(unittest.TestCase):
    def probe(self, path, answer):
        with patch.object(checks.urllib.request, "build_opener") as build:
            opener = build.return_value
            if isinstance(answer, Exception):
                opener.open.side_effect = answer
            else:
                opener.open.return_value = answer
            result = checks.probe_once(path)
            self.assertEqual(opener.open.call_args.kwargs["timeout"], 5)
            return result, opener.open.call_args.args[0]

    def test_health_ok_down_missing_invalid_and_status(self):
        for response, result in [(Response(), None), (Response(body=b'{"db":"down"}'), "db is not ok"),
                                 (Response(body=b'{}'), "db is not ok"), (Response(body=b'[]'), "db is not ok"),
                                 (Response(body=b'broken'), "returned invalid JSON"), (Response(status=503), "returned 503")]:
            with self.subTest(result=result):
                actual, request = self.probe("/api/health", response)
                self.assertEqual(actual, result)
                self.assertIsNone(request.get_header("Authorization"))

    def test_me_401_and_all_other_statuses(self):
        self.assertIsNone(self.probe("/api/me", status_error(401))[0])
        for status in [200, 302, 403, 404, 429, 500, 502, 503]:
            with self.subTest(status=status):
                self.assertEqual(self.probe("/api/me", status_error(status))[0], f"returned {status}")

    def test_user_agent_is_sent_on_every_probe_request(self):
        for path, response in [("/api/health", Response()), ("/api/me", status_error(401))]:
            with self.subTest(path=path):
                result, request = self.probe(path, response)
                self.assertIsNone(result)
                self.assertEqual(request.get_header("User-agent"), "aeon-watch/1 (OPS-307)")

    def test_cloudflare_403_has_distinct_problem_without_response_body(self):
        body = b"error code: 1010\nprivate response detail"
        for path in checks.PROBE_URLS:
            for answer in [Response(403, body), status_error(403, body)]:
                with self.subTest(path=path, answer=type(answer).__name__):
                    result, _ = self.probe(path, answer)
                    self.assertEqual(result, "blocked by Cloudflare (403 10xx)")

    def test_other_403_and_non_403_cloudflare_text_keep_status_problem(self):
        for path in checks.PROBE_URLS:
            for status, body in [(403, b"permission denied"), (500, b"error code: 1010")]:
                with self.subTest(path=path, status=status):
                    self.assertEqual(self.probe(path, status_error(status, body))[0], f"returned {status}")

    def test_unreadable_403_body_is_a_problem(self):
        for path in checks.PROBE_URLS:
            answer = status_error(403)
            with self.subTest(path=path), patch.object(answer, "read", side_effect=http.client.IncompleteRead(b"raw")):
                self.assertEqual(self.probe(path, answer)[0], "unreachable (IncompleteRead)")

    def test_timeout_and_network_errors_are_problems(self):
        for error, expected in [(TimeoutError("raw"), "timed out"),
                                (urllib.error.URLError(TimeoutError()), "timed out"),
                                (urllib.error.URLError("raw"), "unreachable (URLError)"),
                                (http.client.IncompleteRead(b"raw"), "unreachable (IncompleteRead)")]:
            self.assertEqual(self.probe("/api/me", error)[0], expected)

    def test_new_tenant_prefixed_fake_key_and_connection_per_request(self):
        headers = []
        with patch.object(checks.urllib.request, "build_opener") as build:
            build.return_value.open.side_effect = lambda *_args, **_kwargs: Response(401)
            for _ in range(3):
                self.assertIsNone(checks.probe_once("/api/me"))
                request = build.return_value.open.call_args.args[0]
                headers.append(request.get_header("Authorization"))
                self.assertEqual(request.full_url, "https://aeon.barta.cm/api/me")
                self.assertEqual(request.get_header("Connection"), "close")
                self.assertEqual(request.get_method(), "GET")
            self.assertEqual(build.call_count, 3)
        self.assertEqual(len(set(headers)), 3)
        for header in headers:
            self.assertRegex(header, re.compile(r"^Bearer aeon_" + checks.PROBE_TENANT + r"[0-9a-f]{16}_[0-9a-f]{32}$"))

    def test_redirects_are_rejected(self):
        self.assertIsNone(checks.NoRedirect().redirect_request(None, None, 302, "", {}, "https://example.invalid"))

    def test_three_probes_each_and_failure_counts_with_mocked_http(self):
        answers = {"/api/health": deque([Response(), Response(body=b'{"db":"down"}'), Response()]),
                   "/api/me": deque([status_error(401), status_error(500), status_error(500)])}
        calls = []

        def open_request(request, timeout):
            path = request.full_url.removeprefix("https://aeon.barta.cm")
            calls.append((path, timeout))
            answer = answers[path].popleft()
            if isinstance(answer, Exception):
                raise answer
            return answer

        with patch.object(checks.urllib.request, "build_opener") as build:
            build.return_value.open.side_effect = open_request
            problems = checks.check_probes()
        self.assertEqual(sorted(calls), [("/api/health", 5)] * 3 + [("/api/me", 5)] * 3)
        self.assertEqual(build.call_count, 6)
        self.assertEqual([p.key for p in problems], ["aeon:probe:/api/health", "aeon:probe:/api/me"])
        self.assertIn("db is not ok (1/3)", problems[0].text)
        self.assertIn("returned 500 (2/3)", problems[1].text)
        self.assertNotIn("Bearer", checks.render([p.text for p in problems], []))

    def test_all_good_and_mixed_timeout_counts(self):
        with patch.object(checks, "probe_once", side_effect=lambda path: None):
            self.assertEqual(checks.check_probes(), [])
        answers = deque(["timed out", "returned 500", None])
        with patch.object(checks, "probe_once", side_effect=lambda path: answers.popleft() if path == "/api/me" else None):
            text = checks.check_probes()[0].text
        self.assertIn("timed out (1/3)", text)
        self.assertIn("returned 500 (1/3)", text)


class EngineIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state = str(Path(self.temp.name) / "state.json")
        self.sent = []
        self.deliver = True
        self.stamp = 0
        self.problem = engine.Problem("aeon:traffic", "aeon.barta.cm: 6/20 API requests 5xx in 60 s")

    def run_once(self, bad):
        self.stamp += 30
        def sender(text, identifier):
            if self.deliver:
                self.sent.append((text, identifier))
            return self.deliver
        with contextlib.redirect_stdout(io.StringIO()):
            return engine.run_cycle(self.state, self.stamp, lambda: [self.problem] if bad else [],
                                    checks.render, sender, clear_confirm_runs=2)

    def test_two_bad_then_two_clean_with_persisted_counts(self):
        self.run_once(True)
        self.assertEqual(self.sent, [])
        self.run_once(True)
        self.assertEqual(len(self.sent), 1)
        self.run_once(True)
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.run_once(False), engine.EXIT_CLEAN)
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(engine.load_state(self.state)["seen"]["aeon:traffic"]["clean_count"], 1)
        self.run_once(False)
        self.assertEqual(len(self.sent), 2)
        self.assertIn("Cleared", self.sent[-1][0])
        self.run_once(False)
        self.assertEqual(len(self.sent), 2)

    def test_single_bad_never_announces_or_clears(self):
        for bad in [True, False, True, False, False]:
            self.run_once(bad)
        self.assertEqual(self.sent, [])

    def test_relapse_resets_clean_confirmation(self):
        for bad in [True, True, False, True, False]:
            self.run_once(bad)
        self.assertEqual(len(self.sent), 1)
        self.run_once(False)
        self.assertEqual(len(self.sent), 2)

    def test_status_change_keeps_same_problem_key(self):
        state, announce, _ = engine.advance({}, [engine.Problem("aeon:probe:/api/me", "500")])
        _, announce, _ = engine.advance(state, [engine.Problem("aeon:probe:/api/me", "timeout")])
        self.assertEqual(announce, ["timeout"])

    def test_failed_alert_and_clear_retry_identical_pending_event(self):
        self.run_once(True)
        self.deliver = False
        self.assertEqual(self.run_once(True), engine.EXIT_UNDELIVERED)
        pending = engine.load_state(self.state)["pending"]
        self.deliver = True
        self.run_once(False)
        self.assertEqual(self.sent[0], (pending["text"], pending["event_id"]))
        self.deliver = False
        self.assertEqual(self.run_once(False), engine.EXIT_UNDELIVERED)
        pending = engine.load_state(self.state)["pending"]
        self.assertIn("Cleared", pending["text"])
        self.deliver = True
        self.run_once(False)
        self.assertEqual(self.sent[1], (pending["text"], pending["event_id"]))
        self.assertIsNone(engine.load_state(self.state)["pending"])

    def test_main_opts_in_and_notification_errors_are_redacted(self):
        with patch.object(checks.engine, "env_file_value", return_value="synthetic target"), \
             patch.object(checks.engine, "shoutrrr_telegram_sender", return_value=lambda *_: True), \
             patch.object(checks.engine, "run_cycle", return_value=0) as run:
            self.assertEqual(checks.main(), 0)
            self.assertEqual(run.call_args.kwargs["clear_confirm_runs"], 2)
        with patch.object(checks.engine, "env_file_value", return_value=""), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(checks.main(), engine.EXIT_UNDELIVERED)
        with patch.object(checks.engine, "env_file_value", return_value="synthetic target"), \
             patch.object(checks.engine, "shoutrrr_telegram_sender", side_effect=ValueError("raw diagnostic")), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(checks.main(), engine.EXIT_UNDELIVERED)
            self.assertNotIn("raw", output.getvalue())


if __name__ == "__main__":
    unittest.main()
