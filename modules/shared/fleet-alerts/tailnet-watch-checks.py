#!/usr/bin/env python3
"""Per-host tailnet witness — OPS-181 (csb1) / OPS-185 (hsb1).

On 2026-08-21 headscale (0.25.1, csb0) replaced the fleet's DERP map with an
EMPTY one after a failed scheduled refresh. Every node lost its relay, cold
tailnet connections timed out, and nothing paged for ~57 minutes: the existing
pollers watch services, not the mesh they ride on.

This is a tiny OPS-107 unit with one job: read THIS host's own view of the
tailnet and page when it is persistently broken. Deliberately separate from
hausv-alerts and peer-watch (both mature and test-pinned). One shared check
file; each host's tailnet-watch.nix substitutes HOSTNAME, TAILSCALE_BIN and the
env file carrying its WATCHTOWER_NOTIFICATION_URL.

What it reads (each command bounded to TIMEOUT seconds):
  * `tailscale status --json` — must run, parse, and report BackendState=Running;
    every entry in `.Health` (tailscaled's own list of detected problems, e.g.
    "Tailscale could not connect to any relay server") is a problem of its own,
    keyed by a digest of the message so ordering changes do not re-page.
  * `tailscale debug derp-map` — zero regions is exactly the 2026-08-21 state.

The engine confirms a problem on two consecutive runs before paging, so with
the 10-minute timer a real outage pages ~10–20 min after onset and the
transient health lines tailscaled emits while reconnecting never page.

Scope: this host's view only. `.Health` is per-node; a witness, not fleet
truth. csb1 shares the netcup failure domain with headscale (catches the
post-outage poisoned-map state); hsb1 sits at home on a different provider and
can page while netcup is dark. Two witnesses, two failure domains.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import time

import engine
from engine import Problem

STATE_PATH = "/var/lib/tailnet-watch/state.json"
NOTIFICATION_ENV = "@NOTIFICATION_ENV@"
TAILSCALE = "@TAILSCALE_BIN@"
HOSTNAME = "@HOSTNAME@"
TIMEOUT = 15

# Exact Health messages that are intentional on this host and must not page.
# Baseline on 2026-08-21 was empty on csb1 and hsb1; add an entry ONLY with a comment saying why
# and a test pinning it (tests/test_tailnet_watch_checks.py).
SUPPRESSED_HEALTH: frozenset[str] = frozenset()


def run_json(args: list[str]) -> dict:
    """Run a tailscale subcommand and parse its JSON. Raises on any failure."""
    completed = subprocess.run(  # noqa: S603 -- literal argv, substituted at build
        [TAILSCALE, *args],
        capture_output=True,
        text=True,
        timeout=TIMEOUT,
        check=True,
    )
    parsed = json.loads(completed.stdout)
    if not isinstance(parsed, dict):
        raise ValueError("unexpected JSON shape")
    return parsed


def health_key(message: str) -> str:
    return "tailnet:health:" + hashlib.sha256(message.encode()).hexdigest()[:12]


def check_status() -> list[Problem]:
    try:
        status = run_json(["status", "--json"])
    except Exception as error:  # noqa: BLE001
        return [
            Problem(
                "tailnet:status",
                f"{HOSTNAME}: `tailscale status` unreadable ({type(error).__name__}). "
                f"tailscaled may be down or wedged; this host's tailnet view is unknown.",
            )
        ]
    found: list[Problem] = []
    backend = status.get("BackendState")
    if backend != "Running":
        found.append(
            Problem(
                "tailnet:backend",
                f"{HOSTNAME}: tailscaled BackendState is {backend!r}, not Running.",
            )
        )
    for message in status.get("Health") or []:
        if not isinstance(message, str) or message in SUPPRESSED_HEALTH:
            continue
        found.append(Problem(health_key(message), f"{HOSTNAME} tailscale health: {message}"))
    return found


def check_derp_map() -> list[Problem]:
    try:
        derp = run_json(["debug", "derp-map"])
    except Exception as error:  # noqa: BLE001
        return [
            Problem(
                "tailnet:derpmap",
                f"{HOSTNAME}: `tailscale debug derp-map` unreadable ({type(error).__name__}).",
            )
        ]
    if not (derp.get("Regions") or {}):
        return [
            Problem(
                "tailnet:derpmap",
                f"{HOSTNAME}: DERP map is EMPTY — headscale is serving no relay servers "
                "(2026-08-21 failure mode). Check `docker logs headscale` on csb0 for "
                "'Could not load DERP map'; `docker restart headscale` refetches it.",
            )
        ]
    return []


def collect() -> list[Problem]:
    return check_status() + check_derp_map()


def render(announced: list[str], cleared: list[str]) -> str:
    lines: list[str] = []
    if announced:
        lines += [f"\U0001f534 Tailnet ({HOSTNAME} view):"] + [f"• {item}" for item in announced]
    if cleared:
        lines += ["✅ Cleared — no longer failing:"] + [f"• {item}" for item in cleared]
    return "\n".join(lines)


def main() -> int:
    target = engine.env_file_value(NOTIFICATION_ENV, "WATCHTOWER_NOTIFICATION_URL")
    if not target:
        print("notification target missing")
        return engine.EXIT_UNDELIVERED
    try:
        sender = engine.shoutrrr_telegram_sender(target)
    except ValueError as error:
        print(f"notification target unusable: {error}")
        return engine.EXIT_UNDELIVERED
    return engine.run_cycle(STATE_PATH, time.time(), collect, render, sender)


if __name__ == "__main__":
    raise SystemExit(main())
