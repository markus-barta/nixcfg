#!/usr/bin/env python3
"""One-shot, bounded, read-only official-IB execution window reader."""

from __future__ import annotations

import json
import math
import re
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from importlib.metadata import version as package_version
from typing import Any, Callable


REQUEST_SCHEMA = "inspr.ib.official-window-request.v1"
SDK_VERSION = "10.45.1"
PAPER_PORT = 4002
READER_CLIENT_ID = 94
PAPER_ACCOUNT = "DUR970597"
MIN_PROTOBUF_SERVER_VERSION = 201
MAX_INPUT_BYTES = 64 * 1024
MAX_OUTPUT_BYTES = 16 * 1024 * 1024
MAX_RECORDS = 50_000
MAX_DATES = 7
MAX_TEXT = 512
STARTUP_TIMEOUT_SECONDS = 15.0
PER_DATE_TIMEOUT_SECONDS = 20.0
POST_END_QUIET_SECONDS = 5.0
FINAL_DRAIN_TIMEOUT_SECONDS = 20.0
FATAL_SESSION_CODES = frozenset({1100, 1101, 1102, 1300, 2110})
# IB system-message codes: 2107/2108 mean dormant data farms that remain
# available on demand, not a failed execution-query connection.
INFORMATIONAL_CODES = frozenset({2104, 2106, 2107, 2108, 2158})
SAFE_INTEGER = 9_007_199_254_740_991
HOST_RE = re.compile(r"^[^\s\x00-\x20]{1,253}$")
ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$")
FILTER_TIME_RE = re.compile(r"^\d{8}-\d{2}:\d{2}:\d{2}$")


class ProtocolError(ValueError):
    """An input, callback, or bounded-protocol invariant failed."""


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _iso(value: Any, label: str) -> str:
    if not isinstance(value, str) or not ISO_RE.fullmatch(value):
        raise ProtocolError(f"{label} must be a canonical UTC timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _text(value: Any, label: str, *, upper: bool = False, allow_empty: bool = False) -> str:
    if not isinstance(value, str):
        raise ProtocolError(f"{label} must be a string")
    result = value.strip()
    if not allow_empty and not result:
        raise ProtocolError(f"{label} must not be empty")
    if len(result) > MAX_TEXT or any(ord(ch) < 32 for ch in result):
        raise ProtocolError(f"{label} is invalid or too long")
    return result.upper() if upper else result


def _integer(value: Any, label: str, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ProtocolError(f"{label} must be an integer")
    if abs(value) > SAFE_INTEGER or (positive and value <= 0):
        raise ProtocolError(f"{label} is outside the supported range")
    return value


def _decimal_text(value: Any, label: str, *, positive: bool = False, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if isinstance(value, bool):
        raise ProtocolError(f"{label} must be numeric")
    try:
        decimal = value if isinstance(value, Decimal) else Decimal(str(value).strip())
    except (InvalidOperation, AttributeError, ValueError):
        raise ProtocolError(f"{label} must be numeric") from None
    if not decimal.is_finite():
        if optional:
            return None
        raise ProtocolError(f"{label} must be finite")
    if abs(decimal) == Decimal(str(sys.float_info.max)):
        if optional:
            return None
        raise ProtocolError(f"{label} contains an unset sentinel")
    if positive and decimal <= 0:
        raise ProtocolError(f"{label} must be positive")
    return format(decimal, "f")


def canonical_execution(contract: Any, execution: Any, account: str) -> dict[str, Any]:
    # Check this broker correction signal before transforming any other field.
    pending = getattr(execution, "pendingPriceRevision", None)
    if not isinstance(pending, bool):
        raise ProtocolError("execution.pendingPriceRevision must be boolean")
    acct_number = _text(getattr(execution, "acctNumber", None), "execution.acctNumber")
    if acct_number != account:
        raise ProtocolError("foreign execution account")
    side = _text(getattr(execution, "side", None), "execution.side", upper=True)
    sec_type = _text(getattr(contract, "secType", None), "contract.secType", upper=True)
    currency = _text(getattr(contract, "currency", None), "contract.currency", upper=True)
    if not re.fullmatch(r"[A-Z]{3}", currency):
        raise ProtocolError("contract.currency must be a three-letter code")
    return {
        "contract": {
            "conId": _integer(getattr(contract, "conId", None), "contract.conId", positive=True),
            "symbol": _text(getattr(contract, "symbol", None), "contract.symbol", upper=True),
            "secType": sec_type,
            "currency": currency,
            "multiplier": _text(getattr(contract, "multiplier", ""), "contract.multiplier", allow_empty=True),
            "exchange": _text(getattr(contract, "exchange", ""), "contract.exchange", allow_empty=True),
        },
        "execution": {
            "execId": _text(getattr(execution, "execId", None), "execution.execId"),
            "time": _text(getattr(execution, "time", None), "execution.time"),
            "acctNumber": acct_number,
            "clientId": _integer(getattr(execution, "clientId", None), "execution.clientId"),
            "orderId": _integer(getattr(execution, "orderId", 0), "execution.orderId"),
            "permId": _integer(getattr(execution, "permId", 0), "execution.permId"),
            "side": side,
            "shares": _decimal_text(getattr(execution, "shares", None), "execution.shares", positive=True),
            "price": _decimal_text(getattr(execution, "price", None), "execution.price", positive=True),
            "avgPrice": _decimal_text(getattr(execution, "avgPrice", None), "execution.avgPrice", optional=True),
            "orderRef": _text(getattr(execution, "orderRef", ""), "execution.orderRef", allow_empty=True),
            "modelCode": _text(getattr(execution, "modelCode", ""), "execution.modelCode", allow_empty=True),
            "pendingPriceRevision": pending,
        },
    }


def canonical_commission(report: Any) -> dict[str, Any]:
    currency = _text(getattr(report, "currency", None), "commission.currency", upper=True)
    if not re.fullmatch(r"[A-Z]{3}", currency):
        raise ProtocolError("commission.currency must be a three-letter code")
    return {
        "execId": _text(getattr(report, "execId", None), "commission.execId"),
        "commissionAndFees": _decimal_text(
            getattr(report, "commissionAndFees", None), "commission.commissionAndFees"
        ),
        "currency": currency,
        "realizedPNL": _decimal_text(getattr(report, "realizedPNL", None), "commission.realizedPNL", optional=True),
        "yield": _decimal_text(getattr(report, "yield_", None), "commission.yield", optional=True),
        "yieldRedemptionDate": _integer(
            getattr(report, "yieldRedemptionDate", 0), "commission.yieldRedemptionDate"
        ),
    }


@dataclass(frozen=True)
class ReaderConfig:
    host: str
    port: int
    client_id: int
    account: str
    startup_timeout: float = STARTUP_TIMEOUT_SECONDS
    request_timeout: float = PER_DATE_TIMEOUT_SECONDS
    quiet_period: float = POST_END_QUIET_SECONDS
    final_drain_timeout: float = FINAL_DRAIN_TIMEOUT_SECONDS


@dataclass
class RequestState:
    request_id: int
    plan: dict[str, Any]
    requested_at: str
    ended_at: str | None = None
    ended_monotonic: float | None = None
    last_callback_monotonic: float | None = None
    timed_out: bool = False
    executions: dict[str, dict[str, Any]] = field(default_factory=dict)
    errors: list[dict[str, Any]] = field(default_factory=list)


def validate_plan(value: Any) -> tuple[ReaderConfig, dict[str, Any]]:
    expected = {"schema", "schemaVersion", "endpoint", "startedAt", "requestedCoverage", "actualWindows"}
    if not isinstance(value, dict) or set(value) != expected:
        raise ProtocolError("request has an invalid shape")
    if value["schema"] != REQUEST_SCHEMA or value["schemaVersion"] != 1:
        raise ProtocolError("unsupported request schema")
    endpoint = value["endpoint"]
    if not isinstance(endpoint, dict) or set(endpoint) != {"host", "port", "clientId", "account"}:
        raise ProtocolError("endpoint has an invalid shape")
    host = endpoint["host"]
    if not isinstance(host, str) or not HOST_RE.fullmatch(host):
        raise ProtocolError("endpoint host is invalid")
    if endpoint["port"] != PAPER_PORT:
        raise ProtocolError("official reader permits paper Gateway port 4002 only")
    if endpoint["clientId"] != READER_CLIENT_ID:
        raise ProtocolError("official reader requires dedicated client ID 94")
    if endpoint["account"] != PAPER_ACCOUNT:
        raise ProtocolError("official reader requires the configured paper account")
    started_at = _iso(value["startedAt"], "startedAt")
    coverage = value["requestedCoverage"]
    if not isinstance(coverage, dict) or set(coverage) != {"fromInclusive", "toExclusive"}:
        raise ProtocolError("requestedCoverage has an invalid shape")
    coverage_from = _iso(coverage["fromInclusive"], "requestedCoverage.fromInclusive")
    coverage_to = _iso(coverage["toExclusive"], "requestedCoverage.toExclusive")
    if not coverage_from < coverage_to or coverage_to > started_at:
        raise ProtocolError("requestedCoverage is empty or extends past query start")
    windows = value["actualWindows"]
    if not isinstance(windows, list) or not 1 <= len(windows) <= MAX_DATES:
        raise ProtocolError("actualWindows must contain one to seven entries")
    ids: set[int] = set()
    normalized_windows: list[dict[str, Any]] = []
    cursor = coverage_from
    for item in windows:
        if not isinstance(item, dict) or set(item) != {
            "requestId", "newYorkDate", "fromInclusive", "toExclusive", "filter"
        }:
            raise ProtocolError("actual window has an invalid shape")
        request_id = _integer(item["requestId"], "actualWindow.requestId", positive=True)
        if request_id in ids:
            raise ProtocolError("actual window request IDs must be unique")
        ids.add(request_id)
        day = item["newYorkDate"]
        if isinstance(day, bool) or not isinstance(day, int) or not re.fullmatch(r"\d{8}", str(day)):
            raise ProtocolError("actual window New York date is invalid")
        window_from = _iso(item["fromInclusive"], "actualWindow.fromInclusive")
        window_to = _iso(item["toExclusive"], "actualWindow.toExclusive")
        if window_from != cursor or not window_from < window_to or window_to > coverage_to:
            raise ProtocolError("actual windows must exactly and contiguously cover requestedCoverage")
        execution_filter = item["filter"]
        if not isinstance(execution_filter, dict) or set(execution_filter) != {"acctCode", "time", "specificDates"}:
            raise ProtocolError("execution filter has an invalid shape")
        if execution_filter["acctCode"] != PAPER_ACCOUNT:
            raise ProtocolError("execution filter account is invalid")
        if not isinstance(execution_filter["time"], str) or not FILTER_TIME_RE.fullmatch(execution_filter["time"]):
            raise ProtocolError("execution filter time is invalid")
        if execution_filter["specificDates"] != [day]:
            raise ProtocolError("execution filter must contain exactly its New York date")
        normalized_windows.append({
            "requestId": request_id,
            "newYorkDate": day,
            "fromInclusive": window_from,
            "toExclusive": window_to,
            "filter": dict(execution_filter),
        })
        cursor = window_to
    if cursor != coverage_to:
        raise ProtocolError("actual windows do not reach requestedCoverage end")
    return ReaderConfig(host, PAPER_PORT, READER_CLIENT_ID, PAPER_ACCOUNT), {
        "startedAt": started_at,
        "requestedCoverage": {"fromInclusive": coverage_from, "toExclusive": coverage_to},
        "actualWindows": normalized_windows,
    }


class OfficialWindowReader:
    """Coordinates one bounded series of official exact-date queries."""

    def __init__(
        self,
        config: ReaderConfig,
        broker: Any,
        *,
        now: Callable[[], str] = utc_now,
        monotonic: Callable[[], float] = time.monotonic,
        max_records: int = MAX_RECORDS,
    ) -> None:
        self.config = config
        self.broker = broker
        self.now = now
        self.monotonic = monotonic
        self.max_records = max_records
        self._condition = threading.Condition()
        self._ready = False
        self._startup_error: dict[str, Any] | None = None
        self._closed = False
        self._disconnected = False
        self._stopped = False
        self._managed_accounts: list[str] = []
        self._foreign_account_violation = False
        self._active: RequestState | None = None
        self._executions: dict[str, dict[str, Any]] = {}
        self._commissions: dict[str, dict[str, Any]] = {}
        self._pending_commissions: dict[str, dict[str, Any]] = {}
        self._run_errors: list[dict[str, Any]] = []
        self._last_callback_monotonic: float | None = None

    def on_ready(self, managed_accounts: list[str]) -> None:
        with self._condition:
            if self._closed:
                return
            accounts = sorted({_text(item, "managed account") for item in managed_accounts})
            self._managed_accounts = accounts
            if self.config.account not in accounts:
                self._startup_error = {"code": "configured-account-not-managed"}
            else:
                self._ready = True
            self._condition.notify_all()

    def on_startup_error(self, code: str) -> None:
        with self._condition:
            self._startup_error = {"code": _text(code, "startup error")}
            self._condition.notify_all()

    def on_execution(self, request_id: int, contract: Any, execution: Any) -> None:
        with self._condition:
            self._note_callback_locked()
            active = self._active
            if active is None or active.request_id != request_id:
                self._fail_locked("unexpected-execution-request-id")
                return
            try:
                row = canonical_execution(contract, execution, self.config.account)
                exec_id = row["execution"]["execId"]
                prior = self._executions.get(exec_id)
                if prior is not None and prior != row:
                    raise ProtocolError("conflicting duplicate execution")
                if prior is None and len(self._executions) >= self.max_records:
                    raise ProtocolError("execution record limit exceeded")
                self._executions[exec_id] = row
                active.executions[exec_id] = row
                pending = self._pending_commissions.pop(exec_id, None)
                if pending is not None:
                    self._store_commission_locked(pending)
            except ProtocolError as error:
                if str(error) == "foreign execution account":
                    self._foreign_account_violation = True
                self._fail_locked(str(error))
            self._condition.notify_all()

    def on_execution_end(self, request_id: int) -> None:
        with self._condition:
            self._note_callback_locked()
            if self._active is None or self._active.request_id != request_id:
                self._fail_locked("unexpected-execution-end-request-id")
            elif self._active.ended_at is not None:
                self._fail_locked("duplicate-execution-end")
            else:
                self._active.ended_at = self.now()
                self._active.ended_monotonic = self.monotonic()
                self._active.last_callback_monotonic = self._last_callback_monotonic
            self._condition.notify_all()

    def on_commission(self, report: Any) -> None:
        with self._condition:
            self._note_callback_locked()
            try:
                row = canonical_commission(report)
                exec_id = row["execId"]
                if exec_id in self._executions:
                    self._store_commission_locked(row)
                else:
                    prior = self._pending_commissions.get(exec_id)
                    if prior is not None and prior != row:
                        raise ProtocolError("conflicting duplicate commission")
                    if prior is None and len(self._pending_commissions) >= self.max_records:
                        raise ProtocolError("pending commission record limit exceeded")
                    self._pending_commissions[exec_id] = row
            except ProtocolError as error:
                self._fail_locked(str(error))
            self._condition.notify_all()

    def on_broker_error(self, request_id: int, code: int) -> None:
        if code in INFORMATIONAL_CODES:
            return
        with self._condition:
            self._note_callback_locked()
            if code in FATAL_SESSION_CODES:
                self._closed = True
                self._disconnected = True
                self._fail_locked("broker-session-retired", brokerCode=code)
            elif self._ready:
                self._fail_locked("broker-request-error", brokerCode=code)
            self._condition.notify_all()

    def on_disconnect(self) -> None:
        with self._condition:
            expected = self._closed
            self._closed = True
            self._disconnected = True
            if not expected and not self._ready:
                self._startup_error = {"code": "broker-disconnected-before-ready"}
            elif not expected:
                self._fail_locked("broker-disconnected")
            self._condition.notify_all()

    def _store_commission_locked(self, row: dict[str, Any]) -> None:
        exec_id = row["execId"]
        prior = self._commissions.get(exec_id)
        if prior is not None and prior != row:
            raise ProtocolError("conflicting duplicate commission")
        if prior is None and len(self._commissions) >= self.max_records:
            raise ProtocolError("commission record limit exceeded")
        self._commissions[exec_id] = row

    def _note_callback_locked(self) -> None:
        observed = self.monotonic()
        self._last_callback_monotonic = observed
        if self._active is not None:
            self._active.last_callback_monotonic = observed

    def _fail_locked(self, code: str, **detail: Any) -> None:
        error = {"code": code, **detail}
        if self._active is None:
            if not self._ready and self._startup_error is None:
                self._startup_error = error
            elif error not in self._run_errors:
                self._run_errors.append(error)
            return
        if error not in self._active.errors:
            self._active.errors.append(error)
        if error not in self._run_errors:
            self._run_errors.append(error)

    def _stop_once(self) -> None:
        with self._condition:
            if self._stopped:
                return
            self._stopped = True
        self.broker.stop()

    def _start(self) -> None:
        try:
            self.broker.start(self, self.config.host, self.config.port, self.config.client_id, self.config.account)
            deadline = self.monotonic() + self.config.startup_timeout
            with self._condition:
                while not self._ready and self._startup_error is None:
                    remaining = deadline - self.monotonic()
                    if remaining <= 0:
                        raise ProtocolError("broker readiness timed out")
                    self._condition.wait(remaining)
                if self._startup_error is not None:
                    raise ProtocolError(self._startup_error["code"])
            if not isinstance(self.broker.server_version, int) or self.broker.server_version < MIN_PROTOBUF_SERVER_VERSION:
                raise ProtocolError("broker server does not support protobuf execution filters")
            if self.broker.execution_request_framing != "protobuf":
                raise ProtocolError("official SDK did not negotiate protobuf execution framing")
        except Exception:
            self._stop_once()
            raise

    def _query(self, item: dict[str, Any]) -> dict[str, Any]:
        active = RequestState(item["requestId"], item, self.now())
        with self._condition:
            self._active = active
        deadline = self.monotonic() + self.config.request_timeout
        try:
            self.broker.request_executions(active.request_id, item["filter"])
        except Exception:
            with self._condition:
                self._fail_locked("execution-request-failed")
        with self._condition:
            while not active.errors:
                if self._closed or self._disconnected:
                    self._fail_locked("broker-connection-unavailable")
                    break
                current = self.monotonic()
                if active.ended_at is not None:
                    if active.ended_monotonic is None or active.last_callback_monotonic is None:
                        self._fail_locked("execution-end-clock-missing")
                        break
                    deadline_remaining = deadline - current
                    quiet_remaining = active.last_callback_monotonic + self.config.quiet_period - current
                    if deadline_remaining <= 0:
                        active.timed_out = True
                        self._fail_locked("execution-query-timeout", phase="post-end-quiet")
                        break
                    if quiet_remaining <= 0:
                        missing = [exec_id for exec_id in active.executions if exec_id not in self._commissions]
                        if missing:
                            self._fail_locked("missing-commission-callbacks", count=len(missing))
                        if self._pending_commissions:
                            self._fail_locked("orphan-commission-callbacks", count=len(self._pending_commissions))
                        break
                    remaining = min(deadline_remaining, quiet_remaining)
                else:
                    remaining = deadline - current
                    if remaining <= 0:
                        active.timed_out = True
                        self._fail_locked("execution-query-timeout", phase="execDetailsEnd")
                        break
                self._condition.wait(remaining)
            result = {
                "label": "specific-date",
                "filter": dict(item["filter"]),
                "actualWindow": {
                    "fromInclusive": item["fromInclusive"],
                    "toExclusive": item["toExclusive"],
                },
                "requestedAt": active.requested_at,
                "endedAt": active.ended_at,
                "timedOut": active.timed_out,
                "errors": list(active.errors),
                "executions": [active.executions[key] for key in sorted(active.executions)],
            }
            self._active = None
            return result

    def _final_drain(self) -> None:
        with self._condition:
            self._last_callback_monotonic = self.monotonic()
            deadline = self._last_callback_monotonic + self.config.final_drain_timeout
            while True:
                current = self.monotonic()
                last_callback = self._last_callback_monotonic
                if last_callback is None:
                    self._fail_locked("final-drain-clock-missing")
                    break
                quiet_remaining = last_callback + self.config.quiet_period - current
                deadline_remaining = deadline - current
                if quiet_remaining <= 0:
                    break
                if deadline_remaining <= 0:
                    self._fail_locked("final-drain-timeout")
                    break
                self._condition.wait(min(quiet_remaining, deadline_remaining))

            missing = [exec_id for exec_id in self._executions if exec_id not in self._commissions]
            if missing:
                self._fail_locked("missing-commission-callbacks", count=len(missing))
            if self._pending_commissions:
                self._fail_locked("orphan-commission-callbacks", count=len(self._pending_commissions))

    def run(self, plan: dict[str, Any]) -> dict[str, Any]:
        self._start()
        requests: dict[str, dict[str, Any]] = {}
        try:
            for item in plan["actualWindows"]:
                result = self._query(item)
                requests[str(item["requestId"])] = result
                if result["errors"]:
                    break
            if not self._run_errors:
                self._final_drain()
        finally:
            self._closed = True
            self._stop_once()
        included_ids = {
            row["execution"]["execId"]
            for request in requests.values()
            for row in request["executions"]
        }
        return {
            "schemaVersion": 1,
            "endpoint": {
                "host": self.config.host,
                "port": self.config.port,
                "clientId": self.config.client_id,
                "account": self.config.account,
            },
            "sdk": {"package": "ibapi", "version": self.broker.sdk_version},
            "negotiated": {
                "serverVersion": self.broker.server_version,
                "executionRequestFraming": self.broker.execution_request_framing,
                "parameterizedExecutionFilters": True,
            },
            "managedAccounts": list(self._managed_accounts),
            "foreignAccountViolation": self._foreign_account_violation,
            "startedAt": plan["startedAt"],
            "finishedAt": self.now(),
            "requestedCoverage": dict(plan["requestedCoverage"]),
            "actualWindows": list(plan["actualWindows"]),
            "disconnected": True,
            "exitCode": 0,
            "errors": list(self._run_errors),
            "requests": requests,
            "commissionsByExecId": {
                key: self._commissions[key] for key in sorted(self._commissions) if key in included_ids
            },
        }


class OfficialBroker:
    """Small allowlisted adapter around the official callback API."""

    def __init__(self) -> None:
        self.sdk_version = package_version("ibapi")
        if self.sdk_version != SDK_VERSION:
            raise ProtocolError("installed official SDK version does not match reader pin")
        self.server_version: int | None = None
        self.execution_request_framing = "unavailable"
        self._app: Any = None
        self._thread: threading.Thread | None = None
        self._execution_filter: Any = None

    def start(self, sink: OfficialWindowReader, host: str, port: int, client_id: int, account: str) -> None:
        from ibapi.client import EClient
        from ibapi.execution import ExecutionFilter
        from ibapi.wrapper import EWrapper

        class App(EWrapper, EClient):
            def __init__(self) -> None:
                EWrapper.__init__(self)
                EClient.__init__(self, self)

            def nextValidId(self, _order_id: int) -> None:
                self.reqManagedAccts()

            def managedAccounts(self, accounts_list: str) -> None:
                accounts = [item.strip() for item in accounts_list.split(",") if item.strip()]
                sink.on_ready(accounts)

            def execDetails(self, request_id: int, contract: Any, execution: Any) -> None:
                sink.on_execution(request_id, contract, execution)

            def execDetailsEnd(self, request_id: int) -> None:
                sink.on_execution_end(request_id)

            def commissionAndFeesReport(self, report: Any) -> None:
                sink.on_commission(report)

            def error(
                self,
                request_id: int,
                _error_time: int,
                error_code: int,
                _error_string: str,
                _advanced_order_reject_json: str = "",
            ) -> None:
                sink.on_broker_error(request_id, error_code)

            def connectionClosed(self) -> None:
                sink.on_disconnect()

        app = App()
        self._app = app
        app.connect(host, port, client_id)
        if not app.isConnected():
            raise ProtocolError("official SDK connection failed")
        self.server_version = app.serverVersion()
        self.execution_request_framing = (
            "protobuf" if self.server_version >= MIN_PROTOBUF_SERVER_VERSION else "unsupported"
        )
        self._execution_filter = ExecutionFilter
        self._thread = threading.Thread(target=app.run, name="official-window-reader", daemon=True)
        self._thread.start()

    def request_executions(self, request_id: int, execution_filter_value: dict[str, Any]) -> None:
        execution_filter = self._execution_filter()
        execution_filter.acctCode = execution_filter_value["acctCode"]
        execution_filter.time = execution_filter_value["time"]
        execution_filter.specificDates = list(execution_filter_value["specificDates"])
        self._app.reqExecutions(request_id, execution_filter)

    def stop(self) -> None:
        if self._app is not None:
            self._app.disconnect()
        if self._thread is not None and self._thread is not threading.current_thread():
            self._thread.join(timeout=2.0)


def encode_result(value: dict[str, Any]) -> bytes:
    encoded = json.dumps(value, separators=(",", ":"), allow_nan=False).encode("utf-8")
    if len(encoded) > MAX_OUTPUT_BYTES:
        raise ProtocolError("result exceeds output limit")
    return encoded + b"\n"


def read_input(stream: Any) -> dict[str, Any]:
    raw = stream.read(MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        raise ProtocolError("request exceeds input limit")
    try:
        value = json.loads(raw, parse_constant=lambda token: (_ for _ in ()).throw(ValueError(token)))
    except (UnicodeDecodeError, ValueError):
        raise ProtocolError("request is not valid JSON") from None
    if not isinstance(value, dict):
        raise ProtocolError("request must be a JSON object")
    return value


def main(broker_factory: Callable[[], Any] = OfficialBroker) -> int:
    try:
        config, plan = validate_plan(read_input(sys.stdin.buffer))
        result = OfficialWindowReader(config, broker_factory()).run(plan)
        sys.stdout.buffer.write(encode_result(result))
        sys.stdout.buffer.flush()
        return 0
    except (OSError, ProtocolError, ValueError) as error:
        print(f"official-window-reader failed: {str(error)[:MAX_TEXT]}", file=sys.stderr, flush=True)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
