"""OPS-496: offline counter, miio retry, wire payload and HTTP boundary tests."""

import base64
import hashlib
import importlib.util
import io
import json
import logging
import os
import shutil
import stat
import re
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from concurrent.futures import ThreadPoolExecutor
from email.message import Message
from html.parser import HTMLParser
from pathlib import Path
from unittest.mock import MagicMock, Mock, call, patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "hosts/hsb1/aqara-nightlight.py"


class PageParser(HTMLParser):
    def __init__(self, page):
        super().__init__()
        self.ids = {}
        self.elements = []
        self.raw_elements = []
        self.feed(page)

    def handle_starttag(self, tag, attributes):
        self.raw_elements.append((tag, attributes))
        attributes = dict(attributes)
        self.elements.append((tag, attributes))
        if "id" in attributes:
            if attributes["id"] in self.ids:
                raise AssertionError("duplicate page id: " + attributes["id"])
            self.ids[attributes["id"]] = (tag, attributes)


class FakeDeviceError(Exception):
    pass


def load(page=True, *, state_directory=None, page_file=None):
    # Import no actual miio code and open no UDP sockets in this suite.
    miio = types.ModuleType("miio")
    miio.DeviceError = FakeDeviceError
    protocol = types.ModuleType("miio.miioprotocol")
    protocol.MiIOProtocol = Mock()
    spec = importlib.util.spec_from_file_location("aqara_nightlight", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    if state_directory is not None:
        module._TEST_STATE_DIRECTORY = state_directory
    with patch.dict(sys.modules, {"miio": miio, "miio.miioprotocol": protocol}):
        spec.loader.exec_module(module)
    if page_file is not None:
        original_load_page = module._load_page
        module._load_page = lambda: original_load_page(page_file)
    if page:
        module._load_page()
    return module


class StateDirectoryTest(unittest.TestCase):
    def test_production_uses_only_the_canonical_systemd_root(self):
        for configured in (None, "/var/lib/aqara-nightlight"):
            with self.subTest(configured=configured), patch.dict(os.environ, {}, clear=True):
                if configured is not None:
                    os.environ["STATE_DIRECTORY"] = configured
                module = load(page=False)
            root = Path("/var/lib/aqara-nightlight").resolve()
            self.assertEqual(module.STATE_DIRECTORY, root)
            self.assertEqual(Path(module.ID_FILE), root / "msgid")
            self.assertEqual(module.PRESET_FILE, root / "presets.json")
            self.assertEqual(module.SETTINGS_FILE, root / "settings.json")
            self.assertEqual(module.FEED_FILE, root / "desk-counts.json")

    def test_invalid_or_noncanonical_environment_fails_before_file_io(self):
        for configured in ("", "relative", "/tmp", "/var/lib/aqara-nightlight/../aqara-nightlight",
                           "/var/lib//aqara-nightlight", "/var/lib/aqara-nightlight/.",
                           "/var/lib/aqara-nightlight/", "//var/lib/aqara-nightlight",
                           "/var/lib/aqara-nightlight:/tmp"):
            with self.subTest(configured=configured), patch.dict(os.environ, {"STATE_DIRECTORY": configured}), patch.object(Path, "open") as opened:
                with self.assertRaises(ValueError):
                    load(page=False)
                opened.assert_not_called()

    def test_test_override_is_explicit_resolved_and_validated_at_import(self):
        with tempfile.TemporaryDirectory() as directory:
            module = load(page=False, state_directory=directory)
            self.assertEqual(module.STATE_DIRECTORY, Path(directory).resolve())
            with patch.dict(os.environ, {"STATE_DIRECTORY": "/tmp/changed-after-import"}):
                self.assertEqual(module.PRESET_FILE, Path(directory).resolve() / "presets.json")
        for directory in ("relative", "/tmp/../tmp", "/tmp//state", "/tmp/state/"):
            with self.subTest(directory=directory), self.assertRaises(ValueError):
                load(page=False, state_directory=directory)

    def test_query_hub_cannot_be_used_as_a_state_filename(self):
        with tempfile.TemporaryDirectory() as directory:
            module = load(page=False, state_directory=directory)
            with patch("builtins.open") as opened:
                for hub in ("../msgid", "plug/../../outside", "/tmp/outside", "__proto__"):
                    with self.subTest(hub=hub), self.assertRaises(ValueError):
                        with module._color_transaction(hub):
                            self.fail("invalid hub entered a state transaction")
                opened.assert_not_called()
            for hub, filename in (("plug", "last-color-plug.json"), ("round", "last-color-round.json")):
                with module._color_transaction(hub) as path:
                    self.assertEqual(path, Path(directory).resolve() / filename)
            self.assertEqual(sorted(p.name for p in Path(directory).iterdir()),
                             ["last-color-plug.json.lock", "last-color-round.json.lock"])


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
        self.assertEqual(fresh._next_id(), 4257)  # unspent reserved IDs are discarded

    def test_counter_never_wraps_and_corrupt_state_fails_closed(self):
        for state in ("", "corrupt", "-1", str(self.module.ID_LIMIT)):
            with self.subTest(state=state):
                self.path.write_text(state)
                with self.assertRaises(ValueError):
                    self.module._next_id()
                self.assertEqual(self.path.read_text(), state)
        self.path.write_text("9998")
        self.assertEqual(self.module._next_id(), 9999)
        self.assertEqual(self.module._next_id(), 10000)

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
        self.assertEqual(len(set(ids)), 160)
        expected = sorted(start+i for start in (101,357,613,869) for i in range(40))
        self.assertEqual(sorted(ids), expected)
        self.assertEqual(int(self.path.read_text()), 1124)


class ProtocolTest(unittest.TestCase):
    def setUp(self):
        self.module = load()
        self.ids = patch.object(self.module, "_next_id", side_effect=range(101, 120)).start()
        self.sleep = patch.object(self.module.time, "sleep").start()
        self.addCleanup(patch.stopall)

    def fake_protocol(self, outcome=None):
        protocol = Mock()
        def send(*args, **kwargs):
            protocol._MiIOProtocol__id = kwargs["extra_parameters"]["id"]
            if isinstance(outcome, Exception):
                raise outcome
            return outcome or ["ok"]
        protocol.send.side_effect = send
        return protocol

    def test_handshake_and_timeout_contract(self):
        protocol = self.module.MiIOProtocol.return_value
        handshake = self.module.MiIOProtocol.discover.return_value
        self.assertIs(self.module._connect("plug"), protocol)
        self.module.MiIOProtocol.assert_called_once_with("192.168.1.106", timeout=1.5)
        self.module.MiIOProtocol.discover.assert_called_once_with("192.168.1.106", timeout=1.5)
        protocol.send_handshake.assert_not_called()
        self.assertTrue(protocol._discovered)
        self.assertIs(protocol.token, handshake.checksum)

    def test_retry_rehandshakes_and_uses_new_id_without_library_retry(self):
        lost, good = self.fake_protocol(TimeoutError()), self.fake_protocol()
        with patch.object(self.module, "_connect", side_effect=[lost, good]) as connect:
            self.assertEqual(self.module.call("plug", "set_rgb", [1]), (["ok"], 2))
            self.assertEqual(self.module.call("plug", "get_prop"), (["ok"], 1))
        self.assertEqual(connect.call_count, 2)
        self.assertEqual(lost._MiIOProtocol__id, 101)
        self.assertEqual(good._MiIOProtocol__id, 103)
        lost.send.assert_called_once_with("set_rgb", [1], retry_count=0, extra_parameters={"id":101})
        good.send.assert_has_calls([call("set_rgb", [1], retry_count=0, extra_parameters={"id":102}), call("get_prop", [], retry_count=0, extra_parameters={"id":103})])
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
        self.assertEqual(self.module.error_response(caught.exception), {
            "ok": False, "error": "Hub antwortet nicht (4 Versuche)",
            "code": "hub_unavailable", "attempts": 4,
        })
        self.assertEqual([p._MiIOProtocol__id for p in peers], [101, 102, 103, 104])

    def test_handshake_failure_gets_a_fresh_handshake(self):
        peer = self.fake_protocol()
        with patch.object(self.module, "_connect", side_effect=[TimeoutError(), peer]) as connect:
            self.assertEqual(self.module.call("round", "get_prop"), (["ok"], 2))
        self.assertEqual(connect.call_count, 2)
        self.assertEqual(self.ids.call_count, 2)

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
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.module = load()
        self.module.STATE_DIRECTORY = Path(self.tmp.name)
        self.module.PRESET_FILE = Path(self.tmp.name, "presets.json")

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
        page = PageParser(self.module.PAGE)
        for key, low, high, default in (("bri", "0", "100", "0"), ("vol", "0", "40", "15")):
            attributes = page.ids[key][1]
            self.assertEqual([attributes[k] for k in ("min", "max", "value")], [low, high, default])
        self.assertEqual(page.ids["col"][1]["value"], "#5c0701")

    def test_allowed_peers_cover_only_loopback_lan_and_tailnet(self):
        for peer in ("127.0.0.1", "::1", "192.168.1.42", "100.64.0.1", "100.127.255.254"):
            self.assertTrue(self.module.allowed_peer(peer), peer)
        for peer in ("192.168.2.1", "100.63.255.255", "100.128.0.1", "203.0.113.1", "2001:db8::1", "invalid"):
            self.assertFalse(self.module.allowed_peer(peer), peer)

    def request(self, path, peer="192.168.1.42", headers=None, method="GET", body=None):
        handler = object.__new__(self.module.H)
        handler.path, handler.client_address = path, (peer, 12345)
        handler.command = method
        handler.headers = Message()
        for name, value in headers if headers is not None else [("Host", "hsb1:8765"), ("X-Nightlight", "1")]:
            handler.headers[name] = value
        if body is not None:
            raw = body if isinstance(body, bytes) else json.dumps(body).encode()
            handler.rfile = io.BytesIO(raw)
            if "Content-Length" not in handler.headers:
                handler.headers["Content-Length"] = str(len(raw))
            if "Content-Type" not in handler.headers:
                handler.headers["Content-Type"] = "application/json"
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
            ("/tone?hub=plug&id=27", "play_tone", ("plug", "27", 15, None)),
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
        for path in ("/set?hub=plug&rgb=FF8C28&bri=10", "/tone?hub=plug&id=27", "/stop?hub=plug",
                     "/preset?hub=plug&name=nacht&rgb=5C0701&bri=44", "/apply?hub=plug&preset=nacht"):
            for method in ("GET", "POST"):
                for values in ([], [""], ["0"], ["true"], ["1, 1"], ["1", "1"], ["1", "0"]):
                    headers = [("Host", "192.168.1.101:8765")] + [("X-Nightlight", v) for v in values]
                    with self.subTest(path=path, method=method, values=values), patch.object(self.module, "call") as send:
                        handler = self.request(path, headers=headers, method=method)
                        handler.send_error.assert_called_once_with(403)
                        handler._reply.assert_not_called()
                        send.assert_not_called()

    def test_acting_get_with_header_remains_compatible(self):
        for path, function in (
            ("/set?hub=plug&rgb=5C0701&bri=44", "set_light"),
            ("/tone?hub=plug&id=27", "play_tone"),
            ("/stop?hub=plug", "stop_sound"),
            ("/preset?hub=plug&name=nacht&reset=1", "save_preset"),
            ("/apply?hub=plug&preset=nacht", "apply_preset"),
        ):
            for method in ("GET", "POST"):
                with self.subTest(path=path, method=method), patch.object(self.module, function, return_value={"ok": True}) as action:
                    headers, body = self.parsed_request(
                        f"{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nX-Nightlight: 1\r\nContent-Length: 0\r\n\r\n".encode()
                    )
                    self.assertIn(b"200 OK", headers)
                    self.assertTrue(json.loads(body)["ok"])
                    action.assert_called_once()

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
        for path in ("/", "/get?hub=plug", "/presets", "/unknown"):
            with self.subTest(path=path), patch.object(self.module, "call") as send:
                handler = self.request(path, method="POST")
                self.assertEqual(handler._reply.call_args.kwargs, {"status": 405, "allow": "GET"})
                send.assert_not_called()

    def test_options_preflight_is_denied_without_cors_permission(self):
        for path in ("/set", "/tone", "/stop", "/preset", "/apply", "/presets", "/get", "/"):
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
            for path in ("/set?hub=plug&rgb=FF8C28&bri=10", "/tone?hub=plug&id=27", "/stop?hub=plug",
                     "/preset?hub=plug&name=nacht&rgb=5C0701&bri=44", "/apply?hub=plug&preset=nacht"):
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


def nacht(presets, hub):
    p = next(p for p in presets[hub] if p["id"] == "nacht")
    return {"rgb":p["rgb"], "bri":p["bri"]}


class PresetTest(unittest.TestCase):
    request = ApiTest.request
    parsed_request = ApiTest.parsed_request

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.module = load()
        self.module.STATE_DIRECTORY = Path(self.tmp.name)
        self.path = Path(self.tmp.name, "presets.json")
        self.module.PRESET_FILE = self.path
        self.module.ID_FILE = str(Path(self.tmp.name, "msgid"))

    def result(self, path, method="POST", headers=None, peer="127.0.0.1"):
        response = self.request(path, method=method, headers=headers, peer=peer)
        return json.loads(response._reply.call_args.args[0])

    def test_defaults_for_both_hubs_are_readable_without_custom_header(self):
        with patch.object(self.module, "call") as send:
            result = self.result("/presets", method="GET", headers=[("Host", "127.0.0.1:8765")])
        self.assertEqual(result, {"ok": True, "presets": self.module._default_presets()})
        send.assert_not_called()
        self.assertFalse(self.path.exists())

    def test_save_and_reset_are_per_hub_and_never_contact_hardware(self):
        with patch.object(self.module, "call") as send:
            saved = self.result("/preset?hub=plug&name=nacht&rgb=ffb46b&bri=5")
            self.assertTrue(saved["ok"])
            self.assertEqual(nacht(saved["presets"], "plug"), {"rgb": "FFB46B", "bri": 5})
            self.assertEqual(nacht(saved["presets"], "round"), {"rgb": "5C0701", "bri": 44})
            self.result("/preset?hub=round&name=nacht&rgb=112233&bri=6", method="GET")
            reset = self.result("/preset?hub=plug&name=nacht&reset=1")
            self.assertEqual(nacht(reset["presets"], "plug"), {"rgb": "5C0701", "bri": 44})
            self.assertEqual(nacht(reset["presets"], "round"), {"rgb": "112233", "bri": 6})
        send.assert_not_called()

    def test_persists_across_a_fresh_process_module_with_state_directory(self):
        self.module.save_preset("plug", "nacht", "FFB46B", "5")
        restarted = load(state_directory=self.tmp.name)
        self.assertEqual(restarted.PRESET_FILE, self.path.resolve())
        self.assertEqual(nacht(restarted.get_presets()["presets"], "plug"), {"rgb": "FFB46B", "bri": 5})
        self.assertEqual(nacht(restarted.get_presets()["presets"], "round"), {"rgb": "5C0701", "bri": 44})
        restarted.save_preset("plug", "nacht", reset=True)
        self.assertEqual(nacht(self.module.get_presets()["presets"], "plug"), self.module.DEFAULT_NIGHTLIGHT)

    def test_atomic_write_is_complete_private_and_preserves_counter_inode(self):
        counter = Path(self.module.ID_FILE)
        counter.write_text("3456")
        inode = counter.stat().st_ino
        replace = self.module.os.replace
        observed = []
        def inspect_replace(source, destination):
            staged = Path(source)
            self.assertEqual(staged.parent, self.path.parent)
            self.assertEqual(staged.stat().st_mode & 0o777, 0o600)
            self.assertEqual(nacht(json.loads(staged.read_text()), "plug"), {"rgb": "ABCDEF", "bri": 9})
            observed.append((source, destination))
            replace(source, destination)
        with patch.object(self.module.os, "replace", side_effect=inspect_replace):
            self.module.save_preset("plug", "nacht", "ABCDEF", 9)
        self.assertEqual(len(observed), 1)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.path.parent.glob(".presets-*")), [])
        self.assertEqual((counter.stat().st_ino, counter.read_text()), (inode, "3456"))

    def test_failed_replace_preserves_previous_preset_and_cleans_own_temporary_file(self):
        self.module.save_preset("plug", "nacht", "ABCDEF", 9)
        previous = self.path.read_bytes()
        with patch.object(self.module.os, "replace", side_effect=OSError("fixture")):
            with self.assertRaises(OSError):
                self.module.save_preset("plug", "nacht", "FFFFFF", 50)
        self.assertEqual(self.path.read_bytes(), previous)
        self.assertEqual(list(self.path.parent.glob(".presets-*")), [])

    def test_concurrent_hub_saves_preserve_both_hubs(self):
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda i: self.module.save_preset("plug" if i % 2 else "round", "nacht", "123456" if i % 2 else "ABCDEF", 5), range(40)))
        presets = self.module.get_presets()["presets"]
        self.assertEqual(nacht(presets, "plug"), {"rgb": "123456", "bri": 5})
        self.assertEqual(nacht(presets, "round"), {"rgb": "ABCDEF", "bri": 5})

    def test_independent_processes_do_not_lose_other_hub_updates(self):
        program = """
import sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'tests'))
from test_aqara_nightlight import load
module = load()
module.PRESET_FILE = Path(sys.argv[2])
for i in range(12):
    module.save_preset(sys.argv[3], 'nacht', sys.argv[4], i)
"""
        children = [subprocess.Popen([sys.executable, "-B", "-c", program, str(ROOT), str(self.path), hub, rgb], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    for hub, rgb in (("plug", "123456"), ("round", "ABCDEF"))]
        for child in children:
            _, error = child.communicate(timeout=15)
            self.assertEqual(child.returncode, 0, error)
        saved = self.module.get_presets()["presets"]
        self.assertEqual(nacht(saved, "plug"), {"rgb": "123456", "bri": 11})
        self.assertEqual(nacht(saved, "round"), {"rgb": "ABCDEF", "bri": 11})

    def test_apply_default_and_saved_nightlight_returns_set_shape_for_ha(self):
        for method in ("GET", "POST"):
            for hub in ("plug", "round"):
                with self.subTest(method=method, hub=hub), patch.object(self.module, "call", return_value=(["ok"], 2)) as send, patch.object(self.module.time, "sleep"):
                    # No browser Origin/CSRF token, exactly the HA loopback contract.
                    result = self.result(f"/apply?hub={hub}&preset=nacht", method=method, headers=[("Host", "127.0.0.1:8765"), ("X-Nightlight", "1")])
                    self.assertEqual((result["ok"], result["rgb"], result["brightness"], result["versuche"]), (True, "5C0701", 44, 2))
                    self.assertEqual(send.call_args_list, [call(hub, "set_rgb", [(44 << 24) | 0x5C0701]), call(hub, "set_rgb", [(44 << 24) | 0x5C0701], attempts=1)])
        self.module.save_preset("round", "nacht", "112233", "7")
        with patch.object(self.module, "set_light", return_value={"ok": True}) as action:
            self.result("/apply?hub=round&preset=nacht")
            action.assert_called_once_with("round", "112233", 7)

    def test_unknown_and_unsaved_preset_or_hub_never_contacts_hardware(self):
        with patch.object(self.module, "call") as send:
            for method in ("GET", "POST"):
                for query in ("hub=plug&preset=unknown", "hub=missing&preset=nacht", "hub=plug", "preset=nacht", "hub=plug&preset=../msgid"):
                    self.assertFalse(self.result("/apply?" + query, method=method)["ok"])
            self.path.write_text(json.dumps({"plug": {}, "round": {}}))
            for hub in ("plug", "round"):
                self.assertFalse(self.result(f"/apply?hub={hub}&preset=nacht")["ok"])
        send.assert_not_called()

    def test_invalid_saves_cannot_change_state_or_contact_hardware(self):
        self.module.save_preset("plug", "nacht", reset=True)
        before = self.path.read_bytes()
        with patch.object(self.module, "call") as send:
            for query in ("hub=other&name=nacht&rgb=ABCDEF&bri=5", "hub=plug&name=other&rgb=ABCDEF&bri=5", "hub=plug&name=nacht&rgb=invalid&bri=5", "hub=plug&name=nacht&rgb=FFFFFF&bri=-1", "hub=plug&name=nacht&rgb=FFFFFF&bri=101", "hub=plug&name=nacht&rgb=FFFFFF&bri=44.5", "hub=plug&name=nacht", "hub=plug&name=nacht&reset=0"):
                self.assertFalse(self.result("/preset?" + query)["ok"], query)
                self.assertEqual(self.path.read_bytes(), before)
        send.assert_not_called()

    def test_corrupt_state_fails_closed_without_hub_calls_or_overwrite(self):
        for content in ("not json", "[]", '{"plug":{"nacht":{"rgb":"5C0701","bri":101}}}', '{"plug":{"nacht":{"rgb":"invalid","bri":3}}}', '{"plug":{"nacht":{"rgb":"5C0701","bri":true}}}'):
            self.path.write_text(content)
            with patch.object(self.module, "call") as send, patch("sys.stderr", new_callable=io.StringIO) as journal:
                self.assertFalse(self.result("/apply?hub=plug&preset=nacht")["ok"])
                self.assertFalse(self.result("/preset?hub=plug&name=nacht&reset=1")["ok"])
                self.assertFalse(self.result("/presets", method="GET")["ok"])
            self.assertEqual(journal.getvalue().count("aqara-nightlight: preset state corrupt;"), 3)
            self.assertEqual(self.path.read_text(), content)
            send.assert_not_called()

    def test_corrupt_state_has_specific_safe_error_and_journal_line(self):
        for content in (b"not json", b"[]", b"\xff", b'{"plug":{"nacht":{"rgb":"invalid","bri":44}}}'):
            self.path.write_bytes(content)
            with patch("sys.stderr", new_callable=io.StringIO) as journal, patch.object(self.module, "call") as hub:
                result = self.result("/presets", method="GET")
            self.assertEqual(result, {"ok": False, "error": "Gespeicherte Nachtlicht-Vorgaben beschädigt; Server prüfen", "code": "presets_corrupt"})
            self.assertEqual(journal.getvalue(), "aqara-nightlight: preset state corrupt; stop service and move presets.json aside before restart\n")
            self.assertEqual(self.path.read_bytes(), content)
            hub.assert_not_called()

    def test_new_routes_preserve_host_origin_fetch_and_peer_guards(self):
        for path in ("/presets", "/preset?hub=plug&name=nacht&reset=1", "/apply?hub=plug&preset=nacht"):
            for method in (("GET",) if path == "/presets" else ("GET", "POST")):
                for bad_headers in ([('Host', 'foreign.example'), ('X-Nightlight', '1')], [('Host', 'hsb1:8765'), ('X-Nightlight', '1'), ('Origin', 'http://foreign.example')], [('Host', 'hsb1:8765'), ('X-Nightlight', '1'), ('Sec-Fetch-Site', 'cross-site')]):
                    with self.subTest(path=path, method=method, headers=bad_headers), patch.object(self.module, "call") as send:
                        response = self.request(path, headers=bad_headers, method=method)
                        response.send_error.assert_called_once_with(403)
                        send.assert_not_called()
                response = self.request(path, peer="203.0.113.1", method=method)
                response.send_error.assert_called_once_with(403)
        self.assertFalse(self.path.exists())


class PageTest(unittest.TestCase):
    def setUp(self):
        self.module = load()
        self.page = PageParser(self.module.PAGE)

    def test_packaged_page_has_controls_and_no_remote_assets_or_inline_handlers(self):
        for key in ("mode", "theme", "nightlight", "off", "bri", "vol", "own-color", "col", "stop", "status", "retry", "reload", "undo", "readback", "save-nightlight", "save-sheet", "confirm-save", "reset-preset", "goodnight", "alarm-list"):
            self.assertIn(key, self.page.ids)
        for tag, attrs in self.page.elements:
            self.assertFalse(any(name.startswith("on") for name in attrs), tag)
            for key in ("src", "href"):
                if key in attrs:
                    self.assertTrue(attrs[key].startswith("#"), (tag, key))
                    self.assertIn(attrs[key][1:], self.page.ids)
        self.assertIn("hidden", self.page.ids["alarm-list"][1])
        self.assertEqual(self.page.ids["loud-toggle"][1]["aria-expanded"], "false")
        self.assertEqual(self.page.ids["status"][1]["role"], "status")
        self.assertEqual(self.page.ids["save-sheet"][0], "dialog")
        self.assertEqual(sum(tag == "main" for tag, _ in self.page.elements), 1)
        self.assertFalse(any(tag == "figure" for tag, _ in self.page.elements))

    def test_exact_page_script_hash_is_in_csp_with_no_unsafe_inline_script(self):
        scripts = re.findall(r"<script\b[^>]*>(.*?)</script\b[^>]*>", self.module.PAGE, re.DOTALL | re.IGNORECASE)
        self.assertEqual(len(scripts), 1)
        expected = "'sha256-" + base64.b64encode(hashlib.sha256(scripts[0].encode()).digest()).decode() + "'"
        self.assertEqual(self.module.SCRIPT_HASHES, expected)
        headers, _ = ApiTest.parsed_request(self, b"GET / HTTP/1.1\r\nHost: hsb1:8765\r\n\r\n")
        self.assertIn(("script-src " + expected).encode(), headers)
        self.assertNotIn(b"script-src 'unsafe-inline'", headers)
        self.assertIn(b"img-src 'self'", headers)  # Inline SVG fragment references.
        self.assertIn(b"Cache-Control: no-store", headers)

    def test_script_hash_preserves_exact_body_with_case_and_attributes(self):
        body = "\n  const text = '<tag>';\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "page.html")
            for opening, closing in (("<SCRIPT>", "</SCRIPT>"), ("<ScRiPt type=\"text/javascript\">", "</sCrIpT >"),
                                     ("<script type=\"text/javascript\">", "</script\t\n bar>")):
                with self.subTest(opening=opening):
                    path.write_text(opening + body + closing)
                    self.module._load_page(path)
                    expected = "'sha256-" + base64.b64encode(hashlib.sha256(body.encode()).digest()).decode() + "'"
                    self.assertEqual(self.module.SCRIPT_HASHES, expected)
                    self.assertEqual(self.module.PAGE, opening + body + closing)

    def test_missing_or_multiple_scripts_fail_closed_and_preserve_loaded_page(self):
        before = self.module.PAGE, self.module.SCRIPT_HASHES
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "page.html")
            for page in ("<html></html>", "<scripture>not a script</scripture>",
                         "<script>a()</script><SCRIPT>b()</SCRIPT>"):
                path.write_text(page)
                with self.subTest(page=page), self.assertRaises(ValueError):
                    self.module._load_page(path)
                self.assertEqual((self.module.PAGE, self.module.SCRIPT_HASHES), before)

    def test_local_template_assembly_fails_closed_on_marker_or_module_drift(self):
        before = self.module.PAGE, self.module.SCRIPT_HASHES
        with tempfile.TemporaryDirectory() as directory:
            page = Path(directory, "page.html")
            page.write_text("<!--AQARA_INLINE_SCRIPT--><!--AQARA_INLINE_SCRIPT-->")
            with self.assertRaises(ValueError):
                self.module._load_page(page)
            page.write_text("<!--AQARA_INLINE_SCRIPT-->")
            read_text = Path.read_text
            def broken_source(path, *args, **kwargs):
                if path.name == "aqara-nightlight-script.cjs":
                    return "invalid module wrapper"
                return read_text(path, *args, **kwargs)
            with patch.object(Path, "read_text", broken_source), self.assertRaises(ValueError):
                self.module._load_page(page)
            self.assertEqual((self.module.PAGE, self.module.SCRIPT_HASHES), before)
        asset = "/nix/store/" + "a" * 32 + "-aqara-nightlight-page.html"
        with patch.dict(os.environ, {"AQARA_PAGE_FILE": asset}), patch.object(Path, "read_text", return_value="<!--AQARA_INLINE_SCRIPT-->"), self.assertRaises(ValueError):
            self.module._load_page()

    def test_environment_page_is_only_an_immutable_nix_store_asset(self):
        asset = "/nix/store/" + "a" * 32 + "-aqara-nightlight-page.html"
        with patch.dict(os.environ, {"AQARA_PAGE_FILE": asset}), patch.object(Path, "read_text", return_value="<script>const a=1;</script>") as read:
            self.module._load_page()
            read.assert_called_once_with(encoding="utf-8")
        for path in ("page.html", "/tmp/page.html", asset + "/../other", "/nix/store/../" + Path(asset).name,
                     "/nix/store//" + Path(asset).name):
            with self.subTest(path=path), patch.dict(os.environ, {"AQARA_PAGE_FILE": path}), patch.object(Path, "read_text") as read:
                with self.assertRaises(ValueError):
                    self.module._load_page()
                read.assert_not_called()

    def test_each_button_has_one_matching_preset_swatch_or_tone_attribute_set(self):
        expected = {
            "data-preset": {i:None for i in ("p2", "p3", "p4", "p5", "p6")},
            "data-color": {"FF8C28": "Warmweiß", "FFB46B": "Hellwarm", "FF5A00": "Orange", "FF0000": "Rot", "0000FF": "Blau", "FFFFFF": "Weiß"},
            "data-t": {str(i): name for _, tones in self.module.TONES for i, name in tones},
        }
        found = {key: {} for key in expected}
        for tag, pairs in self.page.raw_elements:
            if tag != "button":
                continue
            attrs = dict(pairs)
            classes = attrs.get("class", "").split()
            key = "data-preset" if "pre" in classes else "data-color" if "sw" in classes and attrs.get("id") != "own-color" else "data-t" if "tone" in classes else None
            self.assertEqual([attribute for attribute in expected if attribute in attrs], [] if key is None else [key], pairs)
            if key is None:
                continue
            names = [name for name, _ in pairs]
            self.assertEqual(names.count(key), 1, pairs)
            value = attrs[key]
            self.assertNotIn(value, found[key])
            if key != "data-preset":
                companion = "data-color-name" if key == "data-color" else "title"
                self.assertEqual(names.count(companion), 1, pairs)
                found[key][value] = attrs[companion]
            else:
                found[key][value] = None
        self.assertEqual(found, expected)

    def test_stop_fill_and_mode_ring_are_scoped_to_their_active_classes(self):
        for rule in re.findall(r"\.stop\s*\{([^}]*)\}", self.module.PAGE):
            backgrounds = re.findall(r"background:\s*([^;]+);", rule)
            self.assertTrue(all(value == "var(--surface)" for value in backgrounds), rule)
        self.assertRegex(self.module.PAGE, r"(?s)\.stop\.on\s*\{[^}]*background: var\(--stop-bg\);")
        self.assertRegex(self.module.PAGE, r"(?s)\.ib \.mring\s*\{[^}]*visibility: hidden;")
        self.assertRegex(self.module.PAGE, r"(?s)\.ib\.holding \.mring\s*\{[^}]*visibility: visible;")
        self.assertRegex(self.module.PAGE, r"(?s)\.mhint\s*\{[^}]*height: 16px;")
        self.assertNotIn("Ansicht und Hell/Dunkel werden auf diesem Gerät gespeichert.", self.module.PAGE)

    def test_page_path_is_read_once_at_startup(self):
        with tempfile.TemporaryDirectory() as directory:
            page = Path(directory, "page.html")
            page.write_text("<!doctype html><title>fixture</title><script>const a=1;</script>")
            restarted = load(page=False, page_file=page)
            self.assertEqual(restarted.PAGE, "")
            with patch.dict(restarted.os.environ, {"AQARA_LISTEN_ADDRESSES": "127.0.0.1"}), patch.object(restarted, "Server", MagicMock()), patch.object(restarted.SignalEngine, "start"), patch("sys.stdout", new_callable=io.StringIO):
                restarted.serve()
            self.assertEqual(restarted.PAGE, page.read_text())
            page.write_text("changed after startup")
            self.assertIn("<title>fixture</title>", restarted.PAGE)

    def test_standalone_cli_does_not_need_the_page_or_page_environment(self):
        with patch.object(self.module.Path, "read_text", side_effect=AssertionError("CLI read the page")):
            standalone = load(page=False)
            for args, name in ((["get", "plug"], "get_light"), (["set", "round", "5C0701", "44"], "set_light"), (["tone", "plug", "27"], "play_tone"), (["stop", "round"], "stop_sound")):
                with patch.object(standalone, name, return_value={"ok": True}) as action, patch("sys.stdout", new_callable=io.StringIO):
                    self.assertEqual(standalone.main(args), 0)
                    action.assert_called_once()

    def test_missing_page_uses_fixed_startup_error_before_opening_sockets(self):
        with tempfile.TemporaryDirectory() as directory:
            standalone = load(page=False, page_file=Path(directory, "missing.html"))
            with patch.object(standalone, "Server") as server, patch("sys.stderr", new_callable=io.StringIO) as journal:
                self.assertEqual(standalone.main([]), 1)
            self.assertEqual(journal.getvalue(), "aqara-nightlight: listener startup failed; check listen addresses and port\n")
            server.assert_not_called()


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
        self.assertEqual(thread.call_count, 4)
        self.assertEqual(thread.return_value.start.call_count, 4)
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
        self.assertEqual(thread.return_value.start.call_count, 4)
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


class RoundFourTest(unittest.TestCase):
    request = ApiTest.request

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.module = load()
        root = Path(self.tmp.name)
        self.module.STATE_DIRECTORY = root
        self.module.PRESET_FILE = root / 'presets.json'
        self.module.SETTINGS_FILE = root / 'settings.json'
        self.module.FEED_FILE = root / 'desk-counts.json'
        self.module.ID_FILE = str(root / 'msgid')
        self.module.KEY_DIRECTORY = root / 'desk-keys'
        # Existing round-4 installations migrate; fresh installations have 0 desks.
        seeded = {h:self.module._migrate_hub(v) for h,v in self.module._legacy_defaults().items()}
        self.module._atomic_json(self.module.SETTINGS_FILE, seeded)
        self.send = patch.object(self.module, 'call', return_value=(["ok"], 1)).start()
        self.addCleanup(patch.stopall)
        self.now = self.stamp('2026-10-29T12:00:00+01:00')

    def stamp(self, text):
        return self.module.datetime.fromisoformat(text).timestamp()

    def feed(self, **overrides):
        counts = dict(open=2, held=1, oldest_held_at=self.now-3600,
                      oldest_expiry_at=None, generation=1)
        counts.update(overrides)
        feed = dict(version=1, updated_at=self.now, desks={'ppm': counts, 'pma':dict(open=0,held=0,oldest_held_at=None,oldest_expiry_at=None,generation=0)})
        self.module.FEED_FILE.write_text(json.dumps(feed))
        return feed

    def result(self, path, method='POST', **kwargs):
        handler = self.request(path, method=method, **kwargs)
        return json.loads(handler._reply.call_args.args[0])

    def test_lossless_atomic_idempotent_legacy_migration(self):
        old = {h:{'nacht':dict(rgb='5C0701',bri=44)} for h in ('plug','round')}
        self.module.PRESET_FILE.write_text(json.dumps(old))
        with patch.object(self.module.os, 'replace', wraps=self.module.os.replace) as replace:
            result = self.module.get_presets()
            self.assertEqual(replace.call_count, 1)
            first = self.module.PRESET_FILE.read_bytes()
            self.assertEqual(self.module.get_presets(), result)
            self.assertEqual(self.module.PRESET_FILE.read_bytes(), first)
            self.assertEqual(replace.call_count, 1)
        for hub in ('plug', 'round'):
            self.assertEqual(nacht(result['presets'],hub), old[hub]['nacht'])
            self.assertEqual([p['id'] for p in result['presets'][hub]], ['nacht','p2','p3','p4'])
        self.send.assert_not_called()

    def test_migration_validates_every_hub_before_writing_and_preserves_on_failure(self):
        old = dict(plug={'nacht':dict(rgb='5C0701',bri=44)}, round={'nacht':dict(rgb='bad',bri=44)})
        self.module.PRESET_FILE.write_text(json.dumps(old))
        before = self.module.PRESET_FILE.read_bytes()
        with self.assertRaises(self.module.PresetStateError):
            self.module.get_presets()
        self.assertEqual(self.module.PRESET_FILE.read_bytes(), before)
        old['round']['nacht']['rgb']='5C0701'
        self.module.PRESET_FILE.write_text(json.dumps(old))
        before = self.module.PRESET_FILE.read_bytes()
        with patch.object(self.module.os,'replace',side_effect=OSError()), self.assertRaises(OSError):
            self.module.get_presets()
        self.assertEqual(self.module.PRESET_FILE.read_bytes(),before)
        self.assertEqual(list(self.module.PRESET_FILE.parent.glob('.presets-*')),[])

    def test_all_preset_ops_fixed_ids_names_capacity_and_delete_refusals(self):
        saved=self.result('/preset?hub=plug&id=p2&rgb=123456&bri=12')
        self.assertTrue(saved['ok'])
        renamed=self.result('/preset?hub=plug&id=p2&name=Lesen')
        self.assertEqual(renamed['presets']['plug'][1],dict(id='p2',name='Lesen',rgb='123456',bri=12))
        for name in ('','%20','12345678901234567','bad%0Aname'):
            self.assertFalse(self.result('/preset?hub=plug&id=p2&name='+name)['ok'])
        created=self.result('/preset?hub=plug&new=1&rgb=AABBCC&bri=8&name=Leselicht')
        self.assertEqual(created['id'],'p5')
        self.assertEqual(self.result('/preset?hub=plug&new=1')['id'],'p6')
        self.assertFalse(self.result('/preset?hub=plug&new=1')['ok'])
        self.assertFalse(self.result('/preset?hub=plug&id=nacht&delete=1')['ok'])
        self.assertFalse(self.result('/preset?hub=plug&id=missing&delete=1')['ok'])
        self.assertTrue(self.result('/preset?hub=plug&id=p3&delete=1')['ok'])
        remaining=self.module.get_presets()['presets']['plug']
        self.assertEqual([p['id'] for p in remaining],['nacht','p2','p4','p5','p6'])
        reset=self.result('/preset?hub=plug&id=p2&reset=1')['presets']['plug'][1]
        self.assertEqual((reset['id'],reset['name'],reset['rgb'],reset['bri']),('p2','Lesen','FF8C28',40))
        self.send.assert_not_called()

    def test_ha_can_apply_any_saved_id_and_refusals_never_call_hub(self):
        with patch.object(self.module,'set_light',return_value={'ok':True}) as light:
            for preset in self.module.PLACE_DEFAULTS:
                self.assertTrue(self.result('/apply?hub=round&preset='+preset['id'],method='GET')['ok'])
                light.assert_called_with('round',preset['rgb'],preset['bri'])
            self.result('/preset?hub=round&id=p2&delete=1')
            light.reset_mock()
            for id in ('p2','p5','unknown','../msgid',''):
                self.assertFalse(self.result('/apply?hub=round&preset='+id,method='GET')['ok'])
            light.assert_not_called()

    def test_usage_and_rules_persist_per_hub_across_restart(self):
        defaults=self.result('/config',method='GET')['settings']
        self.assertEqual(defaults['round']['usage'],'desk')
        self.assertEqual(defaults['plug']['usage'],'nightlight')
        result=self.result('/settings?hub=round&usage=nightlight')
        self.assertTrue(result['ok'])
        fresh=load(state_directory=self.tmp.name)
        self.assertEqual(fresh.get_settings()['settings']['round']['usage'],'nightlight')
        self.assertEqual(fresh.get_settings()['settings']['plug'],defaults['plug'])
        self.assertTrue(self.result('/settings?hub=round&rule=urgent&rgb=ABCDEF&bri=42&mode=alternate&rgb2=123456&takt=3&all=1')['ok'])
        rules=fresh.get_settings()['settings']['round']['rules']
        self.assertEqual(set(rules), set(self.module.RULE_KEYS))
        self.assertEqual(rules['urgent']['bri'],42)
        self.assertEqual(rules['urgent']['mode'],'alternate')
        for suffix in ('usage=bad','threshold_ppm=0','threshold_pma=49','auto_sound=2','sound_vol=16','sound_ms=199'):
            self.assertFalse(self.result('/settings?hub=round&'+suffix)['ok'])
        self.send.assert_not_called()

    def test_rule_minimum_and_unknown_never_off_including_alternate(self):
        for query in ('rule=urgent&bri=60&mode=blink&takt=1',
                      'rule=unknown&bri=0&mode=steady&takt=2',
                      'rule=unknown&bri=5&mode=blink&takt=2',
                      'rule=unknown&bri=5&mode=steady&takt=6'):
            self.assertFalse(self.result('/settings?hub=round&rgb=8FA3B0&rgb2=000000&'+query)['ok'])
        self.assertEqual(self.module._engine_settings('round')['rules']['urgent']['takt'],2)
        self.assertTrue(self.result('/settings?hub=round&rule=unknown&rgb=8FA3B0&rgb2=18C2B0&bri=5&mode=alternate&takt=2')['ok'])

    def test_new_endpoints_preserve_every_http_guard(self):
        paths=('/settings?hub=round&usage=desk','/seen?hub=round','/signal-test?hub=round&rule=unknown')
        for path in paths:
            for headers in ([('Host','hsb1:8765')], [('Host','hsb1:8765'),('X-Nightlight','1'),('X-Nightlight','1')],
                            [('Host','foreign.example'),('X-Nightlight','1')],
                            [('Host','hsb1:8765'),('X-Nightlight','1'),('Origin','null')],
                            [('Host','hsb1:8765'),('X-Nightlight','1'),('Sec-Fetch-Site','cross-site')]):
                for method in ('GET','POST'):
                    handler=self.request(path,headers=headers,method=method)
                    handler.send_error.assert_called_once_with(403)
            self.request(path,method='OPTIONS').send_error.assert_called_once_with(403)
        self.send.assert_not_called()

    def test_tone_duration_is_validated_before_play_and_timer_sends_stop(self):
        for ms in (199,3001,'bad'):
            self.assertFalse(self.result('/tone?hub=plug&id=10&ms='+str(ms))['ok'])
        self.send.assert_not_called()
        with patch.object(self.module.threading,'Timer') as timer:
            value=self.result('/tone?hub=plug&id=10&vol=100&ms=200')
            self.assertEqual((value['ms'],value['vol']),(200,40))
            timer.assert_called_once_with(.2,self.module._timed_stop,('plug',))
            timer.return_value.start.assert_called_once()
            with patch.object(self.module.threading,'current_thread',return_value=timer.return_value):
                self.module._timed_stop('plug')
        self.send.assert_called_with('plug','set_sound_playing',['off'],attempts=1)

    def test_replacing_or_stopping_sound_cancels_old_duration(self):
        with patch.object(self.module.threading,'Timer') as timer:
            first,second=Mock(),Mock()
            timer.side_effect=[first,second]
            self.module.play_tone('plug',10,10,1000)
            self.module.play_tone('plug',10,10,3000)
            first.cancel.assert_called_once()
            self.module.stop_sound('plug')
            second.cancel.assert_called_once()
            before=self.send.call_count
            with patch.object(self.module.threading,'current_thread',return_value=first):
                self.module._timed_stop('plug')
            self.assertEqual(self.send.call_count,before)

    def test_quiet_hours_vienna_midnight_boundaries_and_dst(self):
        for text,quiet in [('2026-10-29T19:59:59+01:00',False),('2026-10-29T20:00:00+01:00',True),
                           ('2026-10-30T00:00:00+01:00',True),('2026-10-30T07:29:59+01:00',True),
                           ('2026-10-30T07:30:00+01:00',False),('2026-07-01T20:00:00+02:00',True),
                           ('2026-10-25T02:30:00+02:00',True),('2026-10-25T02:30:00+01:00',True)]:
            self.assertEqual(self.module.quiet_hours(self.stamp(text)),quiet,text)

    def test_feed_absent_stale_invalid_or_future_is_unknown_never_idle(self):
        cfg=self.module._engine_settings('round')
        for content in (None,'bad','{}','[]'):
            if content is not None:self.module.FEED_FILE.write_text(content)
            feed=self.module.read_feed(self.now)
            result=self.module.resolve_signal(cfg,feed,self.now)
            self.assertEqual(result['key'],'unknown')
            self.assertEqual(result['rule']['bri'],5)
        good=self.feed()
        for stamp in (self.now-121,self.now+1):
            bad={**good,'updated_at':stamp}
            self.module.FEED_FILE.write_text(json.dumps(bad))
            self.assertIsNone(self.module.read_feed(self.now))
        self.feed(held=3,open=2)
        self.assertIsNone(self.module.read_feed(self.now))
        self.feed()
        self.assertIsNotNone(self.module.read_feed(self.now+120))

    def test_mapping_threshold_expiry_open_minus_held_and_both(self):
        cfg=self.module._engine_settings('round')
        def key(feed):return self.module.resolve_signal(cfg,feed,self.now)['key']
        self.assertEqual(key(self.feed()),'regular:ppm')
        self.assertEqual(key(self.feed(oldest_held_at=self.now-4*3600)),'urgent:ppm')
        self.assertEqual(key(self.feed(oldest_expiry_at=self.now+3600)),'urgent:ppm')
        self.assertEqual(key(self.feed(oldest_expiry_at=self.now+3601)),'regular:ppm')
        self.assertEqual(key(self.feed(held=0,oldest_held_at=None)),'open:ppm')
        self.assertEqual(key(self.feed(held=0,open=0,oldest_held_at=None)),'idle')
        feed=self.feed();feed['desks']['pma']=dict(feed['desks']['ppm'])
        self.assertEqual(key(feed),'regular:both')
        feed['desks']['pma']['oldest_expiry_at']=self.now+60
        self.assertEqual(key(feed),'urgent:pma')

    def test_seen_survives_restart_until_new_held_generation(self):
        feed=self.feed()
        with patch.object(self.module.time,'time',return_value=self.now):
            self.assertTrue(self.module.mark_seen('round')['ok'])
        cfg=self.module.get_settings()['settings']['round']
        self.assertEqual(self.module.resolve_signal(cfg,feed,self.now)['key'],'idle')
        feed['desks']['ppm']['generation']+=1
        self.assertEqual(self.module.resolve_signal(cfg,feed,self.now)['key'],'regular:ppm')
        self.assertEqual(self.module.resolve_signal(cfg,None,self.now)['key'],'unknown')

    def test_engine_single_attempt_minimum_no_echo_and_static_on_transition(self):
        self.feed(oldest_expiry_at=self.now+60)
        engine=self.module.SignalEngine()
        self.assertTrue(engine.tick('round',self.now,0))
        self.send.assert_called_once_with('round','set_rgb',[(60<<24)|0x18C2B0],attempts=1)
        self.assertFalse(engine.tick('round',self.now+1,1))
        self.assertTrue(engine.tick('round',self.now+2,2))
        self.send.assert_called_with('round','set_rgb',[0x18C2B0],attempts=1)
        self.feed(oldest_expiry_at=None)
        self.assertTrue(engine.tick('round',self.now+4,4))
        self.send.assert_called_with('round','set_rgb',[(20<<24)|0x18C2B0],attempts=1)
        self.assertFalse(engine.tick('round',self.now+6,6))

    def test_engine_skips_busy_hub_without_queue_or_blocking_other_hub(self):
        engine=self.module.SignalEngine()
        entered,release=threading.Event(),threading.Event()
        def busy():
            with self.module._locks['round']:
                entered.set();release.wait(3)
        worker=threading.Thread(target=busy);worker.start()
        try:
            self.assertTrue(entered.wait(1))
            self.assertFalse(engine.tick('round',self.now,0))
            self.send.assert_not_called()
        finally:release.set();worker.join(2)
        self.assertTrue(engine.tick('round',self.now,2))
        self.assertEqual(self.send.call_count,1)

    def test_page_command_pauses_engine_until_http_reply_has_been_sent(self):
        engine=self.module.SignalEngine()
        def reply(*args,**kwargs):
            self.assertFalse(engine.tick('round',self.now,0))
            self.assertEqual(self.module._page_active['round'],1)
        handler=object.__new__(self.module.H)
        handler.path='/signal?hub=round';handler.client_address=('127.0.0.1',123)
        handler.command='GET';handler.headers=Message();handler.headers['Host']='hsb1:8765'
        handler._reply=Mock(side_effect=reply)
        handler.do_GET()
        self.assertEqual(self.module._page_active['round'],0)
        self.send.assert_not_called()
        self.assertTrue(engine.tick('round',self.now,2))

    def test_quiet_hours_force_steady_five_percent_and_unknown_stays_lit(self):
        night=self.stamp('2026-10-29T23:00:00+01:00')
        self.now=night;self.feed(oldest_expiry_at=night+60)
        engine=self.module.SignalEngine()
        self.assertTrue(engine.tick('round',night,0))
        self.send.assert_called_once_with('round','set_rgb',[(5<<24)|0x18C2B0],attempts=1)
        self.assertFalse(engine.tick('round',night+2,2))
        self.assertEqual(engine.previous['round'][1]['mode'],'steady')
        self.module.FEED_FILE.write_text('bad')
        self.assertTrue(engine.tick('round',night+4,4))
        self.send.assert_called_with('round','set_rgb',[(5<<24)|0x8FA3B0],attempts=1)

    def test_alternate_and_ten_second_test_return_to_static_live_state(self):
        self.module.save_settings('round',dict(rule='regular',rgb='18C2B0',rgb2='FFA020',bri='20',mode='alternate',takt='2'))
        self.feed();engine=self.module.SignalEngine()
        engine.tick('round',self.now,0);engine.tick('round',self.now+2,2)
        self.send.assert_called_with('round','set_rgb',[(20<<24)|0xFFA020],attempts=1)
        self.module._signal_tests['round']=(10,'unknown',self.module._engine_settings('round')['rules']['unknown'])
        engine.tick('round',self.now+4,4)
        self.send.assert_called_with('round','set_rgb',[(5<<24)|0x8FA3B0],attempts=1)
        engine.tick('round',self.now+10,10)
        self.send.assert_called_with('round','set_rgb',[(20<<24)|0x18C2B0],attempts=1)

    def test_automatic_sound_off_by_default_rate_limited_and_durable_deduplication(self):
        feed=self.feed()
        engine=self.module.SignalEngine()
        with patch.object(self.module,'play_tone') as tone:
            engine._auto_sound('round',self.module.get_settings()['settings']['round'],feed,self.now)
            tone.assert_not_called()
            self.module.save_settings('round',{'auto_sound':'1'})
            feed['desks']['ppm']['generation']=2
            engine._auto_sound('round',self.module.get_settings()['settings']['round'],feed,self.now)
            tone.assert_called_once_with('round',10,10,1000)
            feed['desks']['ppm']['generation']=3
            engine._auto_sound('round',self.module.get_settings()['settings']['round'],feed,self.now+100)
            self.assertEqual(tone.call_count,1)
            engine._auto_sound('round',self.module.get_settings()['settings']['round'],feed,self.now+700)
            self.assertEqual(tone.call_count,1)  # suppressed item never replays later
            feed['desks']['ppm']['generation']=4
            engine._auto_sound('round',self.module.get_settings()['settings']['round'],feed,self.now+700)
            self.assertEqual(tone.call_count,2)
            fresh=self.module.SignalEngine()
            fresh._auto_sound('round',self.module.get_settings()['settings']['round'],feed,self.now+1400)
            self.assertEqual(tone.call_count,2)

    def test_automatic_sound_never_runs_in_vienna_quiet_hours(self):
        self.module.save_settings('round',{'auto_sound':'1'})
        engine=self.module.SignalEngine()
        with patch.object(self.module,'play_tone') as tone:
            for stamp in ('2026-10-29T20:00:00+01:00','2026-10-30T07:29:00+01:00'):
                self.now=self.stamp(stamp);feed=self.feed(generation=int(self.now))
                engine._auto_sound('round',self.module.get_settings()['settings']['round'],feed,self.now)
            tone.assert_not_called()

    def test_engine_exceptions_have_fixed_log_and_worker_keeps_running(self):
        engine=self.module.SignalEngine()
        engine.stop=Mock();engine.stop.is_set.side_effect=[False,False,True]
        with patch.object(engine,'tick',side_effect=[RuntimeError('private-packet-fixture'),True]) as tick, patch('sys.stderr',new_callable=io.StringIO) as log:
            engine.run('round')
        self.assertEqual(tick.call_count,2)
        self.assertEqual(log.getvalue(),'aqara-nightlight: signal engine tick failed\n')
        self.assertEqual(engine.stop.wait.call_count,2)

    def test_leaving_desk_finishes_blink_before_a_later_page_command(self):
        self.feed(oldest_expiry_at=self.now+60)
        engine=self.module.SignalEngine();self.module._engine=engine
        engine.tick('round',self.now,0);engine.tick('round',self.now+2,2)
        self.send.reset_mock()
        self.module.save_settings('round',{'usage':'nightlight'})
        self.send.assert_called_once_with('round','set_rgb',[(60<<24)|0x18C2B0],attempts=1)
        self.assertFalse(engine.tick('round',self.now+4,4))
        self.assertEqual(self.send.call_count,1)

    def test_unknown_black_colours_are_rejected_in_both_slots(self):
        for first,second in [('000000','18C2B0'),('8FA3B0','000000')]:
            self.assertFalse(self.result(f'/settings?hub=round&rule=unknown&rgb={first}&rgb2={second}&bri=5&mode=alternate&takt=2')['ok'])

    def test_every_lit_rule_rejects_black_in_either_slot_in_every_mode(self):
        for key in self.module.RULE_KEYS:
            for mode in ('steady', 'blink', 'alternate'):
                for slot in ('rgb', 'rgb2'):
                    for bri in (1, 20, 100):
                        with self.subTest(key=key, mode=mode, slot=slot, bri=bri):
                            rule = dict(rgb='18C2B0', rgb2='FFA020', bri=bri, mode=mode, takt=2)
                            rule[slot] = '000000'
                            self.assertFalse(self.module._valid_rule(rule, key))
                            rule['bri'] = 0
                            self.assertEqual(self.module._valid_rule(rule, key), key != 'unknown')

    def test_black_rule_saves_and_signal_tests_return_400_without_side_effects(self):
        self.module.save_settings('round', {})
        before = self.module.SETTINGS_FILE.read_bytes()
        with patch.object(self.module, 'set_light') as light, patch.object(self.module, 'quiet_hours', return_value=True):
            for endpoint in ('settings', 'signal-test'):
                for method in ('GET', 'POST'):
                    for key in self.module.RULE_KEYS:
                        for mode in ('steady', 'blink', 'alternate'):
                            for slot in ('rgb', 'rgb2'):
                                with self.subTest(endpoint=endpoint, method=method, key=key, mode=mode, slot=slot):
                                    colors = dict(rgb='18C2B0', rgb2='FFA020')
                                    colors[slot] = '000000'
                                    handler = self.request(f'/{endpoint}?hub=round&rule={key}&rgb={colors["rgb"]}&rgb2={colors["rgb2"]}&bri=20&mode={mode}&takt=2&all=1', method=method)
                                    result = json.loads(handler._reply.call_args.args[0])
                                    self.assertEqual(handler._reply.call_args.kwargs['status'], 400)
                                    self.assertFalse(result['ok'])
                                    self.assertEqual(result['code'], 'invalid_rule')
                                    self.assertIn('Schwarz', result['error'])
                                    self.assertEqual(self.module.SETTINGS_FILE.read_bytes(), before)
            light.assert_not_called()
        self.assertEqual(self.module._signal_tests, {})
        self.send.assert_not_called()

    def test_saved_black_lit_rules_fail_closed_on_read(self):
        for slot in ('rgb', 'rgb2'):
            with self.subTest(slot=slot):
                settings = self.module.default_settings()
                settings['round']['rules']['regular'][slot] = '000000'
                self.module.SETTINGS_FILE.write_text(json.dumps(settings))
                with self.assertRaises(self.module.SettingsStateError):
                    self.module.SignalEngine().tick('round', self.now, 0)
        self.send.assert_not_called()

    def test_engine_rejects_black_in_live_and_test_rules_before_single_attempt_send(self):
        for source in ('live', 'test'):
            for slot in ('rgb', 'rgb2'):
                for mode in ('steady', 'blink', 'alternate'):
                    with self.subTest(source=source, slot=slot, mode=mode):
                        rule = dict(rgb='18C2B0', rgb2='FFA020', bri=20, mode=mode, takt=2)
                        rule[slot] = '000000'
                        engine = self.module.SignalEngine()
                        signal = dict(key='regular:ppm', rule=rule, quiet=False)
                        if source == 'test':
                            self.module._signal_tests['round'] = (10, 'regular:ppm', rule)
                            signal = dict(key='unknown', rule=self.module._engine_settings('round')['rules']['unknown'], quiet=False)
                        with patch.object(self.module, 'resolve_signal', return_value=signal), self.assertRaises(self.module.RuleValidationError):
                            engine.tick('round', self.now, 0)
                        self.send.assert_not_called()
                        self.assertEqual(engine.next_tick, {})
                        self.assertEqual(engine.previous, {})
                        self.assertEqual(engine.applied, {})
                        self.module._signal_tests.clear()
        self.feed()
        engine = self.module.SignalEngine()
        self.assertTrue(engine.tick('round', self.now, 0))
        self.send.assert_called_once_with('round', 'set_rgb', [(20 << 24) | 0x18C2B0], attempts=1)

    def test_engine_finish_rejects_cached_black_in_either_slot(self):
        for slot in ('rgb', 'rgb2'):
            with self.subTest(slot=slot):
                rule = dict(rgb='18C2B0', rgb2='FFA020', bri=20, mode='alternate', takt=2)
                rule[slot] = '000000'
                engine = self.module.SignalEngine()
                engine.previous['round'] = ('regular:ppm', rule)
                with self.assertRaises(self.module.RuleValidationError):
                    engine.finish('round')
        self.send.assert_not_called()

    def test_explicit_zero_brightness_black_rule_remains_off(self):
        query = dict(rule='regular', rgb='000000', rgb2='000000', bri='0', mode='alternate', takt='2')
        self.assertTrue(self.module.save_settings('round', query)['ok'])
        with patch.object(self.module, 'set_light', return_value={'ok': True}) as light:
            self.assertTrue(self.module.test_signal('round', query)['ok'])
            light.assert_called_once_with('round', '18C2B0', 0)
        self.module._signal_tests.clear()
        self.feed()
        engine = self.module.SignalEngine()
        self.assertTrue(engine.tick('round', self.now, 0))
        self.assertTrue(engine.tick('round', self.now + 2, 2))
        self.assertEqual(self.send.call_args_list, [call('round', 'set_rgb', [0x18C2B0], attempts=1),call('round', 'set_rgb', [0], attempts=1)])

    def test_block_reservation_reduces_fsync_and_never_reuses_after_crash(self):
        with patch.object(self.module.os,'fsync',wraps=self.module.os.fsync) as sync:
            ids=[self.module._next_id() for _ in range(256)]
            self.assertEqual(ids,list(range(1,257)))
            self.assertEqual(sync.call_count,2)  # data + directory, once per block
            self.assertEqual(self.module._next_id(),257)
            self.assertEqual(sync.call_count,4)
        fresh=load(state_directory=self.tmp.name)
        self.assertEqual(fresh._next_id(),513)
        self.assertEqual(int(Path(self.module.ID_FILE).read_text()),768)

    def test_counter_file_failure_never_calls_or_blames_the_hub(self):
        module = load()
        module.ID_FILE = self.module.ID_FILE
        Path(module.ID_FILE).write_text('corrupt')
        with patch.object(module,'_connect') as connect:
            with self.assertRaises(module.MessageIdStateError) as caught:
                module.call('round','set_rgb',[1])
            connect.assert_not_called()
        with patch('sys.stderr',new_callable=io.StringIO) as journal:
            result=module.error_response(caught.exception)
        self.assertEqual(result['code'],'msgid_state')
        self.assertEqual(journal.getvalue(),'aqara-nightlight: message id state failed\n')

    def test_failed_reservation_does_not_issue_ids_or_damage_high_water_mark(self):
        Path(self.module.ID_FILE).write_text('10000')
        with patch.object(self.module.os,'replace',side_effect=OSError()), self.assertRaises(OSError):
            self.module._next_id()
        self.assertEqual(Path(self.module.ID_FILE).read_text(),'10000')
        self.assertEqual(self.module._next_id(),10001)

    def test_every_new_control_attribute_has_one_value_and_expected_identity(self):
        page=PageParser(self.module.PAGE)
        expected={'data-usage':{'nightlight','desk'},'data-duration':{'full','short'},'data-auto-duration':{'full','short'},
                  'data-tab':{'light','sounds','signal','rules','auto-tone','desks'},
                  'data-multiple':{'cycle','own'},
                  'data-rule':set(self.module.RULE_KEYS),'data-rule-mode':{'steady','blink','alternate'},
                  'data-rule-slot':{'rgb','rgb2'}, 'data-rule-color':{'18C2B0','FFA020','9B6BFF','8FA3B0','FF2A00','FFFFFF'},
                  'data-save-place':set(self.module.PRESET_IDS),'data-rename-place':set(self.module.PRESET_IDS),
                  'data-delete-place':set(self.module.PRESET_IDS),'data-rule-place':set(self.module.PRESET_IDS)}
        for attribute,values in expected.items():
            found=[]
            for tag,pairs in page.raw_elements:
                if tag!='button':continue
                keys=[key for key,_ in pairs]
                self.assertEqual(len(keys),len(set(keys)),pairs)
                found.extend(v for k,v in pairs if k==attribute)
            self.assertEqual(set(found),values,attribute)
            self.assertEqual(len(found),len(values),attribute)


class Version33Test(unittest.TestCase):
    request = ApiTest.request
    FAKE_KEY = "FAKE-DESK-SIGNAL-KEY-DO-NOT-USE"
    FAKE_REPLACEMENT = "FAKE-REPLACEMENT-KEY-DO-NOT-USE"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.module = load(state_directory=self.tmp.name)
        self.now = self.module.datetime.fromisoformat("2026-10-30T12:00:00+01:00").timestamp()
        self.payload = dict(hub="round", short="ABC", name="Example", url="https://desk.invalid", rgb="18C2B0", key=self.FAKE_KEY)
        self.guard = [("Host", "hsb1:8765"), ("X-Nightlight", "1"), ("X-Nightlight-Mode", "erwachsen")]

    def save_fake(self, **changes):
        with patch.object(self.module, "check_desk_key", return_value=True), patch("sys.stderr", new_callable=io.StringIO):
            return self.module.desk_action("round", {**self.payload, **changes})

    def seed(self, n=2):
        settings = {h:self.module._migrate_hub(v) for h,v in self.module._legacy_defaults().items()}
        for cfg in settings.values():
            for i in range(2, n):
                desk = json.loads(json.dumps(cfg["desks"][0]))
                desk.update(id=f"{i:032x}", short=f"D{i:03}", name="Example", rgb="AABBCC")
                cfg["desks"].append(desk)
                cfg["thresholds"][desk["id"]] = 4
                cfg["sound_generation"][desk["id"]] = 0
            cfg["desks"] = cfg["desks"][:n]
            for field in ("thresholds", "sound_generation"):
                cfg[field] = {d["id"]:cfg[field][d["id"]] for d in cfg["desks"]}
        self.module._atomic_json(self.module.SETTINGS_FILE, settings)
        return settings

    def feed(self, settings):
        return dict(version=1, updated_at=self.now, desks={d["id"]:dict(open=2, held=1, oldest_held_at=self.now-3600, oldest_expiry_at=None, generation=1) for d in settings["desks"]})

    def test_fresh_install_has_zero_desks_and_never_false_idle(self):
        cfg = self.module.get_settings()["settings"]["round"]
        self.assertEqual(cfg["desks"], [])
        for feed in (None, dict(desks={})):
            resolved = self.module.resolve_signal(cfg, feed, self.now)
            self.assertEqual(resolved["key"], "unknown")
            self.assertGreater(resolved["rule"]["bri"], 0)

    def test_settings_matrix_migration_is_lossless_atomic_and_idempotent(self):
        old = self.module._legacy_defaults()
        old["round"]["rules"]["regular:ppm"]["rgb"] = "123456"
        old["round"]["rules"]["urgent:pma"]["bri"] = 81
        old["round"]["rules"]["urgent:pma"]["rgb2"] = "ABCDEF"
        old["round"]["rules"]["open:both"]["rgb"] = "000000"
        old["round"]["seen"] = dict(ppm=4,pma=8)
        self.module.SETTINGS_FILE.write_text(json.dumps(old))
        with patch.object(self.module.os, "replace", wraps=self.module.os.replace) as replace:
            migrated = self.module._engine_settings("round")
            self.assertEqual(replace.call_count, 1)
            inode = self.module.SETTINGS_FILE.stat().st_ino
            raw = self.module.SETTINGS_FILE.read_bytes()
            self.assertEqual(self.module._engine_settings("round"), migrated)
            self.assertEqual(replace.call_count, 1)
            self.assertEqual(self.module.SETTINGS_FILE.stat().st_ino, inode)
            self.assertEqual(self.module.SETTINGS_FILE.read_bytes(), raw)
        self.assertEqual(migrated["legacy_rules"], old["round"]["rules"])
        self.assertEqual(migrated["desks"][0]["rgb"], "123456")
        self.assertEqual(migrated["rules"]["urgent"], old["round"]["rules"]["urgent:ppm"])
        self.assertTrue(migrated["desks"][1]["override"])
        self.assertEqual(migrated["desks"][1]["rules"]["urgent"]["bri"], 81)
        self.assertEqual(migrated["seen"], old["round"]["seen"])
        self.assertEqual(stat.S_IMODE(self.module.SETTINGS_FILE.stat().st_mode), 0o600)

    def test_invalid_matrix_and_failed_migration_preserve_original_bytes(self):
        old = self.module._legacy_defaults()
        old["round"]["rules"]["urgent:pma"]["takt"] = 1
        self.module.SETTINGS_FILE.write_text(json.dumps(old))
        before = self.module.SETTINGS_FILE.read_bytes()
        with self.assertRaises(self.module.SettingsStateError): self.module.get_settings()
        self.assertEqual(self.module.SETTINGS_FILE.read_bytes(), before)
        self.module.SETTINGS_FILE.write_text(json.dumps(self.module._legacy_defaults()))
        before = self.module.SETTINGS_FILE.read_bytes()
        with patch.object(self.module.os, "replace", side_effect=OSError()), self.assertRaises(OSError): self.module.get_settings()
        self.assertEqual(self.module.SETTINGS_FILE.read_bytes(), before)
        self.assertEqual(list(Path(self.tmp.name).glob(".settings-*")), [])

    def test_corrupt_new_schema_fails_closed_without_overwriting(self):
        settings = self.seed()
        for modify in (
            lambda s:s["round"].update(version=True),
            lambda s:s["round"]["desks"][0].update(id="../../outside"),
            lambda s:s["round"]["desks"][0].update(rgb="000000"),
            lambda s:s["round"]["multiple"].update(rgb="000000"),
            lambda s:s["round"]["desks"].append(s["round"]["desks"][0]),
        ):
            value = json.loads(json.dumps(settings)); modify(value)
            self.module.SETTINGS_FILE.write_text(json.dumps(value)); before = self.module.SETTINGS_FILE.read_bytes()
            with self.assertRaises(self.module.SettingsStateError): self.module.get_settings()
            self.assertEqual(self.module.SETTINGS_FILE.read_bytes(), before)

    def test_counts_capability_must_be_verified_on_test_and_every_save(self):
        for test in (False, True):
            with self.assertRaises(self.module.DeskKeyError): self.module.desk_action("round", self.payload, test=test)
            for verdict in (False, None, "true", {"counts_only":True}):
                with patch.object(self.module, "check_desk_key", return_value=verdict), self.assertRaises(self.module.DeskKeyError): self.module.desk_action("round", self.payload, test=test)
        self.assertFalse(self.module.KEY_DIRECTORY.exists())
        self.assertFalse(self.module.SETTINGS_FILE.exists())
        with patch.object(self.module, "check_desk_key", side_effect=RuntimeError(self.FAKE_KEY)), self.assertRaises(self.module.DeskKeyError) as caught:
            self.module.desk_action("round", self.payload)
        self.assertNotIn(self.FAKE_KEY, str(caught.exception))
        saved = self.save_fake()["settings"]["round"]["desks"][0]
        before = self.module.SETTINGS_FILE.read_bytes()
        with self.assertRaises(self.module.DeskKeyError): self.module.desk_action("round", dict(hub="round",id=saved["id"]))
        self.assertEqual(self.module.SETTINGS_FILE.read_bytes(), before)

    def test_key_modes_write_only_output_and_audit_never_contain_material(self):
        with patch.object(self.module, "check_desk_key", return_value=True), patch("sys.stderr", new_callable=io.StringIO) as log:
            result = self.module.desk_action("round", self.payload)
        cfg = self.module._engine_settings("round"); desk = cfg["desks"][0]
        path = self.module.KEY_DIRECTORY / desk["key_ref"]
        self.assertEqual(stat.S_IMODE(self.module.KEY_DIRECTORY.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(self.module._read_key(desk["key_ref"]), self.FAKE_KEY)
        public = json.dumps([result, self.module.get_settings(), self.module.signal_status("round")])
        self.assertNotIn(self.FAKE_KEY, public)
        self.assertNotIn("key_ref", public)
        self.assertNotIn(self.FAKE_KEY, log.getvalue())
        self.assertEqual(log.getvalue(), "aqara-nightlight: desk add\n")
        self.assertNotIn(self.FAKE_KEY, self.module.SETTINGS_FILE.read_text())
        self.assertEqual(cfg["history"][0]["action"], "add")
        self.assertEqual(set(cfg["history"][0]), {"action","short","at"})

    def test_test_only_never_persists_a_key_or_settings(self):
        with patch.object(self.module, "check_desk_key", return_value=True):
            self.assertEqual(self.module.desk_action("round",self.payload,test=True), {"ok":True,"counts_only":True})
        self.assertFalse(self.module.KEY_DIRECTORY.exists())
        self.assertFalse(self.module.SETTINGS_FILE.exists())

    def test_replace_and_remove_require_confirmation_and_leave_revoke_reminder(self):
        first = self.save_fake(); desk = first["settings"]["round"]["desks"][0]
        ref = self.module._engine_settings("round")["desks"][0]["key_ref"]
        with patch.object(self.module, "check_desk_key", return_value=True):
            with self.assertRaises(self.module.DeskKeyError): self.module.desk_action("round",{**self.payload,"id":desk["id"],"key":self.FAKE_REPLACEMENT})
            with self.assertRaises(self.module.DeskKeyError): self.module.desk_action("round",dict(id=desk["id"],action="remove"))
        replaced = self.save_fake(id=desk["id"],key=self.FAKE_REPLACEMENT,confirm="replace")
        self.assertTrue(replaced["revoke"])
        self.assertFalse((self.module.KEY_DIRECTORY / ref).exists())
        current = self.module._engine_settings("round")["desks"][0]
        self.assertEqual(self.module._read_key(current["key_ref"]),self.FAKE_REPLACEMENT)
        with patch("sys.stderr",new_callable=io.StringIO):
            removed = self.module.desk_action("round",dict(id=desk["id"],action="remove",confirm="remove"))
        self.assertTrue(removed["revoke"])
        self.assertEqual(removed["settings"]["round"]["desks"],[])
        self.assertEqual(list(self.module.KEY_DIRECTORY.iterdir()),[])
        self.assertEqual([e["action"] for e in removed["settings"]["round"]["history"]],["add","replace","remove"])

    def test_failed_key_or_settings_commit_preserves_previous_key_and_metadata(self):
        desk = self.save_fake()["settings"]["round"]["desks"][0]
        before = self.module.SETTINGS_FILE.read_bytes(); files = list(self.module.KEY_DIRECTORY.iterdir())
        replace = self.module.os.replace
        def fail_settings(source,target):
            if target == self.module.SETTINGS_FILE: raise OSError(self.FAKE_REPLACEMENT)
            return replace(source,target)
        for operation in ("settings","key"):
            with patch.object(self.module.os,"replace",side_effect=fail_settings if operation == "settings" else OSError(self.FAKE_REPLACEMENT)):
                with self.assertRaises(self.module.DeskKeyError): self.save_fake(id=desk["id"],key=self.FAKE_REPLACEMENT,confirm="replace")
            self.assertEqual(self.module.SETTINGS_FILE.read_bytes(),before)
            self.assertEqual(list(self.module.KEY_DIRECTORY.iterdir()),files)
            self.assertEqual(self.module._read_key(files[0].name),self.FAKE_KEY)

    def test_post_rename_sync_failure_never_deletes_a_committed_generation(self):
        desk = self.save_fake()["settings"]["round"]["desks"][0]
        atomic = self.module._atomic_json
        def fail_after_settings(path,value):
            atomic(path,value)
            if path == self.module.SETTINGS_FILE: raise OSError("FAKE-FSYNC-FAILURE")
        with patch.object(self.module,"_atomic_json",side_effect=fail_after_settings), self.assertRaises(self.module.DeskKeyError) as caught:
            self.save_fake(id=desk["id"],key=self.FAKE_REPLACEMENT,confirm="replace")
        committed = self.module._engine_settings("round")["desks"][0]
        self.assertEqual(self.module._read_key(committed["key_ref"]),self.FAKE_REPLACEMENT)
        self.assertEqual(len(list(self.module.KEY_DIRECTORY.iterdir())),2)
        self.assertTrue(self.module.error_response(caught.exception)["revoke"])

    def test_corrupt_key_directory_cannot_redirect_removal_outside_state(self):
        desk = self.save_fake()["settings"]["round"]["desks"][0]
        original = self.module.KEY_DIRECTORY
        retained = original.with_name("retained-private-keys")
        original.rename(retained)
        original.symlink_to(retained,target_is_directory=True)
        before = self.module.SETTINGS_FILE.read_bytes()
        with self.assertRaises(self.module.DeskKeyError):
            self.module.desk_action("round",dict(id=desk["id"],action="remove",confirm="remove"))
        self.assertEqual(len(list(retained.iterdir())),1)
        self.assertEqual(self.module.SETTINGS_FILE.read_bytes(),before)

    def test_hardlinked_and_oversized_key_files_are_not_read(self):
        desk = self.save_fake()["settings"]["round"]["desks"][0]
        path = next(self.module.KEY_DIRECTORY.iterdir())
        sibling = path.with_name("fake-hardlink")
        os.link(path,sibling)
        with self.assertRaises(self.module.DeskKeyError): self.module._read_key(path.name)
        sibling.unlink()
        path.write_text("FAKE"*1024)
        with self.assertRaises(self.module.DeskKeyError): self.module._read_key(path.name)

    def test_restore_and_wrong_key_permissions_report_missing_without_reading(self):
        desk = self.save_fake()["settings"]["round"]["desks"][0]
        path = next(self.module.KEY_DIRECTORY.iterdir())
        path.chmod(0o644)
        self.assertFalse(self.module.get_settings()["settings"]["round"]["desks"][0]["key_set"])
        with self.assertRaises(self.module.DeskKeyError): self.module._read_key(path.name)
        path.unlink()
        restored = load(state_directory=self.tmp.name).get_settings()["settings"]["round"]["desks"][0]
        self.assertEqual(restored["id"],desk["id"])
        self.assertFalse(restored["key_set"])

    def test_symlinked_key_directory_and_files_are_refused(self):
        elsewhere = Path(self.tmp.name)/"elsewhere"; elsewhere.mkdir()
        self.module.KEY_DIRECTORY.symlink_to(elsewhere, target_is_directory=True)
        with self.assertRaises(self.module.DeskKeyError): self.save_fake()
        self.assertEqual(list(elsewhere.iterdir()),[])
        self.assertFalse(self.module.SETTINGS_FILE.exists())

    def test_key_destinations_and_untrusted_scope_assertions_are_refused(self):
        for changes in (dict(url="http://desk.invalid"),dict(url="https://user:pass@desk.invalid"),dict(url="https://desk.invalid/other"),dict(url="https://desk.invalid?key=FAKE"),dict(counts_only="1"),dict(key="tiny"),dict(short="X"),dict(name=""),dict(rgb="000000")):
            with patch.object(self.module,"check_desk_key",return_value=True), self.assertRaises((self.module.DeskKeyError,self.module.SettingsStateError)):
                self.module.desk_action("round",{**self.payload,**changes})
        desk = self.save_fake()["settings"]["round"]["desks"][0]
        with patch.object(self.module,"check_desk_key",return_value=True) as verifier, self.assertRaises(self.module.DeskKeyError):
            self.module.desk_action("round",dict(id=desk["id"],url="https://other.invalid"))
        verifier.assert_not_called()

    def test_desk_http_requires_one_marker_adult_post_and_network_guards(self):
        denied = [[],[("X-Nightlight","1"),("X-Nightlight","1"),("X-Nightlight-Mode","erwachsen")],[("X-Nightlight","1"),("X-Nightlight-Mode","kind")],[("X-Nightlight","1"),("X-Nightlight-Mode","erwachsen"),("X-Nightlight-Mode","erwachsen")]]
        for endpoint in ("/desk","/desk-test"):
            for headers in denied:
                request = self.request(endpoint,headers=[("Host","hsb1:8765"),*headers],method="POST",body=self.payload)
                request.send_error.assert_called_once_with(403)
            for method in ("GET","OPTIONS"):
                self.request(endpoint,headers=self.guard,method=method).send_error.assert_called_once_with(403)
            for bad in (dict(peer="203.0.113.8"),dict(headers=[*self.guard,("Origin","https://foreign.invalid")]),dict(headers=[*self.guard,("Sec-Fetch-Site","cross-site")])):
                self.request(endpoint,method="POST",body=self.payload,**bad).send_error.assert_called_once_with(403)
            self.request(endpoint+"?key=FAKE-DO-NOT-USE",headers=self.guard,method="POST",body=self.payload).send_error.assert_called_once_with(403)
        self.assertFalse(self.module.KEY_DIRECTORY.exists())

    def test_desk_http_body_only_write_only_safe_refusal_and_success(self):
        refused = self.request("/desk",headers=self.guard,method="POST",body=self.payload)
        self.assertEqual(refused._reply.call_args.kwargs["status"],400)
        self.assertNotIn(self.FAKE_KEY,refused._reply.call_args.args[0].decode())
        with patch.object(self.module,"check_desk_key",return_value=True), patch("sys.stderr",new_callable=io.StringIO):
            accepted = self.request("/desk",headers=self.guard,method="POST",body=self.payload)
        self.assertTrue(json.loads(accepted._reply.call_args.args[0])["ok"])
        self.assertNotIn(self.FAKE_KEY,accepted._reply.call_args.args[0].decode())
        self.assertNotIn(self.FAKE_KEY,json.dumps(self.module.get_settings()))
        for body,extra in ((b"{",[]),(b"[]",[]),(b"{}",[("Content-Length","1"),("Content-Length","1")]),(b"{}",[("Transfer-Encoding","chunked")]),(b"{}",[("Content-Type","text/plain")])):
            handler = self.request("/desk",headers=[*self.guard,*extra],method="POST",body=body)
            self.assertEqual(handler._reply.call_args.kwargs["status"],400)

    def test_arbitrary_desks_only_highest_urgency_colours_cycle_each_takt(self):
        settings = self.seed(5); cfg = settings["round"]; feed = self.feed(cfg)
        resolved = self.module.resolve_signal(cfg,feed,self.now)
        self.assertEqual(resolved["colors"],[d["rgb"] for d in cfg["desks"]])
        feed["desks"]["pma"]["oldest_expiry_at"] = self.now+60
        resolved = self.module.resolve_signal(cfg,feed,self.now)
        self.assertEqual(resolved["key"],"urgent:pma")
        self.assertEqual(resolved["rule"]["rgb"],cfg["desks"][1]["rgb"])
        self.assertEqual(resolved["colors"],[])
        feed["desks"]["ppm"]["oldest_expiry_at"] = self.now+60
        resolved = self.module.resolve_signal(cfg,feed,self.now)
        self.assertEqual(resolved["colors"],["18C2B0","FFA020"])
        self.module.FEED_FILE.write_text(json.dumps(feed))
        engine = self.module.SignalEngine()
        with patch.object(self.module,"call",return_value=(["ok"],1)) as send:
            for phase in range(5):
                self.assertTrue(engine.tick("round",self.now+phase*2,phase*2))
                self.assertEqual(send.call_args.args[2][0],(60<<24)|int(resolved["colors"][phase%2],16))
                self.assertEqual(send.call_args.kwargs,{"attempts":1})
                self.assertFalse(engine.tick("round",self.now+phase*2+1,phase*2+1))
        self.assertEqual(engine.desk_applied["round"]["ppm"]["rgb"],"18C2B0")
        self.assertEqual(engine.desk_applied["round"]["pma"]["rgb"],"FFA020")

    def test_multiple_own_colour_override_and_incomplete_feed(self):
        cfg = self.seed()["round"]; feed = self.feed(cfg)
        before = self.module.SETTINGS_FILE.read_bytes()
        for query in (dict(multiple_mode="bad"),dict(multiple_rgb="000000"),dict(multiple_rgb="BAD")):
            with self.assertRaises(ValueError): self.module.save_settings("round",query)
            self.assertEqual(self.module.SETTINGS_FILE.read_bytes(),before)
        cfg["multiple"] = dict(mode="own",rgb="ABCDEF")
        resolved = self.module.resolve_signal(cfg,feed,self.now)
        self.assertEqual(resolved["rule"]["rgb"],"ABCDEF")
        self.assertEqual(resolved["colors"],[])
        cfg["desks"][0]["override"] = True
        cfg["desks"][0]["rules"]["regular"].update(bri=81,mode="alternate",rgb2="FF2A00",takt=5)
        feed["desks"]["pma"].update(open=0,held=0,oldest_held_at=None)
        resolved = self.module.resolve_signal(cfg,feed,self.now)
        self.assertEqual((resolved["rule"]["rgb"],resolved["rule"]["bri"],resolved["rule"]["takt"]),("18C2B0",81,5))
        del feed["desks"]["pma"]
        self.assertEqual(self.module.resolve_signal(cfg,feed,self.now)["key"],"unknown")

    @unittest.skipUnless(shutil.which("nix-instantiate"),"Nix is required for pure backup config evaluation")
    def test_restic_exclusion_is_in_actual_evaluated_compose_and_script(self):
        expression = 'let c = import ./hosts/hsb1/docker/compose-spec.nix; in { exclude = c.services.restic-cron-hetzner.environment.RESTIC_EXCLUDE_NIGHTLIGHT_KEYS; mounts = c.services.restic-cron-hetzner.volumes; }'
        result = subprocess.run(["nix-instantiate","--eval","--strict","--json","--expr",expression],cwd=ROOT,capture_output=True,text=True,check=True)
        value = json.loads(result.stdout)
        self.assertEqual(value["exclude"],"*/aqara-nightlight/desk-keys")
        self.assertIn("./restic-cron/hetzner/run_backup.sh:/usr/local/bin/run_backup.sh:ro",value["mounts"])
        script = (ROOT/"hosts/hsb1/docker/restic-cron/hetzner/run_backup.sh").read_text()
        self.assertIn('--exclude "${RESTIC_EXCLUDE_NIGHTLIGHT_KEYS:-*/aqara-nightlight/desk-keys}"',script)
        import fnmatch
        for root in ("/var/lib","/var/lib/private","/backup/var/lib/private"):
            self.assertTrue(fnmatch.fnmatch(root+"/aqara-nightlight/desk-keys",value["exclude"]))


    @unittest.skipUnless(shutil.which("restic"),"Restic is required to exercise its real exclusion matcher")
    def test_real_restic_snapshot_excludes_keys_at_both_state_roots(self):
        root = Path(self.tmp.name)
        source = root/"FAKE-BACKUP-SOURCE"
        for parent in (source/"var/lib",source/"var/lib/private",source/"backup/var/lib/private"):
            state = parent/"aqara-nightlight"
            keys = state/"desk-keys"
            keys.mkdir(parents=True)
            (keys/"FAKE-KEY-DO-NOT-USE").write_text(self.FAKE_KEY)
            (state/"settings.json").write_text('{"fixture":"FAKE-METADATA"}')
        password = root/"FAKE-RESTIC-PASSWORD-DO-NOT-USE"
        password.write_text("FAKE-LOCAL-TEST-PASSWORD-DO-NOT-USE")
        repository = root/"FAKE-LOCAL-RESTIC-REPOSITORY"
        args = [shutil.which("restic"),"--no-cache","--repo",str(repository),"--password-file",str(password)]
        def local(*arguments):
            return subprocess.run([*args,*arguments],check=True,text=True,capture_output=True,timeout=30).stdout
        local("init")
        local("backup","--exclude","*/aqara-nightlight/desk-keys",str(source))
        entries = [json.loads(line) for line in local("ls","--json","latest").splitlines()]
        paths = [e["path"] for e in entries if e.get("type") == "file"]
        self.assertEqual(len([p for p in paths if p.endswith("/settings.json")]),3)
        self.assertFalse(any("desk-keys" in p for p in paths))


class StreamingProgressTest(unittest.TestCase):
    parsed_request = ApiTest.parsed_request

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.module = load()
        self.module.STATE_DIRECTORY = Path(self.tmp.name)
        self.ids = patch.object(self.module, '_next_id', side_effect=range(101,120)).start()
        patch.object(self.module.time,'sleep').start()
        self.addCleanup(patch.stopall)

    def test_retry_frames_and_final_reply_share_one_guarded_response(self):
        lost,good=Mock(),Mock()
        lost.send.side_effect=TimeoutError()
        good.send.return_value=['ok']
        with patch.object(self.module,'_connect',side_effect=[lost,good]):
            headers,body=self.parsed_request(b'POST /set?hub=plug&rgb=5C0701&bri=44 HTTP/1.1\r\nHost: hsb1:8765\r\nX-Nightlight: 1\r\nAccept: application/x-ndjson\r\nContent-Length: 0\r\n\r\n')
        self.assertIn(b'application/x-ndjson',headers)
        frames=[json.loads(line) for line in body.splitlines()]
        self.assertEqual(frames[:-1],[dict(progress=1,attempts=4),dict(progress=2,attempts=4)])
        self.assertEqual(frames[-1]['versuche'],2)
        self.assertTrue(frames[-1]['ok'])
        self.assertIsNone(self.module._request_progress.callback)
        self.assertNotIn(b'access-control-',headers.lower())
        self.assertEqual(good.send.call_args_list[0].kwargs['extra_parameters'],{'id':102})

    def test_ha_without_stream_accept_keeps_plain_json_and_header_guards(self):
        good=Mock();good.send.return_value=['ok']
        with patch.object(self.module,'_connect',return_value=good):
            headers,body=self.parsed_request(b'GET /stop?hub=plug HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nX-Nightlight: 1\r\n\r\n')
        self.assertIn(b'application/json',headers)
        self.assertTrue(json.loads(body)['ok'])
        headers,body=self.parsed_request(b'POST /stop?hub=plug HTTP/1.1\r\nHost: hsb1:8765\r\nAccept: application/x-ndjson\r\nContent-Length: 0\r\n\r\n')
        self.assertIn(b'403 Forbidden',headers)
        self.assertNotIn(b'application/x-ndjson',headers)


class ColorRecoveryTest(unittest.TestCase):
    request = ApiTest.request

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.module = load(state_directory=self.tmp.name)
        self.send = patch.object(self.module, "call", return_value=(["ok"], 1)).start()
        patch.object(self.module.time, "sleep").start()
        self.addCleanup(patch.stopall)

    def color_path(self, hub="plug"):
        return Path(self.tmp.name, f"last-color-{hub}.json")

    def result(self, query):
        response = self.request(query, method="POST")
        return json.loads(response._reply.call_args.args[0])

    def test_set_recovers_saved_color_after_black_off_and_process_restart(self):
        self.assertTrue(self.result("/set?hub=plug&rgb=123456&bri=30")["ok"])
        self.assertTrue(self.result("/set?hub=plug&rgb=000000&bri=0")["ok"])
        fresh = load(state_directory=self.tmp.name)
        with patch.object(fresh, "call", return_value=(["ok"], 1)) as send:
            result = fresh.set_light("plug", "000000", 70)
        self.assertEqual(result["rgb"], "123456")
        self.assertEqual(send.call_args_list[0], call("plug", "set_rgb", [(70 << 24) | 0x123456]))
        self.assertEqual(json.loads(self.color_path().read_text()), "123456")

    def test_fallback_uses_each_hubs_saved_nacht_without_replacing_it(self):
        for hub, rgb in (("plug", "ABCDEF"), ("round", "123456")):
            self.module.save_preset(hub, "nacht", rgb, 44)
        before = self.module.PRESET_FILE.read_bytes()
        for hub, rgb in (("plug", "ABCDEF"), ("round", "123456")):
            result = self.result(f"/set?hub={hub}&rgb=000000&bri=65")
            self.assertEqual((result["rgb"], result["brightness"]), (rgb, 65))
        self.assertEqual(self.module.PRESET_FILE.read_bytes(), before)

    def test_missing_or_black_nacht_still_cannot_send_black_with_brightness(self):
        self.module.save_preset("plug", "nacht", "000000", 44)
        self.assertEqual(self.module.set_light("plug", "000000", 50)["rgb"], "5C0701")
        self.assertEqual(self.module.set_light("round", "000000", 50)["rgb"], "5C0701")

    def test_apply_updates_recovery_color_and_preserves_ha_response_shape(self):
        result = self.result("/apply?hub=round&preset=p2")
        self.assertEqual(set(result), {"ok", "hub", "cmd", "sent", "brightness", "rgb", "reply", "versuche"})
        self.assertEqual(json.loads(self.color_path("round").read_text()), "FF8C28")
        self.assertFalse(self.color_path("plug").exists())
        self.assertEqual(self.module.set_light("round", "000000", 80)["rgb"], "FF8C28")

    def test_readback_keeps_raw_black_and_exposes_per_hub_recovery_color(self):
        self.module.set_light("plug", "ABCDEF", 20)
        self.send.return_value = ([0, 42], 1)
        result = self.module.get_light("plug")
        self.assertEqual((result["raw"], result["rgb"], result["brightness"], result["last_rgb"]),
                         ("0x00000000", "000000", 0, "ABCDEF"))
        self.assertEqual(self.module.get_light("round")["last_rgb"], "5C0701")
        self.assertFalse(self.color_path("round").exists())

    def test_failed_set_never_changes_the_durable_color(self):
        self.module.set_light("plug", "123456", 20)
        before = self.color_path().read_bytes()
        self.send.side_effect = self.module.HubUnavailableError(4)
        self.assertFalse(self.result("/set?hub=plug&rgb=ABCDEF&bri=50")["ok"])
        self.assertEqual(self.color_path().read_bytes(), before)

    def test_atomic_color_file_is_private_and_failed_replace_preserves_previous(self):
        self.module.set_light("plug", "123456", 20)
        self.assertEqual(self.color_path().stat().st_mode & 0o777, 0o600)
        before = self.color_path().read_bytes()
        with patch.object(self.module.os, "replace", side_effect=OSError()):
            self.assertFalse(self.result("/set?hub=plug&rgb=ABCDEF&bri=50")["ok"])
        self.assertEqual(self.color_path().read_bytes(), before)
        self.assertEqual(list(Path(self.tmp.name).glob(".last-color-*")), [])

    def test_corrupt_color_state_fails_without_contacting_hub(self):
        for invalid in ('"000000"', '"GGGGGG"', '{}', 'broken'):
            self.color_path().write_text(invalid)
            self.send.reset_mock()
            self.assertFalse(self.result("/set?hub=plug&rgb=000000&bri=50")["ok"])
            self.send.assert_not_called()
            self.assertEqual(self.color_path().read_text(), invalid)

    def test_independent_hub_writers_preserve_both_colors(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda args: self.module.set_light(*args),
                                    (("plug", "123456", 20), ("round", "ABCDEF", 30))))
        self.assertTrue(all(r["ok"] for r in results))
        self.assertEqual(json.loads(self.color_path().read_text()), "123456")
        self.assertEqual(json.loads(self.color_path("round").read_text()), "ABCDEF")


if __name__ == "__main__":
    unittest.main()
