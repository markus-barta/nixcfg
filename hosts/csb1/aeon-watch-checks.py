#!/usr/bin/env python3
"""OPS-307: API error-rate and public DB/auth-path witness on csb1.

Only aggregate counts and Aeon's privacy-safe route patterns enter alerts or
state. Raw log lines, response bodies and fake Authorization headers never do.
The shared engine confirms two bad runs and, for this poller, two clean runs.
"""

from __future__ import annotations

import http.client
import json
import math
import secrets
import ssl
import subprocess
import time
import urllib.error
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import engine
from engine import Problem

STATE_PATH = "/var/lib/aeon-watch/state.json"
DOCKER = "@DOCKER_BIN@"
NOTIFICATION_ENV = "@NOTIFICATION_ENV@"
PROBE_TENANT = "@PROBE_TENANT@"
WATCH_INTERVAL_SECONDS = int("@WATCH_INTERVAL_SECONDS@")
RESTART_WINDOW_SECONDS = 600
RESTART_STARTS_THRESHOLD = 3
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


def check_container() -> tuple[float | None, int | None, list[Problem]]:
    try:
        running = docker_command([
            "ps", "--filter", "name=^aeon$", "--filter", "status=running",
            "--format", "{{.Names}}",
        ])
        if "aeon" not in running.stdout.splitlines():
            return None, None, [Problem("aeon:traffic", "aeon.barta.cm: aeon container is not running")]
        # Read only these two lifecycle fields; never inspect the environment.
        lifecycle = docker_command([
            "container", "inspect", "-f", "{{.State.StartedAt}} {{.RestartCount}}", "aeon",
        ])
        started, count = lifecycle.stdout.split()
        stamp = datetime.fromisoformat(started.replace("Z", "+00:00"))
        restart_count = int(count)
        if stamp.tzinfo is None:
            raise ValueError("StartedAt has no timezone")
        if restart_count < 0:
            raise ValueError("RestartCount is negative")
        return stamp.timestamp(), restart_count, []
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        return None, None, [Problem(
            "aeon:traffic",
            f"aeon.barta.cm: container/logs unreadable ({type(error).__name__})",
        )]


def valid_timestamp(value) -> bool:
    return type(value) in {int, float} and math.isfinite(value)


def read_watch_state(path: Path, default: dict, validate) -> dict:
    """Reset unreadable/malformed state once, without printing its contents."""
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
        validate(state)
        return state
    except FileNotFoundError:
        return default
    except Exception as error:
        print(f"aeon-watch: resetting {path.name} ({type(error).__name__})")
        engine.atomic_write_state(str(path), default)
        return default


def validate_container_state(state: dict) -> None:
    if (
        not valid_timestamp(state["started_at"])
        or not valid_timestamp(state["observed_at"])
        or type(state["restart_count"]) is not int
        or state["restart_count"] < 0
        or not isinstance(state["starts"], list)
    ):
        raise ValueError("invalid container state")
    for event in state["starts"]:
        if not valid_timestamp(event["at"]) or type(event["count"]) is not int or event["count"] < 1:
            raise ValueError("invalid start event")


def check_restarts(now: float, started_at: float, restart_count: int) -> list[Problem]:
    path = Path(STATE_PATH).with_name("container.json")
    # Inspect can observe a start after this run's clock snapshot. Bound event
    # times, but retain Docker's original timestamp as the restart identity.
    observed_start = min(started_at, now)
    # On first observation, count the current start, not lifetime RestartCount.
    state = read_watch_state(path, {
        "started_at": started_at, "restart_count": restart_count, "observed_at": now,
        "starts": [{"at": observed_start, "count": 1}],
    }, validate_container_state)
    starts = [event for event in state["starts"] if now - RESTART_WINDOW_SECONDS <= event["at"] <= now]
    if started_at != state["started_at"] or restart_count != state["restart_count"]:
        # Count missed Docker restarts too, when the previous observation was
        # inside this window. Recreates reset RestartCount; manual restarts may
        # leave it unchanged. Both still contribute one observed start.
        delta = restart_count - state["restart_count"]
        count = max(1, delta) if delta >= 0 else restart_count + 1
        if not now - RESTART_WINDOW_SECONDS <= state["observed_at"] <= now:
            count = 1
        if now - RESTART_WINDOW_SECONDS <= observed_start <= now:
            if count > 1:
                # Docker gives only the latest timestamp. Earlier unseen
                # starts expire from their earliest possible time, so they
                # cannot inflate the count beyond the ten-minute window.
                starts.append({"at": min(state["observed_at"], observed_start), "count": count - 1})
            starts.append({"at": observed_start, "count": 1})
    engine.atomic_write_state(str(path), {
        "started_at": started_at, "restart_count": restart_count, "observed_at": now, "starts": starts,
    })
    count = sum(event["count"] for event in starts)
    if count >= RESTART_STARTS_THRESHOLD:
        return [Problem("aeon:restart", f"aeon restarting repeatedly ({count} starts in 10 min)")]
    return []


def validate_request_state(state: dict) -> None:
    if not valid_timestamp(state["last_seen"]) or type(state.get("reachable", False)) is not bool:
        raise ValueError("invalid request state")


def check_request_log(logs: str, now: float, started_at: float, reachable: bool) -> list[Problem]:
    """Persist a liveness timestamp separately from the engine's alert state."""
    path = Path(STATE_PATH).with_name("request-log.json")
    state = read_watch_state(path, {"last_seen": now, "reachable": False}, validate_request_state)
    # A restart begins a new period of observation; stopped time is not blindness.
    last_seen = min(now, max(state["last_seen"], started_at))
    # Exclude probe-outage time, including the first window after it ends.
    if not reachable or not state.get("reachable", False) or any(request_lines(logs)):
        last_seen = now
    engine.atomic_write_state(str(path), {"last_seen": last_seen, "reachable": reachable})
    if reachable and now - last_seen >= NO_REQUEST_SECONDS:
        return [Problem(
            "aeon:log-format",
            "aeon-watch: no parsable request lines for 10 min (log format changed?)",
        )]
    return []


def check_traffic(now: float, started_at: float, reachable: bool) -> list[Problem]:
    window_start = now - WATCH_INTERVAL_SECONDS
    since = datetime.fromtimestamp(window_start, timezone.utc).isoformat()
    until = datetime.fromtimestamp(now, timezone.utc).isoformat()
    try:
        logs = docker_command(["logs", "--since", since, "--until", until, "aeon"])
    except (OSError, subprocess.SubprocessError) as error:
        check_request_log("", now, started_at, False)
        # Never print Docker stderr or exception text: either may contain logs.
        return [Problem(
            "aeon:traffic",
            f"aeon.barta.cm: container/logs unreadable ({type(error).__name__})",
        )]
    # Docker preserves the container's two output streams; slog uses stderr.
    output = logs.stdout + "\n" + logs.stderr
    return traffic_problems(output) + check_request_log(output, now, started_at, reachable)


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


def check_probes() -> tuple[bool, list[Problem]]:
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
    reachable = any(route == "/api/health" and result is None for route, result in zip(paths, results))
    return reachable, problems


def collect() -> list[Problem]:
    now = time.time()
    started_at, restart_count, problems = check_container()
    reachable, probe_problems = check_probes()
    if started_at is not None:
        problems += check_restarts(now, started_at, restart_count)
        problems += check_traffic(now, started_at, reachable)
    else:
        check_request_log("", now, now, False)
    return problems + probe_problems


def render(announced: list[str], cleared: list[str]) -> str:
    lines = []
    if announced:
        lines += ["🔴 aeon-watch (csb1):"] + [f"• {item}" for item in announced]
    if cleared:
        lines += ["🟢 aeon-watch (csb1) recovered:"] + [f"• {item}" for item in cleared]
    if announced:
        lines.append('check: ssh csb1 "docker logs --since 5m aeon 2>&1 | grep \'\\"status\\":5\'" ; runbook OPS-307')
    return "\n".join(lines)


def validate_alert_state(state: dict) -> None:
    """Validate nested engine state too, before the shared loader consumes it."""
    if not isinstance(state, dict) or not isinstance(state["seen"], dict):
        raise ValueError("invalid alert state")
    for key, entry in state.get("seen", {}).items():
        if (
            not isinstance(key, str) or not isinstance(entry, dict)
            or not isinstance(entry["text"], str)
            or type(entry["count"]) is not int or entry["count"] < 0
            or type(entry["alerted"]) is not bool
            or type(entry.get("clean_count", 0)) is not int or entry.get("clean_count", 0) < 0
        ):
            raise ValueError("invalid alert entry")
    pending = state.get("pending")
    if pending is not None:
        if not isinstance(pending, dict) or not isinstance(pending["text"], str) or not isinstance(pending["event_id"], str):
            raise ValueError("invalid pending alert")
        validate_alert_state(pending["next_state"])


def run() -> int:
    target = engine.env_file_value(
        NOTIFICATION_ENV, "WATCHTOWER_NOTIFICATION_URL", require_canonical_path=True
    )
    if not target:
        print("notification target missing")
        return engine.EXIT_UNDELIVERED
    try:
        sender = engine.shoutrrr_telegram_sender(target)
    except ValueError:
        print("notification target unusable")
        return engine.EXIT_UNDELIVERED
    read_watch_state(Path(STATE_PATH), {"seen": {}, "pending": None}, validate_alert_state)
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
