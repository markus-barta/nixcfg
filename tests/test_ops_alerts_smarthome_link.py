"""Unit tests for the OPS-115 smart-home link check.

Why this check exists, and therefore what these tests are protecting:

On 2026-07-29 hsb1's Node-RED container lost DNS and could no longer re-resolve
mosquitto.barta.cm to reconnect to the csb0 broker. Every Telegram /zufahrt was
accepted, permission-checked, logged as success on csb0, and published to a
broker with no subscriber. The access gate was dead for two days. Every existing
check stayed green, because Home Assistant was healthy and both pollers were
running (OPS-113).

The check reads a retained heartbeat that hsb1 publishes THROUGH that broker, so
it goes stale for the same reasons a real command would be dropped.

The cases below are the ones that decide whether it pages or not, so each is
pinned:

  * unreachable broker and empty topic are DIFFERENT facts and must read
    differently — "I cannot tell" is not "it is broken"
  * milliseconds vs seconds, because Node-RED's inject emits epoch ms and
    misreading it as seconds dates the heartbeat to 1970 and pages forever
  * the boundary either side of maxAgeSeconds, because an off-by-one here is
    either a permanent false page or a check that never fires
"""

from __future__ import annotations

import json
import sys
import time
import types
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CHECKS = REPO / "hosts" / "csb0" / "ops-alerts-checks.py"

LINK = {
    "name": "hsb1 smart-home link",
    "host": "127.0.0.1",
    "port": 1883,
    "topic": "scom/jhw22/heartbeat/hsb1",
    "maxAgeSeconds": 600,
}


def load_checks():
    """Render the poller the way lib.nix does, then import it with engine stubbed.

    mkPoller substitutes the @..._JSON@ placeholders at build time, so the file
    on disk is not importable as-is. Doing the same substitution here means the
    tests exercise the real source rather than a copy that can drift from it.
    """
    source = CHECKS.read_text()
    source = source.replace("@TARGETS_JSON@", json.dumps([]))
    source = source.replace("@PEERS_JSON@", json.dumps([]))
    source = source.replace("@SMARTHOME_LINKS_JSON@", json.dumps([LINK]))
    assert "@" not in source.split("json.loads(r")[1][:40], "a placeholder survived"

    engine_stub = types.ModuleType("engine")

    class Problem:  # mirrors engine.Problem's shape, not its behaviour
        def __init__(self, identifier: str, text: str) -> None:
            self.identifier = identifier
            self.text = text

    engine_stub.Problem = Problem
    engine_stub.EXIT_UNDELIVERED = 2
    engine_stub.run_cycle = lambda *a, **k: 0
    engine_stub.telegram_sender = lambda *a, **k: (lambda *_: True)
    sys.modules["engine"] = engine_stub

    module = types.ModuleType("ops_alerts_checks")
    module.__dict__["__file__"] = str(CHECKS)
    exec(compile(source, str(CHECKS), "exec"), module.__dict__)  # noqa: S102
    return module


checks = load_checks()


class SmarthomeLinkTest(unittest.TestCase):
    def setUp(self) -> None:
        self.calls: list[tuple] = []
        self._real = checks.read_retained
        checks.os.environ["MQTT_USER"] = "probe"
        checks.os.environ["MQTT_PASS"] = "secret"

    def tearDown(self) -> None:
        checks.read_retained = self._real

    def stub(self, result):
        def fake(host, port, user, password, topic, timeout):
            self.calls.append((host, port, topic))
            if isinstance(result, Exception):
                raise result
            return result

        checks.read_retained = fake

    def only(self, problems):
        self.assertEqual(len(problems), 1, f"expected exactly one problem, got {problems}")
        return problems[0].text

    # -- credentials ------------------------------------------------------

    def test_missing_credentials_is_a_problem_not_a_crash(self):
        checks.os.environ["MQTT_USER"] = ""
        text = self.only(checks.check_smarthome_link(LINK))
        self.assertIn("credentials", text)

    # -- broker reachability ---------------------------------------------

    def test_unreachable_broker_says_unverifiable_not_broken(self):
        self.stub(ConnectionRefusedError("nope"))
        text = self.only(checks.check_smarthome_link(LINK))
        self.assertIn("cannot read the local MQTT broker", text)
        self.assertIn("unverifiable", text)

    def test_empty_topic_is_reported_differently_from_unreachable(self):
        self.stub(None)
        text = self.only(checks.check_smarthome_link(LINK))
        self.assertIn("nothing retained", text)
        self.assertNotIn("unverifiable", text)

    # -- payload parsing --------------------------------------------------

    def test_garbage_payload_is_reported(self):
        self.stub(b"not-a-timestamp")
        self.assertIn("not a timestamp", self.only(checks.check_smarthome_link(LINK)))

    def test_milliseconds_are_recognised(self):
        # Node-RED's inject emits epoch ms. Read as seconds this is 1970 and the
        # check would page forever.
        self.stub(str(int(time.time() * 1000)).encode())
        self.assertEqual(checks.check_smarthome_link(LINK), [])

    def test_seconds_are_tolerated(self):
        self.stub(str(int(time.time())).encode())
        self.assertEqual(checks.check_smarthome_link(LINK), [])

    def test_whitespace_is_tolerated(self):
        self.stub(b"  " + str(int(time.time() * 1000)).encode() + b"\n")
        self.assertEqual(checks.check_smarthome_link(LINK), [])

    # -- staleness boundary -----------------------------------------------

    def test_fresh_heartbeat_is_silent(self):
        self.stub(str(int((time.time() - 60) * 1000)).encode())
        self.assertEqual(checks.check_smarthome_link(LINK), [])

    def test_just_inside_the_limit_is_silent(self):
        self.stub(str(int((time.time() - 590) * 1000)).encode())
        self.assertEqual(checks.check_smarthome_link(LINK), [])

    def test_past_the_limit_pages_and_names_the_consequence(self):
        self.stub(str(int((time.time() - 3600) * 1000)).encode())
        text = self.only(checks.check_smarthome_link(LINK))
        self.assertIn("60 min ago", text)
        # The operator must be told what is actually broken for a user, not just
        # that a number is large.
        self.assertIn("access gate", text)
        self.assertIn("bot still reports success", text)

    # -- wiring ------------------------------------------------------------

    def test_the_probe_targets_the_configured_broker_and_topic(self):
        self.stub(str(int(time.time() * 1000)).encode())
        checks.check_smarthome_link(LINK)
        self.assertEqual(self.calls, [("127.0.0.1", 1883, "scom/jhw22/heartbeat/hsb1")])

    def test_collect_runs_the_link_check(self):
        self.stub(str(int((time.time() - 3600) * 1000)).encode())
        self.assertEqual(len(checks.collect()), 1, "collect() must include the link check")


if __name__ == "__main__":
    unittest.main()
