#!/usr/bin/env python3
"""Privacy-safe HAUSV snapshot, health, and application alert poller.

The poller consumes existing signals. It does not create backups, inspect
business data, or repeat HAUSV's retention logic. Only stable problem
categories, counters, and timestamps are persisted or sent.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

STATE_SCHEMA = "inspr.hausv.ops-alert-state.v1"
ALERT_SCHEMA = "inspr.hausv.ops-alert.v1"
DEFAULT_STATE_PATH = "/var/lib/hausv-alerts/state.json"
DEFAULT_NOTIFICATION_ENV = "/run/agenix/csb1-watchtower-env"
SNAPSHOT_MARKER = "/var/lib/csb1-docker/hausv-org-backup-snapshot/SNAPSHOT-CREATED-UTC"
RESTIC_STATUS = "/var/lib/csb1-docker/pharos-backup-status/restic-cron-hetzner.json"
HEALTH_URL = "https://jhw22.hausv.org/healthz"
SNAPSHOT_MAX_AGE_SECONDS = 30 * 60 * 60
RESTIC_MAX_AGE_SECONDS = 30 * 60 * 60
RUNTIME_QUIET_SECONDS = 30 * 60
INITIAL_LOG_LOOKBACK_SECONDS = 10 * 60
NETWORK_TIMEOUT_SECONDS = 10
MAX_TEXT_INPUT_CHARS = 128 * 1024
MAX_COMMAND_OUTPUT_CHARS = 1024 * 1024
MAX_LOG_LINES = 5000

CRITICAL_WARNINGS = {
    "dropping unparseable trailing audit line",
    "OIDC discovery unavailable at startup",
    "magic link creation failed",
    "magic link delivery not queued",
    "magic link delivery panicked",
    "magic link delivery failed",
    "magic link delivery shutdown deadline reached",
    "Telegram bot disabled",
    "Telegram charging notifications throttled",
}

RUNTIME_LABELS = {
    "auth": "Anmeldung und Identitätsanbieter",
    "charging": "Ladesteuerung",
    "data": "Datenhaltung und Audit",
    "documents": "Dokumente und Anhänge",
    "mail": "E-Mail und Benachrichtigungen",
    "parking": "Parkplatz-Messung",
    "server": "Anwendungsprozess",
    "telegram": "Telegram-Integration",
    "other": "nicht klassifizierter Anwendungsbereich",
    "log-contract": "Struktur des Containerlogs",
}

BASE_PROBLEM_LABELS = {
    "snapshot-timer": "Snapshot-Zeitplan",
    "snapshot-service": "letzter Snapshot-Lauf",
    "snapshot-marker": "lokaler SQLite-/Blob-Snapshot",
    "restic-status": "externe Restic-Sicherung",
    "container-health": "HAUSV-Container",
    "container-restart": "unerwarteter Container-Neustart",
    "public-health": "öffentliches HAUSV-Healthsignal",
}

DEBOUNCED_KEYS = {"container-health", "public-health"}


@dataclass(frozen=True)
class Problem:
    summary: str
    action: str


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


Runner = Callable[[list[str]], CommandResult]
Reader = Callable[[str], str]
HealthReader = Callable[[], bytes]
Sender = Callable[[str, str], bool]


def run_command(args: list[str]) -> CommandResult:
    try:
        result = subprocess.run(
            args,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if len(result.stdout) + len(result.stderr) > MAX_COMMAND_OUTPUT_CHARS:
            return CommandResult(125, "", "")
        return CommandResult(result.returncode, result.stdout, result.stderr)
    except Exception:
        return CommandResult(127, "", "")


def read_text(path: str) -> str:
    with Path(path).open(encoding="utf-8") as handle:
        value = handle.read(MAX_TEXT_INPUT_CHARS + 1)
    if len(value) > MAX_TEXT_INPUT_CHARS:
        raise ValueError("input exceeds safe size limit")
    return value


def read_health() -> bytes:
    request = urllib.request.Request(
        HEALTH_URL,
        headers={"Accept": "application/json", "User-Agent": "hausv-alerts/1"},
    )
    opener = urllib.request.build_opener(NoRedirectHandler())
    with opener.open(request, timeout=NETWORK_TIMEOUT_SECONDS) as response:
        if response.status != 200:
            raise RuntimeError("health status is not successful")
        return response.read(512)


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


def utc_label(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def docker_time(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).isoformat().replace("+00:00", "Z")


def parse_timestamp(raw: str) -> float:
    value = raw.strip()
    if not value:
        raise ValueError("empty timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp lacks timezone")
    return parsed.timestamp()


def systemd_properties(unit: str, runner: Runner) -> dict[str, str]:
    result = runner(
        [
            "systemctl",
            "show",
            unit,
            "--no-pager",
            "--property=LoadState",
            "--property=UnitFileState",
            "--property=ActiveState",
            "--property=Result",
            "--property=ExecMainStatus",
        ]
    )
    if result.returncode != 0:
        return {}
    properties: dict[str, str] = {}
    for line in result.stdout.splitlines():
        key, separator, value = line.partition("=")
        if separator and key:
            properties[key] = value
    return properties


def classify_runtime(message: str) -> str:
    lowered = message.lower()
    if message.startswith("OIDC ") or "login" in lowered or "magic link" in lowered:
        return "auth" if "magic link" not in lowered else "mail"
    if message.startswith("Telegram "):
        return "telegram"
    if "charging" in lowered:
        return "charging"
    if "parking" in lowered:
        return "parking"
    if any(word in lowered for word in ("notification", "delivery", "invite email")):
        return "mail"
    if any(word in lowered for word in ("document", "attachment", "upload", "file open")):
        return "documents"
    if any(
        word in lowered
        for word in (
            "audit",
            "database",
            "sqlite",
            "migration",
            "persistence",
            "store",
            "save failed",
            "purge failed",
            "ledger",
        )
    ):
        return "data"
    if any(
        word in lowered
        for word in ("panic", "http server", "initialization", "template render")
    ):
        return "server"
    return "other"


def parse_runtime_logs(raw: str) -> tuple[dict[str, int], int]:
    categories: dict[str, int] = {}
    invalid = 0
    for line in raw.splitlines():
        if not line.strip():
            continue
        _timestamp, separator, payload = line.partition(" ")
        if not separator:
            invalid += 1
            continue
        try:
            record = json.loads(payload)
        except (TypeError, ValueError):
            invalid += 1
            continue
        if not isinstance(record, dict):
            invalid += 1
            continue
        level = str(record.get("level", "")).upper()
        message = record.get("msg")
        if not isinstance(message, str):
            if level in {"ERROR", "WARN"}:
                invalid += 1
            continue
        if level == "ERROR" or (level == "WARN" and message in CRITICAL_WARNINGS):
            category = classify_runtime(message)
            categories[category] = categories.get(category, 0) + 1
    if invalid:
        categories["log-contract"] = invalid
    return categories, invalid


def safe_state(raw: object, now: float) -> dict:
    empty = {
        "schema": STATE_SCHEMA,
        "active": [],
        "failure_counts": {},
        "runtime_last_seen": {},
        "log_cursor": now - INITIAL_LOG_LOOKBACK_SECONDS,
        "container_restarts": None,
    }
    if not isinstance(raw, dict) or raw.get("schema") != STATE_SCHEMA:
        return empty
    active = raw.get("active")
    failure_counts = raw.get("failure_counts")
    runtime_last_seen = raw.get("runtime_last_seen")
    log_cursor = raw.get("log_cursor")
    container_restarts = raw.get("container_restarts")
    if (
        not isinstance(active, list)
        or not isinstance(failure_counts, dict)
        or not isinstance(runtime_last_seen, dict)
        or not isinstance(log_cursor, (int, float))
        or container_restarts is not None
        and not isinstance(container_restarts, int)
    ):
        return empty
    empty["active"] = [key for key in active if isinstance(key, str) and known_problem_key(key)]
    empty["failure_counts"] = {
        key: min(max(int(value), 0), 2)
        for key, value in failure_counts.items()
        if key in DEBOUNCED_KEYS and isinstance(value, int)
    }
    empty["runtime_last_seen"] = {
        key: float(value)
        for key, value in runtime_last_seen.items()
        if key in RUNTIME_LABELS and isinstance(value, (int, float))
    }
    empty["log_cursor"] = min(float(log_cursor), now)
    empty["container_restarts"] = container_restarts
    pending = raw.get("pending")
    pending_next = pending.get("next_state") if isinstance(pending, dict) else None
    if (
        isinstance(pending, dict)
        and isinstance(pending.get("event_id"), str)
        and isinstance(pending.get("text"), str)
        and isinstance(pending_next, dict)
        and pending_next.get("schema") == STATE_SCHEMA
        and isinstance(pending_next.get("log_cursor"), (int, float))
        and len(pending["event_id"]) <= 96
        and len(pending["text"]) <= 4096
    ):
        sanitized_pending_next = dict(pending_next)
        sanitized_pending_next.pop("pending", None)
        empty["pending"] = {
            "event_id": pending["event_id"],
            "text": pending["text"],
            "next_state": safe_state(sanitized_pending_next, now),
        }
    return empty


def load_state(path: str, now: float) -> dict:
    try:
        return safe_state(json.loads(read_text(path)), now)
    except Exception:
        return safe_state({}, now)


def atomic_write_state(path: str, state: dict) -> None:
    destination = Path(path)
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".state-", dir=destination.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def known_problem_key(key: str) -> bool:
    if key in BASE_PROBLEM_LABELS:
        return True
    return key.startswith("runtime:") and key.removeprefix("runtime:") in RUNTIME_LABELS


def recovery_label(key: str) -> str:
    if key.startswith("runtime:"):
        category = key.removeprefix("runtime:")
        return f"Fehlerklasse {RUNTIME_LABELS.get(category, RUNTIME_LABELS['other'])}"
    return BASE_PROBLEM_LABELS.get(key, "Betriebssignal")


def add_snapshot_checks(
    problems: dict[str, Problem],
    now: float,
    reader: Reader,
    timer: dict[str, str],
    service: dict[str, str],
) -> bool:
    timer_ok = (
        timer.get("LoadState") == "loaded"
        and timer.get("UnitFileState") == "enabled"
        and timer.get("ActiveState") == "active"
    )
    if not timer_ok:
        problems["snapshot-timer"] = Problem(
            "Der tägliche Snapshot-Zeitplan ist nicht aktiviert und aktiv.",
            "Auf csb1 hausv-backup-snapshot.timer prüfen und wieder aktivieren.",
        )

    service_active = service.get("ActiveState") in {"active", "activating"}
    if (
        service.get("LoadState") != "loaded"
        or service.get("Result") != "success"
        or service.get("ExecMainStatus") != "0"
    ):
        problems["snapshot-service"] = Problem(
            "Der letzte tägliche Snapshot-Lauf war nicht erfolgreich.",
            "Journal von hausv-backup-snapshot.service prüfen; alten Recovery-Punkt bewahren.",
        )

    try:
        created_at = parse_timestamp(reader(SNAPSHOT_MARKER))
        age = now - created_at
        if age < -300:
            raise ValueError("snapshot timestamp lies in the future")
        if age > SNAPSHOT_MAX_AGE_SECONDS:
            hours = int(age // 3600)
            problems["snapshot-marker"] = Problem(
                (
                    f"Der lokale SQLite-/Blob-Snapshot ist {hours} Stunden alt; "
                    "Grenze sind 30 Stunden."
                ),
                "Snapshot-Service und danach den bestehenden Restic-Status prüfen.",
            )
    except Exception:
        problems["snapshot-marker"] = Problem(
            "Der Zeitnachweis des lokalen SQLite-/Blob-Snapshots fehlt oder ist ungültig.",
            "SNAPSHOT-CREATED-UTC und hausv-backup-snapshot.service auf csb1 prüfen.",
        )
    return service_active


def add_restic_check(problems: dict[str, Problem], now: float, reader: Reader) -> None:
    try:
        status = json.loads(reader(RESTIC_STATUS))
        if not isinstance(status, dict):
            raise ValueError("invalid status")
        state = status.get("state")
        attempt = status.get("last_attempt_state")
        last_success = status.get("last_success_at")
        if state != "healthy" or attempt != "succeeded":
            problems["restic-status"] = Problem(
                "Die bestehende Restic-Beobachtung meldet keinen erfolgreichen letzten Lauf.",
                "Pharos-Backupstatus und restic-cron-hetzner auf csb1 prüfen.",
            )
            return
        if not isinstance(last_success, (int, float)):
            raise ValueError("missing last success")
        age = now - float(last_success)
        if age < -300:
            raise ValueError("future success")
        if age > RESTIC_MAX_AGE_SECONDS:
            hours = int(age // 3600)
            problems["restic-status"] = Problem(
                (
                    f"Die letzte bestätigte externe Sicherung ist {hours} Stunden alt; "
                    "Grenze sind 30 Stunden."
                ),
                "Pharos-Backupstatus und restic-cron-hetzner auf csb1 prüfen.",
            )
    except Exception:
        problems["restic-status"] = Problem(
            "Der bestehende, bereinigte Restic-Status fehlt oder ist ungültig.",
            "Pharos-Backupstatus und restic-cron-hetzner auf csb1 prüfen.",
        )


def add_container_and_health_candidates(
    candidates: dict[str, Problem],
    state: dict,
    runner: Runner,
    health_reader: HealthReader,
    planned_snapshot: bool,
) -> int | None:
    if planned_snapshot:
        return state.get("container_restarts")
    inspect = runner(
        [
            "docker",
            "inspect",
            "--format",
            (
                "{{.State.Running}}|"
                "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|"
                "{{.RestartCount}}"
            ),
            "hausv-org",
        ]
    )
    restarts: int | None = None
    if inspect.returncode != 0:
        candidates["container-health"] = Problem(
            "Der HAUSV-Containerzustand ist nicht lesbar.",
            "Docker und den HAUSV-Container auf csb1 prüfen.",
        )
    else:
        parts = inspect.stdout.strip().split("|")
        try:
            running, health, raw_restarts = parts
            restarts = int(raw_restarts)
        except (ValueError, TypeError):
            running, health = "", ""
        if running != "true" or health != "healthy":
            candidates["container-health"] = Problem(
                "Der HAUSV-Container ist nicht durchgehend gesund.",
                "Containerstatus und aktuelle Startlogs auf csb1 prüfen.",
            )
        previous_restarts = state.get("container_restarts")
        if (
            isinstance(restarts, int)
            and isinstance(previous_restarts, int)
            and restarts > previous_restarts
        ):
            candidates["container-restart"] = Problem(
                "Der HAUSV-Container wurde seit dem letzten Prüflauf unerwartet neu gestartet.",
                "Containerzustand und Startlogs auf csb1 prüfen.",
            )

    try:
        payload = json.loads(health_reader())
        if payload != {"service": "hausv-org", "status": "ok"}:
            raise ValueError("unexpected health payload")
    except Exception:
        candidates["public-health"] = Problem(
            "Das öffentliche HAUSV-Healthsignal ist nicht gesund oder nicht vertragskonform.",
            "Öffentliche Kante, Container und /healthz auf csb1 prüfen.",
        )
    return restarts


def add_runtime_checks(
    problems: dict[str, Problem],
    state: dict,
    now: float,
    runner: Runner,
    planned_snapshot: bool,
) -> tuple[dict[str, float], float]:
    cursor = float(state.get("log_cursor", now - INITIAL_LOG_LOOKBACK_SECONDS))
    runtime_last_seen = dict(state.get("runtime_last_seen", {}))
    next_cursor = cursor
    if not planned_snapshot:
        result = runner(
            [
                "docker",
                "logs",
                "--timestamps",
                "--tail",
                str(MAX_LOG_LINES),
                "--since",
                docker_time(cursor),
                "--until",
                docker_time(now),
                "hausv-org",
            ]
        )
        if result.returncode == 0:
            categories, _invalid = parse_runtime_logs(
                "\n".join(part for part in (result.stdout, result.stderr) if part)
            )
            for category in categories:
                runtime_last_seen[category] = now
            next_cursor = now
        else:
            runtime_last_seen["log-contract"] = now

    if planned_snapshot:
        active_runtime = {
            key.removeprefix("runtime:")
            for key in state.get("active", [])
            if isinstance(key, str) and key.startswith("runtime:")
        }
        runtime_last_seen = {
            category: seen
            for category, seen in runtime_last_seen.items()
            if category in RUNTIME_LABELS and category in active_runtime
        }
    else:
        runtime_last_seen = {
            category: seen
            for category, seen in runtime_last_seen.items()
            if category in RUNTIME_LABELS and now - seen <= RUNTIME_QUIET_SECONDS
        }
    for category, seen in runtime_last_seen.items():
        age_minutes = max(0, int((now - seen) // 60))
        problems[f"runtime:{category}"] = Problem(
            (
                f"Kritische Fehlerklasse „{RUNTIME_LABELS[category]}“ war in den "
                f"letzten {max(1, age_minutes + 1)} Minuten aktiv."
            ),
            "Die entsprechende stabile Fehlerklasse im HAUSV-Containerjournal prüfen.",
        )
    return runtime_last_seen, next_cursor


def apply_debounce(
    immediate: dict[str, Problem],
    candidates: dict[str, Problem],
    state: dict,
    planned_snapshot: bool,
) -> tuple[dict[str, Problem], dict[str, int]]:
    problems = dict(immediate)
    previous_active = set(state.get("active", []))
    previous_counts = state.get("failure_counts", {})
    if planned_snapshot:
        held = {
            "container-health": Problem(
                (
                    "Der zuvor gemeldete HAUSV-Containerzustand wird nach dem "
                    "geplanten Snapshot erneut geprüft."
                ),
                "Den Abschluss von hausv-backup-snapshot.service abwarten.",
            ),
            "public-health": Problem(
                (
                    "Das zuvor gemeldete öffentliche HAUSV-Healthsignal wird nach "
                    "dem geplanten Snapshot erneut geprüft."
                ),
                "Den Abschluss von hausv-backup-snapshot.service abwarten.",
            ),
            "container-restart": Problem(
                (
                    "Der zuvor gemeldete unerwartete Container-Neustart wird nach "
                    "dem geplanten Snapshot erneut geprüft."
                ),
                "Den Abschluss von hausv-backup-snapshot.service abwarten.",
            ),
        }
        for key, problem in held.items():
            if key in previous_active:
                problems[key] = problem
        return problems, {
            key: int(value)
            for key, value in previous_counts.items()
            if key in DEBOUNCED_KEYS and isinstance(value, int)
        }
    next_counts: dict[str, int] = {}
    for key in DEBOUNCED_KEYS:
        if key not in candidates:
            continue
        count = min(int(previous_counts.get(key, 0)) + 1, 2)
        next_counts[key] = count
        if count >= 2 or key in previous_active:
            problems[key] = candidates[key]
    if "container-restart" in candidates:
        problems["container-restart"] = candidates["container-restart"]
    return problems, next_counts


def evaluate(
    state: dict,
    now: float,
    runner: Runner = run_command,
    reader: Reader = read_text,
    health_reader: HealthReader = read_health,
) -> tuple[dict[str, Problem], dict]:
    immediate: dict[str, Problem] = {}
    candidates: dict[str, Problem] = {}
    timer = systemd_properties("hausv-backup-snapshot.timer", runner)
    service = systemd_properties("hausv-backup-snapshot.service", runner)
    planned_snapshot = add_snapshot_checks(immediate, now, reader, timer, service)
    add_restic_check(immediate, now, reader)
    restarts = add_container_and_health_candidates(
        candidates, state, runner, health_reader, planned_snapshot
    )
    runtime_last_seen, log_cursor = add_runtime_checks(
        immediate, state, now, runner, planned_snapshot
    )
    problems, failure_counts = apply_debounce(
        immediate, candidates, state, planned_snapshot
    )

    next_state = {
        "schema": STATE_SCHEMA,
        "active": sorted(problems),
        "failure_counts": failure_counts,
        "runtime_last_seen": runtime_last_seen,
        "log_cursor": log_cursor,
        "container_restarts": restarts,
    }
    return problems, next_state


def event_id(now: float, new: list[str], recovered: list[str]) -> str:
    material = "|".join([str(int(now)), *new, "--", *recovered])
    import hashlib

    return "hausv-" + hashlib.sha256(material.encode()).hexdigest()[:20]


def transition_text(
    now: float,
    problems: dict[str, Problem],
    new: list[str],
    recovered: list[str],
    identifier: str,
) -> str:
    lines = ["HAUSV Betriebszustand", "System: csb1 / hausv-org", f"Zeit: {utc_label(now)}"]
    if new:
        lines.append("")
        lines.append("🔴 Neuer Alarm:")
        for key in new:
            problem = problems[key]
            lines.append(f"• {problem.summary}")
            lines.append(f"  Nächster Schritt: {problem.action}")
    if recovered:
        lines.append("")
        lines.append("✅ Entwarnung:")
        for key in recovered:
            lines.append(f"• {recovery_label(key)} ist wieder unauffällig.")
    remaining = len(problems)
    lines.extend(
        [
            "",
            f"Noch aktiv: {remaining}",
            "Runbook: HAUSV Snapshot, Health And Application Alerts",
            f"Ereignis: {identifier}",
        ]
    )
    return "\n".join(lines)


def env_file_value(path: str, key: str) -> str:
    for raw_line in read_text(path).splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line.removeprefix("export ").lstrip()
        name, separator, value = line.partition("=")
        if separator and name.strip() == key:
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
                value = value[1:-1]
            return value.strip()
    return ""


def parse_notification_target(raw: str) -> dict:
    parsed = urllib.parse.urlsplit(raw.strip())
    if parsed.scheme == "telegram":
        if parsed.hostname != "telegram" or "@" not in parsed.netloc:
            raise ValueError("invalid telegram target")
        userinfo = parsed.netloc.rsplit("@", 1)[0]
        token = urllib.parse.unquote(userinfo)
        query = urllib.parse.parse_qs(parsed.query)
        chats = query.get("chats") or query.get("channels") or []
        recipients = [
            item.strip()
            for value in chats
            for item in value.split(",")
            if re.fullmatch(r"-?[0-9]+", item.strip())
        ]
        if not token or not recipients:
            raise ValueError("invalid telegram target")
        return {"kind": "telegram", "token": token, "recipients": recipients}
    if parsed.scheme == "https" and parsed.hostname and not parsed.username:
        return {"kind": "webhook", "url": raw.strip()}
    raise ValueError("unsupported notification target")


def load_notification_target(path: str) -> dict:
    value = env_file_value(path, "WATCHTOWER_NOTIFICATION_URL")
    if not value:
        raise ValueError("notification target missing")
    return parse_notification_target(value)


def post_request(url: str, payload: bytes, content_type: str, event: str) -> bool:
    request = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Content-Type": content_type,
            "Idempotency-Key": event,
            "User-Agent": "hausv-alerts/1",
        },
        method="POST",
    )
    opener = urllib.request.build_opener(
        NoRedirectHandler(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
    )
    try:
        with opener.open(request, timeout=NETWORK_TIMEOUT_SECONDS) as response:
            return 200 <= response.status < 300
    except Exception:
        return False


def target_sender(target: dict) -> Sender:
    def send(text: str, event: str) -> bool:
        if target["kind"] == "telegram":
            endpoint = f"https://api.telegram.org/bot{target['token']}/sendMessage"
            for recipient in target["recipients"]:
                payload = json.dumps(
                    {
                        "chat_id": recipient,
                        "text": text,
                        "disable_web_page_preview": True,
                    },
                    separators=(",", ":"),
                ).encode()
                if not post_request(endpoint, payload, "application/json", event):
                    return False
            return True
        payload = json.dumps(
            {
                "schema": ALERT_SCHEMA,
                "event_id": event,
                "component": "hausv-org",
                "host": "csb1",
                "text": text,
            },
            separators=(",", ":"),
        ).encode()
        return post_request(target["url"], payload, "application/json", event)

    return send


def retry_pending(state_path: str, state: dict, sender: Sender) -> tuple[dict, bool]:
    pending = state.get("pending")
    if not isinstance(pending, dict):
        return state, True
    if not sender(pending["text"], pending["event_id"]):
        return state, False
    next_state = safe_state(pending["next_state"], float(pending["next_state"]["log_cursor"]))
    atomic_write_state(state_path, next_state)
    return next_state, True


def run_cycle(
    state_path: str,
    now: float,
    sender: Sender,
    runner: Runner = run_command,
    reader: Reader = read_text,
    health_reader: HealthReader = read_health,
) -> tuple[int, dict[str, int]]:
    state = load_state(state_path, now)
    state, delivered = retry_pending(state_path, state, sender)
    if not delivered:
        return 2, {"active": len(state.get("active", [])), "new": 0, "recovered": 0}

    problems, next_state = evaluate(state, now, runner, reader, health_reader)
    previous = set(state.get("active", []))
    current = set(problems)
    new = sorted(current - previous)
    recovered = sorted(previous - current)
    if new or recovered:
        identifier = event_id(now, new, recovered)
        text = transition_text(now, problems, new, recovered, identifier)
        pending_state = dict(state)
        pending_state["pending"] = {
            "event_id": identifier,
            "text": text,
            "next_state": next_state,
        }
        atomic_write_state(state_path, pending_state)
        if not sender(text, identifier):
            return 2, {"active": len(current), "new": len(new), "recovered": len(recovered)}
    atomic_write_state(state_path, next_state)
    return (1 if current else 0), {
        "active": len(current),
        "new": len(new),
        "recovered": len(recovered),
    }


def delivery_probe(sender: Sender, now: float) -> bool:
    probe_id = event_id(now, ["delivery-probe"], [])
    alarm = "\n".join(
        [
            "HAUSV Alarmweg-Test",
            "System: csb1 / hausv-org",
            f"Zeit: {utc_label(now)}",
            "🔴 Testalarm: Der Betriebskanal ist erreichbar.",
            "Keine Produktionsstörung wurde ausgelöst.",
            f"Ereignis: {probe_id}-alarm",
        ]
    )
    recovery = "\n".join(
        [
            "HAUSV Alarmweg-Test",
            "System: csb1 / hausv-org",
            f"Zeit: {utc_label(now)}",
            "✅ Testentwarnung: Alarm und Entwarnung wurden zugestellt.",
            "Keine Produktionsstörung wurde ausgelöst.",
            f"Ereignis: {probe_id}-recovery",
        ]
    )
    return sender(alarm, f"{probe_id}-alarm") and sender(recovery, f"{probe_id}-recovery")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--delivery-probe", action="store_true")
    return parser.parse_args()


def main() -> int:
    os.umask(0o077)
    args = parse_args()
    now = datetime.now(timezone.utc).timestamp()
    try:
        sender = target_sender(load_notification_target(DEFAULT_NOTIFICATION_ENV))
    except Exception:
        print("hausv-alerts: operator channel unavailable", file=sys.stderr)
        return 2
    if args.delivery_probe:
        if not delivery_probe(sender, now):
            print("hausv-alerts: delivery probe failed", file=sys.stderr)
            return 2
        print("hausv-alerts: delivery probe succeeded")
        return 0
    try:
        result, counts = run_cycle(DEFAULT_STATE_PATH, now, sender)
    except Exception:
        print("hausv-alerts: monitor cycle failed", file=sys.stderr)
        return 2
    print(
        "hausv-alerts: "
        f"active={counts['active']} new={counts['new']} recovered={counts['recovered']}"
    )
    return result


if __name__ == "__main__":
    sys.exit(main())
