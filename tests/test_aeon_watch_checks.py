"""OPS-307: fixture traffic, public probes and durable two-way debounce."""

from __future__ import annotations

import contextlib
import errno
import http.client
import http.server
import importlib.util
import io
import json
import re
import subprocess
import sys
import tempfile
import threading
import types
import unittest
import urllib.error
import uuid
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
    source = source.replace("@PROBE_TENANT@", "0000a0e7000040008000000000000307")
    source = source.replace("@WATCH_INTERVAL_SECONDS@", "30")
    module = types.ModuleType("aeon_watch_checks")
    exec(compile(source, str(CHECKS), "exec"), module.__dict__)
    return module


checks = load_checks()


def fixture(name):
    return (FIXTURES / (name + ".jsonl")).read_text()


def request_line(status=200, path="GET /api/me", method="GET"):
    return json.dumps({"msg": "request", "method": method, "path": path, "status": status}) + "\n"


class TrafficTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        state = patch.object(checks, "STATE_PATH", str(Path(temp.name) / "state.json"))
        state.start()
        self.addCleanup(state.stop)

    def test_below_and_above_threshold_fixtures(self):
        self.assertEqual(checks.traffic_problems(fixture("below-threshold")), [])
        found = checks.traffic_problems(fixture("above-threshold"))
        self.assertEqual(len(found), 1)
        self.assertIn("5/10 API requests 5xx in 30 s", found[0].text)
        self.assertIn("top: GET /api/me 3, GET /api/tasks 1, GET /api/nodes 1", found[0].text)
        self.assertNotIn("/api/health", found[0].text)

    def test_all_three_thresholds_and_exact_boundaries(self):
        for total, failed, alarm in [(9, 3, False), (10, 2, False), (10, 3, True), (30, 3, True), (31, 3, False)]:
            with self.subTest(total=total, failed=failed):
                logs = request_line(500) * failed + request_line() * (total - failed)
                self.assertEqual(bool(checks.traffic_problems(logs)), alarm)

    def test_webhook_excluded_from_numerator_and_denominator(self):
        webhook = fixture("webhook-excluded")
        self.assertEqual(checks.traffic_problems(fixture("below-threshold") + webhook), [])
        found = checks.traffic_problems(fixture("above-threshold") + webhook * 20)
        self.assertIn("5/10 API", found[0].text)
        self.assertNotIn("webhook", found[0].text)
        # Other methods on the same route remain eligible.
        self.assertTrue(checks.traffic_problems(request_line(502, "GET /api/github/webhook") * 5 + request_line() * 15))

    def test_noise_and_malformed_lines_do_not_crash_or_affect_counts(self):
        noise = fixture("unparsable")
        self.assertEqual(checks.traffic_problems(noise), [])
        self.assertIn("5/10 API", checks.traffic_problems(fixture("above-threshold") + noise * 30)[0].text)
        self.assertEqual(checks.traffic_problems(""), [])

    def test_sanitized_unmatched_api_routes_use_method_field(self):
        logs = request_line(500, "/api/{redacted}") * 5 + request_line() * 15
        self.assertIn("GET /api/{redacted} 5", checks.traffic_problems(logs)[0].text)

    def test_docker_stderr_logs_and_exact_read_commands(self):
        responses = [subprocess.CompletedProcess([], 0, "aeon\n", ""),
                     subprocess.CompletedProcess([], 0, "2026-10-11T12:00:00.123456789Z\n", ""),
                     subprocess.CompletedProcess([], 0, "", fixture("above-threshold"))]
        with patch.object(checks.subprocess, "run", side_effect=responses) as run:
            started_at, problems = checks.check_container()
            self.assertEqual(problems, [])
            self.assertIsInstance(started_at, float)
            self.assertIn("5/10 API", checks.check_traffic(started_at + 120, started_at)[0].text)
        self.assertEqual(run.call_args_list[0].args[0], [
            "/fixture/docker", "--host", "unix:///run/docker.sock", "ps", "--filter", "name=^aeon$",
            "--filter", "status=running", "--format", "{{.Names}}"
        ])
        self.assertEqual(run.call_args_list[1].args[0], [
            "/fixture/docker", "--host", "unix:///run/docker.sock", "container", "inspect",
            "-f", "{{.State.StartedAt}}", "aeon"
        ])
        self.assertEqual(run.call_args_list[2].args[0][-4:], ["logs", "--since", "30s", "aeon"])
        for call in run.call_args_list:
            self.assertEqual(call.kwargs["timeout"], 5)
            self.assertTrue(call.kwargs["check"])
            self.assertEqual(call.kwargs["encoding"], "utf-8")
            self.assertEqual(call.kwargs["errors"], "replace")

    def test_stopped_unreadable_and_timed_out_docker(self):
        with patch.object(checks, "docker_command", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            self.assertIn("not running", checks.check_container()[1][0].text)
            self.assertEqual(run.call_count, 1)
        for error in [OSError("raw diagnostic"), subprocess.TimeoutExpired("docker", 5),
                      subprocess.CalledProcessError(1, "docker", stderr="raw log diagnostic")]:
            with patch.object(checks, "docker_command", side_effect=error):
                text = checks.check_container()[1][0].text
                self.assertIn("unreadable", text)
                self.assertNotIn("raw", text)

    def test_log_failure_after_container_check(self):
        with patch.object(checks, "docker_command", side_effect=OSError("raw log diagnostic")):
            self.assertIn("unreadable", checks.check_traffic(1000, 0)[0].text)

    def test_invalid_utf8_docker_output_is_replaced(self):
        real_run = subprocess.run

        def byte_output(_args, **kwargs):
            return real_run([sys.executable, "-c", "import sys; sys.stdout.buffer.write(bytes([255]))"], **kwargs)

        with patch.object(checks.subprocess, "run", side_effect=byte_output):
            self.assertEqual(checks.docker_command(["logs", "--since", "30s", "aeon"]).stdout, "\ufffd")

    def test_own_requests_do_not_supply_floor_or_dilute_errors(self):
        own = request_line(503, "GET /api/health") * 3 + request_line(401) * 3
        real = request_line(500) * 3 + request_line() * 6
        self.assertEqual(checks.traffic_problems(real + own), [])
        found = checks.traffic_problems(real + request_line() + own * 20)
        self.assertIn("3/10 API", found[0].text)
        # Other 401 routes and methods remain real traffic.
        other = request_line(401, "GET /api/tasks") * 4 + request_line(401, "POST /api/me") * 3
        self.assertIn("3/10 API", checks.traffic_problems(request_line(500) * 3 + other)[0].text)

    def test_blindness_ten_minute_boundary_persists_between_processes(self):
        logs = fixture("format-changed")
        self.assertEqual(checks.check_request_log(logs, 1000, 0), [])
        self.assertEqual(checks.check_request_log(logs, 1599, 0), [])
        fresh = load_checks()
        fresh.STATE_PATH = checks.STATE_PATH
        found = fresh.check_request_log(logs, 1600, 0)
        self.assertEqual(found[0].text, "aeon-watch: no parsable request lines for 10 min (log format changed?)")
        self.assertEqual(json.loads(Path(checks.STATE_PATH).with_name("request-log.json").read_text()),
                         {"last_seen": 1000})

    def test_probe_lines_reset_blindness_without_counting_as_traffic(self):
        self.assertEqual(checks.check_request_log("", 1000, 0), [])
        for logs in [request_line(200, "GET /api/health"), request_line(401)]:
            self.assertEqual(checks.traffic_problems(logs), [])
            self.assertEqual(checks.check_request_log(logs, 1600, 0), [])
            self.assertEqual(checks.check_request_log("", 2199, 0), [])
            self.assertTrue(checks.check_request_log("", 2200, 0))

    def test_restart_resets_blindness_and_clock_rollback_is_bounded(self):
        checks.check_request_log("", 1000, 0)
        self.assertEqual(checks.check_request_log("", 1800, 1700), [])
        self.assertEqual(checks.check_request_log("", 900, 0), [])
        self.assertTrue(checks.check_request_log("", 1500, 0))

    def test_traffic_check_reports_changed_format_without_storing_logs(self):
        with patch.object(checks, "docker_command", return_value=subprocess.CompletedProcess(
            [], 0, "", fixture("format-changed")
        )):
            self.assertEqual(checks.check_traffic(1000, 0), [])
            self.assertEqual(checks.check_traffic(1600, 0)[0].key, "aeon:log-format")
        self.assertEqual(set(json.loads(Path(checks.STATE_PATH).with_name("request-log.json").read_text())),
                         {"last_seen"})

    def test_warm_container_skips_logs_and_probes_until_exact_boundary(self):
        for age in [0, 119.999, 120, 121]:
            with self.subTest(age=age), patch.object(checks.time, "time", return_value=1000 + age), \
                 patch.object(checks, "check_container", return_value=(1000, [])), \
                 patch.object(checks, "check_traffic", return_value=[]) as traffic, \
                 patch.object(checks, "check_probes", return_value=[]) as probes:
                self.assertEqual(checks.collect(), [])
                self.assertEqual(traffic.call_count, int(age >= 120))
                self.assertEqual(probes.call_count, int(age >= 120))

    def test_stopped_or_unreadable_container_still_checks_public_probes(self):
        fault = engine.Problem("aeon:traffic", "container not running")
        with patch.object(checks, "check_container", return_value=(None, [fault])), \
             patch.object(checks, "check_traffic") as traffic, \
             patch.object(checks, "check_probes", return_value=[]) as probes:
            self.assertEqual(checks.collect(), [fault])
            traffic.assert_not_called()
            probes.assert_called_once()

    def test_invalid_or_unreadable_started_at_is_a_problem(self):
        for response in [subprocess.CompletedProcess([], 0, "invalid raw data", ""),
                         subprocess.CompletedProcess([], 0, "2026-10-11T12:00:00", ""),
                         OSError("raw diagnostic")]:
            with self.subTest(response=type(response).__name__), patch.object(checks, "docker_command", side_effect=[
                subprocess.CompletedProcess([], 0, "aeon\n", ""), response
            ]):
                started_at, found = checks.check_container()
                self.assertIsNone(started_at)
                self.assertIn("unreadable", found[0].text)
                self.assertNotIn("raw", found[0].text)


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
            self.assertIsInstance(build.call_args.args[0], checks.NoRedirect)
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
        self.assertEqual(self.probe("/api/me", status_error(200))[0], "fake key ACCEPTED — auth bypass?")
        for status in [302, 403, 404, 429, 500, 502, 503]:
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
        self.assertEqual(str(uuid.UUID(checks.PROBE_TENANT)), "0000a0e7-0000-4000-8000-000000000307")
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

    def test_real_loopback_http_errors_and_redirect_refusal(self):
        hits = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                hits.append(self.path)
                status, body = {
                    "/redirect": (302, b"redirect"),
                    "/unauthorized": (401, b"private diagnostic"),
                    "/cloudflare": (403, b"error code: 1010\nprivate diagnostic"),
                    "/target": (200, b'{"db":"ok"}'),
                }[self.path]
                self.send_response(status)
                if status == 302:
                    self.send_header("Location", "/target")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        try:
            server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        except PermissionError as error:
            if error.errno not in {errno.EPERM, errno.EACCES}:
                raise
            self.skipTest("loopback bind denied by sandbox; real HTTP paths need an unrestricted runner")
        with server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                base = f"http://127.0.0.1:{server.server_port}"
                for route, expected in [("/redirect", "returned 302"), ("/unauthorized", None),
                                        ("/cloudflare", "blocked by Cloudflare (403 10xx)")]:
                    with self.subTest(route=route), patch.dict(checks.PROBE_URLS, {"/api/me": base + route}):
                        self.assertEqual(checks.probe_once("/api/me"), expected)
                self.assertNotIn("/target", hits)
            finally:
                server.shutdown()
                worker.join(timeout=5)

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
        self.problem = engine.Problem("aeon:traffic", "aeon.barta.cm: 5/10 API requests 5xx in 30 s")

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
        self.assertIn("recovered:", self.sent[-1][0])
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
        self.assertIn("recovered:", pending["text"])
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

    def test_one_burst_in_distinct_windows_never_pages(self):
        windows = [fixture("above-threshold"), request_line() * 10, request_line() * 10]
        with patch.object(checks, "STATE_PATH", self.state):
            for index, logs in enumerate(windows):
                with patch.object(checks, "check_container", return_value=(0, [])), \
                     patch.object(checks, "check_probes", return_value=[]), \
                     patch.object(checks.time, "time", return_value=1000 + index * 30), \
                     patch.object(checks, "docker_command", return_value=subprocess.CompletedProcess([], 0, logs, "")) as docker, \
                     contextlib.redirect_stdout(io.StringIO()):
                    engine.run_cycle(self.state, 1000 + index * 30, checks.collect, checks.render,
                                     lambda text, identifier: self.sent.append(text) or True, clear_confirm_runs=2)
                    self.assertEqual(docker.call_args.args[0], ["logs", "--since", "30s", "aeon"])
        self.assertEqual(self.sent, [])

    def test_headers_action_and_mixed_recovery(self):
        action = 'check: ssh csb1 \'docker logs --since 5m aeon | grep "\\"status\\":5"\' ; runbook OPS-307'
        self.assertTrue(checks.render(["fault"], []).startswith("🔴 aeon-watch (csb1):\n"))
        self.assertTrue(checks.render([], ["fault"]).startswith("🟢 aeon-watch (csb1) recovered:\n"))
        mixed = checks.render(["new fault"], ["old fault"])
        self.assertIn("🟢 aeon-watch (csb1) recovered:", mixed)
        self.assertEqual(mixed.splitlines()[-1], action)
        self.assertEqual(mixed.count("check:"), 1)
        self.assertEqual(checks.render([], []), "")

    def test_unexpected_crash_exits_two_without_diagnostics(self):
        for failure in [RecursionError("raw log body"), OSError("raw credential detail")]:
            with self.subTest(kind=type(failure).__name__), \
                 patch.object(checks.engine, "env_file_value", return_value="synthetic target"), \
                 patch.object(checks.engine, "shoutrrr_telegram_sender", return_value=lambda *_: True), \
                 patch.object(checks.engine, "run_cycle", side_effect=failure), \
                 contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(checks.main(), 2)
                self.assertIn(type(failure).__name__, output.getvalue())
                self.assertNotIn("raw", output.getvalue())

    def test_collection_and_state_write_crashes_fail_unit(self):
        for target in ["collect", "atomic_write_state"]:
            owner = checks if target == "collect" else checks.engine
            with self.subTest(target=target), patch.object(checks, "STATE_PATH", self.state), \
                 patch.object(checks.engine, "env_file_value", return_value="synthetic target"), \
                 patch.object(checks.engine, "shoutrrr_telegram_sender", return_value=lambda *_: True), \
                 patch.object(checks, "collect", return_value=[]), \
                 patch.object(owner, target, side_effect=OSError("raw diagnostic")), \
                 contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(checks.main(), 2)
                self.assertNotIn("raw", output.getvalue())


if __name__ == "__main__":
    unittest.main()
