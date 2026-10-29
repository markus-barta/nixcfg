#!/usr/bin/env python3
"""OPS-496: Aqara light/sound API, ported from the verified local prototype.

GET /set?hub=plug&rgb=FF8C28&bri=10, /get?hub=plug,
/tone?hub=plug&id=27&vol=10, /stop?hub=plug. The second hub is round.
CLI: set <hub> <RRGGBB> <brightness>, get <hub>, tone <hub> <id> [vol], stop <hub>.
The handshake token stays in memory; no library payloads or exceptions are logged.
"""

import fcntl
import ipaddress
import json
import logging
import os
import random
import re
import sys
import threading
import time
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from miio import DeviceError
from miio.miioprotocol import MiIOProtocol

# A child logger can emit payloads even when the parent's level is raised.
# Sink the whole library subtree as well as suppressing its normal messages.
_miio_log = logging.getLogger("miio")
_miio_log.setLevel(logging.CRITICAL)
_miio_log.addHandler(logging.NullHandler())
_miio_log.propagate = False

# Neutral API handles: no hardware identifiers from the prototype in public code.
HUBS = {"plug": "192.168.1.106", "round": "192.168.1.108"}
TIMEOUT = 1.5
ATTEMPTS = 4
ID_FILE = os.path.join(os.environ.get("STATE_DIRECTORY", "/var/lib/aqara-nightlight"), "msgid")
ALLOWED_NETWORKS = tuple(ipaddress.ip_network(n) for n in (
    "127.0.0.0/8", "::1/128", "192.168.1.0/24", "100.64.0.0/10",
))

# Built-in ringtones (IDs confirmed by the hub's own get_music_info [0]/[1]/[2]; names from Xiaomi docs)
TONES = [
    ("Alarm", [(0, "Polizei 1"), (1, "Polizei 2"), (2, "Unfall"), (3, "Countdown"), (4, "Geist"),
               (5, "Scharfschütze"), (6, "Gefecht"), (7, "Fliegeralarm"), (8, "Hundebellen")]),
    ("Türklingel", [(10, "Klingel"), (11, "Klopfen"), (12, "Lustig"), (13, "Wecker-Klingel")]),
    ("Wecker", [(20, "MiMix"), (21, "Enthusiastisch"), (22, "Gitarre klassisch"), (23, "Eiswelt-Klavier"),
                (24, "Freizeit"), (25, "Kindheit"), (26, "Morgenbach"), (27, "Spieluhr"), (28, "Orange"),
                (29, "Denker")]),
]


_dev = {}
_locks = {name: threading.Lock() for name in HUBS}
_idlock = threading.Lock()


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
    raise RuntimeError(f"Hub {name} antwortet nicht ({attempts} Versuche)")


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
    vol = max(0, min(100, int(vol)))
    if tid not in {i for _, items in TONES for i, _ in items}:
        raise ValueError("Unbekannter Ton")
    reply, attempts = call(name, "play_music_new", [str(tid), vol])
    return {"ok": True, "hub": name, "cmd": "tone", "id": tid, "vol": vol,
            "reply": reply, "versuche": attempts}


def stop_sound(name):
    reply, attempts = call(name, "set_sound_playing", ["off"])
    return {"ok": True, "hub": name, "cmd": "stop", "reply": reply, "versuche": attempts}


def _tone_html():
    out = []
    for group, items in TONES:
        out.append(f"<div class=grp>{group}</div>")
        out += [f'<button class=tone data-t="{i}" title="ID {i}">{name} <small>{i}</small></button>'
                for i, name in items]
    return "".join(out)


PAGE = """<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width">
<title>Nachtlicht</title><style>body{font-family:system-ui;background:#111;color:#eee;max-width:460px;margin:2em auto;padding:0 1em}
label{display:block;margin:1.2em 0 .3em}input[type=range]{width:100%}button{margin:.3em .3em 0 0;padding:.6em 1em;border:0;border-radius:8px;cursor:pointer}
h3{margin:1.6em 0 .2em;border-top:1px solid #333;padding-top:1em}.grp{color:#999;font-size:13px;margin:.8em 0 0}
button.tone{background:#2a2a3a;color:#eee;padding:.5em .8em}button.tone small{color:#888}#stop{background:#b33;color:#fff;font-weight:bold}
#st{margin-top:1em;padding:.6em .8em;border-radius:8px;background:#222;min-height:1.3em}#st.ok{background:#173d22}#st.bad{background:#5a1a1a}#st.busy{background:#3a3415}
#again{background:#e0b030;color:#000}#log{font:12px monospace;white-space:pre-wrap;color:#9c9;margin-top:1em;max-height:14em;overflow:auto}</style>
<h2>Aqara Nachtlicht</h2>
<label>Hub <select id=hub><option>plug<option>round</select></label>
<div id=st>Bereit.</div><button id=again disabled>Nochmal senden</button>
<label>Farbe <input type=color id=col value="#ff8c28"></label>
<div><button data-c="#ff8c28" style="background:#ff8c28">Warmweiß</button><button data-c="#ffb46b" style="background:#ffb46b">Hellwarm</button><button data-c="#ff5a00" style="background:#ff5a00">Orange</button><button data-c="#ff0000" style="background:#f00">Rot</button><button data-c="#0000ff" style="background:#00f;color:#fff">Blau</button><button data-c="#ffffff" style="background:#fff">Weiß</button></div>
<label>Helligkeit <b id=bv>10</b> %<input type=range id=bri min=0 max=100 value=10></label>
<button id=nightlight>Nachtlicht 10 %</button><button id=off>Aus</button><button id=rd>Status lesen</button>
<h3>Töne</h3>
<label>Lautstärke <b id=vv>15</b> %<input type=range id=vol min=1 max=100 value=15></label>
<button id=stop>■ Stop</button>
__TONES__
<div id=log></div>
<script>
const $=id=>document.getElementById(id);let t,last=null,seq=0;
function log(x){$('log').textContent=JSON.stringify(x)+"\\n"+$('log').textContent}
function status(cls,txt){$('st').className=cls;$('st').textContent=txt}
async function go(path,params,label){
 last={path,params,label};$('again').disabled=false;const my=++seq;
 status('busy','Sende: '+label+' …');
 try{const r=await fetch(path+'?'+new URLSearchParams(params));const j=await r.json();log(j);
  if(my!==seq)return;
  if(j.ok)status('ok','✓ '+label+' – angekommen'+(j.versuche>1?' (nach '+j.versuche+' Versuchen)':''));
  else status('bad','✗ '+label+' – FEHLER: '+j.error+'  → „Nochmal senden“');
 }catch(e){if(my===seq)status('bad','✗ '+label+' – keine Verbindung zum Nachtlicht-Server')}}
$('again').onclick=()=>{if(last)go(last.path,last.params,last.label)};
const hub=()=>$('hub').value;
function send(){go('/set',{hub:hub(),rgb:$('col').value.slice(1),bri:$('bri').value},'Licht '+$('col').value+' '+$('bri').value+'% ('+hub()+')')}
function later(){clearTimeout(t);t=setTimeout(send,250)}
$('bri').oninput=()=>{$('bv').textContent=$('bri').value;later()};
$('col').oninput=later;
$('vol').oninput=()=>{$('vv').textContent=$('vol').value};
document.querySelectorAll('[data-c]').forEach(b=>b.onclick=()=>{$('col').value=b.dataset.c;send()});
document.querySelectorAll('[data-t]').forEach(b=>b.onclick=()=>go('/tone',{hub:hub(),id:b.dataset.t,vol:$('vol').value},'Ton „'+b.firstChild.textContent.trim()+'“ ('+hub()+')'));
$('stop').onclick=()=>go('/stop',{hub:hub()},'Stop ('+hub()+')');
$('nightlight').onclick=()=>{$('col').value='#ff8c28';$('bri').value=10;$('bv').textContent=10;send()};
$('off').onclick=()=>{$('bri').value=0;$('bv').textContent=0;send()};
$('rd').onclick=()=>go('/get',{hub:hub()},'Status lesen ('+hub()+')');
</script>""".replace("__TONES__", _tone_html())



def error_response(error):
    # Fixed messages only, including DeviceError and unexpected library failures.
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


class H(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if not allowed_peer(self.client_address[0]):
            self.send_error(403)
            return
        url = urlparse(self.path)
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
            else:
                self._reply(PAGE.encode(), "text/html; charset=utf-8")
                return
        except Exception as error:
            result = error_response(error)
        self._reply(json.dumps(result, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def _reply(self, body, content_type):
        try:
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


class Server(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # BaseServer otherwise prints a traceback with arbitrary exception data.
        print("aqara-nightlight: HTTP request failed", file=sys.stderr, flush=True)


def serve():
    addresses = os.environ.get("AQARA_LISTEN_ADDRESSES", "127.0.0.1").split(",")
    port = int(os.environ.get("AQARA_PORT", "8765"))
    with ExitStack() as stack:
        servers = [stack.enter_context(Server((address, port), H)) for address in addresses]
        for server in servers[:-1]:
            threading.Thread(target=server.serve_forever, daemon=True).start()
        print(f"aqara-nightlight: UI/API listening on {','.join(addresses)}:{port}", flush=True)
        servers[-1].serve_forever()


def main(args):
    try:
        if not args:
            serve()
            return 0
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
