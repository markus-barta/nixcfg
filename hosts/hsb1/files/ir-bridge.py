#!/usr/bin/env python3
"""
IR → {Sony Bravia, Home Assistant} bridge.

Reads a FLIRC USB IR receiver (evdev) on hsb1 and drives two independent paths:

  1. FAST PATH (HA-independent): for keys with a real TV function, POST the Sony
     IRCC command straight to the Bravia over HTTP. Instant, and keeps working
     even when Home Assistant / MQTT is down — this is the resilience that
     motivated moving the bridge off the old Node-RED/Docker stack (NIX-186).

  2. SMART PATH: publish EVERY keypress to MQTT and advertise the remote to Home
     Assistant via MQTT Discovery as a device with per-button *device triggers*
     (zigbee2mqtt-remote style). HA then owns the "smart" behaviour — Hue Sync
     Box input switching (blue/yellow), pixdcon scene toggle (tv_radio), etc.

Design rules:
  * Publish-vs-IRCC are decoupled. A button publishes to MQTT regardless; it only
    sends IRCC if it has a real, correct Sony code. The colour keys
    (red/green/yellow/blue) and tv_radio are MQTT-only — no IRCC — which also
    kills the HTTP-500 spam the old bogus colour codes caused.
  * MQTT failures are NEVER fatal and never block the TV path.
  * Held keys auto-repeat on the TV path only (volume/nav/channel/seek); the
    MQTT action topic fires once per physical press (no trigger spam).

Button map (evdev code → name → Sony IRCC) is the single source of truth below.
The evdev codes were captured live from this exact FLIRC on hsb1 (see PPM NIX-194).

Environment variables (see hosts/hsb1/ir-bridge.nix):
    SONY_TV_IP            Sony TV IP (default 192.168.1.137)
    SONY_TV_PSK           Pre-Shared Key for TV auth (required)
    FLIRC_DEVICE          evdev path (default /dev/input/event0)
    MQTT_BROKER           MQTT host; empty string disables the smart path
    MQTT_PORT             default 1883
    MQTT_USER, MQTT_PASS  MQTT credentials (optional)
    MQTT_BASE_TOPIC       default home/hsb1/ir-bridge
    HA_DISCOVERY_PREFIX   default homeassistant
    DEVICE_ID             discovery device id (default flirc_hsb1)
    LOG_LEVEL             default INFO
    DEBOUNCE_MS           default 300
    REPEAT_DELAY_MS       default 350
    REPEAT_RATE_MS        default 120
    RETRY_COUNT           HTTP retries (default 3)
    RETRY_DELAY           seconds between HTTP retries (default 1.0)
"""

import json
import logging
import os
import signal
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, Optional

import requests

try:
    from evdev import InputDevice, categorize, ecodes
    EVDEV_AVAILABLE = True
except ImportError:  # pragma: no cover - simulation only
    EVDEV_AVAILABLE = False

try:
    import paho.mqtt.client as mqtt
    MQTT_AVAILABLE = True
except ImportError:  # pragma: no cover
    MQTT_AVAILABLE = False

VERSION = "1.1.0"

CONFIG = {
    "sony_tv_ip": os.getenv("SONY_TV_IP", "192.168.1.137"),
    "sony_tv_psk": os.getenv("SONY_TV_PSK", ""),
    "flirc_device": os.getenv("FLIRC_DEVICE", "/dev/input/event0"),
    "mqtt_broker": os.getenv("MQTT_BROKER", ""),
    "mqtt_port": int(os.getenv("MQTT_PORT", "1883")),
    "mqtt_user": os.getenv("MQTT_USER", ""),
    "mqtt_pass": os.getenv("MQTT_PASS", ""),
    "base_topic": os.getenv("MQTT_BASE_TOPIC", "home/hsb1/ir-bridge"),
    "discovery_prefix": os.getenv("HA_DISCOVERY_PREFIX", "homeassistant"),
    "device_id": os.getenv("DEVICE_ID", "flirc_hsb1"),
    "log_level": os.getenv("LOG_LEVEL", "INFO"),
    "debounce_ms": int(os.getenv("DEBOUNCE_MS", "300")),
    "repeat_delay_ms": int(os.getenv("REPEAT_DELAY_MS", "350")),
    "repeat_rate_ms": int(os.getenv("REPEAT_RATE_MS", "120")),
    "retry_count": int(os.getenv("RETRY_COUNT", "3")),
    "retry_delay": float(os.getenv("RETRY_DELAY", "1.0")),
    # Input-device reconnect backoff. The FLIRC can vanish at any time (USB
    # replug, hub power-cycle, boot race where the hub enumerates after us);
    # the bridge waits it out rather than dying or spinning on a dead handle.
    "reopen_delay_min": float(os.getenv("REOPEN_DELAY_MIN", "1.0")),
    "reopen_delay_max": float(os.getenv("REOPEN_DELAY_MAX", "30.0")),
}

# ── Button map ──────────────────────────────────────────────────────────────
# evdev code -> (friendly_name, sony_ircc_or_None)
#   ircc=None  → MQTT-only: the bridge publishes the press but sends NO TV
#                command (smart keys handled by HA; unmapped extras).
# IRCC base64 codes are reused verbatim from the verified hsb1 mapping (NIX-186).
# NOTE: this FLIRC maps the physical Vol+/Vol- to the *opposite* evdev keycodes,
# so the IRCC is intentionally swapped (114→Vol-UP, 115→Vol-DOWN).
BUTTONS: Dict[int, tuple] = {
    # Numbers
    2:  ("num1", "AAAAAQAAAAEAAAAAAw=="),
    3:  ("num2", "AAAAAQAAAAEAAAABAw=="),
    4:  ("num3", "AAAAAQAAAAEAAAACAw=="),
    5:  ("num4", "AAAAAQAAAAEAAAADAw=="),
    6:  ("num5", "AAAAAQAAAAEAAAAEAw=="),
    7:  ("num6", "AAAAAQAAAAEAAAAFAw=="),
    8:  ("num7", "AAAAAQAAAAEAAAAGAw=="),
    9:  ("num8", "AAAAAQAAAAEAAAAHAw=="),
    10: ("num9", "AAAAAQAAAAEAAAAIAw=="),
    11: ("num0", "AAAAAQAAAAEAAAAJAw=="),
    # Navigation
    103: ("up", "AAAAAQAAAAEAAAB0Aw=="),
    108: ("down", "AAAAAQAAAAEAAAB1Aw=="),
    105: ("left", "AAAAAQAAAAEAAAA0Aw=="),
    106: ("right", "AAAAAQAAAAEAAAAzAw=="),
    96:  ("enter", "AAAAAQAAAAEAAABlAw=="),
    28:  ("enter", "AAAAAQAAAAEAAABlAw=="),  # KEY_ENTER alternate
    1:   ("back", "AAAAAQAAAAEAAAAAw=="),
    102: ("home", "AAAAAQAAAAEAAABgAw=="),
    # Volume (swapped — see note above)
    113: ("mute", "AAAAAQAAAAEAAAAUAw=="),
    114: ("volumeup", "AAAAAQAAAAEAAAATAw=="),
    115: ("volumedown", "AAAAAQAAAAEAAAASAw=="),
    # Transport
    164: ("play", "AAAAAQAAAAEAAAANAw=="),
    166: ("stop", "AAAAAQAAAAEAAAAOAw=="),
    168: ("rewind", "AAAAAQAAAAEAAAA4Aw=="),
    208: ("fastforward", "AAAAAQAAAAEAAAA5Aw=="),
    163: ("next", "AAAAAQAAAAEAAAAXAw=="),
    165: ("previous", "AAAAAQAAAAEAAAAYAw=="),
    # System / apps
    44: ("power", "AAAAAQAAAAEAAAAVAw=="),
    23: ("input", "AAAAAQAAAAEAAAAlAw=="),
    30: ("actionmenu", "AAAAAQAAAAEAAAA6Aw=="),
    49: ("netflix", "AAAAAQAAAAEAAAAMAw=="),
    25: ("youtube", "AAAAAQAAAAEAAABDAw=="),
    # Channel / input
    20: ("channelup", "AAAAAQAAAAEAAAA+Aw=="),
    47: ("channeldown", "AAAAAQAAAAEAAAA9Aw=="),
    22: ("hdmi2", "AAAAAQAAAAEAAABBAw=="),
    # ── MQTT-only smart keys (NO IRCC) ──────────────────────────────────────
    48: ("blue", None),       # → HA: Hue Sync Box PS5 input
    21: ("yellow", None),     # → HA: Hue Sync Box PC input
    17: ("tv_radio", None),   # → HA: pixoo-189 scene toggle (was mis-sent as HDMI1)
    19: ("red", None),        # reserved for HA
    34: ("green", None),      # reserved for HA
    # ── MQTT-only extras (physical labels TBD; no IRCC yet) ─────────────────
    119: ("pause", None),
    104: ("page_up", None),
    109: ("page_down", None),
}

# Keys that auto-repeat (TV path only) while physically held.
REPEATABLE_KEYS = {114, 115, 103, 108, 105, 106, 20, 47, 168, 208}


def _now_ms() -> float:
    return time.time() * 1000.0


def _iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


class IRBridge:
    """IR receiver → Sony Bravia (HTTP/IRCC) + Home Assistant (MQTT)."""

    def __init__(self) -> None:
        self.log = self._setup_logging()
        self.mqtt: Optional[Any] = None
        self.mqtt_connected = False
        self.input_device: Optional[Any] = None
        # Availability tracks the INPUT DEVICE, not the broker: a bridge with a
        # live MQTT session but no FLIRC is deaf, and HA must not see it as up.
        self.input_ok = False
        self.running = False
        self.last_scancode: Optional[str] = None
        self.last_key_time: Dict[int, float] = {}
        self.key_down_time: Dict[int, float] = {}
        self.stats = {
            "started_at": _iso_now(),
            "keys_pressed": 0,
            "ircc_sent": 0,
            "ircc_errors": 0,
            "mqtt_published": 0,
            "last_key": None,
        }
        if not CONFIG["sony_tv_psk"]:
            self.log.error("SONY_TV_PSK not set — refusing to start")
            sys.exit(1)

    # ── infra ────────────────────────────────────────────────────────────
    def _setup_logging(self) -> logging.Logger:
        log = logging.getLogger("ir-bridge")
        log.setLevel(getattr(logging, CONFIG["log_level"].upper(), logging.INFO))
        h = logging.StreamHandler(sys.stdout)
        h.setFormatter(logging.Formatter("%(asctime)s - %(name)s - %(levelname)s - %(message)s"))
        log.addHandler(h)
        return log

    @property
    def t_avail(self) -> str:
        return f"{CONFIG['base_topic']}/availability"

    @property
    def t_action(self) -> str:
        return f"{CONFIG['base_topic']}/action"

    @property
    def t_last_key(self) -> str:
        return f"{CONFIG['base_topic']}/last_key"

    @property
    def t_event(self) -> str:
        return f"{CONFIG['base_topic']}/event"

    # ── MQTT ─────────────────────────────────────────────────────────────
    def _setup_mqtt(self) -> None:
        if not CONFIG["mqtt_broker"]:
            self.log.info("MQTT disabled (no broker configured) — TV path only")
            return
        if not MQTT_AVAILABLE:
            self.log.warning("paho-mqtt not importable — smart path unavailable")
            return
        client_id = f"ir-bridge-{CONFIG['device_id']}"
        # paho-mqtt 2.x requires an explicit callback API version; fall back to
        # the 1.x constructor when running against the older library.
        try:
            client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=client_id)
        except (AttributeError, TypeError):
            client = mqtt.Client(client_id=client_id)
        if CONFIG["mqtt_user"]:
            client.username_pw_set(CONFIG["mqtt_user"], CONFIG["mqtt_pass"])
        client.will_set(self.t_avail, "offline", qos=1, retain=True)
        client.on_connect = self._on_connect
        client.on_disconnect = self._on_disconnect
        # Resilient connect: connect_async + loop_start keeps paho retrying if the
        # broker is down at startup (e.g. mosquitto mid-restart during a nixos
        # switch — Errno 111) and auto-reconnects on any later drop. A blocking
        # connect() here would give up once and leave the smart path dead until a
        # manual restart. The TV path never depends on MQTT either way.
        client.reconnect_delay_set(min_delay=1, max_delay=30)
        try:
            client.connect_async(CONFIG["mqtt_broker"], CONFIG["mqtt_port"], keepalive=60)
            client.loop_start()
            self.mqtt = client
            self.log.info("MQTT loop started → %s:%s (async, auto-reconnect)", CONFIG["mqtt_broker"], CONFIG["mqtt_port"])
        except Exception as exc:  # noqa: BLE001 - never fatal
            self.log.error("MQTT setup failed (TV path still works): %s", exc)
            self.mqtt = None

    def _on_connect(self, client, userdata, flags, rc, properties=None) -> None:
        ok = (not rc.is_failure) if hasattr(rc, "is_failure") else (rc == 0)
        if not ok:
            self.log.error("MQTT connect refused: %s", rc)
            return
        self.mqtt_connected = True
        self.log.info("MQTT connected")
        # Reflect real input state on (re)connect — "online" only if we can
        # actually hear the remote, otherwise HA shows a device that is deaf.
        state = "online" if self.input_ok else "offline"
        client.publish(self.t_avail, state, qos=1, retain=True)
        # Use the callback's client (on_connect can fire on the network thread
        # before `self.mqtt = client` is assigned in _setup_mqtt).
        self._publish_discovery(client)

    def _on_disconnect(self, client, userdata, *args) -> None:
        self.mqtt_connected = False
        self.log.warning("MQTT disconnected (will auto-reconnect)")

    def _publish_discovery(self, client) -> None:
        """Advertise the remote to HA: per-button device triggers + last_key sensor."""
        dev = {
            "identifiers": [CONFIG["device_id"]],
            "name": "FLIRC IR Remote (hsb1)",
            "manufacturer": "flirc.tv",
            "model": "FLIRC USB → Sony Bravia bridge",
            "sw_version": VERSION,
        }
        prefix = CONFIG["discovery_prefix"]
        node = CONFIG["device_id"]
        # De-dupe friendly names (code 28/96 both map to "enter").
        names = sorted({name for name, _ in BUTTONS.values()})
        for name in names:
            cfg = {
                "automation_type": "trigger",
                "type": "button_short_press",
                "subtype": name,
                "topic": self.t_action,
                "payload": name,
                "device": dev,
            }
            topic = f"{prefix}/device_automation/{node}/{name}/config"
            client.publish(topic, json.dumps(cfg), qos=1, retain=True)
        # Visibility-only sensor reflecting the last key (retained).
        sensor = {
            "name": "Last Key",
            "unique_id": f"{node}_last_key",
            "object_id": f"{node}_last_key",
            "state_topic": self.t_last_key,
            "icon": "mdi:remote",
            "availability_topic": self.t_avail,
            "device": dev,
        }
        client.publish(
            f"{prefix}/sensor/{node}/last_key/config", json.dumps(sensor), qos=1, retain=True
        )
        self.log.info("Published HA discovery for %d buttons", len(names))

    def _publish_press(self, name: str, code: int, scancode: Optional[str], ircc_sent: bool) -> None:
        if not self.mqtt:
            return
        try:
            # Action topic drives HA device triggers (one message per press).
            self.mqtt.publish(self.t_action, name, qos=1, retain=False)
            # Retained last_key for the visibility sensor.
            self.mqtt.publish(self.t_last_key, name, qos=1, retain=True)
            # Rich event for debugging / dashboards.
            self.mqtt.publish(
                self.t_event,
                json.dumps({
                    "ts": _iso_now(),
                    "key": name,
                    "code": code,
                    "scancode": scancode,
                    "ircc_sent": ircc_sent,
                }),
                qos=0,
                retain=False,
            )
            self.stats["mqtt_published"] += 1
        except Exception as exc:  # noqa: BLE001 - never fatal
            self.log.error("MQTT publish failed: %s", exc)

    # ── TV / IRCC ────────────────────────────────────────────────────────
    def _send_ircc(self, ircc: str, name: str) -> bool:
        url = f"http://{CONFIG['sony_tv_ip']}/sony/IRCC"
        headers = {
            "Content-Type": "text/xml; charset=UTF-8",
            "SOAPACTION": '"urn:schemas-sony-com:service:IRCC:1#X_SendIRCC"',
            "X-Auth-PSK": CONFIG["sony_tv_psk"],
        }
        body = (
            '<?xml version="1.0"?>'
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
            ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
            '<u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1">'
            f"<IRCCCode>{ircc}</IRCCCode></u:X_SendIRCC></s:Body></s:Envelope>"
        )
        for attempt in range(CONFIG["retry_count"]):
            try:
                r = requests.post(url, headers=headers, data=body, timeout=5)
                if r.status_code == 200:
                    return True
                self.log.warning("IRCC %s failed: HTTP %s", name, r.status_code)
            except requests.exceptions.RequestException as exc:
                self.log.error("IRCC %s request error (try %d): %s", name, attempt + 1, exc)
            if attempt < CONFIG["retry_count"] - 1:
                time.sleep(CONFIG["retry_delay"])
        return False

    # ── key handling ─────────────────────────────────────────────────────
    def _handle_key(self, code: int, held: bool) -> None:
        now = _now_ms()
        if held:
            # TV-path auto-repeat: keyboard-style delay then rate.
            if (now - self.key_down_time.get(code, 0)) < CONFIG["repeat_delay_ms"]:
                return
            if (now - self.last_key_time.get(code, 0)) < CONFIG["repeat_rate_ms"]:
                return
        else:
            if (now - self.last_key_time.get(code, 0)) < CONFIG["debounce_ms"]:
                return
            self.key_down_time[code] = now
        self.last_key_time[code] = now

        if code not in BUTTONS:
            self.log.debug("Unknown key code %s (scancode %s)", code, self.last_scancode)
            return
        name, ircc = BUTTONS[code]

        # FAST PATH: send IRCC for mapped TV keys (incl. auto-repeat).
        ircc_sent = False
        if ircc is not None:
            ircc_sent = self._send_ircc(ircc, name)
            self.stats["ircc_sent" if ircc_sent else "ircc_errors"] += 1

        # SMART PATH: publish once per physical press only (no repeat spam).
        if not held:
            self.stats["keys_pressed"] += 1
            self.stats["last_key"] = name
            self.log.info("Key %s (code %s)%s", name, code, " [no-tv]" if ircc is None else "")
            self._publish_press(name, code, self.last_scancode, ircc_sent)

    # ── input loop ───────────────────────────────────────────────────────
    def _set_availability(self, state: str) -> None:
        """Publish input-device health to HA. Never fatal."""
        if not self.mqtt:
            return
        try:
            self.mqtt.publish(self.t_avail, state, qos=1, retain=True)
        except Exception:  # noqa: BLE001 - availability must never kill the bridge
            pass

    def _open_input(self) -> bool:
        if not EVDEV_AVAILABLE:
            self.log.error("evdev not available")
            return False
        try:
            self.input_device = InputDevice(CONFIG["flirc_device"])
        except Exception as exc:  # noqa: BLE001
            # Expected while the FLIRC is unplugged / its hub is still settling.
            self.input_device = None
            self.log.debug("Cannot open %s: %s", CONFIG["flirc_device"], exc)
            return False
        self.log.info("Opened input %s (%s)", CONFIG["flirc_device"], self.input_device.name)
        self.input_ok = True
        self._set_availability("online")
        return True

    def _close_input(self) -> None:
        """Drop the (possibly stale) handle so the next open re-resolves by-id."""
        if self.input_device is not None:
            try:
                self.input_device.close()
            except Exception:  # noqa: BLE001 - already gone is fine
                pass
        self.input_device = None
        if self.input_ok:
            self.input_ok = False
            self._set_availability("offline")

    def _read_loop(self) -> None:
        for event in self.input_device.read_loop():
            if not self.running:
                break
            if event.type == ecodes.EV_MSC and event.code == ecodes.MSC_SCAN:
                # HID usage/scancode for the press that follows (e.g. 0x7001a).
                self.last_scancode = f"0x{event.value:x}"
            elif event.type == ecodes.EV_KEY:
                ke = categorize(event)
                if ke.keystate == ke.key_down:
                    self._handle_key(ke.scancode, held=False)
                elif ke.keystate == ke.key_hold and ke.scancode in REPEATABLE_KEYS:
                    self._handle_key(ke.scancode, held=True)

    def start(self) -> None:
        self.log.info("IR bridge v%s starting", VERSION)
        signal.signal(signal.SIGTERM, self._signal)
        signal.signal(signal.SIGINT, self._signal)
        self._setup_mqtt()
        self.running = True
        self.log.info("Bridge ready")
        # Supervise the input device for the whole lifetime of the process. The
        # device is re-OPENED (not just re-read) after any loss: on USB replug
        # udev rebuilds the by-id symlink to a NEW event node, so the old fd is
        # dead forever and reusing it spins on ENODEV. Startup with no FLIRC is
        # not fatal either — we wait for it, which covers a boot that races the
        # USB hub's enumeration.
        delay = CONFIG["reopen_delay_min"]
        while self.running:
            if self.input_device is None:
                if not self._open_input():
                    if not self.running:
                        break
                    self.log.warning(
                        "FLIRC %s unavailable — retrying in %.0fs",
                        CONFIG["flirc_device"],
                        delay,
                    )
                    time.sleep(delay)
                    delay = min(delay * 2, CONFIG["reopen_delay_max"])
                    continue
                delay = CONFIG["reopen_delay_min"]  # reacquired → reset backoff
            try:
                self._read_loop()
            except OSError as exc:  # ENODEV etc. — device yanked mid-read
                self.log.warning("FLIRC lost (%s) — will reopen", exc)
                self._close_input()
            except Exception as exc:  # noqa: BLE001
                self.log.error("Input loop error: %s", exc)
                self._close_input()
                if self.running:
                    time.sleep(delay)

    def _signal(self, signum, frame) -> None:
        self.log.info("Signal %s — shutting down", signum)
        self.stop()

    def stop(self) -> None:
        self.running = False
        if self.mqtt:
            try:
                self.mqtt.publish(self.t_avail, "offline", qos=1, retain=True)
                self.mqtt.loop_stop()
                self.mqtt.disconnect()
            except Exception:  # noqa: BLE001
                pass
        self.log.info("Stopped (stats: %s)", self.stats)


def main() -> None:
    bridge = IRBridge()
    try:
        bridge.start()
    except KeyboardInterrupt:
        bridge.stop()


if __name__ == "__main__":
    main()
