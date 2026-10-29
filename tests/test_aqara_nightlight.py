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
from pathlib import Path
from unittest.mock import Mock, call, patch

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

    def test_all_23_tones_and_ui_defaults(self):
        tones = [tone for _, items in self.module.TONES for tone in items]
        self.assertEqual([i for i, _ in tones], list(range(9)) + list(range(10, 14)) + list(range(20, 30)))
        self.assertEqual(len(tones), 23)
        for i, name in tones:
            self.assertIn(f'data-t="{i}"', self.module.PAGE)
            self.assertIn(name, self.module.PAGE)
        self.assertIn('id=bri min=0 max=100 value=10', self.module.PAGE)
        self.assertIn("$('col').value='#ff8c28';$('bri').value=10", self.module.PAGE)
        self.assertIn('id=vol min=1 max=100 value=15', self.module.PAGE)

    def test_allowed_peers_cover_only_loopback_lan_and_tailnet(self):
        for peer in ("127.0.0.1", "::1", "192.168.1.42", "100.64.0.1", "100.127.255.254"):
            self.assertTrue(self.module.allowed_peer(peer), peer)
        for peer in ("192.168.2.1", "100.63.255.255", "100.128.0.1", "203.0.113.1", "2001:db8::1", "invalid"):
            self.assertFalse(self.module.allowed_peer(peer), peer)

    def request(self, path, peer="192.168.1.42"):
        handler = object.__new__(self.module.H)
        handler.path, handler.client_address = path, (peer, 12345)
        handler._reply = Mock()
        handler.send_error = Mock()
        handler.do_GET()
        return handler

    def test_http_routes_and_response_shape(self):
        for path, function, args in (
            ("/set?hub=plug&rgb=FF8C28&bri=10", "set_light", ("plug", "FF8C28", "10")),
            ("/get?hub=round", "get_light", ("round",)),
            ("/tone?hub=plug&id=27", "play_tone", ("plug", "27", 15)),
            ("/stop?hub=round", "stop_sound", ("round",)),
        ):
            with self.subTest(path=path), patch.object(self.module, function, return_value={"ok": True}) as route:
                handler = self.request(path)
                route.assert_called_once_with(*args)
                self.assertEqual(json.loads(handler._reply.call_args.args[0]), {"ok": True})
        self.assertEqual(self.request("/")._reply.call_args.args[0], self.module.PAGE.encode())

    def test_denied_http_peer_never_sends_a_command(self):
        with patch.object(self.module, "stop_sound") as stop:
            handler = self.request("/stop?hub=plug", peer="203.0.113.1")
        handler.send_error.assert_called_once_with(403)
        handler._reply.assert_not_called()
        stop.assert_not_called()

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


if __name__ == "__main__":
    unittest.main()
