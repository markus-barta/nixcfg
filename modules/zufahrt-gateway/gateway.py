#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""HAUSV-916: Zufahrt (access gate) gateway for Howie (Amy's assistant), hsb1.

Accepts exactly two authenticated requests, POST /zufahrt (2 s pulse) and
POST /zufahrt5 (the existing 10 x 30 s hold-open), and turns them into the same
command message Node-RED on hsb1 already handles from its local broker
(topic scom/jhw22/smarthome, {"success": true, "command": "/zufahrt"}), so the
gate's own chain (link in 57, limiter, Shelly auto_off, hold-open timer) stays
the single place that switches the relay. The payloads are fixed here and never
taken from the request.

Request guards, in order: deadline (15 s per request; a request the watchdog cut
off never acts) -> framing (a complete header block, no body, no Transfer-Encoding,
no malformed header line, no duplicate Content-Length or Authorization) -> method
(POST) -> path (two actions) -> bearer token (sha256 compared in constant time;
hsb1 stores only the hash) -> cooldown (1 accepted call per 60 s across both
actions) -> MQTT QoS 1 publish, retain=false. The publish starts only when it can
finish (bounded at 5 s in total) inside the request deadline, so a request that
waited for the lock behind another one never switches after its client gave up.

Cooldown rules (gate review r1): the cooldown is reserved and fsynced BEFORE the
publish. It is released only when the failure provably happened before the
PUBLISH left this process (connect or CONNACK failure). Anything after that is
"delivery uncertain" (502) and keeps the cooldown. A corrupt or unreadable state
file fails closed (503) until an operator repairs it. The cooldown runs on the
monotonic clock. The stamp holds wall time, monotonic time and the boot id: a
restart within the same boot seeds from the monotonic stamp (a wall-clock step
changes nothing), and only after a reboot does the wall stamp count (a stamp in
the future means a full cooldown).

Reach (accepted exceptions, see default.nix): Headscale admits only
tag:paper-desk to this port; markus@/gerhard@ and local root can already publish
to the broker directly, so this service gives no principal new power.

Every request, including protocol errors and timeouts, is one JSON log line
(time, source, action, result, HTTP status); never the token, headers or the
raw request line. The log rotates at 4 MiB (one previous file kept).
"""
import argparse
import hashlib
import hmac
import http.server
import json
import math
import os
import re
import socket
import socketserver
import struct
import sys
import threading
import time
from pathlib import Path

ACTIONS = ("/zufahrt", "/zufahrt5")
TOPIC = "scom/jhw22/smarthome"
RATE_SECONDS = 60
LOG_ROTATE_BYTES = 4 * 1024 * 1024
MAX_CONNECTIONS = 8
REQUEST_DEADLINE = 15
PUBLISH_TIMEOUT = 5.0  # total, CONNECT to PUBACK
IP_FREEBIND = 15  # Linux; lets the service bind the tailnet address before tailscaled is up
CREDENTIALS_ROOT = "/run/credentials/"
STATE_ROOT = "/var/lib/"
# One raw header line: an RFC 9110 token name, a colon, printable ASCII or tab. No obs-fold,
# no space before the colon, no other bytes; anything else is refused before the parser's view counts.
HEADER_LINE = re.compile(rb"[!#$%&'*+\-.^_`|~0-9A-Za-z]+:[\t\x20-\x7e]*\r?\n")


class BeforeDelivery(Exception):
    """The PUBLISH never left this process; nothing can have been switched."""


class DeliveryUncertain(Exception):
    """The PUBLISH was (possibly) sent but not acknowledged."""


def confined(path, root):
    """Normalized path, required to stay below root. The inputs are the operator's (systemd's
    environment and the unit's arguments), never a request's; this keeps a typo from aiming elsewhere."""
    real = os.path.realpath(path)
    if not real.startswith(root):
        raise SystemExit(f"refusing a path outside {root}")
    return real


def read_credential(name):
    directory = os.environ.get("CREDENTIALS_DIRECTORY")
    if not directory:
        raise SystemExit(f"missing systemd credential directory for {name}")
    base = confined(directory, CREDENTIALS_ROOT)
    path = os.path.realpath(os.path.join(base, name))
    if not path.startswith(base + os.sep):
        raise SystemExit("credential name leaves the credential directory")
    return Path(path).read_text()


def parse_env(text):
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.removeprefix("export ").strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


def recv_exact(sock, count, left):
    data = b""
    while len(data) < count:
        sock.settimeout(left())
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise ConnectionError("broker closed the connection")
        data += chunk
    return data


def mqtt_publish(host, port, user, password, topic, payload, timeout=PUBLISH_TIMEOUT):
    """MQTT 3.1.1 CONNECT, PUBLISH QoS 1 retain=false, PUBACK, DISCONNECT.

    timeout bounds the whole exchange, not each socket call. Raises BeforeDelivery
    if the PUBLISH was never sent, DeliveryUncertain if it may have been sent but
    was not acknowledged. Returns normally once PUBACK for our packet id arrived;
    a failing DISCONNECT after that is ignored."""
    end = time.monotonic() + timeout

    def left():
        remaining = end - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("mqtt deadline")
        return remaining

    def text(value):
        data = value.encode()
        return struct.pack("!H", len(data)) + data

    def length(value):
        out = bytearray()
        while True:
            digit, value = value % 128, value // 128
            out.append(digit | (0x80 if value else 0))
            if not value:
                return bytes(out)

    connect = text("MQTT") + bytes([4, 0xC2]) + struct.pack("!H", 30)  # level 4; user+pass+clean
    connect += text(f"zufahrt-gw-{os.getpid()}") + text(user) + text(password)
    packet_id = 1
    publish = text(topic) + struct.pack("!H", packet_id) + payload
    try:
        sock = socket.create_connection((host, port), timeout=left())
    except OSError as error:
        raise BeforeDelivery(f"connect: {type(error).__name__}") from None
    with sock:
        try:
            sock.settimeout(left())
            sock.sendall(bytes([0x10]) + length(len(connect)) + connect)
            connack = recv_exact(sock, 4, left)
        except OSError as error:
            raise BeforeDelivery(f"connack: {type(error).__name__}") from None
        # CONNACK: type 0x20, remaining length 2, flags only bit 0 (session present), code 0.
        if connack[0] != 0x20 or connack[1] != 0x02 or connack[2] & 0xFE or connack[3] != 0:
            raise BeforeDelivery("connack rejected or malformed")
        try:
            sock.settimeout(left())
        except OSError as error:
            raise BeforeDelivery(f"publish: {type(error).__name__}") from None
        try:
            # 0x32 = PUBLISH, QoS 1, DUP 0, RETAIN 0. A retained Switch command reopens
            # the gate on every reconnect (AUTOMATIONS.md); this message is never retained.
            sock.sendall(bytes([0x32]) + length(len(publish)) + publish)
            puback = recv_exact(sock, 4, left)
        except OSError as error:
            raise DeliveryUncertain(f"puback: {type(error).__name__}") from None
        if puback[0] != 0x40 or puback[1] != 0x02 or struct.unpack("!H", puback[2:4])[0] != packet_id:
            raise DeliveryUncertain("puback malformed")
        try:
            sock.sendall(b"\xe0\x00")
        except OSError:
            pass  # delivered and acknowledged; the disconnect is courtesy only


def current_boot_id():
    try:
        return Path("/proc/sys/kernel/random/boot_id").read_text().strip() or "-"
    except OSError:
        return "-"  # unknown: a restart falls back to the wall stamp


def fsync_write(path, text):
    tmp = path.with_suffix(".tmp")
    with tmp.open("w") as handle:
        handle.write(text)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


class Gateway:
    def __init__(self, state_dir, token_sha256, mqtt, publish=mqtt_publish, wall=time.time, mono=time.monotonic,
                 boot_id=current_boot_id):
        self.state_dir = Path(state_dir)
        self.token_sha256 = token_sha256.strip().lower()
        if len(self.token_sha256) != 64 or any(c not in "0123456789abcdef" for c in self.token_sha256):
            raise SystemExit("token hash must be 64 lowercase hex characters")
        self.mqtt, self.publish, self.wall, self.mono = mqtt, publish, wall, mono
        self.boot = boot_id()
        if not self.boot or any(c.isspace() for c in self.boot):
            self.boot = "-"
        self.state_file = self.state_dir / "last-accepted"
        self.log_file = self.state_dir / "calls.jsonl"
        self.lock = threading.Lock()
        self.broken = None
        self.cool_until = self.mono()
        self.seed()

    def seed(self):
        """Seed the monotonic cooldown from the persisted stamp ("WALL MONO BOOT")."""
        try:
            raw = self.state_file.read_text()
        except FileNotFoundError:
            return
        except OSError as error:
            self.broken = f"state unreadable: {type(error).__name__}"
            return
        fields = raw.split()
        try:
            wall_stamp, mono_stamp = float(fields[0]), float(fields[1])
        except (IndexError, ValueError):
            self.broken = "state corrupt"
            return
        if (len(fields) != 3 or not math.isfinite(wall_stamp) or wall_stamp <= 0
                or not math.isfinite(mono_stamp) or mono_stamp < 0):
            self.broken = "state corrupt"
            return
        if fields[2] == self.boot and self.boot != "-":
            now, stamp = self.mono(), mono_stamp  # same boot: the monotonic clock is authoritative
        else:
            now, stamp = self.wall(), wall_stamp  # after a reboot (or unknown boot): the wall stamp
        remaining = stamp + RATE_SECONDS - now
        if stamp > now + 1:
            remaining = RATE_SECONDS  # a stamp from the future: assume it was just now
        self.cool_until = self.mono() + min(max(remaining, 0.0), RATE_SECONDS)

    def authorized(self, header):
        if not header or not header.startswith("Bearer "):
            return False
        presented = hashlib.sha256(header[len("Bearer "):].strip().encode()).hexdigest()
        return hmac.compare_digest(presented, self.token_sha256)

    def log(self, source, action, result, status):
        line = json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(self.wall())),
                           "source": source, "action": action, "result": result, "http": status},
                          sort_keys=True)
        print(line, flush=True)
        try:
            if self.log_file.exists() and self.log_file.stat().st_size > LOG_ROTATE_BYTES:
                os.replace(self.log_file, self.log_file.with_suffix(".jsonl.1"))
            with self.log_file.open("a") as handle:
                handle.write(line + "\n")
        except OSError:
            pass  # the journal line above is the fallback record

    def handle(self, method, path, authorization, source, expired=lambda margin=0.0: False, lock_timeout=None):
        """Returns (status, body). Decides and logs exactly once per request.

        expired(margin) is the caller's hard request deadline: a request that could
        not finish its publish before it (for instance after waiting for the lock)
        is refused and never published."""
        action = path if path in ACTIONS else "-"
        if method != "POST":
            return self.finish(source, action, 405, {"error": "method not allowed"}, "refused-method")
        if action == "-":
            return self.finish(source, action, 404, {"error": "not found"}, "refused-path")
        if not self.authorized(authorization):
            return self.finish(source, action, 401, {"error": "unauthorized"}, "refused-auth")
        if not self.lock.acquire(timeout=-1 if lock_timeout is None else max(0.0, lock_timeout)):
            return self.finish(source, action, 503, {"error": "busy"}, "refused-busy")
        try:
            if expired(PUBLISH_TIMEOUT + 1):
                return self.finish(source, action, 408, {"error": "request expired"}, "refused-expired")
            if self.broken:
                return self.finish(source, action, 503, {"error": "gateway state needs an operator"}, f"refused-{self.broken}")
            wait = self.cool_until - self.mono()
            if wait > 0:
                return self.finish(source, action, 429, {"error": "rate limited", "retry_after": math.ceil(wait)}, "refused-rate")
            previous = self.cool_until
            try:
                fsync_write(self.state_file, f"{self.wall():.3f} {self.mono():.3f} {self.boot}\n")  # reserve durably before delivery
            except OSError as error:
                return self.finish(source, action, 503, {"error": "gateway state not writable"}, f"refused-state:{type(error).__name__}")
            self.cool_until = self.mono() + RATE_SECONDS
            payload = json.dumps({"success": True, "command": action, "source": "howie"}).encode()
            if expired(PUBLISH_TIMEOUT + 1):  # the reservation itself was slow: nothing was sent yet
                self.release(previous)
                return self.finish(source, action, 408, {"error": "request expired"}, "refused-expired")
            try:
                self.publish(self.mqtt["host"], self.mqtt["port"], self.mqtt["user"], self.mqtt["password"], TOPIC, payload)
            except BeforeDelivery as error:
                self.release(previous)
                return self.finish(source, action, 502, {"error": "gate command not delivered"}, f"failed-before-delivery:{error}")
            except Exception as error:
                # Possibly delivered: the cooldown stays reserved.
                return self.finish(source, action, 502, {"error": "gate command delivery uncertain"}, f"failed-uncertain:{type(error).__name__}")
            return self.finish(source, action, 202, {"result": "accepted", "action": action.lstrip("/")}, "accepted")
        finally:
            self.lock.release()

    def release(self, previous):
        """Undo a reservation whose command provably never left this process.

        A reservation is only made once the previous cooldown has expired, so the
        undo is: no cooldown in memory, and no stamp on disk."""
        self.cool_until = previous
        try:
            self.state_file.unlink(missing_ok=True)
            directory = os.open(self.state_dir, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except OSError:
            self.cool_until = self.mono() + RATE_SECONDS
            self.broken = "state not restorable"  # keep the conservative reservation and fail closed

    def finish(self, source, action, status, body, result):
        self.log(source, action, result, status)
        return status, body


class LineTracker:
    """The request's read side; keeps the raw lines (one request per connection),
    so a header block that ended at EOF instead of an empty line is told apart from
    a complete one, and every raw header line can be checked on its own."""
    def __init__(self, raw):
        self.raw, self.last, self.lines = raw, b"", []

    def readline(self, *args):
        self.last = self.raw.readline(*args)
        self.lines.append(self.last)
        return self.last

    def __getattr__(self, name):
        return getattr(self.raw, name)


def make_handler(gateway):
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "zufahrt-gw"
        sys_version = ""
        timeout = 5  # per socket operation; the whole request is bounded by REQUEST_DEADLINE

        def setup(self):
            super().setup()
            self.rfile = LineTracker(self.rfile)
            self.logged = False
            self.aborted = False
            self.deadline = time.monotonic() + REQUEST_DEADLINE
            self.watchdog = threading.Timer(REQUEST_DEADLINE, self.abort)
            self.watchdog.daemon = True
            self.watchdog.start()

        def finish(self):
            self.watchdog.cancel()
            super().finish()

        def expired(self, margin=0.0):
            return self.aborted or time.monotonic() + margin >= self.deadline

        def abort(self):
            # Flag first: shutting the socket down makes the header parser see EOF and
            # treat an unfinished request as complete; such a request must never act.
            self.aborted = True
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        def source(self):
            return self.client_address[0] if self.client_address else "-"

        def send_error(self, code, message=None, explain=None):
            # Parser and protocol errors (400, 414, 431, 501, 505 ...): logged, never the raw line.
            if not self.logged:
                self.logged = True
                gateway.log(self.source(), "-", "refused-protocol", code)
            super().send_error(code, message, explain)

        def log_error(self, format, *args):
            if format.startswith("Request timed out") and not self.logged:
                self.logged = True
                gateway.log(self.source(), "-", "refused-timeout", 408)

        def log_message(self, *_args):
            pass  # one structured line per request comes from Gateway.log

        def respond(self, method):
            self.logged = True
            action = self.path if self.path in ACTIONS else "-"
            lengths = self.headers.get_all("Content-Length") or []
            auths = self.headers.get_all("Authorization") or []
            if self.expired():
                status, body = 408, {"error": "request expired"}
                gateway.log(self.source(), action, "refused-timeout", status)
            elif self.rfile.last not in (b"\r\n", b"\n"):
                # The header block ended at EOF (half-closed or cut off), not at an empty line.
                status, body = 400, {"error": "incomplete request"}
                gateway.log(self.source(), action, "refused-incomplete", status)
            elif self.headers.defects or not all(HEADER_LINE.fullmatch(line) for line in self.rfile.lines[1:-1]):
                # A malformed line: the parser may have stopped there and hidden every header after it.
                status, body = 400, {"error": "malformed headers"}
                gateway.log(self.source(), action, "refused-malformed", status)
            elif (self.headers.get_all("Transfer-Encoding") or len(lengths) > 1 or len(auths) > 1
                  or any(v.strip() != "0" for v in lengths)):
                status, body = 400, {"error": "request body or duplicate headers not allowed"}
                gateway.log(self.source(), action, "refused-framing", status)
            else:
                status, body = gateway.handle(method, self.path, auths[0] if auths else None, self.source(),
                                              expired=self.expired, lock_timeout=self.deadline - time.monotonic())
            data = json.dumps(body).encode()
            self.close_connection = True
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            self.respond("POST")

        def do_GET(self):
            self.respond("GET")

        def do_HEAD(self):
            self.respond("HEAD")

        def do_PUT(self):
            self.respond("PUT")

        def do_DELETE(self):
            self.respond("DELETE")

        def do_PATCH(self):
            self.respond("PATCH")

    return Handler


class GatewayServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """Threaded (no single slow client blocks the gate), capped at MAX_CONNECTIONS."""
    daemon_threads = True

    def __init__(self, address, handler):
        self.slots = threading.BoundedSemaphore(MAX_CONNECTIONS)
        super().__init__(address, handler)

    def server_bind(self):
        if hasattr(socket, "IPPROTO_IP"):
            try:
                self.socket.setsockopt(socket.IPPROTO_IP, IP_FREEBIND, 1)
            except OSError:
                pass
        super().server_bind()

    def handle_error(self, request, client_address):
        # One line instead of a traceback (typically: the reply to a cut-off client failed).
        error = sys.exc_info()[1]
        print(json.dumps({"event": "connection-error", "source": client_address[0] if client_address else "-",
                          "error": type(error).__name__}), flush=True)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)  # over capacity: close at once, nothing parsed
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--mqtt-host", default="127.0.0.1")
    parser.add_argument("--mqtt-port", type=int, default=1883)
    args = parser.parse_args(argv)
    env = parse_env(read_credential("mqtt-env"))
    if not env.get("MQTT_USER") or not env.get("MQTT_PASS"):
        raise SystemExit("mqtt-env credential lacks MQTT_USER/MQTT_PASS")
    gateway = Gateway(confined(args.state_dir, STATE_ROOT), read_credential("token-sha256"),
                      {"host": args.mqtt_host, "port": args.mqtt_port,
                       "user": env["MQTT_USER"], "password": env["MQTT_PASS"]})
    server = GatewayServer((args.listen, args.port), make_handler(gateway))
    print(json.dumps({"event": "listening", "listen": args.listen, "port": args.port,
                      "state": gateway.broken or "ok"}), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main(sys.argv[1:])
