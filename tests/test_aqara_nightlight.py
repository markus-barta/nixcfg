"""OPS-496: offline counter, miio retry, wire payload and HTTP boundary tests."""

import importlib.util
import io
import json
import logging
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from concurrent.futures import ThreadPoolExecutor
from email.message import Message
from pathlib import Path
from unittest.mock import MagicMock, Mock, call, patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "hosts/hsb1/aqara-nightlight.py"


class FakeDeviceError(Exception):
    pass


def load():
    # Import no actual miio code and open no UDP sockets in this suite.
    miio = types.ModuleType("miio")
    miio.DeviceError = FakeDeviceError
    protocol = types.ModuleType("miio.miioprotocol")
    protocol.MiIOProtocol = Mock()
    spec = importlib.util.spec_from_file_location("aqara_nightlight", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, {"miio": miio, "miio.miioprotocol": protocol}):
        spec.loader.exec_module(module)
    return module


class CounterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.module = load()
        self.path = Path(self.tmp.name, "msgid")
        self.module.ID_FILE = str(self.path)

    def test_counter_survives_reload(self):
        self.path.write_text("4000")
        self.assertEqual(self.module._next_id(), 4001)
        fresh = load()
        fresh.ID_FILE = str(self.path)
        self.assertEqual(fresh._next_id(), 4002)

    def test_initial_corrupt_and_wrapped_state_stays_in_prototype_range(self):
        for state in (None, "", "corrupt", "-1", "0", "9000", "9999"):
            with self.subTest(state=state), patch.object(self.module.random, "randint", return_value=1234):
                if state is not None:
                    self.path.write_text(state)
                self.assertEqual(self.module._next_id(), 1234)
                self.assertEqual(self.path.read_text(), "1234")
        self.path.write_text("8999")
        self.assertEqual(self.module._next_id(), 9000)

    def test_concurrent_threads_get_distinct_ids(self):
        self.path.write_text("100")
        with ThreadPoolExecutor(max_workers=8) as pool:
            ids = list(pool.map(lambda _: self.module._next_id(), range(80)))
        self.assertEqual(sorted(ids), list(range(101, 181)))

    def test_independent_processes_share_the_file_lock(self):
        self.path.write_text("100")
        program = """
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'tests'))
from test_aqara_nightlight import load
module = load()
module.ID_FILE = sys.argv[2]
print(','.join(str(module._next_id()) for _ in range(40)))
"""
        children = [subprocess.Popen(
            [sys.executable, "-B", "-c", program, str(ROOT), str(self.path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        ) for _ in range(4)]
        ids = []
        for child in children:
            stdout, stderr = child.communicate(timeout=15)
            self.assertEqual(child.returncode, 0, stderr)
            ids.extend(map(int, stdout.strip().split(",")))
        self.assertEqual(sorted(ids), list(range(101, 261)))
        self.assertEqual(self.path.read_text(), "260")


class ProtocolTest(unittest.TestCase):
    def setUp(self):
        self.module = load()
        self.ids = patch.object(self.module, "_next_id", side_effect=range(101, 120)).start()
        self.sleep = patch.object(self.module.time, "sleep").start()
        self.addCleanup(patch.stopall)

    def fake_protocol(self, outcome=None):
        protocol = Mock()
        def send(*args, **kwargs):
            protocol._MiIOProtocol__id += 1
            if isinstance(outcome, Exception):
                raise outcome
            return outcome or ["ok"]
        protocol.send.side_effect = send
        return protocol

    def test_handshake_and_timeout_contract(self):
        protocol = self.module.MiIOProtocol.return_value
        handshake = protocol.send_handshake.return_value
        self.assertIs(self.module._connect("plug"), protocol)
        self.module.MiIOProtocol.assert_called_once_with("192.168.1.106", timeout=1.5)
        protocol.send_handshake.assert_called_once_with(retry_count=1)
        self.assertIs(protocol.token, handshake.checksum)

    def test_retry_rehandshakes_and_uses_new_id_without_library_retry(self):
        lost, good = self.fake_protocol(TimeoutError()), self.fake_protocol()
        with patch.object(self.module, "_connect", side_effect=[lost, good]) as connect:
            self.assertEqual(self.module.call("plug", "set_rgb", [1]), (["ok"], 2))
            self.assertEqual(self.module.call("plug", "get_prop"), (["ok"], 1))
        self.assertEqual(connect.call_count, 2)
        self.assertEqual(lost._MiIOProtocol__id, 101)
        self.assertEqual(good._MiIOProtocol__id, 103)
        lost.send.assert_called_once_with("set_rgb", [1], retry_count=0)
        good.send.assert_has_calls([call("set_rgb", [1], retry_count=0), call("get_prop", [], retry_count=0)])
        self.sleep.assert_called_once_with(0.15)

    def test_exactly_four_attempts_then_no_cached_session_or_exception_payload(self):
        peers = [self.fake_protocol(TimeoutError("private-packet-fixture")) for _ in range(4)]
        with patch.object(self.module, "_connect", side_effect=peers) as connect:
            with self.assertRaises(RuntimeError) as caught:
                self.module.call("round", "get_prop")
        self.assertEqual(connect.call_count, 4)
        self.assertEqual(self.ids.call_count, 4)
        self.assertNotIn("round", self.module._dev)
        self.assertNotIn("private-packet-fixture", str(caught.exception))
        self.assertEqual([p._MiIOProtocol__id for p in peers], [101, 102, 103, 104])

    def test_handshake_failure_gets_a_fresh_handshake(self):
        peer = self.fake_protocol()
        with patch.object(self.module, "_connect", side_effect=[TimeoutError(), peer]) as connect:
            self.assertEqual(self.module.call("round", "get_prop"), (["ok"], 2))
        self.assertEqual(connect.call_count, 2)
        self.ids.assert_called_once()

    def test_device_verdict_is_not_retried(self):
        peer = self.fake_protocol(FakeDeviceError("private-packet-fixture"))
        with patch.object(self.module, "_connect", return_value=peer) as connect:
            with self.assertRaises(FakeDeviceError):
                self.module.call("plug", "set_rgb", [1])
        connect.assert_called_once()
        self.sleep.assert_not_called()

    def test_unknown_hub_never_connects(self):
        with patch.object(self.module, "_connect") as connect:
            with self.assertRaises(ValueError):
                self.module.call("192.0.2.1", "get_prop")
        connect.assert_not_called()

    def test_same_hub_serialized_but_other_hub_can_proceed(self):
        entered, release = threading.Event(), threading.Event()
        peer, other = self.fake_protocol(), self.fake_protocol()
        def block(*args, **kwargs):
            entered.set()
            if not release.wait(3):
                raise AssertionError("fixture timed out")
            return ["ok"]
        peer.send.side_effect = block
        self.module._dev.update(plug=peer, round=other)
        with ThreadPoolExecutor(max_workers=3) as pool:
            first = pool.submit(self.module.call, "plug", "get_prop")
            try:
                self.assertTrue(entered.wait(2))
                second = pool.submit(self.module.call, "plug", "get_prop")
                independent = pool.submit(self.module.call, "round", "get_prop")
                self.assertEqual(independent.result(timeout=2), (["ok"], 1))
                self.assertEqual(peer.send.call_count, 1)
                self.assertFalse(second.done())
            finally:
                release.set()
            self.assertEqual(first.result(timeout=2), (["ok"], 1))
            self.assertEqual(second.result(timeout=2), (["ok"], 1))


class ApiTest(unittest.TestCase):
    def setUp(self):
        self.module = load()

    def test_light_wire_encoding_clamping_and_300ms_echo(self):
        for brightness, expected in ((10, 10), (-1, 0), (101, 100)):
            with self.subTest(brightness=brightness), patch.object(self.module, "call", return_value=(["ok"], 1)) as send, patch.object(self.module.time, "sleep") as sleep:
                result = self.module.set_light("plug", "#FF8C28", brightness)
                packed = (expected << 24) | 0xFF8C28
                self.assertEqual(send.call_args_list, [call("plug", "set_rgb", [packed]), call("plug", "set_rgb", [packed], attempts=1)])
                sleep.assert_called_once_with(0.3)
                self.assertEqual(result["brightness"], expected)

    def test_failed_echo_does_not_erase_first_ack(self):
        with patch.object(self.module, "call", side_effect=[(["ok"], 2), RuntimeError()]), patch.object(self.module.time, "sleep"):
            result = self.module.set_light("plug", "FF8C28", 10)
        self.assertTrue(result["ok"])
        self.assertEqual(result["versuche"], 2)

    def test_readback_and_quiet_sound_and_stop_payloads(self):
        with patch.object(self.module, "call", return_value=([(10 << 24) | 0xFF8C28, 42], 1)) as send:
            value = self.module.get_light("round")
        self.assertEqual((value["brightness"], value["rgb"], value["illumination"]), (10, "FF8C28", 42))
        send.assert_called_once_with("round", "get_prop", ["rgb", "illumination"])
        with patch.object(self.module, "call", return_value=(["ok"], 1)) as send:
            self.module.play_tone("round", "27")
            self.module.play_tone("plug", 20, 10)
            self.module.stop_sound("round")
        self.assertEqual(send.call_args_list, [call("round", "play_music_new", ["27", 15]), call("plug", "play_music_new", ["20", 10]), call("round", "set_sound_playing", ["off"])])

    def test_invalid_color_and_tone_do_not_contact_hub(self):
        with patch.object(self.module, "call") as send:
            for color in ("1000000", "-12345", "notrgb"):
                with self.assertRaises(ValueError):
                    self.module.set_light("plug", color, 10)
            with self.assertRaises(ValueError):
                self.module.play_tone("plug", 5001)
        send.assert_not_called()

    def test_tone_volume_is_capped_on_the_wire(self):
        for volume, expected in ((-1, 0), (0, 0), (15, 15), (40, 40), (41, 40), (100, 40)):
            with self.subTest(volume=volume), patch.object(self.module, "call", return_value=(["ok"], 1)) as send:
                result = self.module.play_tone("plug", 27, volume)
                send.assert_called_once_with("plug", "play_music_new", ["27", expected])
                self.assertEqual(result["vol"], expected)

    def test_http_and_cli_enforce_the_volume_cap(self):
        with patch.object(self.module, "call", return_value=(["ok"], 1)) as send:
            handler = self.request("/tone?hub=plug&id=27&vol=100", method="POST")
            self.assertEqual(json.loads(handler._reply.call_args.args[0])["vol"], 40)
            with patch("sys.stdout", new_callable=io.StringIO) as output:
                self.assertEqual(self.module.main(["tone", "plug", "27", "100"]), 0)
            self.assertEqual(json.loads(output.getvalue())["vol"], 40)
        self.assertEqual(send.call_args_list, [call("plug", "play_music_new", ["27", 40])] * 2)

    def test_all_25_tones_and_ui_defaults(self):
        tones = [tone for _, items in self.module.TONES for tone in items]
        self.assertEqual([i for i, _ in tones], list(range(9)) + list(range(10, 16)) + list(range(20, 30)))
        self.assertEqual(len(tones), 25)
        for i, name in tones:
            self.assertIn(f'data-t="{i}"', self.module.PAGE)
            self.assertIn(name, self.module.PAGE)
        self.assertIn('id=bri min=0 max=100 value=10', self.module.PAGE)
        self.assertIn("$('col').value='#ff8c28';$('bri').value=10", self.module.PAGE)
        self.assertIn('id=vol min=1 max=40 value=15', self.module.PAGE)

    def test_allowed_peers_cover_only_loopback_lan_and_tailnet(self):
        for peer in ("127.0.0.1", "::1", "192.168.1.42", "100.64.0.1", "100.127.255.254"):
            self.assertTrue(self.module.allowed_peer(peer), peer)
        for peer in ("192.168.2.1", "100.63.255.255", "100.128.0.1", "203.0.113.1", "2001:db8::1", "invalid"):
            self.assertFalse(self.module.allowed_peer(peer), peer)

    def request(self, path, peer="192.168.1.42", headers=None, method="GET"):
        handler = object.__new__(self.module.H)
        handler.path, handler.client_address = path, (peer, 12345)
        handler.command = method
        handler.headers = Message()
        for name, value in headers if headers is not None else [("Host", "hsb1:8765"), ("X-Nightlight", "1")]:
            handler.headers[name] = value
        handler._reply = Mock()
        handler.send_error = Mock()
        getattr(handler, "do_" + method)()
        return handler

    def parsed_request(self, raw):
        request = Mock()
        request.makefile.return_value = io.BytesIO(raw)
        output = io.BytesIO()
        request.sendall.side_effect = output.write
        self.module.H(request, ("192.168.1.42", 12345), Mock())
        return output.getvalue().split(b"\r\n\r\n", 1)

    def test_http_routes_and_response_shape(self):
        for path, function, args in (
            ("/set?hub=plug&rgb=FF8C28&bri=10", "set_light", ("plug", "FF8C28", "10")),
            ("/get?hub=round", "get_light", ("round",)),
            ("/tone?hub=plug&id=27", "play_tone", ("plug", "27", 15)),
            ("/stop?hub=round", "stop_sound", ("round",)),
        ):
            with self.subTest(path=path), patch.object(self.module, function, return_value={"ok": True}) as route:
                handler = self.request(path, method="GET" if path.startswith("/get?") else "POST")
                route.assert_called_once_with(*args)
                self.assertEqual(json.loads(handler._reply.call_args.args[0]), {"ok": True})
        self.assertEqual(self.request("/")._reply.call_args.args[0], self.module.PAGE.encode())

    def test_denied_http_peer_never_sends_a_command(self):
        with patch.object(self.module, "stop_sound") as stop:
            handler = self.request("/stop?hub=plug", peer="203.0.113.1", method="POST")
        handler.send_error.assert_called_once_with(403)
        handler._reply.assert_not_called()
        stop.assert_not_called()

    def test_foreign_missing_and_malformed_hosts_are_rejected(self):
        for host in (None, "", "foreign.example:8765", "hsb1.foreign.example:8765", "hsb1:80", "hsb1:8765@foreign.example"):
            headers = [] if host is None else [("Host", host)]
            headers.append(("X-Nightlight", "1"))
            with self.subTest(host=host), patch.object(self.module, "stop_sound") as stop:
                handler = self.request("/stop?hub=plug", headers=headers, method="POST")
                handler.send_error.assert_called_once_with(403)
                handler._reply.assert_not_called()
                stop.assert_not_called()

    def test_cross_site_fetch_metadata_is_rejected(self):
        for site in ("cross-site", "same-site", "", "same-origin, cross-site"):
            with self.subTest(site=site), patch.object(self.module, "stop_sound") as stop:
                handler = self.request("/stop?hub=plug", headers=[("Host", "hsb1:8765"), ("Sec-Fetch-Site", site), ("X-Nightlight", "1")], method="POST")
                handler.send_error.assert_called_once_with(403)
                handler._reply.assert_not_called()
                stop.assert_not_called()

    def test_mismatched_or_malformed_origin_is_rejected(self):
        for origin in ("http://foreign.example", "http://hsb1.lan:8765", "https://hsb1:8765", "null", "", "http://hsb1:8765/", "http://hsb1:8765@foreign.example"):
            with self.subTest(origin=origin), patch.object(self.module, "stop_sound") as stop:
                headers = [("Host", "hsb1:8765"), ("Sec-Fetch-Site", "same-origin"), ("Origin", origin), ("X-Nightlight", "1")]
                handler = self.request("/stop?hub=plug", headers=headers, method="POST")
                handler.send_error.assert_called_once_with(403)
                handler._reply.assert_not_called()
                stop.assert_not_called()

    def test_all_allowed_hosts_support_their_own_ui_requests(self):
        for name in ("127.0.0.1", "localhost", "192.168.1.101", "hsb1", "hsb1.lan", "100.64.0.7"):
            for suffix in ("", ":8765"):
                host = name + suffix
                for site in (None, "same-origin", "none"):
                    for origin in (None, "http://" + host):
                        headers = [("Host", host), ("X-Nightlight", "1")]
                        if site is not None:
                            headers.append(("Sec-Fetch-Site", site))
                        if origin is not None:
                            headers.append(("Origin", origin))
                        with self.subTest(host=host, site=site, origin=origin), patch.object(self.module, "stop_sound", return_value={"ok": True}) as stop:
                            handler = self.request("/stop?hub=plug", headers=headers, method="POST")
                            handler.send_error.assert_not_called()
                            stop.assert_called_once_with("plug")
                            self.assertEqual(json.loads(handler._reply.call_args.args[0]), {"ok": True})

    def test_duplicate_security_headers_are_rejected(self):
        for name, value in (("Host", "hsb1:8765"), ("Sec-Fetch-Site", "same-origin"), ("Origin", "http://hsb1:8765")):
            headers = [("Host", "hsb1:8765"), ("X-Nightlight", "1")]
            if name != "Host":
                headers.append((name, value))
            headers.append((name, value))
            with self.subTest(header=name), patch.object(self.module, "stop_sound") as stop:
                handler = self.request("/stop?hub=plug", headers=headers, method="POST")
                handler.send_error.assert_called_once_with(403)
                stop.assert_not_called()

    def test_same_origin_browser_request_through_http_parser(self):
        with patch.object(self.module, "call", return_value=(["ok"], 1)) as send:
            headers, body = self.parsed_request(
                b"POST /tone?hub=plug&id=27&vol=100 HTTP/1.1\r\n"
                b"Host: hsb1:8765\r\nSec-Fetch-Site: same-origin\r\n"
                b"Origin: http://hsb1:8765\r\nX-Nightlight: 1\r\nContent-Length: 0\r\n\r\n"
            )
        self.assertIn(b"200 OK", headers)
        self.assertTrue(json.loads(body)["ok"])
        send.assert_called_once_with("plug", "play_music_new", ["27", 40])

    def test_acting_endpoints_require_one_exact_custom_header(self):
        for path in ("/set?hub=plug&rgb=FF8C28&bri=10", "/tone?hub=plug&id=27", "/stop?hub=plug"):
            for method in ("GET", "POST"):
                for values in ([], [""], ["0"], ["true"], ["1, 1"], ["1", "1"], ["1", "0"]):
                    headers = [("Host", "192.168.1.101:8765")] + [("X-Nightlight", v) for v in values]
                    with self.subTest(path=path, method=method, values=values), patch.object(self.module, "call") as send:
                        handler = self.request(path, headers=headers, method=method)
                        handler.send_error.assert_called_once_with(403)
                        handler._reply.assert_not_called()
                        send.assert_not_called()

    def test_acting_get_with_header_is_method_not_allowed(self):
        for path in ("/set?hub=plug&rgb=FF8C28&bri=10", "/tone?hub=plug&id=27", "/stop?hub=plug"):
            with self.subTest(path=path), patch.object(self.module, "call") as send:
                headers, _ = self.parsed_request(
                    f"GET {path} HTTP/1.1\r\nHost: hsb1:8765\r\nX-Nightlight: 1\r\n\r\n".encode()
                )
                self.assertIn(b"405 Method Not Allowed", headers)
                self.assertIn(b"Allow: POST\r\n", headers + b"\r\n")
                send.assert_not_called()

    def test_safe_gets_need_no_custom_header(self):
        with patch.object(self.module, "get_light", return_value={"ok": True}) as read:
            handler = self.request("/get?hub=plug", headers=[("Host", "hsb1:8765")])
            read.assert_called_once_with("plug")
            handler.send_error.assert_not_called()
            self.assertTrue(json.loads(handler._reply.call_args.args[0])["ok"])
        handler = self.request("/", headers=[("Host", "hsb1:8765")])
        handler.send_error.assert_not_called()
        self.assertEqual(handler._reply.call_args.args[0], self.module.PAGE.encode())

    def test_safe_routes_reject_post(self):
        for path in ("/", "/get?hub=plug", "/unknown"):
            with self.subTest(path=path), patch.object(self.module, "call") as send:
                handler = self.request(path, method="POST")
                self.assertEqual(handler._reply.call_args.kwargs, {"status": 405, "allow": "GET"})
                send.assert_not_called()

    def test_options_preflight_is_denied_without_cors_permission(self):
        for path in ("/set", "/tone", "/stop", "/get", "/"):
            for origin in ("http://foreign.example", "http://hsb1:8765"):
                with self.subTest(path=path, origin=origin), patch.object(self.module, "call") as send:
                    headers, _ = self.parsed_request(
                        (
                            f"OPTIONS {path} HTTP/1.1\r\nHost: hsb1:8765\r\nOrigin: {origin}\r\n"
                            "Access-Control-Request-Method: POST\r\n"
                            "Access-Control-Request-Headers: x-nightlight\r\n\r\n"
                        ).encode()
                    )
                    self.assertIn(b"403 Forbidden", headers)
                    self.assertNotIn(b"access-control-allow-", headers.lower())
                    send.assert_not_called()

    def test_http_lan_and_tailnet_without_browser_metadata_cannot_act(self):
        for host in ("192.168.1.101:8765", "100.64.0.7:8765"):
            for path in ("/set?hub=plug&rgb=FF8C28&bri=10", "/tone?hub=plug&id=27", "/stop?hub=plug"):
                for method in ("GET", "POST"):
                    with self.subTest(host=host, path=path, method=method), patch.object(self.module, "call") as send:
                        headers, _ = self.parsed_request(
                            f"{method} {path} HTTP/1.1\r\nHost: {host}\r\nContent-Length: 0\r\n\r\n".encode()
                        )
                        self.assertIn(b"403 Forbidden", headers)
                        send.assert_not_called()

    def test_html_response_denies_framing_and_restricts_resources(self):
        headers, body = self.parsed_request(b"GET / HTTP/1.1\r\nHost: hsb1:8765\r\n\r\n")
        self.assertIn(b"200 OK", headers)
        self.assertIn(b"X-Frame-Options: DENY", headers)
        self.assertIn(b"Content-Security-Policy: default-src 'none'", headers)
        for directive in (b"frame-ancestors 'none'", b"connect-src 'self'", b"base-uri 'none'", b"form-action 'none'"):
            self.assertIn(directive, headers)
        self.assertEqual(body, self.module.PAGE.encode())

    def test_http_cli_and_library_logging_do_not_disclose_exceptions(self):
        payload = "private-packet-fixture"
        for error in (FakeDeviceError(payload), TimeoutError(payload), ValueError(payload)):
            with patch.object(self.module, "get_light", side_effect=error):
                handler = self.request("/get?hub=plug")
                self.assertNotIn(payload.encode(), handler._reply.call_args.args[0])
                with patch("sys.stdout", new_callable=io.StringIO) as output:
                    self.assertEqual(self.module.main(["get", "plug"]), 1)
                self.assertNotIn(payload, output.getvalue())
        with patch("sys.stderr", new_callable=io.StringIO) as output:
            child = logging.getLogger("miio.miioprotocol")
            old_level = child.level
            try:
                child.setLevel(logging.DEBUG)
                child.critical(payload)
            finally:
                child.setLevel(old_level)
        self.assertEqual(output.getvalue(), "")


class ListenerTest(unittest.TestCase):
    def setUp(self):
        self.module = load()

    def test_empty_wildcard_and_invalid_binds_fail_before_opening_any_listener(self):
        for addresses in ("", " ", "*", "0.0.0.0", "::", "::0", "127.0.0.1,", ",127.0.0.1", "127.0.0.1,,100.64.0.7", "127.0.0.1,0.0.0.0", "127.0.0.1,*", "127.0.0.1,::", "localhost", "invalid"):
            with self.subTest(addresses=addresses), patch.dict(self.module.os.environ, {"AQARA_LISTEN_ADDRESSES": addresses}), patch.object(self.module, "Server") as server:
                with self.assertRaises(ValueError):
                    self.module.serve()
                server.assert_not_called()

    def test_startup_failures_log_a_distinct_fixed_line_without_exception_details(self):
        message = "aqara-nightlight: listener startup failed; check listen addresses and port\n"
        for error in (ValueError("private-packet-fixture"), OSError("private-packet-fixture")):
            with self.subTest(error=type(error).__name__), patch.object(self.module, "serve", side_effect=error), patch("sys.stderr", new_callable=io.StringIO) as stderr, patch("sys.stdout", new_callable=io.StringIO) as stdout:
                self.assertEqual(self.module.main([]), 1)
                self.assertEqual(stderr.getvalue(), message)
                self.assertEqual(stdout.getvalue(), "")

    def test_explicit_addresses_start_separate_listeners(self):
        servers = [MagicMock() for _ in range(3)]
        for server in servers:
            server.__enter__.return_value = server
        settings = {"AQARA_LISTEN_ADDRESSES": "127.0.0.1, 192.168.1.101,100.64.0.7", "AQARA_PORT": "8765"}
        with patch.dict(self.module.os.environ, settings), patch.object(self.module, "Server", side_effect=servers) as constructor, patch.object(self.module.threading, "Thread") as thread, patch("sys.stdout", new_callable=io.StringIO):
            self.module.serve()
        self.assertEqual(constructor.call_args_list, [call((address, 8765), self.module.H) for address in ("127.0.0.1", "192.168.1.101", "100.64.0.7")])
        self.assertEqual(thread.call_count, 2)
        self.assertEqual(thread.return_value.start.call_count, 2)
        servers[-1].serve_forever.assert_called_once_with()
        for server in servers:
            server.__exit__.assert_called_once()

    def test_freebind_is_enabled_before_binding(self):
        server = object.__new__(self.module.Server)
        server.socket = Mock()
        def bind():
            server.socket.setsockopt.assert_called_once_with(self.module.socket.IPPROTO_IP, self.module.IP_FREEBIND, 1)
        with patch.object(self.module.sys, "platform", "linux"), patch.object(self.module.ThreadingHTTPServer, "server_bind", side_effect=bind) as parent_bind:
            server.server_bind()
        parent_bind.assert_called_once_with()

    def test_missing_tailnet_address_does_not_prevent_other_listeners(self):
        addresses = ("127.0.0.1", "192.168.1.101", "100.64.0.7")
        sockets = [Mock() for _ in addresses]
        for address, listener in zip(addresses, sockets):
            listener.getsockname.return_value = (address, 8765)
        def bind_tailnet(address):
            # Simulate Linux EADDRNOTAVAIL until freebind has been set.
            if call(self.module.socket.IPPROTO_IP, self.module.IP_FREEBIND, 1) not in sockets[-1].setsockopt.call_args_list:
                raise OSError("address not assigned")
        sockets[-1].bind.side_effect = bind_tailnet
        settings = {"AQARA_LISTEN_ADDRESSES": ",".join(addresses), "AQARA_PORT": "8765"}
        with patch.dict(self.module.os.environ, settings), patch.object(self.module.sys, "platform", "linux"), patch.object(self.module.socket, "socket", side_effect=sockets), patch.object(self.module.socket, "getfqdn", return_value="hsb1"), patch.object(self.module.Server, "serve_forever") as serve, patch.object(self.module.threading, "Thread") as thread, patch("sys.stdout", new_callable=io.StringIO):
            self.module.serve()
        for address, listener in zip(addresses, sockets):
            listener.bind.assert_called_once_with((address, 8765))
            listener.listen.assert_called_once()
            listener.close.assert_called_once_with()
        self.assertEqual(thread.return_value.start.call_count, 2)
        serve.assert_called_once_with()

    def test_unsupported_freebind_still_attempts_normal_bind(self):
        server = object.__new__(self.module.Server)
        server.socket = Mock()
        server.socket.setsockopt.side_effect = OSError("unsupported")
        with patch.object(self.module.sys, "platform", "linux"), patch.object(self.module.ThreadingHTTPServer, "server_bind") as parent_bind:
            server.server_bind()
        parent_bind.assert_called_once_with()

    def test_non_linux_does_not_set_linux_socket_options(self):
        server = object.__new__(self.module.Server)
        server.socket = Mock()
        with patch.object(self.module.sys, "platform", "darwin"), patch.object(self.module.ThreadingHTTPServer, "server_bind") as parent_bind:
            server.server_bind()
        server.socket.setsockopt.assert_not_called()
        parent_bind.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
