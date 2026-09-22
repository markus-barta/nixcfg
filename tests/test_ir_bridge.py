"""Bridge-side contracts for hosts/hsb1/files/ir-bridge.py (OPS-224, OPS-225).

  * every IRCC code in the button map is well-formed base64 — the NIX-186 `back`
    code was 19 characters and the TV answered HTTP 500 on every press
  * an HTTP answer from the TV is final: one POST per press, no sleep; a
    transport error still retries
  * key events older than STALE_EVENT_MS are dropped instead of replayed
  * SIGTERM unwinds the blocking read loop (SystemExit) instead of waiting for
    systemd's stop timeout
"""

from __future__ import annotations

import base64
import contextlib
import importlib.util
import io
import logging
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "hosts/hsb1/files/ir-bridge.py"


class RequestFailure(Exception):
    pass


class FakeResponse:
    def __init__(self, status_code):
        self.status_code = status_code


class FakeSession:
    def __init__(self):
        self.trust_env = True
        self.calls = []
        self.outcomes = []

    def post(self, url, **kwargs):
        self.calls.append((url, kwargs))
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return FakeResponse(outcome)


requests = types.ModuleType("requests")
requests.exceptions = types.SimpleNamespace(RequestException=RequestFailure)
requests.Session = FakeSession
sys.modules["requests"] = requests

ecodes = types.SimpleNamespace(EV_MSC=4, MSC_SCAN=4, EV_KEY=1)
evdev = types.ModuleType("evdev")
evdev.InputDevice = lambda path: types.SimpleNamespace(name="fixture", close=lambda: None)
evdev.categorize = lambda event: event
evdev.ecodes = ecodes
sys.modules["evdev"] = evdev

spec = importlib.util.spec_from_file_location("ir_bridge", BRIDGE)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
bridge.CONFIG.update({"sony_tv_psk": "non-secret-fixture", "mqtt_broker": ""})


class KeyEvent:
    """Shape of a categorized evdev key event, plus the raw event's timestamp()."""

    key_down = 1
    key_hold = 2
    type = ecodes.EV_KEY
    code = 0

    def __init__(self, scancode, stamp, keystate=1):
        self.scancode = scancode
        self.keystate = keystate
        self._stamp = stamp

    def timestamp(self):
        return self._stamp


def make_bridge():
    logging.getLogger("ir-bridge").handlers.clear()
    with contextlib.redirect_stdout(io.StringIO()):
        return bridge.IRBridge()


class ButtonMapTest(unittest.TestCase):
    def test_every_ircc_code_is_well_formed(self):
        for code, (name, ircc) in bridge.BUTTONS.items():
            if ircc is None:
                continue
            with self.subTest(key=name):
                self.assertEqual(len(ircc), 20, f"{name}: Sony IRCC codes are 20 base64 chars")
                self.assertEqual(len(base64.b64decode(ircc, validate=True)), 13)

    def test_back_is_the_tv_return_code(self):
        self.assertEqual(bridge.BUTTONS[1], ("back", "AAAAAgAAAJcAAAAjAw=="))

    def test_volume_pair_is_unchanged(self):
        # Daily-verified physical behaviour; see the map's NOTE before touching.
        self.assertEqual(bridge.BUTTONS[114], ("volumeup", "AAAAAQAAAAEAAAATAw=="))
        self.assertEqual(bridge.BUTTONS[115], ("volumedown", "AAAAAQAAAAEAAAASAw=="))

    def test_only_back_changed_from_the_nix186_map(self):
        # The TV table advertises other values for transport/app/channel keys;
        # they are adopted only after each button is verified physically.
        self.assertEqual(bridge.BUTTONS[164], ("play", "AAAAAQAAAAEAAAANAw=="))
        self.assertEqual(bridge.BUTTONS[20], ("channelup", "AAAAAQAAAAEAAAA+Aw=="))


class SendTest(unittest.TestCase):
    def test_http_answer_is_final_one_post_no_sleep(self):
        instance = make_bridge()
        for status in (404, 500, 307):
            with self.subTest(status=status):
                instance.http.calls.clear()
                instance.http.outcomes = [status, 200, 200]
                with patch.object(bridge.time, "sleep") as sleep:
                    self.assertFalse(instance._send_ircc("fixture-code", "fixture"))
                self.assertEqual(len(instance.http.calls), 1)
                sleep.assert_not_called()

    def test_transport_error_is_one_post_too(self):
        # A retry after a read timeout can duplicate a command the TV already
        # executed; the press is simply lost and the viewer presses again.
        instance = make_bridge()
        instance.http.outcomes = [RequestFailure("timeout"), 200]
        with patch.object(bridge.time, "sleep") as sleep:
            self.assertFalse(instance._send_ircc("fixture-code", "fixture"))
        self.assertEqual(len(instance.http.calls), 1)
        sleep.assert_not_called()

    def test_post_uses_tight_lan_timeouts_and_no_redirects(self):
        instance = make_bridge()
        instance.http.outcomes = [200]
        self.assertTrue(instance._send_ircc("fixture-code", "fixture"))
        _, kwargs = instance.http.calls[0]
        self.assertEqual(kwargs["timeout"], (1.0, 2.0))
        self.assertIs(kwargs["allow_redirects"], False)


class StaleEventTest(unittest.TestCase):
    def run_events(self, events, now):
        instance = make_bridge()
        instance.running = True
        instance.input_device = types.SimpleNamespace(read_loop=lambda: iter(events))
        handled = []
        instance._handle_key = lambda code, held: handled.append((code, held))
        with patch.object(bridge.time, "time", return_value=now):
            instance._read_loop()
        return handled

    def test_stale_press_is_dropped_fresh_press_is_handled(self):
        stale = KeyEvent(114, stamp=100.0)
        fresh = KeyEvent(115, stamp=104.5)
        self.assertEqual(self.run_events([stale, fresh], now=105.0), [(115, False)])

    def test_hold_events_are_subject_to_the_same_cutoff(self):
        held = KeyEvent(114, stamp=90.0, keystate=KeyEvent.key_hold)
        self.assertEqual(self.run_events([held], now=105.0), [])


class ShutdownTest(unittest.TestCase):
    def test_sigterm_unwinds_with_systemexit(self):
        instance = make_bridge()
        instance.running = True
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as raised:
            instance._signal(15, None)
        self.assertEqual(raised.exception.code, 0)
        self.assertFalse(instance.running)


if __name__ == "__main__":
    unittest.main()
