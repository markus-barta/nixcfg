#!/usr/bin/env python3
"""OPS-496: Aqara light/sound API, ported from the verified local prototype.

GET /get?hub=plug, /presets, /config, /signal?hub=round and / for the UI.
Acting endpoints /set, /tone, /stop, /preset, /apply, /settings, /seen and
/signal-test require X-Nightlight: 1 and accept GET or POST.
GET actions are deprecated compatibility for Home Assistant; the UI uses POST.
KI-18FB is plug; WZ-594F is round. Default nacht: 5C0701 at 44%.
CLI: set <hub> <RRGGBB> <brightness>, get <hub>, tone <hub> <id> [vol], stop <hub>.
Tone volume defaults to 15% and clamps to 0–40% in both HTTP and CLI use.
The handshake token stays in memory; no library payloads or exceptions are logged.
"""

import base64
import fcntl
import hashlib
import ipaddress
import json
import logging
import os
import re
import socket
import sys
import tempfile
import threading
import time
from datetime import datetime
from zoneinfo import ZoneInfo
from contextlib import ExitStack, contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from miio import DeviceError
from miio.miioprotocol import MiIOProtocol

# A child logger can emit payloads even when the parent's level is raised.
# Sink the whole library subtree as well as suppressing its normal messages.
_miio_log = logging.getLogger("miio")
_miio_log.setLevel(logging.CRITICAL)
_miio_log.addHandler(logging.NullHandler())
_miio_log.propagate = False

# Stable API handles; the page retains the operator-selected hub display labels.
HUBS = {"plug": "192.168.1.106", "round": "192.168.1.108"}
TIMEOUT = 1.5
ATTEMPTS = 4
MAX_TONE_VOLUME = 40
IP_FREEBIND = getattr(socket, "IP_FREEBIND", 15)  # Linux; bind before an address is assigned.
ALLOWED_HOSTS = frozenset(
    host + suffix
    for host in ("127.0.0.1", "localhost", "192.168.1.101", "hsb1", "hsb1.lan", "100.64.0.7")
    for suffix in ("", ":8765")
)
STATE_DIRECTORY = Path(os.environ.get("STATE_DIRECTORY", "/var/lib/aqara-nightlight"))
ID_FILE = str(STATE_DIRECTORY / "msgid")
PRESET_FILE = STATE_DIRECTORY / "presets.json"
SETTINGS_FILE = STATE_DIRECTORY / "settings.json"
FEED_FILE = STATE_DIRECTORY / "desk-counts.json"
FEED_MAX_AGE = 120
ID_BLOCK = 256
ID_LIMIT = 2147483000
DEFAULT_NIGHTLIGHT = {"rgb": "5C0701", "bri": 44}
ACTING_ENDPOINTS = frozenset(("/set", "/tone", "/stop", "/preset", "/apply",
                              "/settings", "/seen", "/signal-test"))
ALLOWED_NETWORKS = tuple(ipaddress.ip_network(n) for n in (
    "127.0.0.0/8", "::1/128", "192.168.1.0/24", "100.64.0.0/10",
))

# Built-in ringtones: get_music_info [0]/[1]/[2] and Xiaomi docs, except
# 14/15 (door_bell_5/6), confirmed playable in the operator's handoff.
TONES = [
    ("Alarm", [(0, "Polizei 1"), (1, "Polizei 2"), (2, "Unfall"), (3, "Countdown"), (4, "Geist"),
               (5, "Scharfschütze"), (6, "Gefecht"), (7, "Fliegeralarm"), (8, "Hundebellen")]),
    ("Türklingel", [(10, "Klingel"), (11, "Klopfen"), (12, "Lustig"), (13, "Wecker-Klingel"),
                    (14, "Klingel 5"), (15, "Klingel 6")]),
    ("Wecker", [(20, "MiMix"), (21, "Enthusiastisch"), (22, "Gitarre klassisch"), (23, "Eiswelt-Klavier"),
                (24, "Freizeit"), (25, "Kindheit"), (26, "Morgenbach"), (27, "Spieluhr"), (28, "Orange"),
                (29, "Denker")]),
]


_dev = {}
_locks = {name: threading.RLock() for name in HUBS}
_idlock = threading.Lock()
_preset_lock = threading.Lock()
_settings_lock = threading.Lock()
_id_blocks = {}
_page_lock = threading.Lock()
_page_active = {name: 0 for name in HUBS}
_tone_timers = {}
_tone_lock = threading.Lock()
_signal_tests = {}
_engine = None
_request_progress = threading.local()


class HubUnavailableError(RuntimeError):
    def __init__(self, attempts):
        self.attempts = attempts
        super().__init__(f"Hub antwortet nicht ({attempts} Versuche)")


class PresetStateError(ValueError):
    pass


class MessageIdStateError(RuntimeError):
    pass


def _next_id():
    """Reserve a durable block before use; crashes discard unused IDs.

    The counter is an exclusive high-water mark, shared by CLI and server.
    Never wrap or randomize: exhaustion/corruption fails closed. Cache by PID
    and path so forked processes cannot reuse a parent's reservation.
    """
    key = (os.getpid(), str(ID_FILE))
    with _idlock:
        next_id, end = _id_blocks.get(key, (0, 0))
        if next_id < end:
            _id_blocks[key] = (next_id + 1, end)
            return next_id
        return _reserve_ids(key)


def _reserve_ids(key):
    with open(str(ID_FILE) + ".lock", "a", encoding="ascii") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            n = int(Path(ID_FILE).read_text(encoding="ascii").strip())
        except FileNotFoundError:
            n = 0
        if not 0 <= n <= ID_LIMIT - ID_BLOCK:
            raise ValueError("Nachrichten-ID erschöpft")
        end = n + ID_BLOCK + 1
        _atomic_json(Path(ID_FILE), end - 1)
        _id_blocks[key] = (n + 2, end)
        return n + 1


def _connect(name):
    protocol = MiIOProtocol(HUBS[name], timeout=TIMEOUT)
    # send_handshake ignores the instance timeout and discover defaults to 5 s.
    # Initialize the same protocol fields from one explicitly bounded discovery.
    handshake = MiIOProtocol.discover(HUBS[name], timeout=TIMEOUT)
    if handshake is None:
        raise TimeoutError()
    protocol._device_id = handshake.header.value.device_id
    protocol._device_ts = handshake.header.value.ts
    protocol._discovered = True
    protocol._last_handshake = datetime.now().astimezone()
    protocol.token = handshake.checksum
    return protocol


def call(name, cmd, params=None, attempts=ATTEMPTS):
    """Serialize per hub, allocate a fresh ID per attempt and re-handshake on loss."""
    if name not in HUBS:
        raise ValueError("Unbekannter Hub (plug oder round)")
    with _locks[name]:
        for attempt in range(1, attempts + 1):
            progress = getattr(_request_progress, "callback", None)
            if progress and attempts == ATTEMPTS:
                progress(attempt)
            # Local persistence failures are service faults, never a hub timeout.
            # Reserve before the network attempt; unused IDs are safe gaps.
            try:
                message_id = _next_id()
            except (OSError, ValueError):
                raise MessageIdStateError() from None
            try:
                if name not in _dev:
                    _dev[name] = _connect(name)
                protocol = _dev[name]
                # python-miio wraps its internal counter at 9999. Override the
                # actual request id through its supported extra_parameters API.
                return protocol.send(cmd, params if params is not None else [], retry_count=0,
                                     extra_parameters={"id": message_id}), attempt
            except DeviceError:
                # A protocol error is a device verdict, not a lost packet.
                raise
            except Exception:
                _dev.pop(name, None)
                if attempt < attempts:
                    time.sleep(0.15 * attempt)
    # Never include library exception strings: they can carry packet/token data.
    raise HubUnavailableError(attempts)


def set_light(name, rgb, bri):
    bri = max(0, min(100, int(bri)))
    rgb = rgb.lstrip("#")
    if re.fullmatch(r"[0-9a-fA-F]{6}", rgb) is None:
        raise ValueError("Farbe muss RRGGBB sein")
    val = (bri << 24) | int(rgb, 16)
    reply, attempts = call(name, "set_rgb", [val])
    time.sleep(0.3)
    try:
        call(name, "set_rgb", [val], attempts=1)
    except Exception:
        pass
    return {"ok": True, "hub": name, "cmd": "set_rgb", "sent": f"0x{val:08x}",
            "brightness": bri, "rgb": rgb.upper(), "reply": reply, "versuche": attempts}


def get_light(name):
    value, attempts = call(name, "get_prop", ["rgb", "illumination"])
    rgb = value[0]
    return {"ok": True, "hub": name, "raw": f"0x{rgb:08x}", "brightness": rgb >> 24,
            "rgb": f"{rgb & 0xFFFFFF:06X}", "illumination": value[1], "versuche": attempts,
            "hinweis": "Rücklesen hinkt oft hinterher"}


def play_tone(name, tid, vol=15, ms=None):
    tid = int(tid)
    vol = max(0, min(MAX_TONE_VOLUME, int(vol)))
    if tid not in {i for _, items in TONES for i, _ in items}:
        raise ValueError("Unbekannter Ton")
    if ms is not None and not 200 <= int(ms) <= 3000:
        raise ValueError("Dauer muss 200–3000 ms sein")
    with _locks[name]:
        reply, attempts = call(name, "play_music_new", [str(tid), vol])
        with _tone_lock:
            previous = _tone_timers.pop(name, None)
            if previous:
                previous.cancel()
            if ms is not None:
                timer = threading.Timer(int(ms) / 1000, _timed_stop, (name,))
                timer.daemon = True
                _tone_timers[name] = timer
                timer.start()
    return {"ok": True, "hub": name, "cmd": "tone", "id": tid, "vol": vol,
            "ms": None if ms is None else int(ms), "reply": reply, "versuche": attempts}


def _timed_stop(name):
    try:
        with _locks[name]:
            with _tone_lock:
                if _tone_timers.get(name) is not threading.current_thread():
                    return
                _tone_timers.pop(name, None)
            call(name, "set_sound_playing", ["off"], attempts=1)
    except Exception:
        print("aqara-nightlight: timed sound stop failed", file=sys.stderr, flush=True)


def stop_sound(name):
    with _tone_lock:
        previous = _tone_timers.pop(name, None)
        if previous:
            previous.cancel()
    reply, attempts = call(name, "set_sound_playing", ["off"])
    return {"ok": True, "hub": name, "cmd": "stop", "reply": reply, "versuche": attempts}


# Only the HTTP server needs the page. CLI commands also work from a standalone
# Nix store script without AQARA_PAGE_FILE or an adjacent HTML file.
PAGE = ""
SCRIPT_HASHES = ""


def _load_page():
    global PAGE, SCRIPT_HASHES
    page_file = Path(os.environ.get("AQARA_PAGE_FILE", Path(__file__).with_name("aqara-nightlight-page.html")))
    page = page_file.read_text(encoding="utf-8")
    hashes = " ".join(
        "'sha256-" + base64.b64encode(hashlib.sha256(script.encode()).digest()).decode() + "'"
        for script in re.findall(r"<script>(.*?)</script>", page, re.DOTALL)
    )
    PAGE, SCRIPT_HASHES = page, hashes


PRESET_IDS = ("nacht", "p2", "p3", "p4", "p5", "p6")
PLACE_DEFAULTS = [
    {"id": "nacht", "name": "Nachtlicht", **DEFAULT_NIGHTLIGHT},
    {"id": "p2", "name": "Warm", "rgb": "FF8C28", "bri": 40},
    {"id": "p3", "name": "Hell", "rgb": "FFF4E0", "bri": 80},
    {"id": "p4", "name": "Rot leise", "rgb": "FF2A00", "bri": 5},
]


def _default_presets():
    return {hub: [dict(p) for p in PLACE_DEFAULTS] for hub in HUBS}


def _valid_light(value):
    return (isinstance(value, dict) and isinstance(value.get("rgb"), str)
            and re.fullmatch(r"[0-9A-F]{6}", value["rgb"]) is not None
            and type(value.get("bri")) is int and 0 <= value["bri"] <= 100)


def _valid_name(value):
    return (isinstance(value, str) and 1 <= len(value.strip()) <= 16
            and all(ord(c) >= 32 and ord(c) != 127 for c in value))


def _atomic_json(path, value):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=Path(path).parent,
                                         prefix="." + Path(path).stem + "-", delete=False) as handle:
            temporary = handle.name
            json.dump(value, handle, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
        directory = os.open(Path(path).parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if temporary is not None:
            os.unlink(temporary)


def _read_presets():
    try:
        with open(PRESET_FILE, encoding="utf-8") as handle:
            presets = json.load(handle)
    except FileNotFoundError:
        return _default_presets()
    except (json.JSONDecodeError, UnicodeError):
        raise PresetStateError("Ungültige Presets") from None
    if not isinstance(presets, dict) or not presets.keys() <= HUBS.keys():
        raise PresetStateError("Ungültige Presets")
    migrated = False
    for hub, values in list(presets.items()):
        if isinstance(values, dict):
            # Legacy files have only nacht. Validate before any migration write;
            # absent nacht remains absent, never silently invent an HA target.
            if not values.keys() <= {"nacht"} or any(
                    not _valid_light(p) or set(p) != {"rgb", "bri"} for p in values.values()):
                raise PresetStateError("Ungültiges Preset")
            presets[hub] = ([{"id": "nacht", "name": "Nachtlicht", **values["nacht"]}]
                            if "nacht" in values else []) + [dict(p) for p in PLACE_DEFAULTS[1:]]
            migrated = True
        values = presets[hub]
        if not isinstance(values, list) or len(values) > 6:
            raise PresetStateError("Ungültige Presets")
        ids = []
        for preset in values:
            if (not _valid_light(preset) or set(preset) != {"id", "name", "rgb", "bri"}
                    or preset["id"] not in PRESET_IDS or not _valid_name(preset["name"])
                    or preset["id"] in ids):
                raise PresetStateError("Ungültiges Preset")
            ids.append(preset["id"])
        values.sort(key=lambda p: PRESET_IDS.index(p["id"]))
    if migrated:
        _atomic_json(PRESET_FILE, presets)
    return presets


@contextmanager
def _preset_transaction():
    with _preset_lock, open(str(PRESET_FILE) + ".lock", "a", encoding="ascii") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def get_presets():
    with _preset_transaction():
        return {"ok": True, "presets": _read_presets()}


def save_preset(hub, preset_id=None, rgb=None, bri=None, reset=False, *, name=None,
                new=False, delete=False):
    if hub not in HUBS or sum((bool(reset), bool(new), bool(delete))) > 1:
        raise ValueError("Unbekanntes Preset")
    if name is not None and not _valid_name(name):
        raise ValueError("Name muss 1–16 Zeichen haben")
    if new and preset_id is not None:
        raise ValueError("Neue Plätze erhalten eine feste ID")
    with _preset_transaction():
        presets = _read_presets()
        places = presets.setdefault(hub, [])
        if new:
            if len(places) >= 6:
                return {"ok": False, "error": "Alle sechs Plätze sind belegt"}
            preset_id = next((i for i in PRESET_IDS if i not in {p["id"] for p in places} and i != "nacht"), None)
            if preset_id is None:
                return {"ok": False, "error": "Alle zusätzlichen Plätze sind belegt"}
            place = {"id": preset_id, "name": name.strip() if name else "Neuer Platz", **DEFAULT_NIGHTLIGHT}
        else:
            place = next((p for p in places if p["id"] == preset_id), None)
            if place is None:
                return {"ok": False, "error": "Preset nicht gespeichert"}
        if delete:
            if preset_id == "nacht":
                return {"ok": False, "error": "Nachtlicht kann nicht gelöscht werden"}
            places.remove(place)
        else:
            if reset:
                default = next((p for p in PLACE_DEFAULTS if p["id"] == preset_id), DEFAULT_NIGHTLIGHT)
                place.update(rgb=default["rgb"], bri=default["bri"])
            elif rgb is not None or bri is not None:
                value = {"rgb": rgb.upper() if isinstance(rgb, str) else rgb, "bri": int(bri)}
                if not _valid_light(value):
                    raise ValueError("Ungültige Farbe oder Helligkeit")
                place.update(value)
            elif not new and name is None:
                raise ValueError("Keine Änderung angegeben")
            if name is not None:
                place["name"] = name.strip()
            if new:
                places.append(place)
            places.sort(key=lambda p: PRESET_IDS.index(p["id"]))
        _atomic_json(PRESET_FILE, presets)
    return {"ok": True, "hub": hub, "id": preset_id, "presets": presets}


def apply_preset(hub, name):
    if hub not in HUBS:
        raise ValueError("Unbekannter Hub")
    with _preset_transaction():
        preset = next((p for p in _read_presets().get(hub, []) if p["id"] == name), None)
    if preset is None:
        return {"ok": False, "error": "Preset nicht gespeichert"}
    return set_light(hub, preset["rgb"], preset["bri"])


DESKS = ("ppm", "pma")
RULE_KEYS = tuple(f"{level}:{desk}" for level in ("urgent", "regular", "open")
                  for desk in (*DESKS, "both")) + ("idle", "unknown")


def default_settings():
    def hub_settings(hub):
        rules = {}
        for key in RULE_KEYS:
            level, _, desk = key.partition(":")
            rules[key] = {"rgb": {"ppm": "18C2B0", "pma": "FFA020", "both": "9B6BFF"}.get(desk, "8FA3B0"),
                          "bri": {"urgent": 60, "regular": 20, "open": 0, "idle": 0, "unknown": 5}[level],
                          "mode": "blink" if level == "urgent" else "steady", "rgb2": "FFFFFF", "takt": 2}
        return {"usage": "desk" if hub == "round" else "nightlight", "rules": rules,
                "thresholds": {desk: 4 for desk in DESKS}, "auto_sound": False,
                "sound_ms": 1000, "sound_vol": 10, "sound_id": 10,
                "seen": None, "sound_generation": {desk: 0 for desk in DESKS}, "last_sound": 0}
    return {hub: hub_settings(hub) for hub in HUBS}


class SettingsStateError(ValueError):
    pass


def _valid_rule(rule, key):
    return (_valid_light(rule) and set(rule) == {"rgb", "bri", "mode", "rgb2", "takt"}
            and rule["mode"] in ("steady", "blink", "alternate")
            and isinstance(rule["rgb2"], str) and re.fullmatch(r"[0-9A-F]{6}", rule["rgb2"]) is not None
            and type(rule["takt"]) is int and 2 <= rule["takt"] <= 5
            and (key != "unknown" or rule["bri"] >= 1 and rule["mode"] != "blink"
                 and rule["rgb"] != "000000" and (rule["mode"] != "alternate" or rule["rgb2"] != "000000")))


def _require_settings(condition):
    if not condition:
        raise SettingsStateError()


def _read_settings():
    try:
        settings = json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default_settings()
    except (UnicodeError, ValueError):
        raise SettingsStateError() from None
    try:
        defaults = default_settings()
        _require_settings(isinstance(settings, dict) and set(settings) == set(HUBS))
        for hub, value in settings.items():
            _require_settings(set(value) == set(defaults[hub]))
            _require_settings(value["usage"] in ("nightlight", "desk") and type(value["auto_sound"]) is bool)
            _require_settings(set(value["rules"]) == set(RULE_KEYS))
            _require_settings(all(_valid_rule(r, k) for k, r in value["rules"].items()))
            _require_settings(set(value["thresholds"]) == set(DESKS))
            _require_settings(all(type(n) is int and 1 <= n <= 48 for n in value["thresholds"].values()))
            _require_settings(value["sound_ms"] is None or type(value["sound_ms"]) is int and 200 <= value["sound_ms"] <= 3000)
            _require_settings(type(value["sound_vol"]) is int and 0 <= value["sound_vol"] <= 15)
            _require_settings(type(value["sound_id"]) is int and value["sound_id"] in {i for _, tones in TONES for i, _ in tones})
            _require_settings(value["seen"] is None or (set(value["seen"]) == set(DESKS)
                    and all(type(n) is int and n >= 0 for n in value["seen"].values())))
            _require_settings(set(value["sound_generation"]) == set(DESKS))
            _require_settings(all(type(n) is int and n >= 0 for n in value["sound_generation"].values()))
            _require_settings(type(value["last_sound"]) in (int, float) and 0 <= value["last_sound"] <= 2**53 - 1)
    except (KeyError, TypeError, AttributeError):
        raise SettingsStateError() from None
    return settings


@contextmanager
def _settings_transaction():
    with _settings_lock, open(str(SETTINGS_FILE) + ".lock", "a", encoding="ascii") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def get_settings():
    with _settings_transaction():
        return {"ok": True, "settings": _read_settings()}


def save_settings(hub, query):
    if hub not in HUBS:
        raise ValueError("Unbekannter Hub")
    with _settings_transaction():
        settings = _read_settings()
        value = settings[hub]
        if "usage" in query:
            if query["usage"] not in ("nightlight", "desk"):
                raise ValueError("Ungültige Verwendung")
            if value["usage"] == "desk" and query["usage"] == "nightlight" and _engine is not None:
                _engine.finish(hub)
            value["usage"] = query["usage"]
        if "rule" in query:
            key = query["rule"]
            if key not in RULE_KEYS:
                raise ValueError("Unbekannte Regel")
            rule = {"rgb": query["rgb"].upper(), "bri": int(query["bri"]),
                    "mode": query["mode"], "rgb2": query.get("rgb2", "FFFFFF").upper(),
                    "takt": int(query["takt"])}
            if not _valid_rule(rule, key):
                raise ValueError("Ungültige Regel; Unbekannt muss immer leuchten")
            keys = [key]
            if query.get("all") == "1" and ":" in key:
                keys = [key.split(":")[0] + ":" + desk for desk in (*DESKS, "both")]
            for target in keys:
                value["rules"][target] = dict(rule)
        for desk in DESKS:
            if "threshold_" + desk in query:
                n = int(query["threshold_" + desk])
                if not 1 <= n <= 48:
                    raise ValueError("Schwelle muss 1–48 h sein")
                value["thresholds"][desk] = n
        if "auto_sound" in query:
            if query["auto_sound"] not in ("0", "1"):
                raise ValueError("Ungültiger Schalter")
            value["auto_sound"] = query["auto_sound"] == "1"
        for field, low, high in (("sound_ms", 200, 3000), ("sound_vol", 0, 15)):
            if field in query:
                n = None if field == "sound_ms" and query[field] == "" else int(query[field])
                if n is not None and not low <= n <= high:
                    raise ValueError("Ungültiger Tonwert")
                value[field] = n
        _atomic_json(SETTINGS_FILE, settings)
    return {"ok": True, "settings": settings}


def quiet_hours(now=None):
    local = datetime.fromtimestamp(time.time() if now is None else now, ZoneInfo("Europe/Vienna"))
    minute = local.hour * 60 + local.minute
    return minute >= 20 * 60 or minute < 7 * 60 + 30


def read_feed(now=None):
    """Strict counts-only, local INPUT. No network, credentials, titles or IDs."""
    now = time.time() if now is None else now
    try:
        with open(FEED_FILE, "rb") as handle:
            raw = handle.read(16385)
        if len(raw) > 16384:
            raise ValueError()
        feed = json.loads(raw.decode("utf-8"))
        if set(feed) != {"version", "updated_at", "desks"} or type(feed["version"]) is not int or feed["version"] != 1:
            raise ValueError()
        if type(feed["updated_at"]) not in (int, float) or not 0 <= now - feed["updated_at"] <= FEED_MAX_AGE:
            raise ValueError()
        if not isinstance(feed["desks"], dict) or not feed["desks"] or not feed["desks"].keys() <= set(DESKS):
            raise ValueError()
        for desk in feed["desks"].values():
            if set(desk) != {"open", "held", "oldest_held_at", "oldest_expiry_at", "generation"}:
                raise ValueError()
            if any(type(desk[k]) is not int or not 0 <= desk[k] <= 2**53 - 1 for k in ("open", "held", "generation")):
                raise ValueError()
            if desk["held"] > desk["open"]:
                raise ValueError()
            for field in ("oldest_held_at", "oldest_expiry_at"):
                stamp = desk[field]
                if stamp is not None and (type(stamp) not in (int, float) or not 0 <= stamp <= 2**53 - 1):
                    raise ValueError()
            if desk["held"] and (desk["oldest_held_at"] is None or desk["oldest_held_at"] > now):
                raise ValueError()
        return feed
    except (OSError, UnicodeError, ValueError, TypeError, KeyError, AttributeError):
        return None


def _generation(feed):
    return {d: feed["desks"].get(d, {}).get("generation", 0) for d in DESKS}


def resolve_signal(settings, feed, now):
    if feed is None:
        key = "unknown"
    elif settings["seen"] == _generation(feed):
        key = "idle"
    else:
        levels = {}
        for desk, counts in feed["desks"].items():
            urgent = counts["held"] and (
                now - counts["oldest_held_at"] >= settings["thresholds"][desk] * 3600
                or counts["oldest_expiry_at"] is not None and counts["oldest_expiry_at"] <= now + 3600)
            levels[desk] = "urgent" if urgent else "regular" if counts["held"] else "open" if counts["open"] else "idle"
        level = next((level for level in ("urgent", "regular", "open") if level in levels.values()), "idle")
        # Both held desks participate even if only one is urgent. Urgency picks
        # the row; the desk columns describe where the waiting items are.
        desks = [desk for desk in DESKS if levels.get(desk) in
                 (("urgent", "regular") if level in ("urgent", "regular") else (level,))]
        key = level if level == "idle" else level + ":" + ("both" if len(desks) == 2 else desks[0])
    rule = dict(settings["rules"][key])
    quiet = quiet_hours(now)
    if quiet:
        rule.update(mode="steady", bri=5 if rule["bri"] else 0)
    return {"key": key, "rule": rule, "quiet": quiet}


def signal_status(hub):
    if hub not in HUBS:
        raise ValueError("Unbekannter Hub")
    settings = get_settings()["settings"][hub]
    now = time.time()
    feed = read_feed(now)
    result = resolve_signal(settings, feed, now)
    return {"ok": True, **result, "feed": feed, "settings": settings,
            "applied": None if _engine is None else _engine.applied.get(hub)}


def mark_seen(hub):
    if hub not in HUBS:
        raise ValueError("Unbekannter Hub")
    feed = read_feed()
    if feed is None:
        return {"ok": False, "error": "Keine aktuellen Desk-Daten"}
    with _settings_transaction():
        settings = _read_settings()
        settings[hub]["seen"] = _generation(feed)
        _atomic_json(SETTINGS_FILE, settings)
    return signal_status(hub)


def test_signal(hub, query):
    if hub not in HUBS:
        raise ValueError("Unbekannter Hub")
    key = query["rule"]
    settings = get_settings()["settings"][hub]
    if key not in RULE_KEYS or settings["usage"] != "desk":
        raise ValueError("Ungültige Signalprobe")
    rule = dict(settings["rules"][key])
    if "rgb" in query:
        rule = {"rgb": query["rgb"].upper(), "bri": int(query["bri"]), "mode": query["mode"],
                "rgb2": query["rgb2"].upper(), "takt": int(query["takt"])}
    if not _valid_rule(rule, key):
        raise ValueError("Ungültige Signalprobe")
    if quiet_hours():
        rule.update(mode="steady", bri=5 if rule["bri"] else 0)
    set_light(hub, rule["rgb"], rule["bri"])
    with _page_lock:
        _signal_tests[hub] = (time.monotonic() + 10, key, rule)
    return {"ok": True, "seconds": 10}


@contextmanager
def page_command(hub):
    """Pause the engine from request arrival through the complete HTTP reply."""
    if hub not in HUBS:
        yield
        return
    with _page_lock:
        _page_active[hub] += 1
    try:
        # Wait only for a single engine attempt (discovery + packet <= 3 s).
        if not _locks[hub].acquire(timeout=3.2):
            raise HubBusyError()
        try:
            yield
        finally:
            _locks[hub].release()
    finally:
        with _page_lock:
            _page_active[hub] -= 1


class HubBusyError(RuntimeError):
    pass


class SignalEngine:
    def __init__(self):
        self.stop = threading.Event()
        self.previous = {}
        self.next_tick = {}
        self.phase = {}
        self.applied = {}

    def finish(self, hub):
        old = self.previous.get(hub)
        if old:
            call(hub, "set_rgb", [(old[1]["bri"] << 24) | int(old[1]["rgb"], 16)], attempts=1)
            self.previous.pop(hub, None)

    def tick(self, hub, now=None, monotonic=None):
        now = time.time() if now is None else now
        monotonic = time.monotonic() if monotonic is None else monotonic
        with _page_lock:
            if _page_active[hub]:
                return False
        if not _locks[hub].acquire(blocking=False):
            return False
        try:
            with _page_lock:
                if _page_active[hub]:
                    return False
            settings = get_settings()["settings"][hub]
            old = self.previous.get(hub)
            if settings["usage"] != "desk":
                if old:
                    # Leave the old animation on its defined first/static colour.
                    self.finish(hub)
                return False
            feed = read_feed(now)
            signal = resolve_signal(settings, feed, now)
            key, rule = signal["key"], signal["rule"]
            with _page_lock:
                test = _signal_tests.get(hub)
                if test and monotonic < test[0]:
                    _, key, rule = test
                    rule = dict(rule)
                    if signal["quiet"]:
                        rule.update(mode="steady", bri=5 if rule["bri"] else 0)
                elif test:
                    _signal_tests.pop(hub, None)
            changed = old != (key, rule)
            if not changed and monotonic < self.next_tick.get(hub, 0):
                return False
            if monotonic < self.next_tick.get((hub, "attempt"), 0):
                return False
            self.next_tick[(hub, "attempt")] = monotonic + max(2, rule["takt"])
            # State transitions always start on the new defined static colour;
            # no queued off phase can leak from the previous animation.
            phase = 0 if changed else 1 - self.phase.get(hub, 0)
            rgb = rule["rgb2"] if phase and rule["mode"] == "alternate" else rule["rgb"]
            bri = 0 if phase and rule["mode"] == "blink" else rule["bri"]
            call(hub, "set_rgb", [(bri << 24) | int(rgb, 16)], attempts=1)
            self.previous[hub] = (key, rule)
            self.phase[hub] = phase
            self.next_tick[hub] = monotonic + (rule["takt"] if rule["mode"] != "steady" else 30)
            self.applied[hub] = {"key": key, "rgb": rgb, "bri": bri, "at": now}
            self._auto_sound(hub, settings, feed, now)
            return True
        finally:
            _locks[hub].release()

    def _auto_sound(self, hub, settings, feed, now):
        if feed is None:
            return
        generation = _generation(feed)
        fresh = any(feed["desks"].get(d, {}).get("held", 0) and generation[d] > settings["sound_generation"][d] for d in DESKS)
        if not fresh:
            return
        play = settings["auto_sound"] and not quiet_hours(now) and now - settings["last_sound"] >= 600
        # Persist consumed generations BEFORE playback: restart/failure can drop
        # a notification, but can never repeat it or play a quiet-hours backlog.
        with _settings_transaction():
            stored = _read_settings()
            for d in DESKS:
                stored[hub]["sound_generation"][d] = max(stored[hub]["sound_generation"][d], generation[d])
            if play:
                stored[hub]["last_sound"] = now
            _atomic_json(SETTINGS_FILE, stored)
        if play:
            play_tone(hub, settings["sound_id"], settings["sound_vol"], settings["sound_ms"])

    def run(self, hub):
        while not self.stop.is_set():
            try:
                self.tick(hub)
            except Exception:
                print("aqara-nightlight: signal engine tick failed", file=sys.stderr, flush=True)
            # Missed ticks are never queued; schedule from completion.
            self.stop.wait(0.5)

    def start(self):
        for hub in HUBS:
            threading.Thread(target=self.run, args=(hub,), daemon=True,
                             name="desk-signal-" + hub).start()


def error_response(error):
    # Fixed messages only, including DeviceError and unexpected library failures.
    if isinstance(error, MessageIdStateError):
        print("aqara-nightlight: message id state failed", file=sys.stderr, flush=True)
        return {"ok": False, "error": "Nachrichten-Zähler nicht verfügbar; Server prüfen",
                "code": "msgid_state"}
    if isinstance(error, PresetStateError):
        print("aqara-nightlight: preset state corrupt; stop service and move presets.json aside before restart",
              file=sys.stderr, flush=True)
        return {"ok": False, "error": "Gespeicherte Nachtlicht-Vorgaben beschädigt; Server prüfen",
                "code": "presets_corrupt"}
    if isinstance(error, HubUnavailableError):
        return {"ok": False, "error": f"Hub antwortet nicht ({error.attempts} Versuche)",
                "code": "hub_unavailable", "attempts": error.attempts}
    if isinstance(error, SettingsStateError):
        print("aqara-nightlight: settings state corrupt", file=sys.stderr, flush=True)
        return {"ok": False, "error": "Gespeicherte Desk-Einstellungen beschädigt; Server prüfen",
                "code": "settings_corrupt"}
    if isinstance(error, HubBusyError):
        return {"ok": False, "error": "Hub beschäftigt; erneut versuchen", "code": "hub_busy"}
    if isinstance(error, (ValueError, KeyError, IndexError, TypeError)):
        message = "Ungültige Anfrage: Hub, Farbe, Helligkeit oder Ton prüfen"
    elif isinstance(error, DeviceError):
        message = "Hub hat den Befehl abgelehnt"
    else:
        message = "Hub oder Dienst nicht erreichbar; erneut versuchen"
    return {"ok": False, "error": message}


def allowed_peer(address):
    try:
        peer = ipaddress.ip_address(address)
    except ValueError:
        return False
    return any(peer in network for network in ALLOWED_NETWORKS)


def allowed_request(headers):
    # Defence in depth: browsers may omit Origin and fetch metadata on HTTP.
    # Reject duplicate security headers rather than trusting only the first one.
    hosts = headers.get_all("Host", [])
    if len(hosts) != 1 or hosts[0].lower() not in ALLOWED_HOSTS:
        return False
    if headers.get_all("Sec-Fetch-Site", []) not in ([], ["same-origin"], ["none"]):
        return False
    # Direct HTTP UI only: a present Origin must match this request's allowed Host.
    return headers.get_all("Origin", []) in ([], [f"http://{hosts[0].lower()}"])


class H(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self._handle()

    def do_POST(self):
        self._handle()

    def do_OPTIONS(self):
        # Never approve a cross-origin preflight for the required custom header.
        self.send_error(403)

    def _handle(self):
        if not allowed_peer(self.client_address[0]) or not allowed_request(self.headers):
            self.send_error(403)
            return
        url = urlparse(self.path)
        if url.path in ACTING_ENDPOINTS:
            # Images, navigations and simple cross-origin requests cannot add
            # this header. Reject duplicates as well as missing/wrong values.
            if self.headers.get_all("X-Nightlight", []) != ["1"]:
                self.send_error(403)
                return
            # GET-with-header is deprecated; retained for live HA rest_command.
        elif self.command != "GET":
            self._reply(b"", "text/plain; charset=utf-8", status=405, allow="GET")
            return
        query = {k: v[0] for k, v in parse_qs(url.query, keep_blank_values=True).items()}
        try:
            with page_command(query.get("hub")):
                self._dispatch(url, query)
        except HubBusyError as error:
            self._reply(json.dumps(error_response(error)).encode(), "application/json; charset=utf-8")

    def _dispatch(self, url, query):
        self._streaming = self.headers.get_all("Accept", []) == ["application/x-ndjson"] and url.path in (
            "/set", "/get", "/tone", "/stop", "/apply")
        if self._streaming:
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            _request_progress.callback = self._progress
        try:
            if url.path == "/set":
                result = set_light(query["hub"], query["rgb"], query["bri"])
            elif url.path == "/get":
                result = get_light(query["hub"])
            elif url.path == "/tone":
                result = play_tone(query["hub"], query["id"], query.get("vol", 15), query.get("ms"))
            elif url.path == "/stop":
                result = stop_sound(query["hub"])
            elif url.path == "/presets":
                result = get_presets()
            elif url.path == "/preset":
                # Keep the old HA name=nacht request compatible; the new API
                # uses id for identity and name only for renaming.
                legacy = "id" not in query and query.get("name") == "nacht" and query.get("new") != "1"
                result = save_preset(query["hub"], "nacht" if legacy else query.get("id"),
                                     query.get("rgb"), query.get("bri"), reset=query.get("reset") == "1",
                                     name=None if legacy else query.get("name"),
                                     new=query.get("new") == "1", delete=query.get("delete") == "1")
            elif url.path == "/apply":
                result = apply_preset(query["hub"], query["preset"])
            elif url.path == "/config":
                result = get_settings()
            elif url.path == "/settings":
                result = save_settings(query["hub"], query)
            elif url.path == "/signal":
                result = signal_status(query["hub"])
            elif url.path == "/seen":
                result = mark_seen(query["hub"])
            elif url.path == "/signal-test":
                result = test_signal(query["hub"], query)
            else:
                self._reply(PAGE.encode(), "text/html; charset=utf-8")
                return
        except Exception as error:
            result = error_response(error)
        finally:
            _request_progress.callback = None
        self._reply(json.dumps(result, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def _progress(self, attempt):
        try:
            self.wfile.write(json.dumps({"progress": attempt, "attempts": ATTEMPTS}).encode() + b"\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _reply(self, body, content_type, status=200, allow=None):
        try:
            if getattr(self, "_streaming", False):
                self.wfile.write(body + b"\n")
                self.wfile.flush()
                return
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            if allow:
                self.send_header("Allow", allow)
            if content_type.startswith("text/html"):
                self.send_header("Content-Security-Policy", f"default-src 'none'; script-src {SCRIPT_HASHES}; "
                                 "style-src 'unsafe-inline'; img-src 'self'; connect-src 'self'; base-uri 'none'; "
                                 "form-action 'none'; frame-ancestors 'none'")
                self.send_header("X-Frame-Options", "DENY")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


class Server(ThreadingHTTPServer):
    def server_bind(self):
        if sys.platform == "linux":
            try:
                self.socket.setsockopt(socket.IPPROTO_IP, IP_FREEBIND, 1)
            except OSError:
                pass
        super().server_bind()

    def handle_error(self, request, client_address):
        # BaseServer otherwise prints a traceback with arbitrary exception data.
        print("aqara-nightlight: HTTP request failed", file=sys.stderr, flush=True)


def serve():
    # main() covers page-loading failures with the same fixed startup log line.
    _load_page()
    global _engine
    addresses = [address.strip() for address in os.environ.get("AQARA_LISTEN_ADDRESSES", "127.0.0.1").split(",")]
    # Validate every entry before opening any socket. Empty strings bind all IPv4.
    for address in addresses:
        parsed = ipaddress.ip_address(address)
        if parsed.version != 4 or parsed.is_unspecified:
            raise ValueError("Listener muss eine konkrete IPv4-Adresse sein")
    port = int(os.environ.get("AQARA_PORT", "8765"))
    with ExitStack() as stack:
        servers = [stack.enter_context(Server((address, port), H)) for address in addresses]
        _engine = SignalEngine()
        _engine.start()
        stack.callback(_engine.stop.set)
        for server in servers[:-1]:
            threading.Thread(target=server.serve_forever, daemon=True).start()
        print(f"aqara-nightlight: UI/API listening on {','.join(addresses)}:{port}", flush=True)
        servers[-1].serve_forever()


def main(args):
    if not args:
        try:
            serve()
        except Exception:
            # Listener validation/bind failures are not HTTP/CLI request errors.
            # Keep arbitrary exception data out of the journal.
            print("aqara-nightlight: listener startup failed; check listen addresses and port",
                  file=sys.stderr, flush=True)
            return 1
        return 0
    try:
        if args[0] == "set" and len(args) == 4:
            result = set_light(args[1], args[2], args[3])
        elif args[0] == "get" and len(args) == 2:
            result = get_light(args[1])
        elif args[0] == "tone" and len(args) in (3, 4):
            result = play_tone(args[1], args[2], args[3] if len(args) > 3 else 15)
        elif args[0] == "stop" and len(args) == 2:
            result = stop_sound(args[1])
        else:
            print(__doc__)
            return 2
    except Exception as error:
        print(json.dumps(error_response(error), ensure_ascii=False), flush=True)
        return 1
    print(json.dumps(result, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
