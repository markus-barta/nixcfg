#!/usr/bin/env python3
"""Fleet alert poller (OPS-104). See ops-alerts.nix for why this exists.

Reads every Home Assistant instance over its REST API and reports problems to
Telegram. Announces transitions only — a problem when it starts, a recovery when
it clears — because a message every 15 minutes for something you already know
about is a message you learn to ignore.

Credentials arrive as environment variables from an agenix secret via systemd's
EnvironmentFile: HA_TOKEN_<HOST>, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID. They are
never logged, never passed as arguments, and never written to the state file.
"""

import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

STATE_PATH = "/var/lib/ops-alerts/state.json"
TIMEOUT = 15

# A problem must be seen on this many CONSECUTIVE runs before it is announced.
# 2026-07-30: the csb0 switch restarted tailscaled, so one run saw all three
# instances "unreachable" and fired a false alarm, followed by a "recovered"
# message 15 minutes later. Nothing was ever wrong with the houses. Requiring
# confirmation costs one interval of delay on a real outage (15 min, against the
# four DAYS this poller exists to prevent) and removes the whole class of blip:
# a tailnet restart, a brief WAN drop, an HA reload.
CONFIRM_RUNS = 2

# Substituted by ops-alerts.nix at build time, so the target list is a literal in
# the built script rather than data read at runtime. Two reasons: the config is
# genuinely declarative (changing a target means a rebuild, which is correct), and
# it removes the taint source behind CodeQL's partial-SSRF finding instead of
# arguing about whether a root-owned file counts as untrusted.
TARGETS = json.loads(r"""@TARGETS_JSON@""")

# The poller may only ever talk to Home Assistant on the tailnet. Anchored, and
# narrow on purpose: it makes the SSRF shape unreachable rather than merely
# unlikely, and it means a typo in the Nix target list fails loudly here instead
# of quietly sending a bearer token somewhere unintended.
ALLOWED_BASE = re.compile(r"^http://100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}:8123$")
# Telegram bot tokens are "<numeric id>:<secret>".
TELEGRAM_TOKEN_RE = re.compile(r"^\d{5,20}:[A-Za-z0-9_-]{20,255}$")
TELEGRAM_CHAT_RE = re.compile(r"^-?\d{1,32}$")


def ha_get(base, token, path):
    if not ALLOWED_BASE.match(base):
        raise ValueError("target base URL is not an allowed tailnet HA address")
    if not path.startswith("/api/"):
        raise ValueError("path must stay under /api/")
    req = urllib.request.Request(
        urllib.parse.urljoin(base, path), headers={"Authorization": f"Bearer {token}"}
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:  # noqa: S310 - scheme fixed by ALLOWED_BASE
        return json.loads(r.read().decode())


def check(target):
    """Return a dict of problem_key -> human message for one instance."""
    name = target["name"]
    token = os.environ.get(target["tokenVar"], "")
    problems = {}

    if not token:
        return {f"{name}:token": f"{name}: no API token in the environment"}

    # 1. Is Home Assistant answering at all? This is the check that no in-HA
    #    automation can ever perform on itself.
    try:
        ha_get(target["url"], token, "/api/")
    except urllib.error.HTTPError as e:
        return {f"{name}:api": f"{name}: HA API returned HTTP {e.code}"}
    except Exception as e:  # noqa: BLE001 - any failure here means "unreachable"
        return {f"{name}:api": f"{name}: HA unreachable ({type(e).__name__})"}

    # 2. Did a config entry fail to load? 'unavailable' means the entry is not
    #    loaded. 'unknown' is a healthy-but-sleeping car and must NOT alert.
    witness = target.get("witness")
    if witness:
        try:
            state = ha_get(target["url"], token, f"/api/states/{witness}").get("state")
            if state == "unavailable":
                problems[f"{name}:entry"] = (
                    f"{name}: Tesla integration not loaded ({witness} is unavailable). "
                    f"The self-heal automation should reload it within the hour."
                )
        except Exception as e:  # noqa: BLE001
            problems[f"{name}:entry"] = f"{name}: cannot read {witness} ({type(e).__name__})"

    # 3. Is the Fleet API budget being burned faster than planned?
    budget = target.get("budgetEntity")
    if budget:
        try:
            raw = ha_get(target["url"], token, f"/api/states/{budget}").get("state")
            used = int(float(raw))
            if used > target.get("budgetLimit", 0):
                problems[f"{name}:budget"] = (
                    f"{name}: Tesla API budget at {used} billed polls this month "
                    f"(threshold {target['budgetLimit']}). Check that built-in polling "
                    f"was not re-enabled and that no new vehicle joined the account."
                )
        except Exception:  # noqa: BLE001 - a missing counter is not an outage
            pass

    return problems


def telegram(text):
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    chat = os.environ.get("TELEGRAM_CHAT_ID", "")
    # Validate shape before it reaches a URL. Telegram requires the token in the
    # path, so this is what keeps a malformed or injected value from steering the
    # request somewhere else. Never print either value.
    if not TELEGRAM_TOKEN_RE.match(token) or not TELEGRAM_CHAT_RE.match(chat):
        print("telegram credentials missing or malformed; message not sent", file=sys.stderr)
        return False
    data = urllib.parse.urlencode(
        {"chat_id": chat, "text": text, "disable_web_page_preview": "true"}
    ).encode()
    url = urllib.parse.urlunsplit(
        ("https", "api.telegram.org", f"/bot{token}/sendMessage", "", "")
    )
    req = urllib.request.Request(url, data=data)
    try:
        with urllib.request.urlopen(  # noqa: S310 - host and scheme are literals above
            req, timeout=TIMEOUT, context=ssl.create_default_context()
        ):
            return True
    except Exception as e:  # noqa: BLE001
        print(f"telegram send failed: {type(e).__name__}", file=sys.stderr)
        return False


def load_previous():
    """Previous state, tolerating the pre-CONFIRM_RUNS format ({key: message})."""
    try:
        with open(STATE_PATH) as f:
            raw = json.load(f)
    except Exception:  # noqa: BLE001 - first run, or unreadable state
        return {}
    out = {}
    for k, v in raw.items():
        if isinstance(v, str):
            out[k] = {"msg": v, "count": CONFIRM_RUNS, "alerted": True}
        elif isinstance(v, dict):
            out[k] = v
    return out


def main():
    current = {}
    for t in TARGETS:
        current.update(check(t))

    previous = load_previous()

    state = {}
    to_alert = []
    for key, msg in current.items():
        prev = previous.get(key, {})
        count = int(prev.get("count", 0)) + 1
        alerted = bool(prev.get("alerted", False))
        if count >= CONFIRM_RUNS and not alerted:
            to_alert.append(msg)
            alerted = True
        state[key] = {"msg": msg, "count": count, "alerted": alerted}

    # Only announce clearing for problems that were actually announced — otherwise
    # a single blip produces a "cleared" message for something never reported.
    cleared = [
        prev["msg"]
        for key, prev in previous.items()
        if key not in current and prev.get("alerted")
    ]

    lines = []
    if to_alert:
        lines += ["\U0001f534 Fleet problem:"] + [f"• {v}" for v in to_alert]
    if cleared:
        lines += ["✅ Cleared — no longer failing:"] + [f"• {v}" for v in cleared]

    if lines:
        telegram("\n".join(lines))
        for line in lines:
            print(line)
    else:
        pend = sum(1 for v in state.values() if not v["alerted"])
        print(f"ok — {len(current)} active problem(s), {pend} awaiting confirmation, nothing to announce")

    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    with open(STATE_PATH, "w") as f:
        json.dump(state, f, indent=2)

    # Non-zero when something is wrong, so `systemctl --failed` and the
    # OPS-102-style journal both reflect it even if Telegram is down.
    return 1 if current else 0


if __name__ == "__main__":
    sys.exit(main())
