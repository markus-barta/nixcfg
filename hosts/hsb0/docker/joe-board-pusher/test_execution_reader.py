"""Synthetic offline tests for the official execution reader seam."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import tempfile
import threading
import time
import unittest
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from types import SimpleNamespace

from execution_reader import (
    COMMISSION_GRACE_SECONDS,
    ExecutionReader,
    FATAL_SESSION_CODES,
    MAX_DATES,
    MAX_OUTPUT_BYTES,
    PER_DATE_TIMEOUT_SECONDS,
    ProtocolError,
    ReaderConfig,
    REQUEST_SCHEMA,
    RESULT_SCHEMA,
    STARTUP_TIMEOUT_SECONDS,
    canonical_execution,
    handle_line,
    managed_account_matches,
    serve_jsonl,
    validate_runtime,
)


ACCOUNT = "DU123456"
HERE = Path(__file__).resolve().parent
INSTALLER_SPEC = importlib.util.spec_from_file_location(
    "install_official_sdk", HERE / "install-official-sdk.py"
)
assert INSTALLER_SPEC is not None and INSTALLER_SPEC.loader is not None
INSTALLER = importlib.util.module_from_spec(INSTALLER_SPEC)
INSTALLER_SPEC.loader.exec_module(INSTALLER)


@dataclass
class Plan:
    callback: object


class FakeBroker:
    sdk_version = "10.45.1"
    server_version = 223
    framing = "protobuf"

    def __init__(self, plans=()):
        self.plans = list(plans)
        self.sink = None
        self.stopped = 0
        self.requests = []

    def start(self, sink, host, port, client_id, account):
        self.sink = sink
        self.start_args = (host, port, client_id, account)
        sink.on_ready()

    def request_executions(self, request_id, account, day):
        self.requests.append((request_id, account, day))
        callback = self.plans.pop(0)
        callback(self.sink, request_id)

    def stop(self):
        self.stopped += 1


def contract(**overrides):
    values = {
        "conId": 123,
        "symbol": "synt",
        "secType": "stk",
        "currency": "usd",
        "multiplier": "",
    }
    values.update(overrides)
    return SimpleNamespace(**values)


def execution(exec_id="synthetic.1.01", **overrides):
    values = {
        "execId": exec_id,
        "time": "20260910 12:00:00 US/Eastern",
        "acctNumber": ACCOUNT,
        "clientId": 27,
        "side": "BOT",
        "shares": Decimal("2.5"),
        "price": 10.25,
        "pendingPriceRevision": False,
    }
    values.update(overrides)
    return SimpleNamespace(**values)


def commission(exec_id="synthetic.1.01", amount=Decimal("0.35")):
    return SimpleNamespace(execId=exec_id, commissionAndFees=amount, currency="usd", realizedPNL=999)


def request(cycle="cycle-1", dates=None, account=ACCOUNT):
    return {
        "schema": REQUEST_SCHEMA,
        "cycleId": cycle,
        "account": account,
        "specificDates": dates or ["20260910"],
    }


def reader_with(*plans, timeout=0.1, commission_grace=0.02, max_records=50_000):
    broker = FakeBroker(plans)
    reader = ExecutionReader(
        ReaderConfig(
            "gateway",
            4002,
            94,
            ACCOUNT,
            connect_timeout=timeout,
            request_timeout=timeout,
            commission_grace=commission_grace,
        ),
        broker,
        max_records=max_records,
    )
    reader.start()
    return reader, broker


class ExecutionReaderTests(unittest.TestCase):
    def test_seam_constants_match_state_worker_deadline_contract(self):
        self.assertEqual(MAX_DATES, 7)
        self.assertEqual(MAX_OUTPUT_BYTES, 16 * 1024 * 1024)
        self.assertEqual(STARTUP_TIMEOUT_SECONDS, 15.0)
        self.assertEqual(PER_DATE_TIMEOUT_SECONDS, 20.0)
        self.assertEqual(COMMISSION_GRACE_SECONDS, 1.0)

        reader, _ = reader_with(lambda sink, request_id: sink.on_execution_end(request_id))
        result = reader.process(request("seam-contract"))
        self.assertEqual(result["schema"], RESULT_SCHEMA)
        self.assertEqual(result["account"], ACCOUNT)
        self.assertEqual(result["sdkVersion"], "10.45.1")
        self.assertIn(result["framing"], {"protobuf", "legacy-extended"})
        self.assertIn("errors", result["requests"][0])
        self.assertIsInstance(result["finishedAt"], str)

    def test_runtime_and_request_protocol_gates(self):
        self.assertEqual(validate_runtime("gateway", 4002, 94, ACCOUNT).client_id, 94)
        for port, client_id in [(4001, 94), (4003, 94), (4002, 92), (4002, 93)]:
            with self.assertRaises(ProtocolError):
                validate_runtime("gateway", port, client_id, ACCOUNT)

        reader, _ = reader_with(lambda sink, request_id: sink.on_execution_end(request_id))
        for invalid in [
            {**request(), "schema": "wrong"},
            {**request(), "account": "DU999999"},
            {**request(), "specificDates": []},
            {**request(), "specificDates": ["20260911", "20260910"]},
            {**request(), "specificDates": ["20260230"]},
            {**request(), "host": "override"},
        ]:
            self.assertTrue(reader.process(invalid)["errors"])

        self.assertTrue(managed_account_matches(f"OTHER,{ACCOUNT}", ACCOUNT))
        self.assertFalse(managed_account_matches("OTHER,DU999999", ACCOUNT))

        old_broker = FakeBroker()
        old_broker.server_version = 199
        old_broker.framing = "unsupported"
        old_reader = ExecutionReader(ReaderConfig("gateway", 4002, 94, ACCOUNT), old_broker)
        with self.assertRaisesRegex(ProtocolError, "does not support"):
            old_reader.start()
        self.assertEqual(old_broker.stopped, 1)

    def test_malformed_and_oversized_input_each_get_one_terminal_reply(self):
        reader, _ = reader_with()
        malformed = handle_line(reader, b"{not-json}\n")
        oversized = handle_line(reader, b"x" * (64 * 1024 + 1))
        nonstandard = handle_line(reader, b'{"schema":NaN}\n')
        for encoded in [malformed, oversized, nonstandard]:
            self.assertEqual(encoded.count(b"\n"), 1)
            result = json.loads(encoded)
            self.assertEqual(result["schema"], "inspr.ib.execution-query.result.v1")
            self.assertTrue(result["errors"])
            self.assertEqual(result["requests"], [])

    def test_fees_arriving_after_execution_end_complete_the_cycle(self):
        def plan(sink, request_id):
            sink.on_execution(request_id, contract(), execution())
            sink.on_execution_end(request_id)
            threading.Timer(0.01, lambda: sink.on_commission(commission())).start()

        reader, broker = reader_with(plan)
        result = reader.process(request())
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["requests"][0]["errors"], [])
        self.assertIsNotNone(result["requests"][0]["endedAt"])
        self.assertEqual(result["commissions"], [{"execId": "synthetic.1.01", "commission": 0.35, "currency": "USD"}])
        self.assertEqual(broker.requests[0][2], "20260910")

    def test_partial_timeout_never_becomes_an_empty_success(self):
        def missing_end(sink, request_id):
            sink.on_execution(request_id, contract(), execution())

        reader, _ = reader_with(missing_end, timeout=0.01)
        result = reader.process(request())
        self.assertEqual(len(result["requests"][0]["executions"]), 1)
        self.assertIsNone(result["requests"][0]["endedAt"])
        self.assertEqual(result["errors"][0]["code"], "execution-query-timeout")
        self.assertEqual(result["errors"][0]["phase"], "execDetailsEnd")

    def test_missing_unrelated_fee_returns_complete_executions_and_captured_fees(self):
        def missing_unrelated_fee(sink, request_id):
            sink.on_execution(request_id, contract(), execution("joe.1.01"))
            sink.on_commission(commission("joe.1.01"))
            sink.on_execution(request_id, contract(conId=124), execution("unrelated.1.01"))
            sink.on_execution_end(request_id)

        reader, _ = reader_with(missing_unrelated_fee, timeout=0.2, commission_grace=0.01)
        started = time.monotonic()
        result = reader.process(request())
        elapsed = time.monotonic() - started
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["requests"][0]["errors"], [])
        self.assertIsNotNone(result["requests"][0]["endedAt"])
        self.assertEqual(
            [row["execution"]["execId"] for row in result["requests"][0]["executions"]],
            ["joe.1.01", "unrelated.1.01"],
        )
        self.assertEqual(
            result["commissions"],
            [{"execId": "joe.1.01", "commission": 0.35, "currency": "USD"}],
        )
        self.assertLess(elapsed, 0.2)

    def test_delayed_fee_within_grace_is_retained(self):
        def delayed_fee(sink, request_id):
            sink.on_execution(request_id, contract(), execution())
            sink.on_execution_end(request_id)
            threading.Timer(0.01, lambda: sink.on_commission(commission())).start()

        reader, _ = reader_with(delayed_fee, timeout=0.2, commission_grace=0.05)
        result = reader.process(request("delayed-fee"))
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["requests"][0]["errors"], [])
        self.assertEqual(
            result["commissions"],
            [{"execId": "synthetic.1.01", "commission": 0.35, "currency": "USD"}],
        )

    def test_fatal_notifications_retire_idle_helper_sessions(self):
        for code in sorted(FATAL_SESSION_CODES):
            with self.subTest(code=code):
                reader, broker = reader_with()
                reader.on_broker_error(-1, code)
                self.assertTrue(reader.retired)
                self.assertEqual(broker.stopped, 1)
                unavailable = reader.process(request(f"fatal-{code}"))
                self.assertEqual(unavailable["errors"][0]["code"], "broker connection is unavailable")
                reader.on_ready()
                self.assertTrue(reader.retired)
                reader.close()
                self.assertEqual(broker.stopped, 1)

    def test_idle_jsonl_wait_exits_when_fatal_notification_retires_session(self):
        reader, broker = reader_with()
        read_fd, write_fd = os.pipe()
        input_stream = os.fdopen(read_fd, "rb")
        output_stream = io.BytesIO()
        os.write(write_fd, b'{"partial":')
        timer = threading.Timer(0.01, lambda: reader.on_broker_error(-1, 2110))
        started = time.monotonic()
        timer.start()
        try:
            serve_jsonl(reader, input_stream, output_stream, poll_timeout=0.01)
        finally:
            timer.join()
            input_stream.close()
            os.close(write_fd)
        self.assertLess(time.monotonic() - started, 0.2)
        self.assertEqual(output_stream.getvalue(), b"")
        self.assertTrue(reader.retired)
        self.assertEqual(broker.stopped, 1)

    def test_fatal_notification_fails_active_request_and_retires_session(self):
        def session_loss(sink, request_id):
            sink.on_broker_error(request_id, 1101)
            sink.on_disconnect()

        reader, broker = reader_with(session_loss)
        result = reader.process(request("active-session-loss"))
        expected = {"code": "broker-session-retired", "brokerCode": 1101}
        self.assertEqual(result["requests"][0]["errors"], [expected])
        self.assertEqual(result["errors"], [expected])
        self.assertTrue(reader.retired)
        self.assertEqual(broker.stopped, 1)

    def test_exact_duplicates_deduplicate_and_conflicts_fail(self):
        def exact(sink, request_id):
            for _ in range(2):
                sink.on_execution(request_id, contract(), execution())
                sink.on_commission(commission())
            sink.on_execution_end(request_id)

        reader, _ = reader_with(exact)
        result = reader.process(request())
        self.assertEqual(result["errors"], [])
        self.assertEqual(len(result["requests"][0]["executions"]), 1)
        self.assertEqual(len(result["commissions"]), 1)

        def conflict(sink, request_id):
            sink.on_execution(request_id, contract(), execution())
            sink.on_execution(request_id, contract(), execution(price=11.0))
            sink.on_execution_end(request_id)

        reader, _ = reader_with(conflict)
        result = reader.process(request("cycle-conflict"))
        self.assertEqual(result["errors"][0]["code"], "conflicting duplicate execution")

        def fee_conflict(sink, request_id):
            sink.on_execution(request_id, contract(), execution())
            sink.on_commission(commission(amount=Decimal("0.35")))
            sink.on_commission(commission(amount=Decimal("0.36")))

        reader, _ = reader_with(fee_conflict)
        result = reader.process(request("cycle-fee-conflict"))
        self.assertEqual(result["errors"][0]["code"], "conflicting duplicate commission")

    def test_duplicate_cycle_id_is_rejected_without_a_second_broker_request(self):
        def empty(sink, request_id):
            sink.on_execution_end(request_id)

        reader, broker = reader_with(empty)
        self.assertEqual(reader.process(request())["errors"], [])
        result = reader.process(request())
        self.assertEqual(result["errors"][0]["code"], "cycleId has already been used")
        self.assertEqual(len(broker.requests), 1)

    def test_date_queries_are_serial_and_commission_before_execution_is_joined(self):
        order = []

        def first(sink, request_id):
            order.append("first")
            sink.on_commission(commission("earlier.1.01"))
            sink.on_execution(request_id, contract(), execution("earlier.1.01"))
            sink.on_execution_end(request_id)

        def second(sink, request_id):
            order.append("second")
            sink.on_execution_end(request_id)

        reader, _ = reader_with(first, second)
        result = reader.process(request(dates=["20260909", "20260910"]))
        self.assertEqual(result["errors"], [])
        self.assertEqual(order, ["first", "second"])
        self.assertEqual([item["date"] for item in result["requests"]], ["20260909", "20260910"])

    def test_decimal_loss_sentinels_and_foreign_account_are_rejected(self):
        with self.assertRaisesRegex(ProtocolError, "round-trip"):
            canonical_execution(contract(), execution(shares=Decimal("1.0000000000000000001")), ACCOUNT)
        with self.assertRaisesRegex(ProtocolError, "finite"):
            canonical_execution(contract(), execution(price=float("nan")), ACCOUNT)
        with self.assertRaisesRegex(ProtocolError, "configured account"):
            canonical_execution(contract(), execution(acctNumber="DU999999"), ACCOUNT)

    def test_other_desk_cash_and_option_contract_multipliers_are_preserved(self):
        cash = canonical_execution(
            contract(conId=12087792, symbol="eur", secType="cash", currency="usd", multiplier=""),
            execution("other.cash.01", clientId=22),
            ACCOUNT,
        )
        option = canonical_execution(
            contract(conId=987654, symbol="spy", secType="opt", currency="usd", multiplier="100"),
            execution("other.option.01", clientId=22),
            ACCOUNT,
        )
        self.assertEqual(
            cash["contract"],
            {"conId": 12087792, "symbol": "EUR", "secType": "CASH", "currency": "USD", "multiplier": ""},
        )
        self.assertEqual(
            option["contract"],
            {"conId": 987654, "symbol": "SPY", "secType": "OPT", "currency": "USD", "multiplier": "100"},
        )

    def test_shutdown_is_idempotent_and_disconnect_fails_active_cycle(self):
        def disconnect(sink, request_id):
            sink.on_disconnect()

        reader, broker = reader_with(disconnect)
        result = reader.process(request())
        self.assertEqual(result["errors"][0]["code"], "broker-disconnected")
        reader.close()
        reader.close()
        self.assertEqual(broker.stopped, 1)

    def test_record_bound_is_enforced_before_accepting_an_extra_execution(self):
        def too_many(sink, request_id):
            sink.on_execution(request_id, contract(), execution("one.1.01"))
            sink.on_execution(request_id, contract(conId=124), execution("two.1.01"))

        reader, _ = reader_with(too_many, max_records=1)
        result = reader.process(request())
        self.assertEqual(result["errors"][0]["code"], "execution record limit exceeded")


class OfficialSdkPackagingTests(unittest.TestCase):
    def test_lock_records_only_the_canonical_dependency_metadata_patch(self):
        lock = INSTALLER.load_lock(HERE / "official-sdk.lock.json")
        self.assertEqual(lock["dependencyMetadataPatch"], INSTALLER.CANONICAL_METADATA_PATCH)
        self.assertEqual(lock["dependencies"][0]["version"], "5.29.6")

    def test_dependency_metadata_patch_is_exact_and_preserves_license(self):
        original = "\n".join(
            [
                "from setuptools import setup",
                INSTALLER.SDK_LICENSE_DECLARATION,
                INSTALLER.CANONICAL_METADATA_PATCH["expected"],
                "",
            ]
        )
        with tempfile.TemporaryDirectory() as temporary_name:
            source = Path(temporary_name)
            setup_path = source / "setup.py"
            setup_path.write_text(original, encoding="utf-8")
            INSTALLER.patch_dependency_metadata(source, INSTALLER.CANONICAL_METADATA_PATCH)
            patched = setup_path.read_text(encoding="utf-8")
            self.assertEqual(
                patched,
                original.replace(
                    INSTALLER.CANONICAL_METADATA_PATCH["expected"],
                    INSTALLER.CANONICAL_METADATA_PATCH["replacement"],
                ),
            )
            self.assertIn(INSTALLER.SDK_LICENSE_DECLARATION, patched)

            with self.assertRaisesRegex(ValueError, "exactly one expected"):
                INSTALLER.patch_dependency_metadata(source, INSTALLER.CANONICAL_METADATA_PATCH)

    def test_dependency_metadata_patch_rejects_duplicate_old_declarations(self):
        with tempfile.TemporaryDirectory() as temporary_name:
            source = Path(temporary_name)
            (source / "setup.py").write_text(
                "\n".join(
                    [
                        INSTALLER.SDK_LICENSE_DECLARATION,
                        INSTALLER.CANONICAL_METADATA_PATCH["expected"],
                        INSTALLER.CANONICAL_METADATA_PATCH["expected"],
                    ]
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "exactly one expected"):
                INSTALLER.patch_dependency_metadata(source, INSTALLER.CANONICAL_METADATA_PATCH)


if __name__ == "__main__":
    unittest.main()
