#!/usr/bin/env python3
"""OPS-307: API error-rate and public DB/auth-path witness on csb1.

Only aggregate counts and Aeon's privacy-safe route patterns enter alerts or
state. Raw log lines, response bodies and fake Authorization headers never do.
The shared engine confirms two bad runs and, for this poller, two clean runs.
"""

from __future__ import annotations

import http.client
import json
import os
import secrets
import ssl
import subprocess
import time
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path

import engine
from engine import Problem

STATE_PATH = "/var/lib/aeon-watch/state.json"
DOCKER = "@DOCKER_BIN@"
PROBE_TENANT = "@PROBE_TENANT@"
WATCH_INTERVAL_SECONDS = int("@WATCH_INTERVAL_SECONDS@")
CONTAINER_GRACE_SECONDS = 120
NO_REQUEST_SECONDS = 600
DOCKER_TIMEOUT = 5
PROBE_TIMEOUT = 5
PROBE_COUNT = 3
PROBE_USER_AGENT = "aeon-watch/1 (OPS-307)"
PROBE_URLS = {
    "/api/health": "https://aeon.barta.cm/api/health",
    "/api/me": "https://aeon.barta.cm/api/me",
}


def request_lines(logs: str):
    """Yield valid request records, including probes, for parser liveness."""
    for line in logs.splitlines():
        try:
            entry = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(entry, dict) or entry.get("msg") != "request":
            continue
        path, status = entry.get("path"), entry.get("status")
        if not isinstance(path, str) or type(status) is not int or not 100 <= status <= 599:
            continue
        parts = path.split()
        if len(parts) == 1:
            parts = [entry.get("method"), path]
        if (
            len(parts) != 2
            or not isinstance(parts[0], str)
            or parts[0] not in {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"}
        ):
            continue
        method, route = parts
        if route.startswith("/"):
            yield method, route, status


def traffic_problems(logs: str) -> list[Problem]:
    """Count API traffic without the webhook or the watcher's own requests."""
    total = 0
    failing: Counter[str] = Counter()
    for method, route, status in request_lines(logs):
        if not route.startswith("/api/") or (method, route) == ("POST", "/api/github/webhook"):
            continue
        if (method, route) == ("GET", "/api/health") or (
            (method, route) == ("GET", "/api/me") and status == 401
        ):
            continue
        total += 1
        if status >= 500:
            failing[f"{method} {route}"] += 1
    errors = sum(failing.values())
    if total < 10 or errors < 3 or errors * 100 < total * 10:
        return []
    top = ", ".join(f"{path} {count}" for path, count in failing.most_common(3))
    return [Problem(
        "aeon:traffic",
        f"aeon.barta.cm: {errors}/{total} API requests 5xx in {WATCH_INTERVAL_SECONDS} s (top: {top})",
    )]


def docker_command(args: list[str]) -> subprocess.CompletedProcess:
    # Explicit local socket: Docker client environment cannot redirect this read.
    return subprocess.run(
        [DOCKER, "--host", "unix:///run/docker.sock", *args],
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        timeout=DOCKER_TIMEOUT,
        check=True,
    )


def check_container() -> tuple[float | None, list[Problem]]:
    try:
        running = docker_command([
            "ps", "--filter", "name=^aeon$", "--filter", "status=running",
            "--format", "{{.Names}}",
        ])
        if "aeon" not in running.stdout.splitlines():
            return None, [Problem("aeon:traffic", "aeon.barta.cm: aeon container is not running")]
        # Read this one field only; never inspect the container environment.
        started = docker_command(["container", "inspect", "-f", "{{.State.StartedAt}}", "aeon"])
        stamp = datetime.fromisoformat(started.stdout.strip().replace("Z", "+00:00"))
        if stamp.tzinfo is None:
            raise ValueError("StartedAt has no timezone")
        return stamp.timestamp(), []
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        return None, [Problem(
            "aeon:traffic",
            f"aeon.barta.cm: container/logs unreadable ({type(error).__name__})",
        )]


def check_request_log(logs: str, now: float, started_at: float) -> list[Problem]:
    """Persist a liveness timestamp separately from the engine's alert state."""
    path = Path(STATE_PATH).with_name("request-log.json")
    try:
        last_seen = json.loads(path.read_text(encoding="utf-8"))["last_seen"]
    except FileNotFoundError:
        last_seen = now
    # A restart begins a new period of observation; stopped time is not blindness.
    last_seen = min(now, max(last_seen, started_at))
    if any(request_lines(logs)):
        last_seen = now
    engine.atomic_write_state(str(path), {"last_seen": last_seen})
    if now - last_seen >= NO_REQUEST_SECONDS:
        return [Problem(
            "aeon:log-format",
            "aeon-watch: no parsable request lines for 10 min (log format changed?)",
        )]
    return []


def check_traffic(now: float, started_at: float) -> list[Problem]:
    try:
        logs = docker_command(["logs", "--since", f"{WATCH_INTERVAL_SECONDS}s", "aeon"])
    except (OSError, subprocess.SubprocessError) as error:
        # Never print Docker stderr or exception text: either may contain logs.
        return [Problem(
            "aeon:traffic",
            f"aeon.barta.cm: container/logs unreadable ({type(error).__name__})",
        )]
    # Docker preserves the container's two output streams; slog uses stderr.
    output = logs.stdout + "\n" + logs.stderr
    return traffic_problems(output) + check_request_log(output, now, started_at)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def probe_once(path: str) -> str | None:
    headers = {"Connection": "close", "User-Agent": PROBE_USER_AGENT}
    if path == "/api/me":
        headers["Authorization"] = f"Bearer aeon_{PROBE_TENANT}{secrets.token_hex(8)}_{secrets.token_hex(16)}"
    request = urllib.request.Request(PROBE_URLS[path], headers=headers, method="GET")
    # A new opener/request per attempt creates a fresh connection. Reject
    # redirects so 3xx is a fault and no Authorization header crosses hosts.
    opener = urllib.request.build_opener(
        NoRedirect(), urllib.request.HTTPSHandler(context=ssl.create_default_context())
    )
    expected = 200 if path == "/api/health" else 401
    try:
        try:
            response = opener.open(request, timeout=PROBE_TIMEOUT)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            if response.status != expected:
                if path == "/api/me" and response.status == 200:
                    return "fake key ACCEPTED — auth bypass?"
                if response.status == 403 and b"error code: 10" in response.read(65536):
                    return "blocked by Cloudflare (403 10xx)"
                return f"returned {response.status}"
            if path == "/api/health":
                try:
                    body = json.loads(response.read(65536))
                except (ValueError, UnicodeError):
                    return "returned invalid JSON"
                if not isinstance(body, dict) or body.get("db") != "ok":
                    return "db is not ok"
    except (TimeoutError, urllib.error.URLError, OSError, http.client.HTTPException) as error:
        if isinstance(error, TimeoutError) or isinstance(getattr(error, "reason", None), TimeoutError):
            return "timed out"
        return f"unreachable ({type(error).__name__})"
    return None


def check_probes() -> list[Problem]:
    paths = [path for path in PROBE_URLS for _ in range(PROBE_COUNT)]
    # Six independent requests keep a full timeout cycle within the 30s timer.
    with ThreadPoolExecutor(max_workers=len(paths)) as workers:
        results = list(workers.map(probe_once, paths))
    problems = []
    for path in PROBE_URLS:
        failures = Counter(
            result for route, result in zip(paths, results) if route == path and result
        )
        if failures:
            text = ", ".join(f"{reason} ({count}/{PROBE_COUNT})" for reason, count in failures.items())
            problems.append(Problem(f"aeon:probe:{path}", f"aeon probe: {path} {text}"))
    return problems


def collect() -> list[Problem]:
    now = time.time()
    started_at, problems = check_container()
    if started_at is not None:
        if now - started_at < CONTAINER_GRACE_SECONDS:
            return []
        problems += check_traffic(now, started_at)
    return problems + check_probes()


def render(announced: list[str], cleared: list[str]) -> str:
    lines = []
    if announced:
        lines += ["🔴 aeon-watch (csb1):"] + [f"• {item}" for item in announced]
    if cleared:
        lines += ["🟢 aeon-watch (csb1) recovered:"] + [f"• {item}" for item in cleared]
    if lines:
        lines.append('check: ssh csb1 \'docker logs --since 5m aeon | grep "\\"status\\":5"\' ; runbook OPS-307')
    return "\n".join(lines)


def run() -> int:
    credential_dir = os.environ.get("CREDENTIALS_DIRECTORY", "/nonexistent")
    target = engine.env_file_value(
        str(Path(credential_dir) / "notification-env"), "WATCHTOWER_NOTIFICATION_URL"
    )
    if not target:
        print("notification target missing")
        return engine.EXIT_UNDELIVERED
    try:
        sender = engine.shoutrrr_telegram_sender(target)
    except ValueError:
        print("notification target unusable")
        return engine.EXIT_UNDELIVERED
    return engine.run_cycle(STATE_PATH, time.time(), collect, render, sender, clear_confirm_runs=2)


def main() -> int:
    try:
        return run()
    except Exception as error:
        # Unexpected failures must fail the unit (1 is a successful problem run).
        # Exception text/tracebacks can contain logs, headers or credentials.
        print(f"aeon-watch: watch crashed ({type(error).__name__})")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
