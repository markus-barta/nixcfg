#!/usr/bin/env python3
"""Durable independent notification state for the paper IB Gateway.

The supervisor decides whether an observation is eligible for notification.
This module records and delivers the resulting problem/recovery transitions.
Each channel has its own write-ahead state file and retry clock, so a
successful email is never repeated merely because the Grok channel failed, and
email can receive recovery while Grok is still retrying its original alert.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

import engine

RETRY_INTERVAL_SECONDS = 5 * 60
STATE_FILENAME = "state.json"


def _state_path(state_directory: str | Path, channel: str) -> Path:
    """Return the private per-channel state file below the caller directory."""

    if not channel or Path(channel).name != channel or channel in {".", ".."}:
        raise ValueError("channel name must be a simple path component")
    return Path(state_directory) / channel / STATE_FILENAME


def _empty_state() -> dict[str, Any]:
    return {"version": 1, "outage": None, "pending": None}


def _load(state_directory: str | Path, channel: str) -> dict[str, Any]:
    path = _state_path(state_directory, channel)
    try:
        with path.open(encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, ValueError, TypeError):
        return _empty_state()
    if not isinstance(raw, dict):
        return _empty_state()
    outage = raw.get("outage") if isinstance(raw.get("outage"), dict) else None
    pending = raw.get("pending") if isinstance(raw.get("pending"), dict) else None
    return {"version": 1, "outage": outage, "pending": pending}


def _save(state_directory: str | Path, channel: str, state: dict[str, Any]) -> None:
    engine.atomic_write_state(str(_state_path(state_directory, channel)), state)


def _event_id(kind: str, now: float, text: str) -> str:
    # Retries retain this value from the pending WAL entry. A timestamp only
    # identifies a new outage after a prior one has recovered.
    material = f"{kind}\0{now:.6f}\0{text}".encode("utf-8")
    return hashlib.sha256(material).hexdigest()[:16]


def _event(kind: str, now: float, text: str) -> dict[str, Any]:
    return {
        "kind": kind,
        "event_id": _event_id(kind, now, text),
        "text": text,
        "status": "pending",
        "attempts": 0,
        "next_attempt_at": 0.0,
    }


def _valid_pending(event: Any) -> bool:
    return (
        isinstance(event, dict)
        and event.get("kind") in {"problem", "recovery"}
        and isinstance(event.get("text"), str)
        and isinstance(event.get("event_id"), str)
        and event.get("status") in {"pending", "delivered"}
    )


def _normalise_pending(event: dict[str, Any]) -> None:
    try:
        event["attempts"] = max(0, int(event.get("attempts", 0)))
    except (TypeError, ValueError):
        event["attempts"] = 0
    try:
        event["next_attempt_at"] = float(event.get("next_attempt_at", 0.0))
    except (TypeError, ValueError):
        event["next_attempt_at"] = 0.0


def _attempt_pending(
    state_directory: str | Path,
    channel: str,
    state: dict[str, Any],
    now: float,
    health: bool | None,
    sender: engine.Sender | None,
) -> bool:
    """Attempt this channel's due event and return whether it was delivered."""

    event = state.get("pending")
    if not _valid_pending(event):
        return False
    assert isinstance(event, dict)
    _normalise_pending(event)
    if event["status"] == "delivered":
        return True
    # A recovery remains queued until a fresh confirmed healthy observation.
    if event["kind"] == "recovery" and health is not True:
        return False
    if now < event["next_attempt_at"]:
        return False

    # Reserve this attempt before the external side effect. A crash after a
    # sender accepts the message cannot immediately bypass the five-minute
    # retry interval and duplicate it.
    event["attempts"] += 1
    event["next_attempt_at"] = now + RETRY_INTERVAL_SECONDS
    _save(state_directory, channel, state)

    delivered = False
    if sender is not None:
        try:
            delivered = bool(sender(event["text"], event["event_id"]))
        except Exception as error:  # noqa: BLE001 - channels fail independently
            print(f"notification channel {channel} failed: {type(error).__name__}")
    if delivered:
        event["status"] = "delivered"
        event["next_attempt_at"] = 0.0
        _save(state_directory, channel, state)
    return delivered


def _recovery_text() -> str:
    return "Paper Gateway recovered and is ready; the previously reported outage has cleared."


def _run_channel(
    state_directory: str | Path,
    channel: str,
    now: float,
    health: bool | None,
    eligible: bool,
    problem_text: str,
    sender: engine.Sender | None,
) -> int:
    state = _load(state_directory, channel)
    pending = state.get("pending")

    # Strict per-channel ordering: this channel's recovery cannot overtake its
    # own problem. Other channels continue independently in run_notifications.
    if pending is not None:
        if not _valid_pending(pending):
            state["pending"] = None
            _save(state_directory, channel, state)
            pending = None
        else:
            if not _attempt_pending(state_directory, channel, state, now, health, sender):
                if health is None and pending.get("kind") == "recovery":
                    return engine.EXIT_CLEAN
                return engine.EXIT_UNDELIVERED
            kind = pending["kind"]
            if kind == "problem":
                state["outage"] = {
                    "event_id": pending["event_id"],
                    "text": pending["text"],
                }
            else:
                state["outage"] = None
            state["pending"] = None
            _save(state_directory, channel, state)
            # One event per poll keeps problem-before-recovery ordering explicit.
            return engine.EXIT_PROBLEMS if health is False else engine.EXIT_CLEAN

    outage = state.get("outage")
    if health is False:
        if not isinstance(outage, dict) and eligible:
            pending = _event("problem", now, problem_text)
            state["pending"] = pending
            _save(state_directory, channel, state)  # WAL before sender
            if not _attempt_pending(state_directory, channel, state, now, health, sender):
                return engine.EXIT_UNDELIVERED
            state["outage"] = {
                "event_id": pending["event_id"],
                "text": pending["text"],
            }
            state["pending"] = None
            _save(state_directory, channel, state)
        return engine.EXIT_PROBLEMS

    if health is True and isinstance(outage, dict):
        pending = _event("recovery", now, _recovery_text())
        pending["source_event_id"] = outage.get("event_id", "")
        state["pending"] = pending
        _save(state_directory, channel, state)  # WAL before sender
        if not _attempt_pending(state_directory, channel, state, now, health, sender):
            return engine.EXIT_UNDELIVERED
        state["outage"] = None
        state["pending"] = None
        _save(state_directory, channel, state)

    return engine.EXIT_CLEAN


def run_notifications(
    state_directory: str,
    now: float,
    health: bool | None,
    eligible: bool,
    problem_text: str,
    senders: dict[str, engine.Sender],
) -> int:
    """Deliver one observation through independent configured channels.

    ``health`` is tri-state: ``True`` is the only value allowed to create a
    recovery event, ``False`` is unhealthy, and ``None`` is an unknown probe
    that preserves alert state. ``eligible`` only gates a new problem event;
    the supervisor supplies it after its sustained-failure gate.
    """

    if health not in {True, False, None}:
        raise ValueError("health must be True, False, or None")
    if not isinstance(problem_text, str):
        raise TypeError("problem_text must be a string")
    if not isinstance(senders, dict):
        raise TypeError("senders must be a mapping")
    if health is False and eligible and not senders:
        return engine.EXIT_UNDELIVERED

    results = [
        _run_channel(state_directory, name, now, health, eligible, problem_text, sender)
        for name, sender in sorted(senders.items())
    ]
    if engine.EXIT_UNDELIVERED in results:
        return engine.EXIT_UNDELIVERED
    if health is False and engine.EXIT_PROBLEMS in results:
        return engine.EXIT_PROBLEMS
    return engine.EXIT_CLEAN
