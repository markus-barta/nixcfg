from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "hosts" / "csb1" / "hausv-alerts-poll.py"
SPEC = importlib.util.spec_from_file_location("hausv_alerts_poll", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("unable to load HAUSV alert poller")
poller = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = poller
SPEC.loader.exec_module(poller)

NOW = 1_800_000_000.0


def systemd_output(**values: str) -> str:
    return "\n".join(f"{key}={value}" for key, value in values.items()) + "\n"


class Fixture:
    def __init__(self) -> None:
        self.marker_age = 60 * 60
        self.restic = {
            "state": "healthy",
            "last_attempt_state": "succeeded",
            "last_success_at": NOW - 60 * 60,
        }
        self.timer = systemd_output(
            LoadState="loaded",
            UnitFileState="enabled",
            ActiveState="active",
            Result="success",
            ExecMainStatus="0",
        )
        self.service = systemd_output(
            LoadState="loaded",
            UnitFileState="static",
            ActiveState="inactive",
            Result="success",
            ExecMainStatus="0",
        )
        self.inspect = "true|healthy|0\n"
        self.logs = ""
        self.health = b'{"service":"hausv-org","status":"ok"}'
        self.docker_calls = 0

    def runner(self, args: list[str]) -> poller.CommandResult:
        if args[:2] == ["systemctl", "show"]:
            output = self.timer if args[2].endswith(".timer") else self.service
            return poller.CommandResult(0, output, "")
        if args[:2] == ["docker", "inspect"]:
            self.docker_calls += 1
            return poller.CommandResult(0, self.inspect, "")
        if args[:2] == ["docker", "logs"]:
            self.docker_calls += 1
            return poller.CommandResult(0, self.logs, "")
        raise AssertionError(f"unexpected command: {args!r}")

    def reader(self, path: str) -> str:
        if path == poller.SNAPSHOT_MARKER:
            value = datetime.fromtimestamp(
                NOW - self.marker_age, timezone.utc
            ).isoformat()
            return value + "\n"
        if path == poller.RESTIC_STATUS:
            return json.dumps(self.restic)
        raise AssertionError(f"unexpected read: {path}")

    def health_reader(self) -> bytes:
        return self.health

    def state(self) -> dict:
        return poller.safe_state({}, NOW)

    def evaluate(self, state: dict | None = None, now: float = NOW):
        return poller.evaluate(
            state or self.state(),
            now,
            self.runner,
            self.reader,
            self.health_reader,
        )


class HausvAlertTests(unittest.TestCase):
    def test_healthy_cycle_has_no_alert(self) -> None:
        fixture = Fixture()
        sent: list[tuple[str, str]] = []
        with tempfile.TemporaryDirectory() as directory:
            state_path = str(Path(directory) / "state.json")
            result, counts = poller.run_cycle(
                state_path,
                NOW,
                lambda text, event: sent.append((text, event)) or True,
                fixture.runner,
                fixture.reader,
                fixture.health_reader,
            )
            state = json.loads(Path(state_path).read_text())

        self.assertEqual(result, 0)
        self.assertEqual(counts, {"active": 0, "new": 0, "recovered": 0})
        self.assertEqual(sent, [])
        self.assertEqual(
            set(state),
            {
                "schema",
                "active",
                "failure_counts",
                "runtime_last_seen",
                "log_cursor",
                "container_restarts",
            },
        )

    def test_snapshot_chain_failures_are_immediate(self) -> None:
        fixture = Fixture()
        fixture.timer = systemd_output(
            LoadState="loaded",
            UnitFileState="disabled",
            ActiveState="inactive",
            Result="success",
            ExecMainStatus="0",
        )
        fixture.service = systemd_output(
            LoadState="loaded",
            UnitFileState="static",
            ActiveState="failed",
            Result="exit-code",
            ExecMainStatus="1",
        )
        fixture.marker_age = 31 * 60 * 60
        fixture.restic["state"] = "failed"

        problems, _state = fixture.evaluate()

        self.assertEqual(
            set(problems),
            {
                "snapshot-timer",
                "snapshot-service",
                "snapshot-marker",
                "restic-status",
            },
        )

    def test_public_health_needs_two_cycles_and_recovers(self) -> None:
        fixture = Fixture()
        fixture.health = b'{"status":"degraded"}'

        first, first_state = fixture.evaluate()
        second, second_state = fixture.evaluate(first_state, NOW + 60)
        fixture.health = b'{"service":"hausv-org","status":"ok"}'
        third, third_state = fixture.evaluate(second_state, NOW + 120)

        self.assertNotIn("public-health", first)
        self.assertEqual(first_state["failure_counts"]["public-health"], 1)
        self.assertIn("public-health", second)
        self.assertEqual(second_state["failure_counts"]["public-health"], 2)
        self.assertNotIn("public-health", third)
        self.assertNotIn("public-health", third_state["failure_counts"])

    def test_runtime_state_and_text_never_include_raw_values(self) -> None:
        fixture = Fixture()
        fixture.logs = "\n".join(
            [
                (
                    "2027-01-15T08:00:00Z "
                    '{"level":"ERROR","msg":"magic link delivery failed",'
                    '"email":"sentinel@example.test","token":"sentinel-token",'
                    '"chat_id":"-123456"}'
                ),
                "malformed-line",
            ]
        )

        problems, state = fixture.evaluate()
        keys = sorted(problems)
        identifier = poller.event_id(NOW, keys, [])
        text = poller.transition_text(NOW, problems, keys, [], identifier)
        rendered = json.dumps(state, sort_keys=True) + text

        self.assertIn("runtime:mail", problems)
        self.assertIn("runtime:log-contract", problems)
        for sentinel in ("sentinel@example.test", "sentinel-token", "-123456"):
            self.assertNotIn(sentinel, rendered)

    def test_alarm_is_deduplicated_and_recovery_is_sent_once(self) -> None:
        fixture = Fixture()
        sent: list[tuple[str, str]] = []

        def sender(text: str, event: str) -> bool:
            sent.append((text, event))
            return True

        with tempfile.TemporaryDirectory() as directory:
            state_path = str(Path(directory) / "state.json")
            fixture.marker_age = 31 * 60 * 60
            first, _ = poller.run_cycle(
                state_path,
                NOW,
                sender,
                fixture.runner,
                fixture.reader,
                fixture.health_reader,
            )
            second, _ = poller.run_cycle(
                state_path,
                NOW + 60,
                sender,
                fixture.runner,
                fixture.reader,
                fixture.health_reader,
            )
            fixture.marker_age = 60 * 60
            third, _ = poller.run_cycle(
                state_path,
                NOW + 120,
                sender,
                fixture.runner,
                fixture.reader,
                fixture.health_reader,
            )

        self.assertEqual((first, second, third), (1, 1, 0))
        self.assertEqual(len(sent), 2)
        self.assertIn("Neuer Alarm", sent[0][0])
        self.assertIn("Entwarnung", sent[1][0])

    def test_failed_delivery_retries_the_same_pending_event(self) -> None:
        fixture = Fixture()
        fixture.marker_age = 31 * 60 * 60
        failed: list[tuple[str, str]] = []
        retried: list[tuple[str, str]] = []

        with tempfile.TemporaryDirectory() as directory:
            state_path = str(Path(directory) / "state.json")
            first, _ = poller.run_cycle(
                state_path,
                NOW,
                lambda text, event: failed.append((text, event)) or False,
                fixture.runner,
                fixture.reader,
                fixture.health_reader,
            )
            pending = json.loads(Path(state_path).read_text())["pending"]
            second, _ = poller.run_cycle(
                state_path,
                NOW + 60,
                lambda text, event: retried.append((text, event)) or True,
                fixture.runner,
                fixture.reader,
                fixture.health_reader,
            )
            final_state = json.loads(Path(state_path).read_text())

        self.assertEqual((first, second), (2, 1))
        self.assertEqual(failed, retried)
        self.assertEqual(pending["event_id"], retried[0][1])
        self.assertNotIn("pending", final_state)

    def test_planned_snapshot_holds_existing_application_signals(self) -> None:
        fixture = Fixture()
        fixture.service = systemd_output(
            LoadState="loaded",
            UnitFileState="static",
            ActiveState="active",
            Result="success",
            ExecMainStatus="0",
        )
        state = fixture.state()
        state["active"] = ["public-health", "runtime:mail"]
        state["failure_counts"] = {"public-health": 2}
        state["runtime_last_seen"] = {
            "mail": NOW - poller.RUNTIME_QUIET_SECONDS + 1
        }
        fixture.health = b"broken"

        problems, next_state = fixture.evaluate(state, NOW + 2)

        self.assertIn("public-health", problems)
        self.assertIn("runtime:mail", problems)
        self.assertEqual(next_state["failure_counts"], {"public-health": 2})
        self.assertEqual(fixture.docker_calls, 0)

    def test_delivery_probe_and_target_contract(self) -> None:
        target = poller.parse_notification_target(
            "telegram://test-token@telegram?chats=-123,456"
        )
        sent: list[tuple[str, str]] = []

        delivered = poller.delivery_probe(
            lambda text, event: sent.append((text, event)) or True,
            NOW,
        )

        self.assertEqual(target["kind"], "telegram")
        self.assertEqual(target["recipients"], ["-123", "456"])
        self.assertTrue(delivered)
        self.assertEqual(len(sent), 2)
        self.assertNotEqual(sent[0][1], sent[1][1])
        self.assertIn("Testalarm", sent[0][0])
        self.assertIn("Testentwarnung", sent[1][0])


if __name__ == "__main__":
    unittest.main()
