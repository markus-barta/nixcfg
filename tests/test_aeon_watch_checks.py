"""OPS-307: fixture traffic, public probes and durable two-way debounce."""

from __future__ import annotations

import contextlib
import errno
import http.client
import http.server
import importlib.util
import io
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import threading
import types
import unittest
import urllib.error
import uuid
from collections import deque
from datetime import datetime
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
    source = source.replace("@NOTIFICATION_ENV@", "/run/credentials/aeon-watch.service/notification-env")
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
                     subprocess.CompletedProcess([], 0, "2026-10-11T12:00:00.123456789Z 7\n", ""),
                     subprocess.CompletedProcess([], 0, "", fixture("above-threshold"))]
        with patch.object(checks.subprocess, "run", side_effect=responses) as run:
            started_at, restart_count, problems = checks.check_container()
            self.assertEqual(problems, [])
            self.assertIsInstance(started_at, float)
            self.assertEqual(restart_count, 7)
            self.assertIn("5/10 API", checks.check_traffic(started_at + 120, started_at, True)[0].text)
        self.assertEqual(run.call_args_list[0].args[0], [
            "/fixture/docker", "--host", "unix:///run/docker.sock", "ps", "--filter", "name=^aeon$",
            "--filter", "status=running", "--format", "{{.Names}}"
        ])
        self.assertEqual(run.call_args_list[1].args[0], [
            "/fixture/docker", "--host", "unix:///run/docker.sock", "container", "inspect",
            "-f", "{{.State.StartedAt}} {{.RestartCount}}", "aeon"
        ])
        self.assertEqual(run.call_args_list[2].args[0][-6:], [
            "logs", "--since", "2026-10-11T12:01:30.123456+00:00",
            "--until", "2026-10-11T12:02:00.123456+00:00", "aeon",
        ])
        for call in run.call_args_list:
            self.assertEqual(call.kwargs["timeout"], 5)
            self.assertTrue(call.kwargs["check"])
            self.assertEqual(call.kwargs["encoding"], "utf-8")
            self.assertEqual(call.kwargs["errors"], "replace")

    def test_log_window_uses_utc_and_preserves_fractional_start_time(self):
        with patch.object(checks, "docker_command", return_value=subprocess.CompletedProcess([], 0, "", "")) as docker:
            self.assertEqual(checks.check_traffic(1000.125, 0, True), [])
        docker.assert_called_once_with([
            "logs", "--since", "1970-01-01T00:16:10.125000+00:00",
            "--until", "1970-01-01T00:16:40.125000+00:00", "aeon",
        ])

    def test_stopped_unreadable_and_timed_out_docker(self):
        with patch.object(checks, "docker_command", return_value=subprocess.CompletedProcess([], 0, "", "")) as run:
            self.assertIn("not running", checks.check_container()[2][0].text)
            self.assertEqual(run.call_count, 1)
        for error in [OSError("raw diagnostic"), subprocess.TimeoutExpired("docker", 5),
                      subprocess.CalledProcessError(1, "docker", stderr="raw log diagnostic")]:
            with patch.object(checks, "docker_command", side_effect=error):
                text = checks.check_container()[2][0].text
                self.assertIn("unreadable", text)
                self.assertNotIn("raw", text)

    def test_log_failure_after_container_check(self):
        with patch.object(checks, "docker_command", side_effect=OSError("raw log diagnostic")):
            self.assertIn("unreadable", checks.check_traffic(1000, 0, True)[0].text)

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
        self.assertEqual(checks.check_request_log(logs, 1000, 0, True), [])
        self.assertEqual(checks.check_request_log(logs, 1599, 0, True), [])
        fresh = load_checks()
        fresh.STATE_PATH = checks.STATE_PATH
        found = fresh.check_request_log(logs, 1600, 0, True)
        self.assertEqual(found[0].text, "aeon-watch: no parsable request lines for 10 min (log format changed?)")
        self.assertEqual(json.loads(Path(checks.STATE_PATH).with_name("request-log.json").read_text()),
                         {"last_seen": 1000, "reachable": True})

    def test_probe_lines_reset_blindness_without_counting_as_traffic(self):
        self.assertEqual(checks.check_request_log("", 1000, 0, True), [])
        for logs in [request_line(200, "GET /api/health"), request_line(401)]:
            self.assertEqual(checks.traffic_problems(logs), [])
            self.assertEqual(checks.check_request_log(logs, 1600, 0, True), [])
            self.assertEqual(checks.check_request_log("", 2199, 0, True), [])
            self.assertTrue(checks.check_request_log("", 2200, 0, True))

    def test_restart_resets_blindness_and_clock_rollback_is_bounded(self):
        checks.check_request_log("", 1000, 0, True)
        self.assertEqual(checks.check_request_log("", 1800, 1700, True), [])
        self.assertEqual(checks.check_request_log("", 900, 0, True), [])
        self.assertTrue(checks.check_request_log("", 1500, 0, True))

    def test_traffic_check_reports_changed_format_without_storing_logs(self):
        with patch.object(checks, "docker_command", return_value=subprocess.CompletedProcess(
            [], 0, "", fixture("format-changed")
        )):
            self.assertEqual(checks.check_traffic(1000, 0, True), [])
            self.assertEqual(checks.check_traffic(1600, 0, True)[0].key, "aeon:log-format")
        self.assertEqual(set(json.loads(Path(checks.STATE_PATH).with_name("request-log.json").read_text())),
                         {"last_seen", "reachable"})

    def test_newly_started_container_always_checks_logs_and_probes(self):
        for age in [0, 119.999, 120, 121]:
            with self.subTest(age=age), patch.object(checks.time, "time", return_value=1000 + age), \
                 patch.object(checks, "check_container", return_value=(1000, 0, [])), \
                 patch.object(checks, "check_traffic", return_value=[]) as traffic, \
                 patch.object(checks, "check_probes", return_value=(True, [])) as probes:
                self.assertEqual(checks.collect(), [])
                traffic.assert_called_once_with(1000 + age, 1000, True)
                probes.assert_called_once()

    def test_stopped_or_unreadable_container_still_checks_public_probes(self):
        fault = engine.Problem("aeon:traffic", "container not running")
        with patch.object(checks, "check_container", return_value=(None, None, [fault])), \
             patch.object(checks, "check_traffic") as traffic, \
             patch.object(checks, "check_probes", return_value=(True, [])) as probes:
            self.assertEqual(checks.collect(), [fault])
            traffic.assert_not_called()
            probes.assert_called_once()

    def test_invalid_or_unreadable_lifecycle_fields_are_a_problem(self):
        for response in [subprocess.CompletedProcess([], 0, "invalid raw data", ""),
                         subprocess.CompletedProcess([], 0, "2026-10-11T12:00:00 0", ""),
                         subprocess.CompletedProcess([], 0, "2026-10-11T12:00:00Z invalid", ""),
                         subprocess.CompletedProcess([], 0, "2026-10-11T12:00:00Z -1", ""),
                         OSError("raw diagnostic")]:
            with self.subTest(response=type(response).__name__), patch.object(checks, "docker_command", side_effect=[
                subprocess.CompletedProcess([], 0, "aeon\n", ""), response
            ]):
                started_at, restart_count, found = checks.check_container()
                self.assertIsNone(started_at)
                self.assertIsNone(restart_count)
                self.assertIn("unreadable", found[0].text)
                self.assertNotIn("raw", found[0].text)

    def test_blindness_counts_only_reachable_windows(self):
        health_fault = engine.Problem("aeon:probe:/api/health", "health unreachable")
        with patch.object(checks, "check_container", return_value=(0, 0, [])), \
             patch.object(checks, "docker_command", return_value=subprocess.CompletedProcess([], 0, "", "")):
            for now, reachable in [(1000, True), (1599, True), (1600, False),
                                   (2200, False), (2300, True), (2899, True), (2900, True)]:
                with self.subTest(now=now), patch.object(checks.time, "time", return_value=now), \
                     patch.object(checks, "check_probes", return_value=(reachable, [] if reachable else [health_fault])):
                    found = checks.collect()
                    self.assertEqual(any(p.key == "aeon:log-format" for p in found), now == 2900)
                    self.assertEqual(health_fault in found, not reachable)

    def test_unreadable_logs_reset_blind_observation(self):
        checks.check_request_log("", 1000, 0, True)
        with patch.object(checks, "docker_command", side_effect=OSError("raw diagnostic")):
            self.assertEqual(checks.check_traffic(1600, 0, True)[0].key, "aeon:traffic")
        self.assertEqual(checks.check_request_log("", 1700, 0, True), [])
        self.assertEqual(checks.check_request_log("", 2299, 0, True), [])
        self.assertTrue(checks.check_request_log("", 2300, 0, True))

    def test_corrupt_request_state_resets_once_without_diagnostics(self):
        path = Path(checks.STATE_PATH).with_name("request-log.json")
        for raw in ["{raw synthetic", "[]", "{}", '{"last_seen":"raw synthetic"}',
                    '{"last_seen":null}', '{"last_seen":true}', '{"last_seen":NaN}',
                    '{"last_seen":Infinity}', '{"last_seen":1000,"reachable":[]}']:
            with self.subTest(raw=raw):
                path.write_text(raw)
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(checks.check_request_log("", 1000, 0, True), [])
                    self.assertEqual(checks.check_request_log("", 1030, 0, True), [])
                self.assertEqual(output.getvalue().count("resetting request-log.json"), 1)
                self.assertNotIn("raw synthetic", output.getvalue())
                self.assertEqual(json.loads(path.read_text()), {"last_seen": 1000, "reachable": True})

    def test_unexpected_read_exception_resets_request_state(self):
        with patch.object(Path, "read_text", side_effect=RuntimeError("raw diagnostic")), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(checks.check_request_log("", 1000, 0, True), [])
        self.assertEqual(output.getvalue().count("resetting request-log.json"), 1)
        self.assertNotIn("raw", output.getvalue())

    def test_corrupt_request_state_does_not_stop_other_checks(self):
        Path(checks.STATE_PATH).with_name("request-log.json").write_text("{raw synthetic")
        probe_fault = engine.Problem("aeon:probe:/api/me", "returned 500")
        with patch.object(checks, "check_container", return_value=(0, 0, [])), \
             patch.object(checks, "check_probes", return_value=(True, [probe_fault])), \
             patch.object(checks.time, "time", return_value=1000), \
             patch.object(checks, "docker_command", return_value=subprocess.CompletedProcess(
                 [], 0, "", fixture("above-threshold")
             )), contextlib.redirect_stdout(io.StringIO()):
            found = checks.collect()
        self.assertEqual([p.key for p in found], ["aeon:traffic", "aeon:probe:/api/me"])

    def test_restart_history_counts_manual_restarts_and_recreates(self):
        for count in [0, 7]:
            path = str(Path(checks.STATE_PATH).parent / f"case-{count}" / "state.json")
            with self.subTest(count=count), patch.object(checks, "STATE_PATH", path):
                self.assertEqual(checks.check_restarts(1000, 1000, count), [])
                self.assertEqual(checks.check_restarts(1030, 1030, count), [])
                self.assertEqual(checks.check_restarts(1060, 1060, count)[0].text,
                                 "aeon restarting repeatedly (3 starts in 10 min)")
                self.assertTrue(checks.check_restarts(1600, 1060, count))
                self.assertEqual(checks.check_restarts(1600.001, 1060, count), [])

    def test_lifetime_restart_count_is_not_a_recent_crash_loop(self):
        self.assertEqual(checks.check_restarts(1000, 999, 500), [])
        self.assertEqual(checks.check_restarts(1030, 999, 500), [])

    def test_restarts_between_polls_of_an_old_container_are_counted(self):
        self.assertEqual(checks.check_restarts(1000, 0, 50), [])
        found = checks.check_restarts(1030, 1025, 53)
        self.assertEqual(found[0].text, "aeon restarting repeatedly (3 starts in 10 min)")

    def test_missed_restarts_expire_from_the_earliest_possible_time(self):
        checks.check_restarts(1000, 0, 50)
        self.assertTrue(checks.check_restarts(1030, 1025, 53))
        self.assertTrue(checks.check_restarts(1600, 1025, 53))
        self.assertEqual(checks.check_restarts(1600.001, 1025, 53), [])

    def test_recreate_with_counter_reset_includes_its_early_crashes(self):
        checks.check_restarts(1000, 0, 50)
        found = checks.check_restarts(1030, 1025, 2)
        self.assertEqual(found[0].text, "aeon restarting repeatedly (3 starts in 10 min)")

    def test_long_observation_gap_does_not_count_old_restart_delta(self):
        self.assertEqual(checks.check_restarts(1000, 0, 50), [])
        self.assertEqual(checks.check_restarts(2000, 1999, 100), [])

    def test_start_after_run_snapshot_is_counted_and_clamped(self):
        checks.check_restarts(1000, 0, 50)
        found = checks.check_restarts(1030, 1032, 53)
        self.assertEqual(found[0].text, "aeon restarting repeatedly (3 starts in 10 min)")
        path = Path(checks.STATE_PATH).with_name("container.json")
        state = json.loads(path.read_text())
        self.assertEqual(state["starts"], [{"at": 1000, "count": 2}, {"at": 1030, "count": 1}])
        self.assertEqual(state["started_at"], 1032)
        self.assertTrue(checks.check_restarts(1060, 1032, 53))
        self.assertEqual(json.loads(path.read_text())["starts"], state["starts"])
        self.assertEqual(checks.check_restarts(1600.001, 1032, 53), [])

    def test_future_start_identity_does_not_invent_repeated_restarts(self):
        for now in [1000, 1030, 1060, 1090, 1120]:
            self.assertEqual(checks.check_restarts(now, 1100, 0), [])
        state = json.loads(Path(checks.STATE_PATH).with_name("container.json").read_text())
        self.assertEqual(state["started_at"], 1100)
        self.assertEqual(state["starts"], [{"at": 1000, "count": 1}])

    def test_corrupt_container_state_is_reset_once(self):
        path = Path(checks.STATE_PATH).with_name("container.json")
        for raw in ["{raw synthetic", "[]", "{}", json.dumps({
            "started_at": 1000, "observed_at": 1000, "restart_count": 0, "starts": [None],
        })]:
            with self.subTest(raw=raw):
                path.write_text(raw)
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(checks.check_restarts(1000, 1000, 0), [])
                    self.assertEqual(checks.check_restarts(1030, 1000, 0), [])
                self.assertEqual(output.getvalue().count("resetting container.json"), 1)
                self.assertNotIn("raw synthetic", output.getvalue())


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
            reachable, problems = checks.check_probes()
        self.assertTrue(reachable)
        self.assertEqual(sorted(calls), [("/api/health", 5)] * 3 + [("/api/me", 5)] * 3)
        self.assertEqual(build.call_count, 6)
        self.assertEqual([p.key for p in problems], ["aeon:probe:/api/health", "aeon:probe:/api/me"])
        self.assertIn("db is not ok (1/3)", problems[0].text)
        self.assertIn("returned 500 (2/3)", problems[1].text)
        self.assertNotIn("Bearer", checks.render([p.text for p in problems], []))

    def test_all_good_and_mixed_timeout_counts(self):
        with patch.object(checks, "probe_once", side_effect=lambda path: None):
            self.assertEqual(checks.check_probes(), (True, []))
        answers = deque(["timed out", "returned 500", None])
        with patch.object(checks, "probe_once", side_effect=lambda path: answers.popleft() if path == "/api/me" else None):
            reachable, problems = checks.check_probes()
            text = problems[0].text
        self.assertTrue(reachable)
        self.assertIn("timed out (1/3)", text)
        self.assertIn("returned 500 (1/3)", text)

    def test_only_http_200_db_ok_health_probe_makes_aeon_reachable(self):
        for reason in ["timed out", "returned 500", "db is not ok", "returned invalid JSON",
                       "blocked by Cloudflare (403 10xx)"]:
            with self.subTest(reason=reason), patch.object(checks, "probe_once", side_effect=lambda path:
                reason if path == "/api/health" else None
            ):
                reachable, problems = checks.check_probes()
                self.assertFalse(reachable)
                self.assertEqual([p.key for p in problems], ["aeon:probe:/api/health"])


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
        with patch.object(checks.engine, "env_file_value", return_value="synthetic target") as reader, \
             patch.object(checks.engine, "shoutrrr_telegram_sender", return_value=lambda *_: True), \
             patch.object(checks.engine, "run_cycle", return_value=0) as run:
            self.assertEqual(checks.main(), 0)
            reader.assert_called_once_with("/run/credentials/aeon-watch.service/notification-env",
                                           "WATCHTOWER_NOTIFICATION_URL", require_canonical_path=True)
            self.assertEqual(run.call_args.kwargs["clear_confirm_runs"], 2)
        with patch.object(checks.engine, "env_file_value", return_value=""), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(checks.main(), engine.EXIT_UNDELIVERED)
        with patch.object(checks.engine, "env_file_value", return_value="synthetic target"), \
             patch.object(checks.engine, "shoutrrr_telegram_sender", side_effect=ValueError("raw diagnostic")), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(checks.main(), engine.EXIT_UNDELIVERED)
            self.assertNotIn("raw", output.getvalue())

    def test_runtime_credential_directory_cannot_redirect_notification_read(self):
        root = Path(self.temp.name).resolve()
        fixed = root / "fixed" / "notification-env"
        fixed.parent.mkdir()
        fixed.write_text("WATCHTOWER_NOTIFICATION_URL=telegram://synthetic@telegram?chats=1\n")
        other = root / "other"
        other.mkdir()
        (other / "notification-env").write_text("WATCHTOWER_NOTIFICATION_URL=other target\n")
        for directory in [str(other), str(other / ".." / "other"), "relative/../other"]:
            with self.subTest(directory=directory), patch.dict(os.environ, {"CREDENTIALS_DIRECTORY": directory}), \
                 patch.object(checks, "NOTIFICATION_ENV", str(fixed)), \
                 patch.object(checks, "STATE_PATH", self.state), \
                 patch.object(checks.engine, "shoutrrr_telegram_sender", return_value=lambda *_: True) as sender, \
                 patch.object(checks.engine, "run_cycle", return_value=0):
                self.assertEqual(checks.main(), 0)
                sender.assert_called_once_with("telegram://synthetic@telegram?chats=1")

    def test_one_burst_in_distinct_windows_never_pages(self):
        windows = [fixture("above-threshold"), request_line() * 10, request_line() * 10]
        with patch.object(checks, "STATE_PATH", self.state):
            for index, logs in enumerate(windows):
                with patch.object(checks, "check_container", return_value=(0, 0, [])), \
                     patch.object(checks, "check_probes", return_value=(True, [])), \
                     patch.object(checks.time, "time", return_value=1000 + index * 30), \
                     patch.object(checks, "docker_command", return_value=subprocess.CompletedProcess([], 0, logs, "")) as docker, \
                     contextlib.redirect_stdout(io.StringIO()):
                    engine.run_cycle(self.state, 1000 + index * 30, checks.collect, checks.render,
                                     lambda text, identifier: self.sent.append(text) or True, clear_confirm_runs=2)
                    command = docker.call_args.args[0]
                    self.assertEqual(len(command), 6)
                    self.assertEqual([command[0], command[1], command[3], command[5]],
                                     ["logs", "--since", "--until", "aeon"])
                    self.assertEqual(datetime.fromisoformat(command[2]).timestamp(), 970 + index * 30)
                    self.assertEqual(datetime.fromisoformat(command[4]).timestamp(), 1000 + index * 30)
        self.assertEqual(self.sent, [])

    def test_slow_probes_leave_consecutive_log_windows_adjacent(self):
        clock = {"now": 1000}
        commands = []
        delays = iter([11, 19])

        def slow_probes():
            clock["now"] += next(delays)
            return True, []

        def logs_for_window(command):
            commands.append(command)
            since = datetime.fromisoformat(command[2]).timestamp()
            until = datetime.fromisoformat(command[4]).timestamp()
            # The burst predates the first run; slower probes must not move it
            # into the second confirmation window or pull in newer requests.
            logs = fixture("above-threshold") if since <= 999 < until else request_line() * 10
            return subprocess.CompletedProcess([], 0, logs, "")

        with patch.object(checks, "STATE_PATH", self.state), \
             patch.object(checks.time, "time", side_effect=lambda: clock["now"]) as timestamp, \
             patch.object(checks, "check_container", side_effect=lambda: (0, 0, [])), \
             patch.object(checks, "check_probes", side_effect=slow_probes), \
             patch.object(checks, "docker_command", side_effect=logs_for_window), \
             contextlib.redirect_stdout(io.StringIO()):
            for start in [1000, 1030]:
                clock["now"] = start
                engine.run_cycle(self.state, start, checks.collect, checks.render,
                                 lambda text, identifier: self.sent.append(text) or True, clear_confirm_runs=2)
            self.assertEqual(timestamp.call_count, 2)
        self.assertEqual([command[2:5:2] for command in commands], [
            ["1970-01-01T00:16:10+00:00", "1970-01-01T00:16:40+00:00"],
            ["1970-01-01T00:16:40+00:00", "1970-01-01T00:17:10+00:00"],
        ])
        self.assertEqual(self.sent, [])

    def test_headers_action_and_mixed_recovery(self):
        action = 'check: ssh csb1 "docker logs --since 5m aeon 2>&1 | grep \'\\"status\\":5\'" ; runbook OPS-307'
        self.assertTrue(checks.render(["fault"], []).startswith("🔴 aeon-watch (csb1):\n"))
        self.assertTrue(checks.render([], ["fault"]).startswith("🟢 aeon-watch (csb1) recovered:\n"))
        mixed = checks.render(["new fault"], ["old fault"])
        self.assertIn("🟢 aeon-watch (csb1) recovered:", mixed)
        self.assertEqual(mixed.splitlines()[-1], action)
        self.assertEqual(mixed.count("check:"), 1)
        self.assertNotIn("check:", checks.render([], ["fault"]))
        self.assertEqual(checks.render([], []), "")
        # Shell parsing leaves the exact stderr-inclusive command on csb1.
        remote_command = shlex.split(action.removeprefix("check: "))[2]
        self.assertEqual(remote_command, 'docker logs --since 5m aeon 2>&1 | grep \'"status":5\'')
        self.assertIn('ssh csb1 "docker logs --since 5m aeon 2>&1 | grep \'\\"status\\":5\'"',
                      (REPO / "hosts/csb1/docs/RUNBOOK.md").read_text())

    def run_collected(self, now, started_at, restart_count, probes=(True, []), module=checks):
        with patch.object(module, "STATE_PATH", self.state), \
             patch.object(module.time, "time", return_value=now), \
             patch.object(module, "check_container", return_value=(started_at, restart_count, [])), \
             patch.object(module, "check_probes", return_value=probes), \
             patch.object(module, "docker_command", return_value=subprocess.CompletedProcess([], 0, "", "")), \
             contextlib.redirect_stdout(io.StringIO()):
            return engine.run_cycle(self.state, now, module.collect, module.render,
                                    lambda text, identifier: self.sent.append(text) or True, clear_confirm_runs=2)

    def test_crash_loop_pages_with_persistent_history_between_processes(self):
        self.run_collected(1000, 1000, 0)
        self.run_collected(1030, 1030, 1)
        fresh = load_checks()
        self.assertEqual(self.run_collected(1060, 1060, 2, module=fresh), engine.EXIT_PROBLEMS)
        self.assertEqual(self.sent, [])
        self.run_collected(1090, 1090, 3, module=fresh)
        self.assertEqual(len(self.sent), 1)
        self.assertIn("aeon restarting repeatedly (4 starts in 10 min)", self.sent[0])
        state = json.loads(Path(self.state).with_name("container.json").read_text())
        self.assertEqual(state["restart_count"], 3)
        self.assertEqual(state["started_at"], 1090)

    def test_repeated_recreates_with_reset_counters_still_page(self):
        for now, started_at in [(1000, 1000), (1030, 1030), (1060, 1060), (1090, 1060)]:
            self.run_collected(now, started_at, 0)
        self.assertEqual(len(self.sent), 1)
        self.assertIn("3 starts in 10 min", self.sent[0])

    def test_single_recreate_with_one_bad_probe_run_does_not_page(self):
        fault = engine.Problem("aeon:probe:/api/health", "returned 503")
        self.run_collected(1000, 0, 10)
        self.run_collected(1030, 1030, 0, probes=(False, [fault]))
        self.run_collected(1060, 1030, 0)
        self.run_collected(1090, 1030, 0)
        self.assertEqual(self.sent, [])

    def test_single_docker_restart_does_not_page(self):
        for now, started_at, count in [(1000, 1000, 0), (1030, 1030, 1), (1060, 1030, 1), (1090, 1030, 1)]:
            self.run_collected(now, started_at, count)
        self.assertEqual(self.sent, [])

    def test_slow_crash_loop_below_three_starts_in_ten_minutes_does_not_page(self):
        for count, start in enumerate([1000, 1400, 1800, 2200]):
            self.run_collected(start, start, count)
            self.run_collected(start + 30, start, count)
        self.assertEqual(self.sent, [])

    def test_restart_during_active_probe_fault_never_fakes_recovery(self):
        fault = engine.Problem("aeon:probe:/api/me", "returned 500")
        for now, started_at in [(1000, 0), (1030, 0), (1060, 1060), (1090, 1060)]:
            self.run_collected(now, started_at, 0, probes=(True, [fault]))
        self.assertEqual(len(self.sent), 1)
        self.assertNotIn("recovered", self.sent[0])
        self.assertNotIn("clean_count", engine.load_state(self.state)["seen"][fault.key])

    def test_corrupt_alert_state_recovers_and_logs_once(self):
        for raw in ["{raw synthetic", "[]", '{"seen":[]}', '{"raw synthetic":{}}',
                    json.dumps({"seen": {"fault": {"text": "raw synthetic", "count": "invalid", "alerted": True}}}),
                    json.dumps({"seen": {"fault": None}}),
                    json.dumps({"seen": {}, "pending": {"text": "raw synthetic"}}),
                    json.dumps({"seen": {}, "pending": {"text": "raw synthetic", "event_id": "id", "next_state": []}})]:
            with self.subTest(raw=raw):
                Path(self.state).write_text(raw)
                with patch.object(checks, "STATE_PATH", self.state), \
                     patch.object(checks.engine, "env_file_value", return_value="synthetic target"), \
                     patch.object(checks.engine, "shoutrrr_telegram_sender", return_value=lambda *_: True), \
                     patch.object(checks, "collect", return_value=[]), \
                     contextlib.redirect_stdout(io.StringIO()) as output:
                    self.assertEqual(checks.main(), engine.EXIT_CLEAN)
                    self.assertEqual(checks.main(), engine.EXIT_CLEAN)
                self.assertEqual(output.getvalue().count("resetting state.json"), 1)
                self.assertNotIn("raw synthetic", output.getvalue())
                self.assertEqual(engine.load_state(self.state), {"seen": {}, "pending": None})

    def test_unexpected_alert_state_read_exception_recovers(self):
        with patch.object(checks, "STATE_PATH", self.state), \
             patch.object(checks.engine, "env_file_value", return_value="synthetic target"), \
             patch.object(checks.engine, "shoutrrr_telegram_sender", return_value=lambda *_: True), \
             patch.object(checks, "collect", return_value=[]), \
             patch.object(Path, "read_text", side_effect=RuntimeError("raw diagnostic")), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(checks.main(), engine.EXIT_CLEAN)
        self.assertEqual(output.getvalue().count("resetting state.json"), 1)
        self.assertNotIn("raw", output.getvalue())

    def test_valid_pending_alert_survives_validation_and_retries(self):
        fault = engine.Problem("aeon:probe:/api/me", "returned 500")
        delivered = []
        with patch.object(checks, "STATE_PATH", self.state), \
             patch.object(checks.engine, "env_file_value", return_value="synthetic target"), \
             patch.object(checks.engine, "shoutrrr_telegram_sender", return_value=lambda *_: False), \
             patch.object(checks, "collect", return_value=[fault]), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(checks.main(), engine.EXIT_PROBLEMS)
            self.assertEqual(checks.main(), engine.EXIT_UNDELIVERED)
            pending = engine.load_state(self.state)["pending"]
            with patch.object(checks.engine, "shoutrrr_telegram_sender",
                              return_value=lambda text, identifier: delivered.append((text, identifier)) or True):
                self.assertEqual(checks.main(), engine.EXIT_PROBLEMS)
        self.assertNotIn("resetting", output.getvalue())
        self.assertEqual(delivered, [(pending["text"], pending["event_id"])])
        self.assertIsNone(engine.load_state(self.state)["pending"])

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
