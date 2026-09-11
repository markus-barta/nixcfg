import ast
import importlib.util
import json
import sys
import tempfile
import threading
import unittest
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
READER_SPEC = importlib.util.spec_from_file_location(
    "official_window_reader", HERE / "official-window-reader.py"
)
assert READER_SPEC is not None and READER_SPEC.loader is not None
READER = importlib.util.module_from_spec(READER_SPEC)
sys.modules[READER_SPEC.name] = READER
READER_SPEC.loader.exec_module(READER)

INSTALLER_SPEC = importlib.util.spec_from_file_location(
    "install_official_sdk", HERE / "install-official-sdk.py"
)
assert INSTALLER_SPEC is not None and INSTALLER_SPEC.loader is not None
INSTALLER = importlib.util.module_from_spec(INSTALLER_SPEC)
INSTALLER_SPEC.loader.exec_module(INSTALLER)

ACCOUNT = "DUR970597"


class Clock:
    def __init__(self):
        self.second = 0

    def __call__(self):
        value = f"2026-09-11T12:00:{self.second:02d}.000Z"
        self.second += 1
        return value


class FakeBroker:
    sdk_version = "10.45.1"
    server_version = 223
    execution_request_framing = "protobuf"

    def __init__(self, plans=(), managed_accounts=None):
        self.plans = list(plans)
        self.managed_accounts = managed_accounts or [ACCOUNT]
        self.calls = []
        self.stopped = 0
        self.sink = None

    def start(self, sink, host, port, client_id, account):
        self.calls.append(("start", host, port, client_id, account))
        self.sink = sink
        sink.on_ready(self.managed_accounts)

    def request_executions(self, request_id, execution_filter):
        self.calls.append(("reqExecutions", request_id, dict(execution_filter)))
        self.plans.pop(0)(self.sink, request_id)

    def stop(self):
        self.calls.append(("stop",))
        self.stopped += 1


def contract(**overrides):
    values = {
        "conId": 1001,
        "symbol": "msft",
        "secType": "stk",
        "currency": "usd",
        "multiplier": "",
        "exchange": "smart",
    }
    values.update(overrides)
    return SimpleNamespace(**values)


def execution(exec_id="synthetic.trade.01", **overrides):
    values = {
        "execId": exec_id,
        "time": "20260910 12:00:00 US/Eastern",
        "acctNumber": ACCOUNT,
        "clientId": 56,
        "orderId": 10,
        "permId": 20,
        "side": "BOT",
        "shares": Decimal("1.25"),
        "price": Decimal("10.50"),
        "avgPrice": Decimal("10.50"),
        "orderRef": "",
        "modelCode": "",
        "pendingPriceRevision": False,
    }
    values.update(overrides)
    return SimpleNamespace(**values)


def commission(exec_id="synthetic.trade.01", amount="0.25"):
    return SimpleNamespace(
        execId=exec_id,
        commissionAndFees=Decimal(amount),
        currency="usd",
        realizedPNL=Decimal("2.75"),
        yield_=Decimal("0"),
        yieldRedemptionDate=0,
    )


def plan():
    return {
        "startedAt": "2026-09-11T12:00:00.000Z",
        "requestedCoverage": {
            "fromInclusive": "2026-09-10T04:00:00.000Z",
            "toExclusive": "2026-09-11T08:00:00.000Z",
        },
        "actualWindows": [
            {
                "requestId": 9300,
                "newYorkDate": 20260910,
                "fromInclusive": "2026-09-10T04:00:00.000Z",
                "toExclusive": "2026-09-11T04:00:00.000Z",
                "filter": {
                    "acctCode": ACCOUNT,
                    "time": "20260910-04:00:00",
                    "specificDates": [20260910],
                },
            },
            {
                "requestId": 9301,
                "newYorkDate": 20260911,
                "fromInclusive": "2026-09-11T04:00:00.000Z",
                "toExclusive": "2026-09-11T08:00:00.000Z",
                "filter": {
                    "acctCode": ACCOUNT,
                    "time": "20260911-04:00:00",
                    "specificDates": [20260911],
                },
            },
        ],
    }


def wire_request(value=None):
    value = value or plan()
    return {
        "schema": READER.REQUEST_SCHEMA,
        "schemaVersion": 1,
        "endpoint": {"host": "gateway", "port": 4002, "clientId": 94, "account": ACCOUNT},
        **value,
    }


def make_reader(*plans, request_timeout=0.1, quiet_period=0.01, final_drain_timeout=0.1, **broker_options):
    broker = FakeBroker(plans, **broker_options)
    config = READER.ReaderConfig(
        "gateway", 4002, 94, ACCOUNT,
        startup_timeout=0.1,
        request_timeout=request_timeout,
        quiet_period=quiet_period,
        final_drain_timeout=final_drain_timeout,
    )
    reader = READER.OfficialWindowReader(config, broker, now=Clock())
    return reader, broker


class OfficialWindowReaderTests(unittest.TestCase):
    def test_filters_are_serial_and_corrections_pending_flag_and_empty_date_are_preserved(self):
        def first(sink, request_id):
            sink.on_execution(request_id, contract(), execution("synthetic.trade.01"))
            sink.on_execution(
                request_id,
                contract(),
                execution("synthetic.trade.02", price=Decimal("10.75"), pendingPriceRevision=True),
            )
            sink.on_commission(commission("synthetic.trade.01"))
            sink.on_commission(commission("synthetic.trade.02"))
            sink.on_execution_end(request_id)

        def second(sink, request_id):
            sink.on_execution_end(request_id)

        reader, broker = make_reader(first, second, quiet_period=0)
        result = reader.run(plan())
        self.assertEqual(result["schemaVersion"], 1)
        self.assertEqual(result["endpoint"], {"host": "gateway", "port": 4002, "clientId": 94, "account": ACCOUNT})
        self.assertEqual(result["negotiated"]["executionRequestFraming"], "protobuf")
        self.assertEqual(result["managedAccounts"], [ACCOUNT])
        self.assertFalse(result["foreignAccountViolation"])
        self.assertTrue(result["disconnected"])
        self.assertEqual(result["exitCode"], 0)
        self.assertEqual([call[0] for call in broker.calls], ["start", "reqExecutions", "reqExecutions", "stop"])
        self.assertEqual(broker.calls[1][2], plan()["actualWindows"][0]["filter"])
        self.assertEqual(broker.calls[2][2], plan()["actualWindows"][1]["filter"])
        rows = result["requests"]["9300"]["executions"]
        self.assertEqual([row["execution"]["execId"] for row in rows], ["synthetic.trade.01", "synthetic.trade.02"])
        self.assertTrue(rows[1]["execution"]["pendingPriceRevision"])
        self.assertEqual(result["requests"]["9301"]["executions"], [])
        self.assertEqual(
            set(result["commissionsByExecId"]),
            {"synthetic.trade.01", "synthetic.trade.02"},
        )

    def test_execution_and_fee_after_end_reset_quiet_period_and_are_retained(self):
        def late(sink, request_id):
            sink.on_execution_end(request_id)
            threading.Timer(0.005, lambda: sink.on_execution(request_id, contract(), execution())).start()
            threading.Timer(0.01, lambda: sink.on_commission(commission())).start()

        first_only = {**plan(), "requestedCoverage": {
            "fromInclusive": "2026-09-10T04:00:00.000Z",
            "toExclusive": "2026-09-11T04:00:00.000Z",
        }, "actualWindows": plan()["actualWindows"][:1]}
        reader, _ = make_reader(late, quiet_period=0.02)
        result = reader.run(first_only)
        self.assertIn("synthetic.trade.01", result["commissionsByExecId"])
        self.assertEqual(len(result["requests"]["9300"]["executions"]), 1)
        self.assertEqual(result["errors"], [])

    def test_unmatched_execution_and_orphan_commission_fail_the_run(self):
        first_only = {**plan(), "requestedCoverage": {
            "fromInclusive": "2026-09-10T04:00:00.000Z",
            "toExclusive": "2026-09-11T04:00:00.000Z",
        }, "actualWindows": plan()["actualWindows"][:1]}
        def missing(sink, request_id):
            sink.on_execution(request_id, contract(), execution())
            sink.on_execution_end(request_id)

        reader, _ = make_reader(missing, quiet_period=0)
        result = reader.run(first_only)
        self.assertEqual(result["requests"]["9300"]["errors"][0]["code"], "missing-commission-callbacks")
        self.assertEqual(result["errors"][0]["code"], "missing-commission-callbacks")

        def orphan(sink, request_id):
            sink.on_execution_end(request_id)
            sink.on_commission(commission("never-returned.01"))

        reader, _ = make_reader(orphan, quiet_period=0)
        result = reader.run(first_only)
        self.assertEqual(result["requests"]["9300"]["errors"][0]["code"], "orphan-commission-callbacks")
        self.assertEqual(result["errors"][0]["code"], "orphan-commission-callbacks")

    def test_true_empty_waits_for_quiet_and_late_previous_request_fails_whole_run(self):
        def empty(sink, request_id):
            sink.on_execution_end(request_id)

        started = READER.time.monotonic()
        reader, _ = make_reader(empty, empty, quiet_period=0.01)
        result = reader.run(plan())
        self.assertGreaterEqual(READER.time.monotonic() - started, 0.025)
        self.assertEqual(result["errors"], [])
        self.assertTrue(all(not request["executions"] for request in result["requests"].values()))

        def first(sink, request_id):
            sink.on_execution_end(request_id)

        def second(sink, request_id):
            sink.on_execution_end(request_id)
            threading.Timer(
                0.002,
                lambda: sink.on_execution(9300, contract(), execution("late.previous.01")),
            ).start()

        reader, _ = make_reader(first, second, quiet_period=0.01)
        result = reader.run(plan())
        self.assertEqual(result["requests"]["9301"]["errors"][0]["code"], "unexpected-execution-request-id")
        self.assertEqual(result["errors"][0]["code"], "unexpected-execution-request-id")

    def test_final_run_drain_catches_a_callback_after_last_request_quiet(self):
        first_only = {**plan(), "requestedCoverage": {
            "fromInclusive": "2026-09-10T04:00:00.000Z",
            "toExclusive": "2026-09-11T04:00:00.000Z",
        }, "actualWindows": plan()["actualWindows"][:1]}

        def late_orphan(sink, request_id):
            sink.on_execution_end(request_id)
            threading.Timer(0.015, lambda: sink.on_commission(commission("final.orphan.01"))).start()

        reader, _ = make_reader(
            late_orphan,
            quiet_period=0.01,
            final_drain_timeout=0.05,
        )
        result = reader.run(first_only)
        self.assertEqual(result["requests"]["9300"]["errors"], [])
        self.assertEqual(result["errors"][0]["code"], "orphan-commission-callbacks")

    def test_dormant_farm_codes_are_informational_without_resetting_quiet(self):
        observations = []

        class InformationalBroker(FakeBroker):
            def start(self, sink, host, port, client_id, account):
                super().start(sink, host, port, client_id, account)
                before = sink._last_callback_monotonic
                sink.on_broker_error(-1, 2107)
                sink.on_broker_error(-1, 2108)
                observations.append(("ready", before, sink._last_callback_monotonic))

        def informational_query_and_quiet(sink, request_id):
            before_query = sink._last_callback_monotonic
            sink.on_broker_error(request_id, 2107)
            sink.on_broker_error(request_id, 2108)
            observations.append(("query", before_query, sink._last_callback_monotonic))
            sink.on_execution_end(request_id)
            before_quiet = sink._last_callback_monotonic
            sink.on_broker_error(request_id, 2107)
            sink.on_broker_error(request_id, 2108)
            observations.append(("quiet", before_quiet, sink._last_callback_monotonic))

        first_only = {**plan(), "requestedCoverage": {
            "fromInclusive": "2026-09-10T04:00:00.000Z",
            "toExclusive": "2026-09-11T04:00:00.000Z",
        }, "actualWindows": plan()["actualWindows"][:1]}
        broker = InformationalBroker([informational_query_and_quiet])
        reader = READER.OfficialWindowReader(
            READER.ReaderConfig(
                "gateway", 4002, 94, ACCOUNT,
                startup_timeout=0.1,
                request_timeout=0.1,
                quiet_period=0.005,
                final_drain_timeout=0.1,
            ),
            broker,
            now=Clock(),
        )
        result = reader.run(first_only)
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["requests"]["9300"]["errors"], [])
        self.assertEqual(observations, [
            ("ready", None, None),
            ("query", None, None),
            ("quiet", observations[2][1], observations[2][1]),
        ])

    def test_connectivity_and_farm_failure_codes_remain_fail_closed(self):
        first_only = {**plan(), "requestedCoverage": {
            "fromInclusive": "2026-09-10T04:00:00.000Z",
            "toExclusive": "2026-09-11T04:00:00.000Z",
        }, "actualWindows": plan()["actualWindows"][:1]}
        for code, expected in [(2110, "broker-session-retired"), (2103, "broker-request-error"), (2105, "broker-request-error")]:
            with self.subTest(code=code):
                def failure(sink, request_id, broker_code=code):
                    sink.on_broker_error(request_id, broker_code)

                reader, _ = make_reader(failure)
                result = reader.run(first_only)
                self.assertEqual(result["errors"][0]["code"], expected)
                self.assertEqual(result["requests"]["9300"]["errors"][0]["code"], expected)

    def test_foreign_account_and_pending_flag_fail_closed(self):
        first_only = {**plan(), "requestedCoverage": {
            "fromInclusive": "2026-09-10T04:00:00.000Z",
            "toExclusive": "2026-09-11T04:00:00.000Z",
        }, "actualWindows": plan()["actualWindows"][:1]}

        def foreign(sink, request_id):
            sink.on_execution(request_id, contract(), execution(acctNumber="DU999999"))
            sink.on_execution_end(request_id)

        reader, _ = make_reader(foreign)
        result = reader.run(first_only)
        self.assertTrue(result["foreignAccountViolation"])
        self.assertEqual(result["requests"]["9300"]["errors"][0]["code"], "foreign execution account")

        def malformed_pending(sink, request_id):
            sink.on_execution(
                request_id,
                contract(currency="bad"),
                execution(acctNumber="DU999999", pendingPriceRevision=None),
            )
            sink.on_execution_end(request_id)

        reader, _ = make_reader(malformed_pending)
        result = reader.run(first_only)
        self.assertEqual(
            result["requests"]["9300"]["errors"][0]["code"],
            "execution.pendingPriceRevision must be boolean",
        )
        self.assertFalse(result["foreignAccountViolation"])

    def test_timeout_is_bounded_and_never_an_empty_success(self):
        first_only = {**plan(), "requestedCoverage": {
            "fromInclusive": "2026-09-10T04:00:00.000Z",
            "toExclusive": "2026-09-11T04:00:00.000Z",
        }, "actualWindows": plan()["actualWindows"][:1]}
        reader, broker = make_reader(lambda _sink, _request_id: None, request_timeout=0.01)
        result = reader.run(first_only)
        request = result["requests"]["9300"]
        self.assertTrue(request["timedOut"])
        self.assertIsNone(request["endedAt"])
        self.assertEqual(request["errors"][0]["code"], "execution-query-timeout")
        self.assertEqual(broker.stopped, 1)

    def test_direct_protocol_rejects_wrong_identity_and_malformed_windows(self):
        config, normalized = READER.validate_plan(wire_request())
        self.assertEqual(config.port, 4002)
        self.assertEqual(config.client_id, 94)
        self.assertEqual(normalized, plan())
        for endpoint in [
            {"host": "gateway", "port": 4001, "clientId": 94, "account": ACCOUNT},
            {"host": "gateway", "port": 4002, "clientId": 93, "account": ACCOUNT},
            {"host": "gateway", "port": 4002, "clientId": 94, "account": "DU999999"},
        ]:
            with self.assertRaises(READER.ProtocolError):
                READER.validate_plan({**wire_request(), "endpoint": endpoint})
        broken = wire_request()
        broken["actualWindows"][0]["filter"]["specificDates"] = [20260909]
        with self.assertRaises(READER.ProtocolError):
            READER.validate_plan(broken)

    def test_official_adapter_call_surface_is_read_only_allowlisted(self):
        source = (HERE / "official-window-reader.py").read_text(encoding="utf-8")
        tree = ast.parse(source)
        invoked = {
            node.func.attr
            for node in ast.walk(tree)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr.startswith("req")
        }
        self.assertEqual(invoked, {"reqManagedAccts", "reqExecutions", "request_executions"})
        self.assertNotIn("placeOrder", source)
        self.assertNotIn("reqMktData", source)

    def test_output_byte_limit_and_installer_lock_are_enforced(self):
        with patch.object(READER, "MAX_OUTPUT_BYTES", 10):
            with self.assertRaisesRegex(READER.ProtocolError, "output limit"):
                READER.encode_result({"large": "value"})
        lock = INSTALLER.load_lock(HERE / "official-sdk.lock.json")
        self.assertEqual(lock["officialSdk"]["version"], "10.45.1")
        self.assertEqual(lock["dependencies"][0]["version"], "5.29.6")


if __name__ == "__main__":
    unittest.main()
