#!/usr/bin/env python3
"""Read-only public health witness for the new Hausvogt — OPS-675.

Only a fixed GET /healthz is sent to the application. The shared fleet engine
owns two-run confirmation, durable Telegram delivery and one recovery per alarm.
Response bodies and exception messages never enter state, alerts or the journal.
"""

from __future__ import annotations

import json
import ssl
import time
import urllib.request

import engine
from engine import Problem

STATE_PATH = "/var/lib/hausvogt-health-watch/state.json"
NOTIFICATION_ENV = "@NOTIFICATION_ENV@"
HEALTH_URL = "https://hausv.org/healthz"
PROBE_TIMEOUT = 10
MAX_HEALTH_BYTES = 512
PROBLEM_KEY = "hausvogt:public-health"


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def collect() -> list[Problem]:
    try:
        request = urllib.request.Request(
            HEALTH_URL,
            headers={
                "Accept": "application/json",
                "User-Agent": "hausvogt-health-watch/1 (OPS-675)",
            },
            method="GET",
        )
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            NoRedirectHandler(),
            urllib.request.HTTPSHandler(context=ssl.create_default_context()),
        )
        with opener.open(request, timeout=PROBE_TIMEOUT) as response:
            if response.status != 200:
                raise ValueError("unexpected health status")
            body = response.read(MAX_HEALTH_BYTES + 1)
        if len(body) > MAX_HEALTH_BYTES or json.loads(body) != {"status": "ok"}:
            raise ValueError("unexpected health marker")
        return []
    except Exception:
        # A timeout, TLS failure, redirect or invalid body is the same signal:
        # switching failure modes must not reset the two-run confirmation.
        return [Problem(
            PROBLEM_KEY,
            'hausv.org: public /healthz must return HTTP 200 with {"status":"ok"}. '
            "Check public ingress and the Hausvogt service on csb1 (OPS-675).",
        )]


def render(announced: list[str], cleared: list[str]) -> str:
    lines: list[str] = []
    if announced:
        lines += ["🔴 Hausvogt health watch (csb1):"] + [f"• {item}" for item in announced]
    if cleared:
        lines += [
            "🟢 Hausvogt health watch (csb1) recovered:",
            '• hausv.org: public /healthz returns HTTP 200 with {"status":"ok"} again.',
        ]
    return "\n".join(lines)


def run() -> int:
    target = engine.env_file_value(
        NOTIFICATION_ENV, "WATCHTOWER_NOTIFICATION_URL", require_canonical_path=True
    )
    try:
        sender = engine.shoutrrr_telegram_sender(target)
    except ValueError:
        print("hausvogt-health-watch: notification target missing or unusable")
        return engine.EXIT_UNDELIVERED
    return engine.run_cycle(STATE_PATH, time.time(), collect, render, sender)


def main() -> int:
    try:
        return run()
    except Exception as error:
        # Delivery/state failures must fail the unit. Exception text can carry
        # credentials; log only the type, never a traceback or response body.
        print(f"hausvogt-health-watch: watch crashed ({type(error).__name__})")
        return engine.EXIT_UNDELIVERED


if __name__ == "__main__":
    raise SystemExit(main())
