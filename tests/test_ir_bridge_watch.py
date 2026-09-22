"""Unit + engine-integration tests for the hsb1 IR bridge witness (OPS-223).

Pins the decisions that make it page (or not):

  * a missing systemd invocation marker, a missing FLIRC node and a broken TV
    API are three independent problems with stable keys
  * the TV check pages on 404 / 5xx / redirect / non-JSON from a REACHABLE TV,
    and never on a TV that is off or unreachable (transport error)
  * through the real engine: one run does not page (confirm-before-alert), the
    second does, and recovery announces a clear
"""

from __future__ import annotations

import importlib.util
import io
import json
import sys
import tempfile
import types
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("engine", ROOT / "modules/shared/fleet-alerts/engine.py")
engine = importlib.util.module_from_spec(SPEC)
sys.modules["engine"] = engine
SPEC.loader.exec_module(engine)


def load(replacements):
    """Render the poller the way lib.nix does, then import it against the real engine."""
    relative = "hosts/hsb1/ir-bridge-watch.py"
    source = (ROOT / relative).read_text()
    for key, value in replacements.items():
        source = source.replace(f"@{key}@", value)
    assert "@" + "NOTIFICATION_ENV" + "@" not in source
    module = types.ModuleType("ir_bridge_watch")
    module.__dict__["__file__"] = str(ROOT / relative)
    exec(compile(source, str(ROOT / relative), "exec"), module.__dict__)
    return module


checks = load({
    "NOTIFICATION_ENV": "/nonexistent/notify.env",
    "FLIRC_DEVICE": "/nonexistent/flirc-event-kbd",
    "SONY_SYSTEM_URL": "http://192.0.2.1/sony/system",
})


class LocalChecksTest(unittest.TestCase):
    def test_missing_marker_and_node_are_two_problems(self):
        with patch.object(checks, "UNIT_MARKER", "/nonexistent/invocation"):
            self.assertEqual([p.key for p in checks.check_unit()], ["ir-bridge:unit"])
        self.assertEqual([p.key for p in checks.check_flirc()], ["ir-bridge:flirc"])

    def test_present_marker_and_node_are_clean(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp, "invocation")
            node = Path(tmp, "flirc")
            marker.write_text("")
            node.write_text("")
            with patch.object(checks, "UNIT_MARKER", str(marker)), patch.object(checks, "FLIRC_DEVICE", str(node)):
                self.assertEqual(checks.check_unit(), [])
                self.assertEqual(checks.check_flirc(), [])

    def test_flirc_text_points_at_the_replug_runbook(self):
        (problem,) = checks.check_flirc()
        self.assertIn("OPS-222", problem.text)
        self.assertIn("replug", problem.text)


class TvApiTest(unittest.TestCase):
    def probe(self, body=None, error=None):
        response = Mock()
        response.__enter__ = Mock(return_value=response)
        response.__exit__ = Mock(return_value=None)
        response.read.return_value = body if body is not None else b""
        opener = Mock()
        opener.open.side_effect = error
        opener.open.return_value = response
        with patch.object(checks.urllib.request, "build_opener", return_value=opener):
            return checks.tv_api_status(), opener

    def http_error(self, code):
        return urllib.error.HTTPError("http://192.0.2.1/sony/system", code, "fixture", {}, io.BytesIO())

    def test_live_api_is_ok_and_posts_to_the_literal_url(self):
        status, opener = self.probe(json.dumps({"result": [{"status": "active"}], "id": 50}).encode())
        self.assertEqual(status, "ok")
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, "http://192.0.2.1/sony/system")
        self.assertEqual(json.loads(request.data)["method"], "getPowerStatus")

    def test_standby_is_still_a_live_api(self):
        status, _ = self.probe(json.dumps({"result": [{"status": "standby"}], "id": 50}).encode())
        self.assertEqual(status, "ok")

    def test_404_and_5xx_page(self):
        for code in (404, 500, 503):
            with self.subTest(code=code):
                self.assertEqual(self.probe(error=self.http_error(code))[0], f"http_{code}")
                with patch.object(checks, "tv_api_status", return_value=f"http_{code}"):
                    (problem,) = checks.check_tv_api()
                self.assertEqual(problem.key, "tv:api")
                self.assertIn("Restart the TV", problem.text)

    def test_redirect_is_not_followed_and_pages(self):
        self.assertEqual(self.probe(error=self.http_error(302))[0], "http_302")

    def test_unreachable_tv_never_pages(self):
        for error in (urllib.error.URLError("refused"), TimeoutError(), OSError("network down")):
            with self.subTest(error=type(error).__name__):
                self.assertEqual(self.probe(error=error)[0], "unreachable")
        with patch.object(checks, "tv_api_status", return_value="unreachable"):
            self.assertEqual(checks.check_tv_api(), [])

    def test_non_json_and_error_envelope_page(self):
        self.assertEqual(self.probe(b"<html>nginx</html>")[0], "invalid")
        self.assertEqual(self.probe(json.dumps({"error": [404, "Not Found"]}).encode())[0], "invalid")


class EngineIntegrationTest(unittest.TestCase):
    def test_confirms_then_pages_then_clears(self):
        sent: list[str] = []

        def sender(text: str, identifier: str) -> bool:
            sent.append(text)
            return True

        with tempfile.TemporaryDirectory() as tmp:
            state = str(Path(tmp, "state.json"))
            broken = [checks.Problem("tv:api", "hsb1: Sony TV is reachable but its control API answers http_404")]
            self.assertEqual(engine.run_cycle(state, 1000, lambda: broken, checks.render, sender), engine.EXIT_PROBLEMS)
            self.assertEqual(sent, [], "one bad run must never page")
            self.assertEqual(engine.run_cycle(state, 1300, lambda: broken, checks.render, sender), engine.EXIT_PROBLEMS)
            self.assertEqual(len(sent), 1)
            self.assertIn("\U0001f534 IR bridge (hsb1):", sent[0])
            self.assertIn("http_404", sent[0])
            self.assertEqual(engine.run_cycle(state, 1600, lambda: [], checks.render, sender), engine.EXIT_CLEAN)
            self.assertEqual(len(sent), 2)
            self.assertIn("✅ Cleared", sent[1])


if __name__ == "__main__":
    unittest.main()
