#!/usr/bin/env python3
"""OPS-104 checks for csb0, running on the shared OPS-107 engine.

The engine owns durability (write-ahead delivery, atomic state, confirm-before-
alert). This file owns only WHAT is checked and HOW it reads to a human.
"""

from __future__ import annotations

import json
import os
import re
import socket
import time
import urllib.error
import urllib.parse
import urllib.request

import engine
from engine import Problem

STATE_PATH = "/var/lib/ops-alerts/state.json"
TIMEOUT = 15
# The broker probe is a loopback read of an already-published retained value, so
# it either answers at once or the broker is not there. Kept well under the
# unit's TimeoutStartSec so a wedged broker cannot stall the whole cycle.
BROKER_TIMEOUT = 8

# Substituted by ops-alerts.nix at build time, so the built script holds literals
# and no runtime data reaches a request URL (CodeQL partial-SSRF, 2026-07-30).
TARGETS = json.loads(r"""@TARGETS_JSON@""")
PEERS = json.loads(r"""@PEERS_JSON@""")
SMARTHOME_LINKS = json.loads(r"""@SMARTHOME_LINKS_JSON@""")

# Only tailnet Home Assistant addresses may ever be requested. Anchored and
# narrow so the SSRF shape is unreachable rather than merely unlikely, and so a
# typo in the Nix target list fails loudly here instead of quietly sending a
# bearer token somewhere unintended.
ALLOWED_BASE = re.compile(r"^http://100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}:8123$")


def ha_get(base: str, token: str, path: str):
    if not ALLOWED_BASE.match(base):
        raise ValueError("target base URL is not an allowed tailnet HA address")
    if not path.startswith("/api/"):
        raise ValueError("path must stay under /api/")
    request = urllib.request.Request(
        urllib.parse.urljoin(base, path), headers={"Authorization": f"Bearer {token}"}
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:  # noqa: S310
        return json.loads(response.read().decode())


def check_home_assistant(target: dict) -> list[Problem]:
    name = target["name"]
    token = os.environ.get(target["tokenVar"], "")
    if not token:
        return [Problem(f"{name}:token", f"{name}: no API token in the environment")]

    # 1. Is Home Assistant answering at all? The check no in-HA automation can
    #    ever perform on itself.
    try:
        ha_get(target["url"], token, "/api/")
    except urllib.error.HTTPError as error:
        return [Problem(f"{name}:api", f"{name}: HA API returned HTTP {error.code}")]
    except Exception as error:  # noqa: BLE001 - any failure here means unreachable
        return [Problem(f"{name}:api", f"{name}: HA unreachable ({type(error).__name__})")]

    found: list[Problem] = []

    # 2. Did a config entry fail to load? 'unavailable' means the entry is not
    #    loaded. 'unknown' is a healthy but SLEEPING car and must NOT alert --
    #    tesla_fleet sets updated_once only after a successful vehicle_data fetch,
    #    so a parked car reports 'unknown' for hours.
    witness = target.get("witness")
    if witness:
        try:
            state = ha_get(target["url"], token, f"/api/states/{witness}").get("state")
            if state == "unavailable":
                found.append(
                    Problem(
                        f"{name}:entry",
                        f"{name}: Tesla integration not loaded ({witness} is unavailable). "
                        f"The self-heal automation should reload it within the hour.",
                    )
                )
        except Exception as error:  # noqa: BLE001
            found.append(
                Problem(f"{name}:entry", f"{name}: cannot read {witness} ({type(error).__name__})")
            )

    # 3. Is the Fleet API budget burning faster than planned?
    budget = target.get("budgetEntity")
    if budget:
        try:
            used = int(float(ha_get(target["url"], token, f"/api/states/{budget}").get("state")))
            limit = target.get("budgetLimit", 0)
            if used > limit:
                found.append(
                    Problem(
                        f"{name}:budget",
                        f"{name}: Tesla API budget at {used} billed polls this month "
                        f"(threshold {limit}). Check that built-in polling was not "
                        f"re-enabled and that no new vehicle joined the account.",
                    )
                )
        except Exception:  # noqa: BLE001 - a missing counter is not an outage
            pass

    return found


def check_peer(peer: dict) -> list[Problem]:
    """Is the peer host's poller still running? See heartbeat.nix for the design.

    A host cannot detect its own death, so csb0 and csb1 check each other. The
    heartbeat is the peer's state-file mtime, served as one integer over the
    tailnet.
    """
    name = peer["name"]
    try:
        with socket.create_connection((peer["address"], peer["port"]), timeout=TIMEOUT) as sock:
            raw = sock.recv(64).decode().strip()
        stamp = float(raw)
    except Exception as error:  # noqa: BLE001
        return [
            Problem(
                f"peer:{name}",
                f"{name}: poller heartbeat unreachable ({type(error).__name__}). "
                f"That host may be down, or its alert poller stopped -- so its own "
                f"alerts would be silent.",
            )
        ]

    if stamp <= 0:
        return [Problem(f"peer:{name}", f"{name}: poller has never recorded a run")]

    age = int(time.time() - stamp)
    if age > peer["maxAgeSeconds"]:
        return [
            Problem(
                f"peer:{name}",
                f"{name}: poller last ran {age // 60} min ago "
                f"(limit {peer['maxAgeSeconds'] // 60} min). Its alerts are not firing.",
            )
        ]
    return []


def read_retained(host: str, port: int, user: str, password: str, topic: str, timeout: int):
    """Return the retained payload on `topic`, or None if none is set.

    A retained message is delivered the instant we subscribe, so this is a
    bounded read, not a wait for the next publish. Returning None means the
    broker answered and has nothing retained there -- a different fact from the
    broker being unreachable, and the caller reports them differently.
    """
    import paho.mqtt.client as mqtt

    received: dict[str, bytes] = {}

    def on_connect(client, userdata, flags, reason_code, properties=None):
        client.subscribe(topic, qos=0)

    def on_message(client, userdata, message):
        received["payload"] = message.payload

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="ops-alerts-probe")
    client.username_pw_set(user, password)
    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(host, port, keepalive=30)
    deadline = time.time() + timeout
    try:
        while time.time() < deadline and "payload" not in received:
            client.loop(timeout=0.5)
    finally:
        try:
            client.disconnect()
        except Exception:  # noqa: BLE001 - teardown must not mask the result
            pass
    return received.get("payload")


def check_smarthome_link(link: dict) -> list[Problem]:
    """Is the smart-home command path from this host to hsb1 still carrying traffic?

    hsb1's Node-RED publishes a retained timestamp every 60s THROUGH this broker.
    That is the same hop every Telegram /zufahrt takes, so the heartbeat goes
    stale for the same reasons a real command would be dropped.

    Why this check exists: on 2026-07-29 hsb1's container lost DNS and could no
    longer re-resolve mosquitto.barta.cm to reconnect here. Every access-gate
    command was accepted, permission-checked, logged as success on this host, and
    published to a broker with no subscriber -- for two days, with every existing
    check green (OPS-113/OPS-115). A check that only proved 'Node-RED is up'
    would have stayed green throughout; this one would not.
    """
    name = link["name"]
    user = os.environ.get("MQTT_USER", "")
    password = os.environ.get("MQTT_PASS", "")
    if not user or not password:
        return [Problem(f"link:{name}", f"{name}: no broker credentials in the environment")]

    try:
        payload = read_retained(
            link["host"], link["port"], user, password, link["topic"], BROKER_TIMEOUT
        )
    except Exception as error:  # noqa: BLE001 - any failure here means we cannot tell
        return [
            Problem(
                f"link:{name}",
                f"{name}: cannot read the local MQTT broker ({type(error).__name__}). "
                f"Smart-home command delivery is unverifiable, not necessarily broken.",
            )
        ]

    if payload is None:
        return [
            Problem(
                f"link:{name}",
                f"{name}: nothing retained on {link['topic']}. Either hsb1 has never "
                f"published since the broker last lost its retained set, or its "
                f"heartbeat flow is gone. Access-gate commands from Telegram would "
                f"be silently dropped.",
            )
        ]

    try:
        stamp = float(payload.decode().strip())
    except (ValueError, UnicodeDecodeError):
        return [Problem(f"link:{name}", f"{name}: heartbeat on {link['topic']} is not a timestamp")]

    # Node-RED's inject emits epoch milliseconds; tolerate seconds too so a
    # future publisher change cannot silently read as 55 years stale.
    if stamp > 1e12:
        stamp /= 1000.0

    age = int(time.time() - stamp)
    if age > link["maxAgeSeconds"]:
        return [
            Problem(
                f"link:{name}",
                f"{name}: last heartbeat {age // 60} min ago (limit "
                f"{link['maxAgeSeconds'] // 60} min). hsb1 is no longer reaching this "
                f"broker, so Telegram commands to the access gate are being dropped "
                f"even though the bot still reports success.",
            )
        ]
    return []


def collect() -> list[Problem]:
    found: list[Problem] = []
    for target in TARGETS:
        found.extend(check_home_assistant(target))
    for peer in PEERS:
        found.extend(check_peer(peer))
    for link in SMARTHOME_LINKS:
        found.extend(check_smarthome_link(link))
    return found


def render(announced: list[str], cleared: list[str]) -> str:
    lines: list[str] = []
    if announced:
        lines += ["\U0001f534 Fleet problem:"] + [f"• {item}" for item in announced]
    if cleared:
        lines += ["✅ Cleared — no longer failing:"] + [f"• {item}" for item in cleared]
    return "\n".join(lines)


def main() -> int:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    chat = os.environ.get("TELEGRAM_CHAT_ID", "")
    # Shape-validated before reaching a URL: Telegram requires the token in the
    # path, so this is what stops a malformed value steering the request.
    if not re.match(r"^\d{5,20}:[A-Za-z0-9_-]{20,255}$", token) or not re.match(
        r"^-?\d{1,32}$", chat
    ):
        print("telegram credentials missing or malformed", flush=True)
        return engine.EXIT_UNDELIVERED
    return engine.run_cycle(
        STATE_PATH, time.time(), collect, render, engine.telegram_sender(token, chat)
    )


if __name__ == "__main__":
    raise SystemExit(main())
