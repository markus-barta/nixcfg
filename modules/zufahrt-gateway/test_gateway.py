#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""HAUSV-916: tests for the Zufahrt gateway (offline; a fake broker and fake clocks)."""
import hashlib
import http.client
import importlib.util
import json
import socket
import struct
import tempfile
import threading
import time
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("gateway", Path(__file__).with_name("gateway.py"))
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)

TOKEN = "a" * 64
TOKEN_SHA = hashlib.sha256(TOKEN.encode()).hexdigest()
MQTT = {"host": "127.0.0.1", "port": 1, "user": "u", "password": "p"}


class Clock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


class Recorder:
    def __init__(self, error=None, on_call=None):
        self.calls, self.error, self.on_call = [], error, on_call

    def __call__(self, host, port, user, password, topic, payload):
        if self.on_call:
            self.on_call()
        self.calls.append((topic, json.loads(payload)))
        if self.error:
            raise self.error


class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory(prefix="zufahrt-gw-")
        self.addCleanup(self.dir.cleanup)
        self.state = Path(self.dir.name)
        self.wall, self.mono, self.publish = Clock(1_000_000.0), Clock(500.0), Recorder()
        self.boot = "boot-a"
        self.gw = self.make()

    def make(self, publish=None):
        return gateway.Gateway(self.dir.name, TOKEN_SHA + "\n", MQTT, publish=publish or self.publish,
                               wall=self.wall, mono=self.mono, boot_id=lambda: self.boot)

    def advance(self, seconds):
        self.wall.now += seconds
        self.mono.now += seconds

    def call(self, gw=None, method="POST", path="/zufahrt", auth=f"Bearer {TOKEN}", source="100.64.0.15"):
        return (gw or self.gw).handle(method, path, auth, source)

    def logged(self):
        return [json.loads(line) for line in (self.state / "calls.jsonl").read_text().splitlines()]

    def test_accepted_publishes_only_the_fixed_command(self):
        for path in ("/zufahrt", "/zufahrt5"):
            with self.subTest(path=path):
                self.advance(61)
                self.assertEqual(self.call(path=path), (202, {"result": "accepted", "action": path.lstrip("/")}))
                self.assertEqual(self.publish.calls[-1], ("scom/jhw22/smarthome",
                                                          {"success": True, "command": path, "source": "howie"}))

    def test_guards_refuse_before_publishing(self):
        cases = [("GET", "/zufahrt", f"Bearer {TOKEN}", 405), ("POST", "/smartlock", f"Bearer {TOKEN}", 404),
                 ("POST", "/zufahrt/", f"Bearer {TOKEN}", 404), ("POST", "/zufahrt?x=1", f"Bearer {TOKEN}", 404),
                 ("POST", "/zufahrt", None, 401), ("POST", "/zufahrt", "Bearer wrong", 401),
                 ("POST", "/zufahrt", TOKEN, 401), ("POST", "/zufahrt", f"Basic {TOKEN}", 401)]
        for method, path, auth, expected in cases:
            with self.subTest(method=method, path=path, auth=auth):
                self.assertEqual(self.call(method=method, path=path, auth=auth)[0], expected)
        self.assertEqual(self.publish.calls, [])
        self.assertFalse((self.state / "last-accepted").exists())

    def test_cooldown_is_reserved_durably_before_the_publish(self):
        seen = []
        publish = Recorder(on_call=lambda: seen.append((self.state / "last-accepted").read_text()))
        gw = self.make(publish)
        self.assertEqual(self.call(gw)[0], 202)
        self.assertEqual(seen, [f"{self.wall.now:.3f} {self.mono.now:.3f} boot-a\n"])

    def test_cooldown_one_per_minute_and_survives_restart(self):
        self.assertEqual(self.call()[0], 202)
        self.advance(30)
        status, body = self.call(path="/zufahrt5")
        self.assertEqual((status, body["retry_after"]), (429, 30))
        self.assertEqual(self.call(self.make())[0], 429)  # restart: seeded from the stamp
        self.advance(30)
        self.assertEqual(self.call(self.make())[0], 202)
        self.assertEqual(len(self.publish.calls), 2)

    def test_wall_clock_jump_forward_does_not_bypass_the_cooldown(self):
        self.assertEqual(self.call()[0], 202)
        self.wall.now += 10_000  # wall jumps, monotonic does not
        self.assertEqual(self.call()[0], 429)

    def test_wall_clock_jump_and_restart_in_the_same_boot_does_not_bypass_the_cooldown(self):
        self.assertEqual(self.call()[0], 202)
        self.wall.now += 10_000
        self.assertEqual(self.call(self.make())[0], 429)  # restarted: the monotonic stamp decides
        self.mono.now += 61
        self.assertEqual(self.call(self.make())[0], 202)

    def test_after_a_reboot_the_wall_stamp_seeds_the_cooldown(self):
        self.assertEqual(self.call()[0], 202)
        self.boot, self.mono.now, self.wall.now = "boot-b", 3.0, self.wall.now + 20  # rebooted 20 s later
        gw = self.make()
        status, body = self.call(gw)
        self.assertEqual((status, body["retry_after"]), (429, 40))
        self.boot = "-"  # unknown boot id: never trusted as "the same boot"
        (self.state / "last-accepted").write_text(f"{self.wall.now:.3f} {self.mono.now + 900:.3f} -\n")
        self.assertEqual(self.call(self.make())[0], 429)

    def test_wall_clock_jump_backward_does_not_lock_out_beyond_a_cooldown(self):
        self.assertEqual(self.call()[0], 202)
        self.wall.now -= 10_000
        self.mono.now += 61
        self.assertEqual(self.call()[0], 202)

    def test_future_stamp_at_restart_means_a_full_cooldown(self):
        (self.state / "last-accepted").write_text(f"{self.wall.now + 5000:.3f} 1.000 boot-old\n")
        gw = self.make()
        self.assertEqual(self.call(gw)[0], 429)
        self.mono.now += 61
        self.assertEqual(self.call(gw)[0], 202)
        (self.state / "last-accepted").write_text(f"{self.wall.now:.3f} {self.mono.now + 5000:.3f} boot-a\n")
        gw = self.make()  # same boot, monotonic stamp from the future
        self.assertEqual(self.call(gw)[0], 429)
        self.mono.now += 61
        self.assertEqual(self.call(gw)[0], 202)

    def test_corrupt_or_non_finite_state_fails_closed(self):
        for text in ("garbage", "nan", "inf", "-inf", "0", "-5", "", "1000000.000", "1000000.000 500.000",
                     "1000000.000 500.000 boot-a x", "1000000.000 nan boot-a", "1000000.000 -1 boot-a", "0 500.000 boot-a"):
            with self.subTest(text=text):
                (self.state / "last-accepted").write_text(text)
                gw = self.make()
                self.assertEqual(self.call(gw)[0], 503)
        self.assertEqual(self.publish.calls, [])

    def test_refused_calls_do_not_consume_the_cooldown(self):
        self.assertEqual(self.call(auth="Bearer wrong")[0], 401)
        self.assertEqual(self.call()[0], 202)

    def test_failure_before_delivery_releases_the_cooldown(self):
        gw = self.make(Recorder(error=gateway.BeforeDelivery("connect: ConnectionRefusedError")))
        self.assertEqual(self.call(gw)[0], 502)
        self.assertFalse((self.state / "last-accepted").exists())
        gw.publish = self.publish
        self.assertEqual(self.call(gw)[0], 202)

    def test_uncertain_delivery_keeps_the_cooldown(self):
        for error in (gateway.DeliveryUncertain("puback: TimeoutError"), RuntimeError("anything else")):
            with self.subTest(error=error):
                self.advance(61)
                gw = self.make(Recorder(error=error))
                self.assertEqual(self.call(gw)[0], 502)
                gw.publish = self.publish
                self.assertEqual(self.call(gw)[0], 429)

    def test_unwritable_state_refuses_without_publishing(self):
        self.state.chmod(0o500)
        self.addCleanup(self.state.chmod, 0o700)
        self.assertEqual(self.call()[0], 503)
        self.assertEqual(self.publish.calls, [])

    def test_every_call_is_logged_without_the_token(self):
        self.call(auth="Bearer wrong")
        self.call()
        self.call(method="GET")
        rows = self.logged()
        self.assertEqual([(r["action"], r["result"], r["http"]) for r in rows],
                         [("/zufahrt", "refused-auth", 401), ("/zufahrt", "accepted", 202), ("/zufahrt", "refused-method", 405)])
        self.assertTrue(all(r["source"] == "100.64.0.15" and r["ts"] for r in rows))
        text = (self.state / "calls.jsonl").read_text()
        self.assertNotIn(TOKEN, text)
        self.assertNotIn("wrong", text)

    def test_log_rotates(self):
        (self.state / "calls.jsonl").write_text("x" * (gateway.LOG_ROTATE_BYTES + 1))
        self.call(auth="Bearer wrong")
        self.assertTrue((self.state / "calls.jsonl.1").exists())
        self.assertEqual(len(self.logged()), 1)

    def test_a_request_past_its_deadline_is_refused_under_the_lock(self):
        margins = []

        def expired(margin=0.0):
            margins.append(margin)
            return True
        self.assertEqual(self.gw.handle("POST", "/zufahrt", f"Bearer {TOKEN}", "100.64.0.15", expired=expired)[0], 408)
        self.assertEqual(self.publish.calls, [])
        self.assertEqual(margins, [gateway.PUBLISH_TIMEOUT + 1])  # the publish must fit before the deadline
        self.assertFalse((self.state / "last-accepted").exists())
        self.assertEqual(self.call()[0], 202)  # nothing was consumed

    def test_a_slow_reservation_past_the_deadline_never_publishes(self):
        deadline = self.mono.now + 15

        def slow(path, text):
            self.advance(20)
            path.write_text(text)
        original = gateway.fsync_write
        gateway.fsync_write = slow
        self.addCleanup(setattr, gateway, "fsync_write", original)
        status, _ = self.gw.handle("POST", "/zufahrt", f"Bearer {TOKEN}", "100.64.0.15",
                                   expired=lambda margin=0.0: self.mono.now + margin >= deadline)
        self.assertEqual(status, 408)
        self.assertEqual(self.publish.calls, [])
        self.assertFalse((self.state / "last-accepted").exists())  # released: nothing was sent
        self.assertEqual(self.call()[0], 202)

    def test_malformed_token_hash_is_refused_at_start(self):
        with self.assertRaises(SystemExit):
            gateway.Gateway(self.dir.name, "not-a-hash", MQTT)

    def test_env_parsing(self):
        env = gateway.parse_env('# c\nexport MQTT_USER="user"\nMQTT_PASS=p=w\n\nX\n')
        self.assertEqual((env["MQTT_USER"], env["MQTT_PASS"]), ("user", "p=w"))


class FakeBroker(threading.Thread):
    """One MQTT session: records packets; replies are configurable per test."""
    def __init__(self, connack=bytes([0x20, 0x02, 0x00, 0x00]), puback=None, close_after_publish=False, dribble=0.0):
        super().__init__(daemon=True)
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        self.connack, self.puback, self.close_after_publish, self.packets = connack, puback, close_after_publish, []
        self.dribble = dribble

    def read_packet(self, conn):
        header = conn.recv(1)
        if not header:
            return None
        multiplier, length = 1, 0
        while True:
            byte = conn.recv(1)[0]
            length += (byte & 0x7F) * multiplier
            multiplier *= 128
            if not byte & 0x80:
                break
        body = b""
        while len(body) < length:
            body += conn.recv(length - len(body))
        return header[0], body

    def run(self):
        try:
            self.serve()
        finally:
            self.sock.close()

    def serve(self):
        conn, _ = self.sock.accept()
        with conn:
            while (packet := self.read_packet(conn)) is not None:
                self.packets.append(packet)
                kind = packet[0] >> 4
                if kind == 1:
                    conn.sendall(self.connack)
                    if self.connack[3:4] != b"\x00":
                        return
                elif kind == 3:
                    if self.close_after_publish:
                        return
                    pid = packet[1][2 + struct.unpack("!H", packet[1][:2])[0]:][:2]
                    reply = self.puback if self.puback is not None else bytes([0x40, 0x02]) + pid
                    if self.dribble:
                        try:
                            for byte in reply:  # each byte in time, the whole reply too late
                                time.sleep(self.dribble)
                                conn.sendall(bytes([byte]))
                        except OSError:
                            return
                    else:
                        conn.sendall(reply)
                elif kind == 14:
                    return


class MqttTests(unittest.TestCase):
    def publish(self, broker, password="pass"):
        broker.start()
        try:
            gateway.mqtt_publish("127.0.0.1", broker.port, "user", password, "scom/jhw22/smarthome", b'{"x":1}', timeout=2)
        finally:
            broker.join(5)

    def test_publish_is_qos1_not_retained_with_exact_topic_and_payload(self):
        broker = FakeBroker()
        self.publish(broker)
        kinds = [p[0] for p in broker.packets]
        connect = broker.packets[0][1]
        self.assertEqual(connect[:7], b"\x00\x04MQTT\x04")
        self.assertEqual(connect[7] & 0xC2, 0xC2)  # username, password, clean session
        self.assertEqual(kinds[1], 0x32)  # PUBLISH, QoS 1, retain 0, dup 0
        body = broker.packets[1][1]
        topic_len = struct.unpack("!H", body[:2])[0]
        self.assertEqual(body[2:2 + topic_len], b"scom/jhw22/smarthome")
        self.assertEqual(body[2 + topic_len + 2:], b'{"x":1}')
        self.assertEqual(kinds[-1], 0xE0)  # DISCONNECT

    def test_connect_failures_are_before_delivery(self):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        with self.assertRaises(gateway.BeforeDelivery):
            gateway.mqtt_publish("127.0.0.1", port, "u", "p", "t", b"x", timeout=1)
        for connack in (bytes([0x20, 0x02, 0x00, 0x05]), bytes([0x20, 0x03, 0x00, 0x00]), bytes([0x20, 0x02, 0x02, 0x00]),
                        bytes([0x21, 0x02, 0x00, 0x00])):
            with self.subTest(connack=connack), self.assertRaises(gateway.BeforeDelivery):
                self.publish(FakeBroker(connack=connack))

    def test_the_timeout_bounds_the_whole_exchange(self):
        with socket.socket() as silent:  # accepts the TCP connection, never answers CONNECT
            silent.bind(("127.0.0.1", 0))
            silent.listen(1)
            started = time.monotonic()
            with self.assertRaises(gateway.BeforeDelivery):
                gateway.mqtt_publish("127.0.0.1", silent.getsockname()[1], "u", "p", "t", b"x", timeout=0.5)
            self.assertLess(time.monotonic() - started, 1.5)
        broker = FakeBroker(dribble=0.3)  # every recv() returns within 0.3 s; the PUBACK as a whole takes 1.2 s
        broker.start()
        started = time.monotonic()
        with self.assertRaises(gateway.DeliveryUncertain):
            gateway.mqtt_publish("127.0.0.1", broker.port, "u", "p", "t", b"x", timeout=0.8)
        self.assertLess(time.monotonic() - started, 1.1)
        broker.join(5)

    def test_missing_or_malformed_puback_is_uncertain(self):
        for broker in (FakeBroker(close_after_publish=True), FakeBroker(puback=bytes([0x40, 0x03, 0x00, 0x01])),
                       FakeBroker(puback=bytes([0x40, 0x02, 0x00, 0x09])), FakeBroker(puback=bytes([0x50, 0x02, 0x00, 0x01]))):
            with self.subTest(puback=broker.puback, close=broker.close_after_publish), \
                    self.assertRaises(gateway.DeliveryUncertain):
                self.publish(broker)


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory(prefix="zufahrt-gw-http-")
        self.addCleanup(self.dir.cleanup)
        self.publish = Recorder()
        self.gw = gateway.Gateway(self.dir.name, TOKEN_SHA, MQTT, publish=self.publish)
        self.server = gateway.GatewayServer(("127.0.0.1", 0), gateway.make_handler(self.gw))
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.port = self.server.server_address[1]

    def request(self, method, path, headers=None, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(method, path, body=body, headers=headers or {})
        response = conn.getresponse()
        return response.status, json.loads(response.read() or b"{}")

    def raw(self, data):
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as sock:
            sock.sendall(data)
            return sock.recv(200).split(b" ", 2)[1]

    def patch(self, name, value):
        old = getattr(gateway, name)
        setattr(gateway, name, value)
        self.addCleanup(setattr, gateway, name, old)

    def results(self):
        return [json.loads(line)["result"] for line in (Path(self.dir.name) / "calls.jsonl").read_text().splitlines()]

    def test_http_round_trip(self):
        auth = {"Authorization": f"Bearer {TOKEN}"}
        self.assertEqual(self.request("GET", "/zufahrt")[0], 405)
        self.assertEqual(self.request("POST", "/zufahrt", {"Authorization": "Bearer nope"})[0], 401)
        self.assertEqual(self.request("POST", "/zufahrt5", auth)[0], 202)
        self.assertEqual(self.request("POST", "/zufahrt", auth)[0], 429)
        self.assertEqual([p["command"] for _, p in self.publish.calls], ["/zufahrt5"])

    def test_any_request_body_or_framing_is_refused_before_auth(self):
        auth = f"Bearer {TOKEN}"
        for headers in ({"Content-Length": "5"}, {"Content-Length": "-1"}, {"Content-Length": "x"},
                        {"Transfer-Encoding": "chunked"}):
            with self.subTest(headers=headers):
                lines = "".join(f"{k}: {v}\r\n" for k, v in headers.items())
                self.assertEqual(self.raw(f"POST /zufahrt HTTP/1.1\r\nHost: x\r\nAuthorization: {auth}\r\n{lines}\r\n".encode()), b"400")
        self.assertEqual(self.publish.calls, [])

    def test_duplicate_framing_or_auth_headers_are_refused(self):
        auth = f"Authorization: Bearer {TOKEN}\r\n"
        for extra in ("Content-Length: 0\r\nContent-Length: 5\r\n", "Content-Length: 0\r\nContent-Length: 0\r\n",
                      "Transfer-Encoding: identity\r\nTransfer-Encoding: chunked\r\n", "Authorization: Bearer nope\r\n"):
            with self.subTest(extra=extra):
                self.assertEqual(self.raw(f"POST /zufahrt HTTP/1.1\r\nHost: x\r\n{auth}{extra}\r\n".encode()), b"400")
        self.assertEqual(self.publish.calls, [])
        self.assertEqual(self.results(), ["refused-framing"] * 4)

    def test_a_malformed_header_line_cannot_hide_the_headers_after_it(self):
        for bad in ("Content-Length : 5", "X Bad Header", ": empty-name", " folded-continuation", "X-Note: caf\u00e9",
                    "X-Ctl: a\x01b", "X(y): 1"):
            with self.subTest(bad=bad):
                data = (f"POST /zufahrt HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {TOKEN}\r\n{bad}\r\n"
                        "Content-Length: 5\r\nTransfer-Encoding: chunked\r\nAuthorization: Bearer second\r\n\r\n")
                self.assertEqual(self.raw(data.encode("latin-1")), b"400")
        self.assertEqual(self.publish.calls, [])
        self.assertEqual(self.results(), ["refused-malformed"] * 7)
        ok = f"POST /zufahrt HTTP/1.1\r\nHost: x\r\nUser-Agent: howie/1 (x; y)\r\nX-Empty:\r\nAuthorization: Bearer {TOKEN}\r\n\r\n"
        self.assertEqual(self.raw(ok.encode()), b"202")  # ordinary headers still pass

    def test_a_header_block_cut_off_at_eof_never_acts(self):
        for data in (f"POST /zufahrt HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {TOKEN}\r\n",
                     f"POST /zufahrt HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {TOKEN}"):
            with self.subTest(terminated=data.endswith("\n")), \
                    socket.create_connection(("127.0.0.1", self.port), timeout=5) as sock:
                sock.sendall(data.encode())
                sock.shutdown(socket.SHUT_WR)  # EOF instead of the empty line
                self.assertEqual(sock.recv(200).split(b" ", 2)[1], b"400")
        self.assertEqual(self.publish.calls, [])
        self.assertEqual(self.results(), ["refused-incomplete"] * 2)

    def wait_for_results(self, count):
        for _ in range(100):
            path = Path(self.dir.name) / "calls.jsonl"
            if path.exists() and len(path.read_text().splitlines()) >= count:
                return self.results()
            time.sleep(0.05)
        self.fail("no log line")

    def test_a_request_the_watchdog_cuts_off_never_acts(self):
        self.patch("REQUEST_DEADLINE", 0.5)
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        self.addCleanup(sock.close)
        sock.sendall(f"POST /zufahrt HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {TOKEN}\r\n".encode())  # never finishes
        self.assertEqual(self.wait_for_results(1), ["refused-timeout"])
        time.sleep(0.2)
        self.assertEqual(self.publish.calls, [])

    def test_a_request_that_waited_for_the_lock_too_long_never_publishes(self):
        self.patch("REQUEST_DEADLINE", 2.0)
        self.patch("PUBLISH_TIMEOUT", 0.5)
        self.gw.lock.acquire()  # another request is publishing
        threading.Timer(1.2, self.gw.lock.release).start()  # 0.8 s left: less than the publish budget of 1.5 s
        self.assertEqual(self.request("POST", "/zufahrt", {"Authorization": f"Bearer {TOKEN}"})[0], 408)
        self.assertEqual(self.publish.calls, [])
        self.assertEqual(self.results(), ["refused-expired"])
        self.assertEqual(self.request("POST", "/zufahrt", {"Authorization": f"Bearer {TOKEN}"})[0], 202)

    def test_protocol_errors_are_logged(self):
        self.assertEqual(self.raw(b"OPTIONS /zufahrt HTTP/1.1\r\nHost: x\r\n\r\n"), b"501")
        self.assertEqual(self.raw(b"POST /zufahrt HTTP/9.9\r\nHost: x\r\n\r\n"), b"505")
        self.assertEqual(self.raw(b"garbage\r\n\r\n"), b"400")
        self.assertEqual(self.results(), ["refused-protocol"] * 3)

    def test_a_slow_client_does_not_block_others(self):
        slow = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        self.addCleanup(slow.close)
        slow.sendall(b"POST /zufahrt HTTP/1.1\r\n")  # never finishes
        started = time.monotonic()
        self.assertEqual(self.request("POST", "/zufahrt", {"Authorization": "Bearer nope"})[0], 401)
        self.assertLess(time.monotonic() - started, 2)


if __name__ == "__main__":
    unittest.main()
