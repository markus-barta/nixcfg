#!/usr/bin/env python3
"""OPS-496: Aqara light/sound API, ported from the verified local prototype.

GET /get?hub=plug, /presets and / for the UI. Acting endpoints /set, /tone,
/stop, /preset and /apply require X-Nightlight: 1 and accept GET or POST.
GET actions are deprecated compatibility for Home Assistant; the UI uses POST.
KI-18FB is plug; EZ-594F is round. Default nacht: 5C0701 at 44%.
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
import random
import re
import socket
import sys
import tempfile
import threading
import time
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
DEFAULT_NIGHTLIGHT = {"rgb": "5C0701", "bri": 44}
ACTING_ENDPOINTS = frozenset(("/set", "/tone", "/stop", "/preset", "/apply"))
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
_locks = {name: threading.Lock() for name in HUBS}
_idlock = threading.Lock()
_preset_lock = threading.Lock()


class HubUnavailableError(RuntimeError):
    def __init__(self, attempts):
        self.attempts = attempts
        super().__init__(f"Hub antwortet nicht ({attempts} Versuche)")


class PresetStateError(ValueError):
    pass


def _next_id():
    """Share IDs between threads, CLI processes and restarts; always below 9999.

    Keep the prototype's rolling/randomized range. Never replace the inode:
    flock must cover every reader/writer of this one persistent file.
    """
    with _idlock, open(ID_FILE, "a+", encoding="ascii") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        handle.seek(0)
        try:
            n = int(handle.read().strip() or 0)
        except ValueError:
            n = 0
        n = n + 1 if 0 < n < 9000 else random.randint(1, 3000)
        handle.seek(0)
        handle.truncate()
        handle.write(str(n))
        handle.flush()
        os.fsync(handle.fileno())
        return n


def _connect(name):
    protocol = MiIOProtocol(HUBS[name], timeout=TIMEOUT)
    handshake = protocol.send_handshake(retry_count=1)
    protocol.token = handshake.checksum
    return protocol


def call(name, cmd, params=None, attempts=ATTEMPTS):
    """Serialize per hub, allocate a fresh ID per attempt and re-handshake on loss."""
    if name not in HUBS:
        raise ValueError("Unbekannter Hub (plug oder round)")
    with _locks[name]:
        for attempt in range(1, attempts + 1):
            try:
                if name not in _dev:
                    _dev[name] = _connect(name)
                protocol = _dev[name]
                protocol._MiIOProtocol__id = _next_id() - 1
                return protocol.send(cmd, params if params is not None else [], retry_count=0), attempt
            except DeviceError:
                # A protocol error is a device verdict, not a lost packet.
                raise
            except Exception:
                _dev.pop(name, None)
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


def play_tone(name, tid, vol=15):
    tid = int(tid)
    vol = max(0, min(MAX_TONE_VOLUME, int(vol)))
    if tid not in {i for _, items in TONES for i, _ in items}:
        raise ValueError("Unbekannter Ton")
    reply, attempts = call(name, "play_music_new", [str(tid), vol])
    return {"ok": True, "hub": name, "cmd": "tone", "id": tid, "vol": vol,
            "reply": reply, "versuche": attempts}


def stop_sound(name):
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


def _default_presets():
    return {hub: {"nacht": dict(DEFAULT_NIGHTLIGHT)} for hub in HUBS}


def _read_presets():
    try:
        with open(PRESET_FILE, encoding="utf-8") as handle:
            presets = json.load(handle)
    except FileNotFoundError:
        return _default_presets()
    except (json.JSONDecodeError, UnicodeError):
        raise PresetStateError("Ungültige Presets") from None
    # Corrupt state fails closed: never silently apply a different light or
    # overwrite damaged state on the next save. Missing saved entries stay absent.
    if not isinstance(presets, dict) or not presets.keys() <= HUBS.keys():
        raise PresetStateError("Ungültige Presets")
    for values in presets.values():
        if not isinstance(values, dict) or not values.keys() <= {"nacht"}:
            raise PresetStateError("Ungültige Presets")
        for preset in values.values():
            if (not isinstance(preset, dict) or set(preset) != {"rgb", "bri"}
                    or not isinstance(preset["rgb"], str)
                    or re.fullmatch(r"[0-9A-F]{6}", preset["rgb"]) is None
                    or type(preset["bri"]) is not int or not 0 <= preset["bri"] <= 100):
                raise PresetStateError("Ungültiges Preset")
    return presets


@contextmanager
def _preset_transaction():
    # Lock a stable inode, never the file replaced by the atomic write. This
    # also prevents lost updates from independent service/maintenance processes.
    with _preset_lock, open(str(PRESET_FILE) + ".lock", "a", encoding="ascii") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def get_presets():
    with _preset_transaction():
        return {"ok": True, "presets": _read_presets()}


def save_preset(hub, name, rgb=None, bri=None, reset=False):
    if hub not in HUBS or name != "nacht":
        raise ValueError("Unbekanntes Preset")
    if reset:
        preset = dict(DEFAULT_NIGHTLIGHT)
    else:
        if not isinstance(rgb, str) or re.fullmatch(r"[0-9a-fA-F]{6}", rgb) is None:
            raise ValueError("Farbe muss RRGGBB sein")
        brightness = int(bri)
        if not 0 <= brightness <= 100:
            raise ValueError("Helligkeit muss 0–100 sein")
        preset = {"rgb": rgb.upper(), "bri": brightness}
    with _preset_transaction():
        presets = _read_presets()
        presets.setdefault(hub, {})[name] = preset
        # Same directory/filesystem, private mode, fsync before replace. Sync the
        # directory as well so a reported save survives a restart/power loss.
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=Path(PRESET_FILE).parent,
                                             prefix=".presets-", delete=False) as handle:
                temporary = handle.name
                json.dump(presets, handle, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, PRESET_FILE)
            temporary = None
            directory = os.open(Path(PRESET_FILE).parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if temporary is not None:
                os.unlink(temporary)
    return {"ok": True, "hub": hub, "name": name, "presets": presets}


def apply_preset(hub, name):
    if hub not in HUBS:
        raise ValueError("Unbekannter Hub")
    with _preset_transaction():
        preset = _read_presets().get(hub, {}).get(name)
    if preset is None:
        return {"ok": False, "error": "Preset nicht gespeichert"}
    return set_light(hub, preset["rgb"], preset["bri"])


def error_response(error):
    # Fixed messages only, including DeviceError and unexpected library failures.
    if isinstance(error, PresetStateError):
        print("aqara-nightlight: preset state corrupt; stop service and move presets.json aside before restart",
              file=sys.stderr, flush=True)
        return {"ok": False, "error": "Gespeicherte Nachtlicht-Vorgaben beschädigt; Server prüfen",
                "code": "presets_corrupt"}
    if isinstance(error, HubUnavailableError):
        return {"ok": False, "error": f"Hub antwortet nicht ({error.attempts} Versuche)",
                "code": "hub_unavailable", "attempts": error.attempts}
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
        query = {k: v[0] for k, v in parse_qs(url.query).items()}
        try:
            if url.path == "/set":
                result = set_light(query["hub"], query["rgb"], query["bri"])
            elif url.path == "/get":
                result = get_light(query["hub"])
            elif url.path == "/tone":
                result = play_tone(query["hub"], query["id"], query.get("vol", 15))
            elif url.path == "/stop":
                result = stop_sound(query["hub"])
            elif url.path == "/presets":
                result = get_presets()
            elif url.path == "/preset":
                result = save_preset(query["hub"], query["name"], query.get("rgb"),
                                     query.get("bri"), reset=query.get("reset") == "1")
            elif url.path == "/apply":
                result = apply_preset(query["hub"], query["preset"])
            else:
                self._reply(PAGE.encode(), "text/html; charset=utf-8")
                return
        except Exception as error:
            result = error_response(error)
        self._reply(json.dumps(result, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def _reply(self, body, content_type, status=200, allow=None):
        try:
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
    addresses = [address.strip() for address in os.environ.get("AQARA_LISTEN_ADDRESSES", "127.0.0.1").split(",")]
    # Validate every entry before opening any socket. Empty strings bind all IPv4.
    for address in addresses:
        parsed = ipaddress.ip_address(address)
        if parsed.version != 4 or parsed.is_unspecified:
            raise ValueError("Listener muss eine konkrete IPv4-Adresse sein")
    port = int(os.environ.get("AQARA_PORT", "8765"))
    with ExitStack() as stack:
        servers = [stack.enter_context(Server((address, port), H)) for address in addresses]
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
