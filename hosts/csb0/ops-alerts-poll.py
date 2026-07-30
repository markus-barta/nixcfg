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
# Fixed path written by the Nix module (environment.etc). Deliberately NOT taken
# from argv: a caller-supplied path is both an injection shape CodeQL rightly
# flags and pointless here, since there is exactly one config.
TARGETS_PATH = "/etc/ops-alerts/targets.json"
TIMEOUT = 15

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


def main():
    with open(TARGETS_PATH) as f:
        targets = json.load(f)

    current = {}
    for t in targets:
        current.update(check(t))

    try:
        previous = json.load(open(STATE_PATH))
    except Exception:  # noqa: BLE001 - first run, or unreadable state
        previous = {}

    new = {k: v for k, v in current.items() if k not in previous}
    cleared = [k for k in previous if k not in current]

    lines = []
    if new:
        lines += ["\U0001f534 Fleet problem:"] + [f"• {v}" for v in new.values()]
    if cleared:
        lines += ["✅ Recovered:"] + [f"• {previous[k]}" for k in cleared]

    if lines:
        telegram("\n".join(lines))
        for line in lines:
            print(line)
    else:
        print(f"ok — {len(current)} active problem(s), no change")

    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    with open(STATE_PATH, "w") as f:
        json.dump(current, f, indent=2)

    # Non-zero when something is wrong, so `systemctl --failed` and the
    # OPS-102-style journal both reflect it even if Telegram is down.
    return 1 if current else 0


if __name__ == "__main__":
    sys.exit(main())
