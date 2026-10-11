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
from pathlib import Path

import engine
from engine import Problem

STATE_PATH = "/var/lib/aeon-watch/state.json"
DOCKER = "@DOCKER_BIN@"
PROBE_TENANT = "@PROBE_TENANT@"
DOCKER_TIMEOUT = 5
PROBE_TIMEOUT = 5
PROBE_COUNT = 3
PROBE_USER_AGENT = "aeon-watch/1 (OPS-307)"
PROBE_URLS = {
    "/api/health": "https://aeon.barta.cm/api/health",
    "/api/me": "https://aeon.barta.cm/api/me",
}


def traffic_problems(logs: str) -> list[Problem]:
    """Ignore startup/noise/malformed lines; count structured API requests only."""
    total = 0
    failing: Counter[str] = Counter()
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
        if not route.startswith("/api/") or (method, route) == ("POST", "/api/github/webhook"):
            continue
        total += 1
        if status >= 500:
            failing[f"{method} {route}"] += 1
    errors = sum(failing.values())
    if total < 20 or errors < 5 or errors * 100 < total * 10:
        return []
    top = ", ".join(f"{path} {count}" for path, count in failing.most_common(3))
    return [Problem(
        "aeon:traffic",
        f"aeon.barta.cm: {errors}/{total} API requests 5xx in 60 s (top: {top})",
    )]


def docker_command(args: list[str]) -> subprocess.CompletedProcess:
    # Explicit local socket: Docker client environment cannot redirect this read.
    return subprocess.run(
        [DOCKER, "--host", "unix:///run/docker.sock", *args],
        capture_output=True,
        text=True,
        timeout=DOCKER_TIMEOUT,
        check=True,
    )


def check_traffic() -> list[Problem]:
    try:
        running = docker_command([
            "ps", "--filter", "name=^aeon$", "--filter", "status=running",
            "--format", "{{.Names}}",
        ])
        if "aeon" not in running.stdout.splitlines():
            return [Problem("aeon:traffic", "aeon.barta.cm: aeon container is not running")]
        logs = docker_command(["logs", "--since", "60s", "aeon"])
    except (OSError, UnicodeError, subprocess.SubprocessError) as error:
        # Never print Docker stderr or exception text: either may contain logs.
        return [Problem(
            "aeon:traffic",
            f"aeon.barta.cm: container/logs unreadable ({type(error).__name__})",
        )]
    # Docker preserves the container's two output streams; slog uses stderr.
    return traffic_problems(logs.stdout + "\n" + logs.stderr)


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
    return check_traffic() + check_probes()


def render(announced: list[str], cleared: list[str]) -> str:
    lines = [f"• {item}" for item in announced]
    if cleared:
        lines += ["✅ Cleared — two clean checks:"] + [f"• {item}" for item in cleared]
    return "\n".join(lines)


def main() -> int:
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


if __name__ == "__main__":
    raise SystemExit(main())
