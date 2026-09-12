#!/usr/bin/env python3
"""Paper IB Gateway session-readiness supervisor — HOSTD-58.

Docker Up and socat 4004 are not a broker session. This timer classifies
slowstarting / authenticating / api_ready / upstream_unavailable, restarts
only allowlisted ib-gateway through the managed compose lock, persists a
one-attempt budget, and pages through the existing fleet-alerts shoutrrr
adapter when a declared env file is configured.
"""

from __future__ import annotations

import errno
import json
import os
import re
import select
import subprocess
import sys
import time
from collections.abc import Iterable
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Callable

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import engine  # noqa: E402

ALLOWED_SERVICE = "ib-gateway"
PHASE_SLOWSTARTING = "slowstarting"
PHASE_AUTHENTICATING = "authenticating"
PHASE_API_READY = "api_ready"
PHASE_UPSTREAM_UNAVAILABLE = "upstream_unavailable"
PHASE_HALTED = "halted"
PHASE_CONTAINER_DOWN = "container_down"
PHASE_UNKNOWN = "unknown"

ACTION_NONE = "none"
ACTION_RESTART = "restart_ib_gateway"
ACTION_HALT = "halt"

PROBLEM_KEY = "ib-gateway:session"
LISTEN_STATE = "0A"
PORT_API = 4002
PORT_RELAY = 4004

LOGIN_LOGGED_OUT = "logged_out"
LOGIN_AUTHENTICATING = "authenticating"
LOGIN_LOGGED_IN = "logged_in"
LOGIN_UNKNOWN = "unknown"

MANUAL_FULLAUTH = "fullauthrequired"
RESTART_LOCK_TIMEOUT_SEC = 30

PUSH_LINE_KEYS = frozenset({"generatedAt", "gateway"})
HISTORY_MARKERS = frozenset(
    {
        "identities",
        "coverageDay",
        "coverage",
        "family-ledger",
        "familyHistory",
        "historyBasis",
        "capturedFifo",
    }
)

AUTHENTICATING_RE = re.compile(
    r"Attempt\s*\d+\s*Authenticating|Authenticating|LOGGING_IN|LOGIN IN PROGRESS",
    re.IGNORECASE,
)
LOGGED_OUT_RE = re.compile(r"LOGGED_OUT|Logged out|not logged in", re.IGNORECASE)
LOGGED_IN_RE = re.compile(
    r"Login has completed|Login completed|Logged in successfully|IBC:\s*TWS.*logged in",
    re.IGNORECASE,
)
TWOFA_RE = re.compile(
    r"\b2FA\b|second factor|two[- ]factor|TWOFA",
    re.IGNORECASE,
)
DOCKER_TS_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T[0-9:.+-]+Z)\s+(.*)$",
)

LINE_LOGIN_PATTERNS = (
    (LOGGED_IN_RE, LOGIN_LOGGED_IN),
    (AUTHENTICATING_RE, LOGIN_AUTHENTICATING),
    (LOGGED_OUT_RE, LOGIN_LOGGED_OUT),
)

# Named failure classes only. Never 2FA unless TWOFA_RE / fullauthrequired hits.
AUTH_CLASS_SESSION_CONFLICT = "session_conflict"
AUTH_CLASS_INVALID_CREDENTIALS = "invalid_credentials"
AUTH_CLASS_UPSTREAM_UNAVAILABLE = "upstream_unavailable"
AUTH_CLASS_TLS = "tls"

AUTH_FAILURE_CLASSES: tuple[tuple[str, re.Pattern[str]], ...] = (
    (
        AUTH_CLASS_SESSION_CONFLICT,
        re.compile(
            r"session conflict|competing session|already logged in from another|"
            r"another (?:computer|user).*(?:logged|connected)|existing session",
            re.IGNORECASE,
        ),
    ),
    (
        AUTH_CLASS_INVALID_CREDENTIALS,
        re.compile(
            r"invalid (?:username|password|credentials)|incorrect password|"
            r"authentication failed|login failed",
            re.IGNORECASE,
        ),
    ),
    (
        AUTH_CLASS_TLS,
        re.compile(
            r"SSL handshake|TLS handshake|certificate (?:expired|verify failed)|"
            r"javax\.net\.ssl|SSLException",
            re.IGNORECASE,
        ),
    ),
    (
        AUTH_CLASS_UPSTREAM_UNAVAILABLE,
        re.compile(
            r"farm (is )?lost|disconnected from farm|upstream_lost|"
            r"connectivity between .{0,80}(has been lost|is broken)|"
            r"\b2110\b|\b1100\b",
            re.IGNORECASE,
        ),
    ),
)

# Bound memory of login observation. Transport flood is scanned and dropped,
# never stored. Overflow/timeout/failure is unknown — not a restart signal.
LOG_SCAN_MAX_BYTES = 4 * 1024 * 1024
LOG_SCAN_MAX_LINES = 50_000
LOG_KEEP_MAX_LINES = 128
LOG_KEEP_MAX_BYTES = 32 * 1024
LOG_RAW_BUF_MAX_BYTES = 64 * 1024
LOG_COLLECT_TIMEOUT_SEC = 15
# Do not rescan from container start every cycle — old socat volume would
# overflow a healthy long-lived generation into permanent probe_unknown.
LOG_LOOKBACK_SEC = 20 * 60


@dataclass(frozen=True)
class Config:
    startup_grace_sec: int = 12 * 60
    auth_timeout_sec: int = 15 * 60
    stale_generated_at_sec: int = 10 * 60
    max_restarts_per_outage: int = 1
    state_path: str = "/var/lib/ib-gateway-session/supervisor.json"
    alert_state_path: str = "/var/lib/ib-gateway-session/alerts.json"
    operator_clear_path: str = "/var/lib/ib-gateway-session/operator-clear"
    compose_lock: str = "/run/lock/compose-hsb0.lock"
    compose_file: str = "/etc/compose/hsb0/docker-compose.yml"
    compose_project: str = "docker"
    compose_project_dir: str = "/home/mba/Code/nixcfg/hosts/hsb0/docker"
    compose_bin: str = "docker-compose"
    flock_bin: str = "flock"
    docker_bin: str = "docker"
    container_name: str = "ib-gateway"
    pusher_container: str = "joe-board-pusher"
    alert_enable: bool = False
    alert_transport: str = "none"
    notification_env: str = ""
    alert_blocker: str = (
        "alert adapter disabled: nixcfg.ibGatewaySession.alert.enable is false. "
        "hsb0 has no declared WATCHTOWER_NOTIFICATION_URL secret. To activate Amy "
        "paging, add an agenix env decryptable by hsb0 with WATCHTOWER_NOTIFICATION_URL "
        "(same fleet-alerts shape as csb1-watchtower-env / hsb1-tailnet-watch-env), then "
        "set alert.enable=true, alert.transport=shoutrrr, alert.notificationEnvFile to that path. "
        "openclaw-gateway is parked so agent-bus is not a live receiver. Do not invent an endpoint."
    )


@dataclass(frozen=True)
class PusherView:
    gateway: bool
    generated_at: float | None
    generated_at_raw: str | None
    source: str
    last_error: str | None = None
    observed_at: float | None = None
    observed_at_raw: str | None = None


@dataclass(frozen=True)
class Observation:
    now: float
    container_running: bool | None
    container_started_at: float | None
    relay_open: bool | None
    api_listening: bool | None
    login_state: str
    authenticating_since: float | None
    manual_action: str | None
    twofa_evidence: bool
    pusher: PusherView | None
    operator_clear: bool = False
    lock_available: bool = True
    probe_unknown: bool = False
    probe_reason: str | None = None
    container_generation: str | None = None
    auth_failure_class: str | None = None


@dataclass
class SupervisorState:
    phase: str = PHASE_SLOWSTARTING
    outage_id: str | None = None
    restarts_this_outage: int = 0
    last_restart_at: float | None = None
    halt_reason: str | None = None
    last_healthy_at: float | None = None
    unhealthy_since: float | None = None
    operator_clear_required: bool = False
    authenticating_since: float | None = None
    last_alert_status: str = "not-configured"
    login_state: str | None = None
    login_generation: str | None = None
    corrupt: bool = False

    def to_dict(self) -> dict:
        return {
            "phase": self.phase,
            "outage_id": self.outage_id,
            "restarts_this_outage": self.restarts_this_outage,
            "last_restart_at": self.last_restart_at,
            "halt_reason": self.halt_reason,
            "last_healthy_at": self.last_healthy_at,
            "unhealthy_since": self.unhealthy_since,
            "operator_clear_required": self.operator_clear_required,
            "authenticating_since": self.authenticating_since,
            "last_alert_status": self.last_alert_status,
            "login_state": self.login_state,
            "login_generation": self.login_generation,
        }

    @classmethod
    def from_dict(cls, raw: dict | None) -> "SupervisorState":
        if not isinstance(raw, dict) or "restarts_this_outage" not in raw:
            return corrupt_halt_state()
        try:
            restarts = int(raw.get("restarts_this_outage"))
        except (TypeError, ValueError):
            return corrupt_halt_state()
        return cls(
            phase=str(raw.get("phase") or PHASE_SLOWSTARTING),
            outage_id=raw.get("outage_id") if isinstance(raw.get("outage_id"), str) else None,
            restarts_this_outage=restarts,
            last_restart_at=_opt_float(raw.get("last_restart_at")),
            halt_reason=raw.get("halt_reason") if isinstance(raw.get("halt_reason"), str) else None,
            last_healthy_at=_opt_float(raw.get("last_healthy_at")),
            unhealthy_since=_opt_float(raw.get("unhealthy_since")),
            operator_clear_required=bool(raw.get("operator_clear_required")),
            authenticating_since=_opt_float(raw.get("authenticating_since")),
            last_alert_status=str(raw.get("last_alert_status") or "not-configured"),
            login_state=raw.get("login_state") if isinstance(raw.get("login_state"), str) else None,
            login_generation=_opt_generation(raw.get("login_generation")),
        )


@dataclass
class Decision:
    phase: str
    action: str
    reason: str
    alert_problem: engine.Problem | None
    persist: SupervisorState
    alert_status: str
    notes: list[str] = field(default_factory=list)


def corrupt_halt_state() -> SupervisorState:
    return SupervisorState(
        phase=PHASE_HALTED,
        restarts_this_outage=10**9,
        operator_clear_required=True,
        halt_reason="supervisor state corrupt; operator clear required",
        last_alert_status="corrupt-state",
        corrupt=True,
    )


def _opt_float(value: object) -> float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return None


def _opt_generation(value: object) -> str | None:
    """Stable identity is containerID:startticks. Discard old rounded-epoch floats."""
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def format_container_generation(container_id: str, start_ticks: int) -> str:
    return f"{container_id}:{start_ticks}"


def parse_docker_ps_id_status(stdout: str) -> tuple[str | None, str]:
    """ID + Status from docker ps. Status is Up/Exited only — never a start epoch."""
    line = (stdout or "").strip().splitlines()[0] if stdout and stdout.strip() else ""
    if not line:
        return None, ""
    if "\t" in line:
        container_id, _, status = line.partition("\t")
        return (container_id.strip() or None), status.strip()
    return None, line


def parse_proc1_startticks(stat_text: str) -> int | None:
    """PID 1 starttime field (clock ticks after boot). comm may contain spaces/parens."""
    line = (stat_text or "").splitlines()[0] if stat_text else ""
    close = line.rfind(")")
    if close < 0:
        return None
    fields = line[close + 1 :].split()
    if len(fields) < 20:
        return None
    try:
        return int(fields[19])
    except ValueError:
        return None


def parse_proc_btime(stat_text: str) -> int | None:
    for line in (stat_text or "").splitlines():
        if line.startswith("btime "):
            parts = line.split()
            if len(parts) < 2:
                return None
            try:
                return int(parts[1])
            except ValueError:
                return None
    return None


def clk_tck() -> int:
    try:
        value = int(os.sysconf("SC_CLK_TCK"))
    except (ValueError, OSError, AttributeError):
        return 100
    return value if value > 0 else 100


def start_epoch_from_proc(btime: int, start_ticks: int, ticks_per_sec: int | None = None) -> float:
    hz = ticks_per_sec if ticks_per_sec and ticks_per_sec > 0 else clk_tck()
    return float(btime) + (float(start_ticks) / float(hz))


def parse_iso_seconds(value: str | None, now: float | None = None) -> float | None:
    """Parse an ISO-8601 timestamp. Returns None instead of inventing now()."""
    del now
    if not isinstance(value, str) or not value.strip():
        return None
    raw = value.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    match = re.match(r"^(.*)(\.)(\d+)([+-].*)$", raw)
    if match:
        frac = match.group(3)[:6].ljust(6, "0")
        raw = match.group(1) + match.group(2) + frac + match.group(4)
    try:
        from datetime import datetime

        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    return parsed.timestamp()


def parse_listening_ports(proc_net_tcp: str) -> set[int]:
    """LISTEN (state 0A) local ports only. Remote/TIME_WAIT :0fa2 must not match."""
    ports: set[int] = set()
    for line in proc_net_tcp.splitlines():
        parts = line.split()
        if len(parts) < 4 or not parts[1] or ":" not in parts[1]:
            continue
        if parts[0] == "sl":
            continue
        if parts[3].upper() != LISTEN_STATE:
            continue
        port_hex = parts[1].rsplit(":", 1)[-1]
        try:
            ports.add(int(port_hex, 16))
        except ValueError:
            continue
    return ports


def classify_login(log_text: str, present_files: list[str]) -> tuple[str, str | None, bool]:
    """Return (login_state, manual_action, twofa_evidence).

    Last chronological transition wins. Authenticating then Login has completed
    is logged_in. 2FA is only true when IBC evidence is present.
    """
    names = {Path(item).name.lower() for item in present_files}
    twofa_file = any(
        "fullauthrequired" in name or "twofa" in name or "2fa" in name for name in names
    )
    twofa_log = bool(TWOFA_RE.search(log_text or ""))
    twofa_evidence = twofa_file or twofa_log
    manual = MANUAL_FULLAUTH if any("fullauthrequired" in name for name in names) else None
    if twofa_evidence and manual is None:
        manual = "operator-auth"
    return login_state_from_log(log_text or ""), manual, twofa_evidence


def login_state_from_log(log_text: str) -> str:
    last = LOGIN_UNKNOWN
    for line in (log_text or "").splitlines():
        for regex, state in LINE_LOGIN_PATTERNS:
            if regex.search(line):
                last = state
                break
    return last


def filter_logs_to_generation(log_text: str, started_at: float | None) -> str:
    """Keep docker --timestamps login lines at or after this init's start epoch.

    Untimestamped or pre-start lines must not classify a new generation
    (including leftover 2FA / Login has completed from the previous init).
    Without a start epoch the tail cannot be proven current, so it is dropped.
    """
    if not log_text or started_at is None:
        return ""
    kept: list[str] = []
    for line in log_text.splitlines():
        raw = line.strip()
        if not raw:
            continue
        match = DOCKER_TS_RE.match(raw)
        if not match:
            continue
        observed = parse_iso_seconds(match.group(1))
        if observed is None or observed < started_at:
            continue
        kept.append(raw)
    return "\n".join(kept)


def log_line_body(raw: str) -> str:
    match = DOCKER_TS_RE.match((raw or "").strip())
    return match.group(2) if match else (raw or "").strip()


def log_line_in_generation(raw: str, started_at: float | None) -> bool:
    if not raw or started_at is None:
        return False
    match = DOCKER_TS_RE.match(raw.strip())
    if not match:
        return False
    observed = parse_iso_seconds(match.group(1))
    return observed is not None and observed >= started_at


def meaningful_auth_event_line(raw: str) -> bool:
    """Login/2FA/named-failure only. Transport flood (socat) is not an event."""
    body = log_line_body(raw)
    if not body:
        return False
    if TWOFA_RE.search(body):
        return True
    for regex, _state in LINE_LOGIN_PATTERNS:
        if regex.search(body):
            return True
    for _name, regex in AUTH_FAILURE_CLASSES:
        if regex.search(body):
            return True
    return False


def classify_auth_failure(log_text: str) -> str | None:
    """Last named failure class in chronological kept events. Never raw text."""
    last = None
    for line in (log_text or "").splitlines():
        body = log_line_body(line)
        for name, regex in AUTH_FAILURE_CLASSES:
            if regex.search(body):
                last = name
                break
    return last


def docker_since_stamp(started_at: float) -> str:
    from datetime import datetime, timezone

    return datetime.fromtimestamp(started_at, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def login_logs_since_epoch(
    started_at: float, now: float, lookback_sec: int = LOG_LOOKBACK_SEC
) -> float:
    """Recent window, never before this generation's start."""
    return max(float(started_at), float(now) - float(lookback_sec))


def docker_login_logs_argv(cfg: Config, since_at: float) -> list[str]:
    """Bounded --since window. Never --tail/--follow (hide or unbounded-follow)."""
    return [
        cfg.docker_bin,
        "logs",
        "--timestamps",
        "--since",
        docker_since_stamp(since_at),
        cfg.container_name,
    ]


@dataclass(frozen=True)
class LogCollectResult:
    kind: str
    text: str = ""
    auth_failure_class: str | None = None
    scanned_lines: int = 0
    kept_lines: int = 0


def collect_meaningful_events_from_lines(
    lines: Iterable[str],
    started_at: float | None,
    *,
    deadline: float | None = None,
    now_fn: Callable[[], float] = time.monotonic,
    max_scan_bytes: int = LOG_SCAN_MAX_BYTES,
    max_scan_lines: int = LOG_SCAN_MAX_LINES,
    max_keep_lines: int = LOG_KEEP_MAX_LINES,
    max_keep_bytes: int = LOG_KEEP_MAX_BYTES,
) -> LogCollectResult:
    """Keep current-generation login/2FA/failure events only. Bound scan and memory.

    Truncation is kind=overflow/timeout with empty text so callers cannot restart
    on a partial chronology. Previous-generation and untimestamped lines drop.
    """
    if started_at is None:
        return LogCollectResult(kind="ok", text="")
    kept: list[str] = []
    keep_bytes = 0
    scan_bytes = 0
    scan_lines = 0
    for raw_line in lines:
        if deadline is not None and now_fn() >= deadline:
            return LogCollectResult(kind="timeout")
        line = raw_line if isinstance(raw_line, str) else str(raw_line)
        scan_lines += 1
        scan_bytes += len(line.encode("utf-8", "replace"))
        if scan_lines > max_scan_lines or scan_bytes > max_scan_bytes:
            return LogCollectResult(kind="overflow")
        raw = line.strip()
        if not raw or not log_line_in_generation(raw, started_at):
            continue
        if not meaningful_auth_event_line(raw):
            continue
        encoded = len(raw.encode("utf-8", "replace"))
        if len(kept) >= max_keep_lines or keep_bytes + encoded > max_keep_bytes:
            return LogCollectResult(kind="overflow")
        kept.append(raw)
        keep_bytes += encoded
    kept.sort(key=_log_line_sort_key)
    text = "\n".join(kept)
    return LogCollectResult(
        kind="ok",
        text=text,
        auth_failure_class=classify_auth_failure(text),
        scanned_lines=scan_lines,
        kept_lines=len(kept),
    )


def _log_line_sort_key(raw: str) -> float:
    match = DOCKER_TS_RE.match((raw or "").strip())
    if not match:
        return 0.0
    observed = parse_iso_seconds(match.group(1))
    return observed if observed is not None else 0.0


class CollectBoundExceeded(Exception):
    """Raw read exceeded byte/line caps before a complete chronology existed."""


class CollectReadFailed(Exception):
    """select/os.read failed; chronology is partial and must not be used."""


def classify_docker_client_error_line(line: str) -> str | None:
    lowered = (line or "").lower()
    if "permission denied" in lowered or "eacces" in lowered or "eperm" in lowered:
        return "permission"
    return None


class _BoundedLineDecoder:
    """Incomplete-line buffer is capped during raw read, not after yield."""

    def __init__(self, raw_bytes: list[int], max_buf_bytes: int, max_raw_bytes: int) -> None:
        self.buf = ""
        self.raw_bytes = raw_bytes
        self.max_buf_bytes = max_buf_bytes
        self.max_raw_bytes = max_raw_bytes

    def feed(self, chunk: bytes) -> list[str]:
        if not chunk:
            return self.flush()
        self.raw_bytes[0] += len(chunk)
        if self.raw_bytes[0] > self.max_raw_bytes:
            raise CollectBoundExceeded
        self.buf += chunk.decode("utf-8", "replace")
        lines: list[str] = []
        while "\n" in self.buf:
            line, self.buf = self.buf.split("\n", 1)
            lines.append(line + "\n")
        if len(self.buf.encode("utf-8", "replace")) > self.max_buf_bytes:
            raise CollectBoundExceeded
        return lines

    def flush(self) -> list[str]:
        if not self.buf:
            return []
        if len(self.buf.encode("utf-8", "replace")) > self.max_buf_bytes:
            raise CollectBoundExceeded
        leftover = self.buf
        self.buf = ""
        return [leftover]


def _iter_multiplexed_log_lines(
    stdout_fd: int,
    stderr_fd: int | None,
    deadline: float,
    *,
    client_kinds: list[str] | None = None,
    max_chunk: int = 8192,
    max_buf_bytes: int = LOG_RAW_BUF_MAX_BYTES,
    max_raw_bytes: int = LOG_SCAN_MAX_BYTES,
    max_lines: int = LOG_SCAN_MAX_LINES,
):
    """Drain stdout and stderr together. Cap incomplete buffers during os.read."""
    raw_bytes = [0]
    decoders = {stdout_fd: _BoundedLineDecoder(raw_bytes, max_buf_bytes, max_raw_bytes)}
    if stderr_fd is not None:
        decoders[stderr_fd] = _BoundedLineDecoder(raw_bytes, max_buf_bytes, max_raw_bytes)
    open_fds = set(decoders)
    yielded = 0

    def emit(fd: int, lines: list[str]):
        nonlocal yielded
        for line in lines:
            if stderr_fd is not None and fd == stderr_fd and not DOCKER_TS_RE.match(line.strip()):
                kind = classify_docker_client_error_line(line)
                if kind and client_kinds is not None:
                    client_kinds.append(kind)
                continue
            yielded += 1
            if yielded > max_lines:
                raise CollectBoundExceeded
            yield line

    while open_fds:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError
        try:
            ready, _, _ = select.select(list(open_fds), [], [], remaining)
        except (ValueError, OSError) as error:
            raise CollectReadFailed("select failed") from error
        if not ready:
            raise TimeoutError
        for fd in ready:
            try:
                chunk = os.read(fd, max_chunk)
            except OSError as error:
                raise CollectReadFailed("os.read failed") from error
            decoder = decoders[fd]
            if not chunk:
                yield from emit(fd, decoder.flush())
                open_fds.discard(fd)
                continue
            yield from emit(fd, decoder.feed(chunk))


def _iter_fd_lines(
    fd: int,
    deadline: float,
    max_chunk: int = 8192,
    max_buf_bytes: int = LOG_RAW_BUF_MAX_BYTES,
    max_raw_bytes: int = LOG_SCAN_MAX_BYTES,
):
    yield from _iter_multiplexed_log_lines(
        fd,
        None,
        deadline,
        max_chunk=max_chunk,
        max_buf_bytes=max_buf_bytes,
        max_raw_bytes=max_raw_bytes,
    )


def _reap_docker_logs(proc: subprocess.Popen, *, kill: bool = False) -> None:
    try:
        if kill and proc.poll() is None:
            proc.kill()
        if proc.poll() is None:
            proc.wait(timeout=1)
    except Exception:
        pass
    for stream in (proc.stdout, proc.stderr):
        if stream is None:
            continue
        try:
            stream.close()
        except Exception:
            pass


def _kill_process(proc: subprocess.Popen) -> None:
    _reap_docker_logs(proc, kill=True)


def observe_login_logs(
    cfg: Config, started_at: float | None, now: float | None = None
) -> LogCollectResult:
    """Stream docker logs; retain only bounded meaningful current-generation events."""
    if started_at is None:
        return LogCollectResult(kind="ok", text="")
    stamp = now if now is not None else time.time()
    since_at = login_logs_since_epoch(started_at, stamp)
    argv = docker_login_logs_argv(cfg, since_at)
    deadline = time.monotonic() + LOG_COLLECT_TIMEOUT_SEC
    try:
        proc = subprocess.Popen(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except PermissionError:
        return LogCollectResult(kind="permission")
    except OSError as error:
        if getattr(error, "errno", None) in {13, 1}:
            return LogCollectResult(kind="permission")
        return LogCollectResult(kind="nonzero")
    if proc.stdout is None:
        _reap_docker_logs(proc, kill=True)
        return LogCollectResult(kind="nonzero")
    client_kinds: list[str] = []
    stderr_fd = proc.stderr.fileno() if proc.stderr is not None else None
    kill = True
    try:
        try:
            result = collect_meaningful_events_from_lines(
                _iter_multiplexed_log_lines(
                    proc.stdout.fileno(),
                    stderr_fd,
                    deadline,
                    client_kinds=client_kinds,
                ),
                started_at,
                deadline=deadline,
            )
        except TimeoutError:
            return LogCollectResult(kind="timeout")
        except CollectBoundExceeded:
            return LogCollectResult(kind="overflow")
        except CollectReadFailed:
            return LogCollectResult(kind="nonzero")
        if result.kind != "ok":
            return result
        try:
            proc.wait(timeout=max(0.05, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            return LogCollectResult(kind="timeout")
        if proc.returncode not in (0, None):
            if "permission" in client_kinds:
                return LogCollectResult(kind="permission")
            return LogCollectResult(kind="nonzero")
        kill = False
        return result
    finally:
        _reap_docker_logs(proc, kill=kill)


def resolve_login_state(
    log_state: str, persist: SupervisorState, generation: str | None
) -> tuple[str, bool]:
    """Keep last auth phase for this container generation when the tail is relay spam.

    generation is containerID:pid1-startticks, not a rounded docker ps age.
    Unread generation is not a new generation — do not erase persist.
    """
    if log_state != LOGIN_UNKNOWN:
        return log_state, False
    if generation is None:
        if persist.login_state and persist.login_state != LOGIN_UNKNOWN:
            return persist.login_state, True
        return LOGIN_UNKNOWN, False
    if (
        persist.login_generation == generation
        and persist.login_state
        and persist.login_state != LOGIN_UNKNOWN
    ):
        return persist.login_state, True
    return LOGIN_UNKNOWN, False


def parse_pusher_published_state(payload: str) -> PusherView | None:
    """Accept live pusher push lines. Reject history ledgers.

    generatedAt is the financial snapshot. Publication time is the docker
    `--timestamps` prefix, not generatedAt. Ungtimestamped lines are kept with
    observed_at=None and cannot prove a recent publish.
    """
    if not payload or not payload.strip():
        return None
    views: list[PusherView] = []
    for observed_at, observed_raw, chunk in _timestamped_json_blobs(payload):
        view = _pusher_view_from_obj(chunk)
        if view is None:
            continue
        views.append(
            replace(view, observed_at=observed_at, observed_at_raw=observed_raw)
        )
    if not views:
        return None
    return views[-1]


def _timestamped_json_blobs(payload: str) -> list[tuple[float | None, str | None, dict]]:
    blobs: list[tuple[float | None, str | None, dict]] = []
    text = payload.strip()
    try:
        loaded = json.loads(text)
        if isinstance(loaded, dict):
            return [(None, None, loaded)]
        if isinstance(loaded, list):
            return [(None, None, item) for item in loaded if isinstance(item, dict)]
    except json.JSONDecodeError:
        pass
    for line in text.splitlines():
        raw = line.strip()
        observed_at = None
        observed_raw = None
        match = DOCKER_TS_RE.match(raw)
        if match:
            observed_raw = match.group(1)
            observed_at = parse_iso_seconds(observed_raw)
            raw = match.group(2).strip()
        if not raw.startswith("{"):
            continue
        try:
            loaded = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if isinstance(loaded, dict):
            blobs.append((observed_at, observed_raw, loaded))
    return blobs


def _pusher_view_from_obj(obj: dict) -> PusherView | None:
    keys = set(obj)
    if keys & HISTORY_MARKERS:
        return None
    if obj.get("schema") == "inspr.joe.household.v1":
        safety = obj.get("safety") if isinstance(obj.get("safety"), dict) else {}
        gateway_obj = safety.get("gateway") if isinstance(safety.get("gateway"), dict) else {}
        status = gateway_obj.get("status")
        gateway = status == "ok"
        generated_raw = obj.get("generatedAt") if isinstance(obj.get("generatedAt"), str) else None
        last_error = None
        if not gateway:
            last_error = gateway_obj.get("detail") if isinstance(gateway_obj.get("detail"), str) else None
        return PusherView(
            gateway=gateway,
            generated_at=parse_iso_seconds(generated_raw),
            generated_at_raw=generated_raw,
            source="household_snapshot",
            last_error=last_error,
        )
    if not PUSH_LINE_KEYS <= keys:
        return None
    if not isinstance(obj.get("gateway"), bool):
        return None
    generated_raw = obj.get("generatedAt") if isinstance(obj.get("generatedAt"), str) else None
    last_error = obj.get("lastError") if isinstance(obj.get("lastError"), str) else None
    return PusherView(
        gateway=bool(obj.get("gateway")),
        generated_at=parse_iso_seconds(generated_raw),
        generated_at_raw=generated_raw,
        source="live_push_log",
        last_error=last_error,
    )


def in_startup_grace(obs: Observation, state: SupervisorState, cfg: Config) -> bool:
    if obs.container_started_at is not None and obs.now - obs.container_started_at < cfg.startup_grace_sec:
        return True
    if state.last_restart_at is not None and obs.now - state.last_restart_at < cfg.startup_grace_sec:
        return True
    return False


def pusher_publish_is_current(obs: Observation, cfg: Config) -> bool:
    """Recent docker-log publish after this Gateway init. generatedAt may be still.

    Requires the exact /proc start epoch. Never guess from rounded docker ps age.
    """
    pusher = obs.pusher
    if pusher is None or pusher.observed_at is None:
        return False
    if obs.container_started_at is None:
        return False
    if pusher.observed_at < obs.container_started_at:
        return False
    if obs.now - pusher.observed_at > cfg.stale_generated_at_sec:
        return False
    return True


def session_healthy(obs: Observation, cfg: Config) -> bool:
    """API 4002 listening AND a recent pusher publish with gateway true.

    generatedAt may stay still on a quiet book. A pre-start or untimestamped
    gateway:true must not reset the budget. Unknown probes are not health.
    """
    if obs.probe_unknown or obs.container_running is not True or obs.api_listening is not True:
        return False
    if obs.pusher is None or not obs.pusher.gateway:
        return False
    return pusher_publish_is_current(obs, cfg)


def session_unhealthy(obs: Observation) -> bool:
    if obs.probe_unknown or obs.container_running is None or obs.api_listening is None:
        return False
    if obs.container_running is False:
        return True
    if obs.api_listening is False:
        return True
    if obs.pusher is not None and obs.pusher.gateway is False and obs.pusher.observed_at is not None:
        return True
    return False


def probes_unknown(obs: Observation) -> bool:
    return bool(obs.probe_unknown) or obs.container_running is None or obs.api_listening is None


def _outage_id(obs: Observation) -> str:
    if obs.container_generation:
        return f"session:gen:{obs.container_generation}"
    if obs.pusher and obs.pusher.observed_at_raw:
        return f"session:pub:{obs.pusher.observed_at_raw}"
    return "session:unknown"


def decide(obs: Observation, state: SupervisorState, cfg: Config) -> Decision:
    persist = SupervisorState.from_dict(state.to_dict())
    persist.corrupt = state.corrupt
    notes: list[str] = []
    if obs.twofa_evidence:
        notes.append("ibc-auth-evidence-present")
    else:
        notes.append("no-2fa-evidence")
    if obs.auth_failure_class:
        notes.append(f"auth-class:{obs.auth_failure_class}")

    if state.corrupt:
        persist = corrupt_halt_state()
        persist.last_alert_status = state.last_alert_status
        return halt_decision(
            obs,
            persist,
            cfg,
            notes,
            "supervisor state corrupt; operator clear required",
        )

    if obs.operator_clear:
        persist = SupervisorState(
            phase=PHASE_SLOWSTARTING if not session_healthy(obs, cfg) else PHASE_API_READY,
            last_healthy_at=state.last_healthy_at,
            last_alert_status=state.last_alert_status,
        )
        notes.append("operator-clear")

    if (
        obs.container_generation is not None
        and persist.login_generation != obs.container_generation
    ):
        persist.phase = PHASE_SLOWSTARTING
        persist.authenticating_since = None
        persist.login_state = None
        persist.login_generation = None
        notes.append("generation-changed")

    login, persisted_login = resolve_login_state(
        obs.login_state, persist, obs.container_generation
    )
    if persisted_login:
        if obs.login_state == LOGIN_UNKNOWN and obs.container_generation is None:
            notes.append("generation-unread")
        else:
            notes.append("login-persisted-across-relay-spam")
    if login != LOGIN_UNKNOWN:
        persist.login_state = login
        if obs.container_generation is not None:
            persist.login_generation = obs.container_generation
    elif obs.container_generation is None:
        notes.append("generation-unread")
    elif persist.login_generation != obs.container_generation:
        persist.login_state = None
        persist.login_generation = None
        persist.authenticating_since = None

    effective = replace(obs, login_state=login)

    if probes_unknown(effective):
        persist.phase = PHASE_UNKNOWN
        return Decision(
            phase=PHASE_UNKNOWN,
            action=ACTION_NONE,
            reason=effective.probe_reason
            or "docker probe unknown; not restarting or resetting budget",
            alert_problem=None,
            persist=persist,
            alert_status=persist.last_alert_status,
            notes=notes + ["probe-unknown"],
        )

    if session_healthy(effective, cfg):
        persist.phase = PHASE_API_READY
        persist.outage_id = None
        persist.restarts_this_outage = 0
        persist.halt_reason = None
        persist.operator_clear_required = False
        persist.unhealthy_since = None
        persist.authenticating_since = None
        persist.last_healthy_at = effective.now
        persist.last_alert_status = state.last_alert_status
        return Decision(
            phase=PHASE_API_READY,
            action=ACTION_NONE,
            reason="paper API 4002 listening and recent pusher publish reports gateway true",
            alert_problem=None,
            persist=persist,
            alert_status=state.last_alert_status,
            notes=notes + ["recovery-reset"],
        )

    if persist.unhealthy_since is None:
        persist.unhealthy_since = effective.now
    persist.outage_id = persist.outage_id or _outage_id(effective)

    grace = in_startup_grace(effective, persist, cfg)
    auth_since = persist.authenticating_since
    if login == LOGIN_AUTHENTICATING:
        persist.authenticating_since = auth_since or effective.now
    elif (
        obs.container_generation is not None
        and persist.login_generation == obs.container_generation
    ):
        persist.authenticating_since = None
    auth_age = (
        effective.now - persist.authenticating_since
        if persist.authenticating_since is not None
        else 0.0
    )

    def stay(phase: str, reason: str, problem: engine.Problem | None = None) -> Decision:
        persist.phase = phase
        return Decision(
            phase=phase,
            action=ACTION_NONE,
            reason=reason,
            alert_problem=problem,
            persist=persist,
            alert_status=state.last_alert_status,
            notes=notes,
        )

    if effective.container_running is False:
        persist.phase = PHASE_CONTAINER_DOWN
        if persist.operator_clear_required or persist.restarts_this_outage >= cfg.max_restarts_per_outage:
            return halt_decision(
                effective,
                persist,
                cfg,
                notes,
                "ib-gateway container is not running; restart budget exhausted",
                PHASE_CONTAINER_DOWN,
            )
        return _maybe_restart(
            effective,
            persist,
            cfg,
            notes,
            PHASE_CONTAINER_DOWN,
            "ib-gateway container is not running",
        )

    if effective.manual_action:
        label = (
            "IB Gateway login needs operator action (IBC fullauthrequired present)"
            if effective.manual_action == MANUAL_FULLAUTH
            else "IB Gateway login needs operator action"
        )
        if not effective.twofa_evidence:
            notes.append("manual-action-without-2fa-label")
        return halt_decision(effective, persist, cfg, notes, label)

    if grace:
        phase = PHASE_AUTHENTICATING if login == LOGIN_AUTHENTICATING else PHASE_SLOWSTARTING
        return stay(
            phase,
            "recent ib-gateway start or restart is inside startup grace; not restarting",
        )

    if login == LOGIN_AUTHENTICATING and auth_age < cfg.auth_timeout_sec:
        return stay(
            PHASE_AUTHENTICATING,
            "IBC is authenticating; waiting before any restart to avoid an auth loop",
        )

    if login == LOGIN_AUTHENTICATING and auth_age >= cfg.auth_timeout_sec:
        reason = "prolonged authenticating without API 4002; operator action may be required"
        if not effective.twofa_evidence:
            notes.append("prolonged-auth-not-labeled-2fa")
        return halt_decision(effective, persist, cfg, notes, reason)

    if effective.api_listening is False:
        phase = PHASE_SLOWSTARTING
        reason = (
            "socat relay open but paper API 4002 is not listening"
            if effective.relay_open
            else "paper API 4002 is not listening"
        )
        if persist.operator_clear_required or persist.restarts_this_outage >= cfg.max_restarts_per_outage:
            return halt_decision(effective, persist, cfg, notes, f"{reason}; restart budget exhausted")
        return _maybe_restart(effective, persist, cfg, notes, phase, reason)

    if effective.pusher is None or not pusher_publish_is_current(effective, cfg):
        persist.phase = PHASE_UPSTREAM_UNAVAILABLE
        notes.append("tcp-is-not-farm-ready")
        if effective.pusher is not None and effective.pusher.gateway:
            notes.append("pre-start-or-stale-publish-ignored")
        return stay(
            PHASE_UPSTREAM_UNAVAILABLE,
            "API 4002 listening without a recent pusher publish; not farm-ready and not restarting",
        )

    if effective.pusher.gateway is False:
        reason = "paper API 4002 listening but recent pusher publish reports gateway false"
        if persist.operator_clear_required or persist.restarts_this_outage >= cfg.max_restarts_per_outage:
            return halt_decision(effective, persist, cfg, notes, f"{reason}; restart budget exhausted")
        return _maybe_restart(effective, persist, cfg, notes, PHASE_UPSTREAM_UNAVAILABLE, reason)

    persist.phase = PHASE_UPSTREAM_UNAVAILABLE
    return stay(
        PHASE_UPSTREAM_UNAVAILABLE,
        "API 4002 listening; pusher gateway not proven true on a current publish; not farm-ready",
    )


def halt_decision(
    obs: Observation,
    persist: SupervisorState,
    cfg: Config,
    notes: list[str],
    reason: str,
    phase: str = PHASE_HALTED,
) -> Decision:
    persist.phase = phase
    persist.halt_reason = reason
    persist.operator_clear_required = True
    problem = engine.Problem(PROBLEM_KEY, _alert_text(obs, persist, cfg, reason))
    return Decision(
        phase=phase,
        action=ACTION_HALT,
        reason=reason,
        alert_problem=problem,
        persist=persist,
        alert_status=persist.last_alert_status,
        notes=notes,
    )


def _maybe_restart(
    obs: Observation,
    persist: SupervisorState,
    cfg: Config,
    notes: list[str],
    phase: str,
    reason: str,
) -> Decision:
    persist.phase = phase
    if persist.operator_clear_required or persist.restarts_this_outage >= cfg.max_restarts_per_outage:
        persist.halt_reason = f"{reason}; restart budget exhausted"
        persist.operator_clear_required = True
        persist.phase = PHASE_HALTED
        problem = engine.Problem(PROBLEM_KEY, _alert_text(obs, persist, cfg, persist.halt_reason))
        return Decision(
            phase=PHASE_HALTED,
            action=ACTION_HALT,
            reason=persist.halt_reason,
            alert_problem=problem,
            persist=persist,
            alert_status=persist.last_alert_status,
            notes=notes,
        )
    if not obs.lock_available:
        notes.append("compose-lock-busy")
        return Decision(
            phase=phase,
            action=ACTION_NONE,
            reason=f"{reason}; managed compose lock busy, not consuming budget",
            alert_problem=engine.Problem(PROBLEM_KEY, _alert_text(obs, persist, cfg, reason)),
            persist=persist,
            alert_status=persist.last_alert_status,
            notes=notes,
        )
    persist.phase = phase
    problem = engine.Problem(
        PROBLEM_KEY,
        _alert_text(obs, persist, cfg, reason + "; one allowlisted ib-gateway restart"),
    )
    notes.append("restart-ib-gateway-only")
    return Decision(
        phase=phase,
        action=ACTION_RESTART,
        reason=reason,
        alert_problem=problem,
        persist=persist,
        alert_status=persist.last_alert_status,
        notes=notes,
    )


def _alert_text(obs: Observation, persist: SupervisorState, cfg: Config, reason: str) -> str:
    api = "unknown" if obs.api_listening is None else ("up" if obs.api_listening else "down")
    relay = "unknown" if obs.relay_open is None else ("open" if obs.relay_open else "absent")
    gw = "unknown"
    generated = "absent"
    published = "absent"
    if obs.pusher is not None:
        gw = "true" if obs.pusher.gateway else "false"
        generated = obs.pusher.generated_at_raw or "absent"
        published = obs.pusher.observed_at_raw or "absent"
    twofa = "present" if obs.twofa_evidence else "not-claimed"
    return (
        "hsb0 paper IB Gateway session: "
        f"{reason}. api4002={api} relay4004={relay} login={obs.login_state} "
        f"pusher_gateway={gw} generatedAt={generated} publishedAt={published} "
        f"restarts={persist.restarts_this_outage}/{cfg.max_restarts_per_outage} "
        f"2fa_evidence={twofa}. Paper 4002 only; live 4001 untouched. "
        "Operator clear: /var/lib/ib-gateway-session/operator-clear"
    )


def compose_restart_argv(cfg: Config, service: str = ALLOWED_SERVICE) -> list[str]:
    if service != ALLOWED_SERVICE:
        raise ValueError("refusing to restart a service that is not ib-gateway")
    argv = [
        cfg.compose_bin,
        "-p",
        cfg.compose_project,
        "-f",
        cfg.compose_file,
        "--project-directory",
        cfg.compose_project_dir,
        "restart",
        "--no-deps",
        ALLOWED_SERVICE,
    ]
    if any(token in argv for token in ("up", "--force-recreate", "compose.yaml", "override")):
        raise RuntimeError("refusing raw compose up/override")
    return argv


def restart_argv(cfg: Config, service: str = ALLOWED_SERVICE) -> list[str]:
    """Compose restart argv. Lock is held separately around reserve+side effect."""
    return compose_restart_argv(cfg, service)


def acquire_compose_lock(lock_path: str, timeout_sec: int = RESTART_LOCK_TIMEOUT_SEC):
    import fcntl

    path = Path(lock_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    deadline = time.time() + timeout_sec
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError:
            if time.time() >= deadline:
                os.close(fd)
                return None
            time.sleep(0.1)


def release_compose_lock(fd: int | None) -> None:
    if fd is None:
        return
    import fcntl

    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def apply_compose_restart(cfg: Config, runner: Callable[..., subprocess.CompletedProcess] | None = None) -> int:
    argv = compose_restart_argv(cfg)
    run = runner or subprocess.run
    result = run(argv, check=False, capture_output=True, text=True)
    return int(result.returncode)


def execute_reserved_restart(
    cfg: Config,
    persist: SupervisorState,
    now: float,
    restarter: Callable[[Config], int],
    locker: Callable[[], object] | None = None,
    unlocker: Callable[[object], None] | None = None,
    dir_sync: Callable[[str], None] | None = None,
) -> tuple[str, SupervisorState]:
    """Hold the managed lock, reserve+fsync file and parent dir, THEN touch Docker.

    Only proven pre-execution lock contention preserves the prior budget.
    Nonzero/timeout/crash after reservation does not refund.
    """
    held = None
    acquire = locker or (lambda: acquire_compose_lock(cfg.compose_lock))
    release = unlocker or release_compose_lock
    held = acquire()
    if not held:
        return "lock_busy", persist
    try:
        persist.restarts_this_outage += 1
        persist.last_restart_at = now
        save_supervisor_state(cfg.state_path, persist, dir_sync=dir_sync)
        code = restarter(cfg)
        if code != 0:
            return "failed_after_reserve", persist
        return "ok", persist
    finally:
        release(held)


def load_supervisor_state(path: str) -> SupervisorState:
    destination = Path(path)
    if not destination.exists():
        return SupervisorState()
    try:
        raw = json.loads(destination.read_text(encoding="utf-8"))
    except Exception:
        return corrupt_halt_state()
    return SupervisorState.from_dict(raw if isinstance(raw, dict) else None)


def fsync_directory(path: str) -> None:
    """fsync the parent directory after replace so a crash cannot lose the reservation.

    engine.atomic_write_state fsyncs the file then os.replace; the directory entry
    must be fsynced too. Implemented here — do not edit shared engine.py.
    """
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    except OSError as error:
        if error.errno not in {errno.EINVAL, errno.ENOTSUP}:
            raise
    finally:
        os.close(fd)


def save_supervisor_state(
    path: str,
    state: SupervisorState,
    *,
    dir_sync: Callable[[str], None] | None = None,
) -> None:
    engine.atomic_write_state(path, state.to_dict())
    sync = fsync_directory if dir_sync is None else dir_sync
    sync(str(Path(path).resolve().parent))


def config_from_env(env: dict[str, str] | None = None) -> Config:
    env = env or dict(os.environ)

    def _i(name: str, default: int) -> int:
        try:
            return int(env.get(name, default))
        except (TypeError, ValueError):
            return default

    return Config(
        startup_grace_sec=_i("IBGSS_STARTUP_GRACE_SEC", 12 * 60),
        auth_timeout_sec=_i("IBGSS_AUTH_TIMEOUT_SEC", 15 * 60),
        stale_generated_at_sec=_i("IBGSS_STALE_GENERATED_AT_SEC", 10 * 60),
        max_restarts_per_outage=_i("IBGSS_MAX_RESTARTS_PER_OUTAGE", 1),
        state_path=env.get("IBGSS_STATE_PATH", Config.state_path),
        alert_state_path=env.get("IBGSS_ALERT_STATE_PATH", Config.alert_state_path),
        operator_clear_path=env.get("IBGSS_OPERATOR_CLEAR_PATH", Config.operator_clear_path),
        compose_lock=env.get("IBGSS_COMPOSE_LOCK", Config.compose_lock),
        compose_file=env.get("IBGSS_COMPOSE_FILE", Config.compose_file),
        compose_project=env.get("IBGSS_COMPOSE_PROJECT", "docker"),
        compose_project_dir=env.get("IBGSS_COMPOSE_PROJECT_DIR", Config.compose_project_dir),
        compose_bin=env.get("IBGSS_COMPOSE_BIN", "docker-compose"),
        flock_bin=env.get("IBGSS_FLOCK_BIN", "flock"),
        docker_bin=env.get("IBGSS_DOCKER_BIN", "docker"),
        alert_enable=env.get("IBGSS_ALERT_ENABLE", "0") == "1",
        alert_transport=env.get("IBGSS_ALERT_TRANSPORT", "none"),
        notification_env=env.get("IBGSS_NOTIFICATION_ENV", ""),
        alert_blocker=env.get("IBGSS_ALERT_BLOCKER", Config.alert_blocker),
    )


def construct_declared_sender(cfg: Config) -> tuple[engine.Sender | None, str | None]:
    """Build a fleet-alerts sender from a declared env file. Never invent a URL."""
    if not cfg.alert_enable or cfg.alert_transport in ("", "none"):
        return None, cfg.alert_blocker
    if cfg.alert_transport == "agent-bus":
        return None, (
            "alert transport agent-bus blocked: openclaw-gateway is parked behind "
            "compose profile openclaw so sessions_send is not live"
        )
    if cfg.alert_transport != "shoutrrr":
        return None, f"alert transport {cfg.alert_transport} is not a supported declared mechanic"
    path = cfg.notification_env.strip()
    if not path:
        return None, (
            "shoutrrr selected but nixcfg.ibGatewaySession.alert.notificationEnvFile is unset; "
            "hsb0 has no declared WATCHTOWER_NOTIFICATION_URL secret. Add an agenix env "
            "decryptable by hsb0 with WATCHTOWER_NOTIFICATION_URL (same shape as "
            "csb1-watchtower-env / hsb1-tailnet-watch-env) and set notificationEnvFile to its path."
        )
    if not Path(path).is_file():
        return None, f"shoutrrr env file missing at configured path (WATCHTOWER_NOTIFICATION_URL unread)"
    url = engine.env_file_value(path, "WATCHTOWER_NOTIFICATION_URL")
    if not url:
        return None, "WATCHTOWER_NOTIFICATION_URL missing from the configured notification env file"
    try:
        return engine.shoutrrr_telegram_sender(url), None
    except ValueError:
        return None, "WATCHTOWER_NOTIFICATION_URL is not a supported fleet-alerts telegram target"


def resolve_alert_blocker(cfg: Config, extra: dict[str, object] | None = None) -> str | None:
    extra = extra or {}
    if extra.get("openclaw_running") is False and cfg.alert_transport == "agent-bus":
        return (
            "alert transport agent-bus blocked: openclaw-gateway is not running "
            "(compose profile openclaw parks it on hsb0)"
        )
    if extra.get("token_file_present") is False and cfg.alert_transport == "agent-bus":
        return "alert transport agent-bus blocked: token file missing"
    if extra.get("notification_env_present") is False and cfg.alert_transport == "shoutrrr":
        return (
            "alert transport shoutrrr blocked: no notification env file configured "
            "for this unit (hsb0 has no declared WATCHTOWER_NOTIFICATION_URL for it)"
        )
    sender, blocker = construct_declared_sender(cfg)
    del sender
    return blocker


def disabled_alert_status(blocker: str) -> str:
    return f"not-sent:{blocker}"


def run_cycle(
    obs: Observation,
    cfg: Config,
    state: SupervisorState | None = None,
    sender: engine.Sender | None = None,
    restarter: Callable[[Config], int] | None = None,
    locker: Callable[[], object] | None = None,
    unlocker: Callable[[object], None] | None = None,
) -> tuple[Decision, int]:
    previous = state or SupervisorState()
    decision = decide(obs, previous, cfg)
    persist = decision.persist

    if decision.action == ACTION_RESTART:
        try:
            outcome, persist = execute_reserved_restart(
                cfg,
                persist,
                obs.now,
                restarter or apply_compose_restart,
                locker=locker,
                unlocker=unlocker,
            )
        except Exception:
            raise
        if outcome == "lock_busy":
            persist = decision.persist
            decision = Decision(
                phase=decision.phase,
                action=ACTION_NONE,
                reason=decision.reason + "; managed compose lock busy, not consuming budget",
                alert_problem=decision.alert_problem,
                persist=persist,
                alert_status=decision.alert_status,
                notes=decision.notes + ["compose-lock-busy"],
            )
        else:
            decision.persist = persist
            if outcome == "failed_after_reserve":
                decision.notes.append("restart-failed-budget-consumed")

    blocker = resolve_alert_blocker(cfg)
    if blocker is None and sender is None:
        blocker = "alert enabled but no sender wired; refusing to invent an endpoint"
    exit_code = engine.EXIT_PROBLEMS if session_unhealthy(obs) or decision.action == ACTION_HALT else engine.EXIT_CLEAN

    if blocker is not None:
        persist.last_alert_status = disabled_alert_status(blocker)
        decision.persist = persist
        save_supervisor_state(cfg.state_path, persist)
        if decision.alert_problem is not None:
            print(f"alert not sent: {blocker}")
            print(f"would-alert: {decision.alert_problem.text}")
        else:
            print(f"alert activation blocker: {blocker}")
        return decision, exit_code

    def check() -> list[engine.Problem]:
        return [decision.alert_problem] if decision.alert_problem else []

    def render(announced: list[str], cleared: list[str]) -> str:
        parts = announced + [f"CLEARED {item}" for item in cleared]
        return " | ".join(parts)

    alert_exit = engine.run_cycle(cfg.alert_state_path, obs.now, check, render, sender)
    if alert_exit == engine.EXIT_UNDELIVERED:
        persist.last_alert_status = "undelivered"
        exit_code = engine.EXIT_UNDELIVERED
    elif alert_exit == engine.EXIT_CLEAN and not check():
        persist.last_alert_status = "cleared"
    else:
        persist.last_alert_status = "attempted"
    decision.persist = persist
    save_supervisor_state(cfg.state_path, persist)
    return decision, exit_code


@dataclass(frozen=True)
class DockerResult:
    kind: str
    stdout: str = ""
    returncode: int | None = None


def docker_command(cfg: Config, args: list[str], timeout: int = 15) -> DockerResult:
    try:
        result = subprocess.run(
            [cfg.docker_bin, *args],
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return DockerResult(kind="timeout")
    except PermissionError:
        return DockerResult(kind="permission")
    except OSError as error:
        if getattr(error, "errno", None) in {13, 1}:
            return DockerResult(kind="permission")
        return DockerResult(kind="nonzero")
    stderr = (result.stderr or "").lower()
    if result.returncode != 0:
        if result.returncode in {1, 126, 127} and (
            "permission denied" in stderr or "eacces" in stderr or "eperm" in stderr
        ):
            return DockerResult(kind="permission", returncode=result.returncode)
        return DockerResult(kind="nonzero", stdout=result.stdout or "", returncode=result.returncode)
    return DockerResult(kind="ok", stdout=result.stdout or "", returncode=0)


def observe_runtime(cfg: Config, now: float | None = None) -> Observation:
    stamp = now if now is not None else time.time()
    ps = docker_command(
        cfg,
        [
            "ps",
            "-a",
            "--filter",
            f"name=^{cfg.container_name}$",
            "--format",
            "{{.ID}}\t{{.Status}}",
        ],
    )
    if ps.kind != "ok":
        return Observation(
            now=stamp,
            container_running=None,
            container_started_at=None,
            relay_open=None,
            api_listening=None,
            login_state=LOGIN_UNKNOWN,
            authenticating_since=None,
            manual_action=None,
            twofa_evidence=False,
            pusher=None,
            operator_clear=Path(cfg.operator_clear_path).exists(),
            probe_unknown=True,
            probe_reason=f"docker ps {ps.kind}; not restarting or resetting budget",
        )
    container_id, status = parse_docker_ps_id_status(ps.stdout)
    lowered = status.lower()
    if not status:
        running: bool | None = False
    elif lowered.startswith("up"):
        running = True
    elif lowered.startswith("exited") or lowered.startswith("created") or lowered.startswith("dead"):
        running = False
    else:
        return Observation(
            now=stamp,
            container_running=None,
            container_started_at=None,
            relay_open=None,
            api_listening=None,
            login_state=LOGIN_UNKNOWN,
            authenticating_since=None,
            manual_action=None,
            twofa_evidence=False,
            pusher=None,
            operator_clear=Path(cfg.operator_clear_path).exists(),
            probe_unknown=True,
            probe_reason=f"docker ps status {status!r} is not a confirmed running/stopped state",
        )

    if running is False:
        return Observation(
            now=stamp,
            container_running=False,
            container_started_at=None,
            relay_open=False,
            api_listening=False,
            login_state=LOGIN_UNKNOWN,
            authenticating_since=None,
            manual_action=None,
            twofa_evidence=False,
            pusher=None,
            operator_clear=Path(cfg.operator_clear_path).exists(),
            probe_unknown=False,
            probe_reason=None,
        )

    proc = docker_command(
        cfg,
        ["exec", cfg.container_name, "sh", "-c", "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null"],
    )
    if proc.kind != "ok":
        return Observation(
            now=stamp,
            container_running=True,
            container_started_at=None,
            relay_open=None,
            api_listening=None,
            login_state=LOGIN_UNKNOWN,
            authenticating_since=None,
            manual_action=None,
            twofa_evidence=False,
            pusher=None,
            operator_clear=Path(cfg.operator_clear_path).exists(),
            probe_unknown=True,
            probe_reason=f"docker exec listen-table {proc.kind}; not restarting or resetting budget",
        )
    ports = parse_listening_ports(proc.stdout)
    identity = docker_command(
        cfg,
        [
            "exec",
            cfg.container_name,
            "sh",
            "-c",
            "cat /proc/1/stat; echo; grep ^btime /proc/stat",
        ],
    )
    generation = None
    started_at = None
    if identity.kind == "ok":
        ticks = parse_proc1_startticks(identity.stdout)
        boot = parse_proc_btime(identity.stdout)
        if container_id and ticks is not None:
            generation = format_container_generation(container_id, ticks)
        if boot is not None and ticks is not None:
            started_at = start_epoch_from_proc(boot, ticks)
    log_obs = observe_login_logs(cfg, started_at, now=stamp)
    if log_obs.kind != "ok":
        return Observation(
            now=stamp,
            container_running=True,
            container_started_at=started_at,
            relay_open=PORT_RELAY in ports,
            api_listening=PORT_API in ports,
            login_state=LOGIN_UNKNOWN,
            authenticating_since=None,
            manual_action=None,
            twofa_evidence=False,
            pusher=None,
            operator_clear=Path(cfg.operator_clear_path).exists(),
            probe_unknown=True,
            probe_reason=(
                f"docker login-log {log_obs.kind}; not restarting or resetting budget"
            ),
            container_generation=generation,
        )
    login_logs = log_obs.text
    files = docker_command(
        cfg,
        [
            "exec",
            cfg.container_name,
            "sh",
            "-c",
            "find /home/ibgateway /opt/ibc /tmp -maxdepth 3 "
            "\\( -iname '*fullauthrequired*' -o -iname '*autorestart*' -o -iname '*twofa*' \\) "
            "2>/dev/null | sed 's|.*/||'",
        ],
    )
    file_names = [line.strip() for line in (files.stdout or "").splitlines() if line.strip()] if files.kind == "ok" else []
    login_state, manual, twofa = classify_login(login_logs, file_names)
    auth_failure_class = log_obs.auth_failure_class
    pusher_logs = docker_command(
        cfg, ["logs", "--timestamps", "--since", "20m", "--tail", "80", cfg.pusher_container]
    )
    pusher = parse_pusher_published_state(pusher_logs.stdout) if pusher_logs.kind == "ok" else None
    operator_clear = Path(cfg.operator_clear_path).exists()
    lock_available = True
    lock_path = Path(cfg.compose_lock)
    if lock_path.exists():
        try:
            import fcntl

            with open(cfg.compose_lock, "a", encoding="utf-8") as handle:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        except OSError:
            lock_available = False
    return Observation(
        now=stamp,
        container_running=running,
        container_started_at=started_at,
        relay_open=PORT_RELAY in ports if proc.kind == "ok" else None,
        api_listening=PORT_API in ports if proc.kind == "ok" else None,
        login_state=login_state,
        authenticating_since=None,
        manual_action=manual,
        twofa_evidence=twofa,
        pusher=pusher,
        operator_clear=operator_clear,
        lock_available=lock_available,
        container_generation=generation,
        auth_failure_class=auth_failure_class,
    )


def consume_operator_clear(path: str) -> None:
    target = Path(path)
    if target.exists():
        target.unlink()


def main() -> int:
    cfg = config_from_env()
    Path(cfg.state_path).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    obs = observe_runtime(cfg)
    if obs.operator_clear:
        consume_operator_clear(cfg.operator_clear_path)
    state = load_supervisor_state(cfg.state_path)
    sender, _blocker = construct_declared_sender(cfg)
    decision, code = run_cycle(obs, cfg, state, sender=sender)
    summary = {
        "phase": decision.phase,
        "action": decision.action,
        "reason": decision.reason,
        "api4002": obs.api_listening,
        "relay4004": obs.relay_open,
        "login": obs.login_state,
        "auth_class": obs.auth_failure_class,
        "pusher_gateway": None if obs.pusher is None else obs.pusher.gateway,
        "generatedAt": None if obs.pusher is None else obs.pusher.generated_at_raw,
        "publishedAt": None if obs.pusher is None else obs.pusher.observed_at_raw,
        "alert": decision.persist.last_alert_status,
        "notes": decision.notes,
    }
    print(json.dumps(summary, sort_keys=True, separators=(",", ":")))
    return 0 if code in (engine.EXIT_CLEAN, engine.EXIT_PROBLEMS) else code


if __name__ == "__main__":
    sys.exit(main())
