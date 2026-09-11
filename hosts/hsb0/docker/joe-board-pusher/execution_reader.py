#!/usr/bin/env python3
"""Bounded, read-only official-IB execution history JSONL helper."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import selectors
import signal
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from importlib.metadata import version as package_version
from typing import Any, Callable


REQUEST_SCHEMA = "inspr.ib.execution-query.request.v1"
RESULT_SCHEMA = "inspr.ib.execution-query.result.v1"
SDK_VERSION = "10.45.1"
PAPER_PORT = 4002
READER_CLIENT_ID = 94
MIN_SERVER_VERSION = 200
PROTOBUF_SERVER_VERSION = 201
MAX_INPUT_BYTES = 64 * 1024
MAX_OUTPUT_BYTES = 16 * 1024 * 1024
MAX_RECORDS = 50_000
MAX_DATES = 7
MAX_TEXT = 256
STARTUP_TIMEOUT_SECONDS = 15.0
PER_DATE_TIMEOUT_SECONDS = 20.0
COMMISSION_GRACE_SECONDS = 1.0
FATAL_SESSION_CODES = frozenset({1100, 1101, 1102, 1300, 2110})
SAFE_INTEGER = 9_007_199_254_740_991
ACCOUNT_RE = re.compile(r"^[A-Z][A-Z0-9]{2,31}$")
CYCLE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
DATE_RE = re.compile(r"^[0-9]{8}$")


class ProtocolError(ValueError):
    """An input, SDK callback, or bounded-protocol invariant failed."""


@dataclass(frozen=True)
class ReaderConfig:
    host: str
    port: int
    client_id: int
    account: str
    connect_timeout: float = STARTUP_TIMEOUT_SECONDS
    request_timeout: float = PER_DATE_TIMEOUT_SECONDS
    commission_grace: float = COMMISSION_GRACE_SECONDS


@dataclass
class _RequestState:
    request_id: int
    date: str
    requested_at: str
    ended_at: str | None = None
    ended_monotonic: float | None = None
    executions: dict[str, dict[str, Any]] = field(default_factory=dict)
    errors: list[dict[str, Any]] = field(default_factory=list)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def validate_runtime(host: str, port: int, client_id: int, account: str) -> ReaderConfig:
    if not isinstance(host, str) or not host or len(host) > 253 or any(ch.isspace() or ord(ch) < 33 for ch in host):
        raise ProtocolError("host must be a bounded non-whitespace name or address")
    if port != PAPER_PORT:
        raise ProtocolError("execution reader permits paper Gateway port 4002 only")
    if client_id != READER_CLIENT_ID:
        raise ProtocolError("execution reader requires reserved client ID 94")
    if not isinstance(account, str) or not ACCOUNT_RE.fullmatch(account):
        raise ProtocolError("account has an invalid format")
    return ReaderConfig(host=host, port=port, client_id=client_id, account=account)


def managed_account_matches(accounts_list: str, configured_account: str) -> bool:
    if not isinstance(accounts_list, str):
        return False
    return configured_account in {item.strip() for item in accounts_list.split(",") if item.strip()}


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


def _number(value: Any, label: str, *, positive: bool = False, nonnegative: bool = False) -> int | float:
    if isinstance(value, bool):
        raise ProtocolError(f"{label} must be numeric")
    if isinstance(value, Decimal):
        if not value.is_finite():
            raise ProtocolError(f"{label} must be finite")
        if value == value.to_integral_value() and abs(value) <= SAFE_INTEGER:
            result: int | float = int(value)
        else:
            result = float(value)
            if not math.isfinite(result) or abs(result) == sys.float_info.max or Decimal(str(result)) != value:
                raise ProtocolError(f"{label} cannot round-trip as a JSON number")
    elif isinstance(value, int):
        if abs(value) > SAFE_INTEGER:
            raise ProtocolError(f"{label} is outside the JSON-safe range")
        result = value
    elif isinstance(value, float):
        if not math.isfinite(value) or abs(value) == sys.float_info.max:
            raise ProtocolError(f"{label} must be finite")
        result = value
    else:
        try:
            decimal = Decimal(str(value).strip())
        except (InvalidOperation, AttributeError):
            raise ProtocolError(f"{label} must be numeric") from None
        return _number(decimal, label, positive=positive, nonnegative=nonnegative)
    if positive and result <= 0:
        raise ProtocolError(f"{label} must be positive")
    if nonnegative and result < 0:
        raise ProtocolError(f"{label} must be nonnegative")
    return result


def canonical_multiplier(value: Any, sec_type: str) -> int | float | str | None:
    if sec_type == "STK" and not isinstance(value, bool) and value in (None, "", 0, 1, "0", "1"):
        return 1
    if value is None:
        return None
    if isinstance(value, str):
        if len(value) > MAX_TEXT or any(ord(ch) < 32 for ch in value):
            raise ProtocolError("contract.multiplier is invalid or too long")
        return value
    if isinstance(value, bool) or not isinstance(value, (Decimal, int, float)):
        raise ProtocolError("contract.multiplier must be a bounded string, finite number, or null")
    return _number(value, "contract.multiplier")


def canonical_execution(contract: Any, execution: Any, account: str) -> dict[str, Any]:
    acct_number = _text(getattr(execution, "acctNumber", None), "execution.acctNumber")
    if acct_number != account:
        raise ProtocolError("execution account does not match configured account")
    sec_type = _text(getattr(contract, "secType", None), "contract.secType", upper=True)
    raw_multiplier = getattr(contract, "multiplier", "")
    multiplier = canonical_multiplier(raw_multiplier, sec_type)
    side = _text(getattr(execution, "side", None), "execution.side", upper=True)
    side = {"BOT": "BUY", "BUY": "BUY", "SLD": "SELL", "SELL": "SELL"}.get(side, "")
    if not side:
        raise ProtocolError("execution.side is unsupported")
    pending = getattr(execution, "pendingPriceRevision", None)
    if not isinstance(pending, bool):
        raise ProtocolError("execution.pendingPriceRevision must be boolean")
    currency = _text(getattr(contract, "currency", None), "contract.currency", upper=True)
    if not re.fullmatch(r"[A-Z]{3}", currency):
        raise ProtocolError("contract.currency must be a three-letter code")
    return {
        "contract": {
            "conId": _integer(getattr(contract, "conId", None), "contract.conId", positive=True),
            "symbol": _text(getattr(contract, "symbol", None), "contract.symbol", upper=True),
            "secType": sec_type,
            "currency": currency,
            "multiplier": multiplier,
        },
        "execution": {
            "execId": _text(getattr(execution, "execId", None), "execution.execId"),
            "time": _text(getattr(execution, "time", None), "execution.time"),
            "acctNumber": acct_number,
            "clientId": _integer(getattr(execution, "clientId", None), "execution.clientId"),
            "side": side,
            "shares": _number(getattr(execution, "shares", None), "execution.shares", positive=True),
            "price": _number(getattr(execution, "price", None), "execution.price", positive=True),
            "pendingPriceRevision": pending,
        },
    }


def canonical_commission(report: Any) -> dict[str, Any]:
    currency = _text(getattr(report, "currency", None), "commission.currency", upper=True)
    if not re.fullmatch(r"[A-Z]{3}", currency):
        raise ProtocolError("commission.currency must be a three-letter code")
    return {
        "execId": _text(getattr(report, "execId", None), "commission.execId"),
        "commission": _number(getattr(report, "commissionAndFees", None), "commission.commission"),
        "currency": currency,
    }


def validate_request(value: Any, configured_account: str) -> tuple[str, list[str]]:
    if not isinstance(value, dict) or set(value) != {"schema", "cycleId", "account", "specificDates"}:
        raise ProtocolError("request must contain exactly schema, cycleId, account, and specificDates")
    if value["schema"] != REQUEST_SCHEMA:
        raise ProtocolError("unsupported request schema")
    cycle_id = value["cycleId"]
    if not isinstance(cycle_id, str) or not CYCLE_RE.fullmatch(cycle_id):
        raise ProtocolError("cycleId has an invalid format")
    if value["account"] != configured_account:
        raise ProtocolError("request account does not match configured account")
    dates = value["specificDates"]
    if not isinstance(dates, list) or not 1 <= len(dates) <= MAX_DATES:
        raise ProtocolError("specificDates must contain one to seven dates")
    if any(not isinstance(day, str) or not DATE_RE.fullmatch(day) for day in dates):
        raise ProtocolError("specificDates entries must use YYYYMMDD")
    if len(set(dates)) != len(dates) or dates != sorted(dates):
        raise ProtocolError("specificDates must be unique and ordered oldest first")
    for day in dates:
        try:
            datetime.strptime(day, "%Y%m%d")
        except ValueError:
            raise ProtocolError(f"specificDates contains invalid calendar date {day}") from None
    return cycle_id, dates


class ExecutionReader:
    """Coordinates one callback-driven exact-date query cycle at a time."""

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
        self._retired = threading.Event()
        self._broker_stopped = False
        self._cycle_active = False
        self._seen_cycle_ids: set[str] = set()
        self._active: _RequestState | None = None
        self._cycle_executions: dict[str, dict[str, Any]] = {}
        self._commissions: dict[str, dict[str, Any]] = {}
        self._pending_commissions: dict[str, dict[str, Any]] = {}
        self._cycle_errors: list[dict[str, Any]] = []
        self._next_request_id = 9400

    def start(self) -> None:
        try:
            self.broker.start(self, self.config.host, self.config.port, self.config.client_id, self.config.account)
            deadline = self.monotonic() + self.config.connect_timeout
            with self._condition:
                while not self._ready and not self._startup_error:
                    remaining = deadline - self.monotonic()
                    if remaining <= 0:
                        raise ProtocolError("broker readiness timed out")
                    self._condition.wait(remaining)
                if self._startup_error:
                    raise ProtocolError(self._startup_error["code"])
            if not isinstance(self.broker.server_version, int) or self.broker.server_version < MIN_SERVER_VERSION:
                raise ProtocolError("broker server does not support exact-date execution queries")
            if self.broker.framing not in {"protobuf", "legacy-extended"}:
                raise ProtocolError("broker execution framing is unsupported")
        except Exception:
            self._stop_broker_once()
            raise

    def close(self) -> None:
        with self._condition:
            self._closed = True
            self._retired.set()
            self._condition.notify_all()
        self._stop_broker_once()

    @property
    def retired(self) -> bool:
        return self._retired.is_set()

    def _stop_broker_once(self) -> None:
        with self._condition:
            if self._broker_stopped:
                return
            self._broker_stopped = True
        self.broker.stop()

    def on_ready(self) -> None:
        with self._condition:
            if self._closed:
                return
            self._disconnected = False
            self._ready = True
            self._condition.notify_all()

    def on_startup_error(self, code: str) -> None:
        with self._condition:
            self._startup_error = {"code": _text(code, "startup error")}
            self._condition.notify_all()

    def on_execution(self, request_id: int, contract: Any, execution: Any) -> None:
        with self._condition:
            active = self._active
            if not active or request_id != active.request_id:
                self._fail_locked("unexpected-execution-request-id")
                return
            try:
                row = canonical_execution(contract, execution, self.config.account)
                exec_id = row["execution"]["execId"]
                prior = self._cycle_executions.get(exec_id)
                if prior is not None and prior != row:
                    raise ProtocolError("conflicting duplicate execution")
                if prior is None and len(self._cycle_executions) >= self.max_records:
                    raise ProtocolError("execution record limit exceeded")
                existing = active.executions.get(exec_id)
                if existing is not None and existing != row:
                    raise ProtocolError("conflicting duplicate execution")
                self._cycle_executions[exec_id] = row
                active.executions[exec_id] = row
                pending = self._pending_commissions.pop(exec_id, None)
                if pending is not None:
                    self._store_commission_locked(pending)
            except ProtocolError as error:
                self._fail_locked(str(error))
            self._condition.notify_all()

    def on_execution_end(self, request_id: int) -> None:
        with self._condition:
            if not self._active or request_id != self._active.request_id:
                self._fail_locked("unexpected-execution-end-request-id")
                return
            if self._active.ended_at is not None:
                self._fail_locked("duplicate-execution-end")
                return
            self._active.ended_at = self.now()
            self._active.ended_monotonic = self.monotonic()
            self._condition.notify_all()

    def on_commission(self, report: Any) -> None:
        with self._condition:
            try:
                row = canonical_commission(report)
                exec_id = row["execId"]
                if exec_id in self._cycle_executions:
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
        retire = False
        with self._condition:
            if code in FATAL_SESSION_CODES and not self._retired.is_set():
                self._closed = True
                self._disconnected = True
                self._retired.set()
                if self._active:
                    self._fail_locked("broker-session-retired", brokerCode=code)
                elif not self._ready:
                    self._startup_error = {"code": "broker-session-retired", "brokerCode": code}
                retire = True
            elif self._active and (request_id == self._active.request_id or code in {502, 504}):
                self._fail_locked("broker-request-error", brokerCode=code)
            self._condition.notify_all()
        if retire:
            self._stop_broker_once()

    def on_disconnect(self) -> None:
        with self._condition:
            was_retired = self._retired.is_set()
            self._closed = True
            self._disconnected = True
            self._retired.set()
            if self._active and not was_retired:
                self._fail_locked("broker-disconnected")
            elif not self._ready and not was_retired:
                self._startup_error = {"code": "broker-disconnected-before-ready"}
            self._condition.notify_all()
        self._stop_broker_once()

    def _store_commission_locked(self, row: dict[str, Any]) -> None:
        exec_id = row["execId"]
        prior = self._commissions.get(exec_id)
        if prior is not None and prior != row:
            raise ProtocolError("conflicting duplicate commission")
        if prior is None and len(self._commissions) >= self.max_records:
            raise ProtocolError("commission record limit exceeded")
        self._commissions[exec_id] = row

    def _fail_locked(self, code: str, **detail: Any) -> None:
        error = {"code": code, **detail}
        if self._active is not None and error not in self._active.errors:
            self._active.errors.append(error)
        if error not in self._cycle_errors:
            self._cycle_errors.append(error)

    def _missing_commissions_locked(self) -> list[str]:
        if not self._active:
            return []
        return [exec_id for exec_id in self._active.executions if exec_id not in self._commissions]

    def process(self, value: Any) -> dict[str, Any]:
        try:
            cycle_id, dates = validate_request(value, self.config.account)
        except ProtocolError as error:
            return self.error_result(None, str(error))
        with self._condition:
            if self._closed or self._disconnected:
                return self.error_result(cycle_id, "broker connection is unavailable")
            if self._cycle_active:
                return self.error_result(cycle_id, "another execution cycle is already active")
            if cycle_id in self._seen_cycle_ids:
                return self.error_result(cycle_id, "cycleId has already been used")
            if len(self._seen_cycle_ids) >= self.max_records:
                return self.error_result(cycle_id, "cycleId retention limit exceeded")
            self._cycle_active = True
            self._seen_cycle_ids.add(cycle_id)
            self._cycle_executions = {}
            self._commissions = {}
            self._pending_commissions = {}
            self._cycle_errors = []
        try:
            requests: list[dict[str, Any]] = []
            for day in dates:
                request = self._query_date(day)
                requests.append(request)
                if request["errors"]:
                    break
            with self._condition:
                commissions = [self._commissions[key] for key in sorted(self._commissions)]
                errors = list(self._cycle_errors)
            return {
                "schema": RESULT_SCHEMA,
                "cycleId": cycle_id,
                "account": self.config.account,
                "sdkVersion": self.broker.sdk_version,
                "serverVersion": self.broker.server_version,
                "framing": self.broker.framing,
                "requests": requests,
                "commissions": commissions,
                "errors": errors,
                "finishedAt": self.now(),
            }
        finally:
            with self._condition:
                self._cycle_active = False

    def _query_date(self, day: str) -> dict[str, Any]:
        with self._condition:
            request_id = self._next_request_id
            self._next_request_id += 1
            active = _RequestState(request_id=request_id, date=day, requested_at=self.now())
            self._active = active
        deadline = self.monotonic() + self.config.request_timeout
        try:
            self.broker.request_executions(request_id, self.config.account, day)
        except Exception:
            with self._condition:
                self._fail_locked("execution-request-failed")
        with self._condition:
            while not active.errors:
                if self._closed or self._disconnected:
                    self._fail_locked("broker connection is unavailable")
                    break
                missing = self._missing_commissions_locked()
                now = self.monotonic()
                if active.ended_at is not None:
                    if not missing:
                        break
                    if active.ended_monotonic is None:
                        self._fail_locked("execution-end-clock-missing")
                        break
                    remaining = min(
                        deadline - now,
                        active.ended_monotonic + self.config.commission_grace - now,
                    )
                    if remaining <= 0:
                        break
                else:
                    remaining = deadline - now
                    if remaining <= 0:
                        self._fail_locked(
                            "execution-query-timeout",
                            phase="execDetailsEnd",
                            missingCommissionCount=len(missing),
                        )
                        break
                self._condition.wait(remaining)
            result = {
                "date": active.date,
                "requestedAt": active.requested_at,
                "endedAt": active.ended_at,
                "executions": [active.executions[key] for key in sorted(active.executions)],
                "errors": list(active.errors),
            }
            self._active = None
            return result

    def error_result(self, cycle_id: str | None, code: str) -> dict[str, Any]:
        return {
            "schema": RESULT_SCHEMA,
            "cycleId": cycle_id,
            "account": self.config.account,
            "sdkVersion": getattr(self.broker, "sdk_version", SDK_VERSION),
            "serverVersion": getattr(self.broker, "server_version", None),
            "framing": getattr(self.broker, "framing", "unavailable"),
            "requests": [],
            "commissions": [],
            "errors": [{"code": code[:MAX_TEXT]}],
            "finishedAt": self.now(),
        }


class OfficialBroker:
    def __init__(self) -> None:
        self.sdk_version = package_version("ibapi")
        if self.sdk_version != SDK_VERSION:
            raise ProtocolError("installed official SDK version does not match reader pin")
        self.server_version: int | None = None
        self.framing = "unavailable"
        self._app: Any = None
        self._thread: threading.Thread | None = None

    def start(self, sink: ExecutionReader, host: str, port: int, client_id: int, account: str) -> None:
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
                if not managed_account_matches(accounts_list, account):
                    sink.on_startup_error("configured account is not managed by this session")
                    return
                sink.on_ready()

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
        self.framing = (
            "protobuf" if self.server_version >= PROTOBUF_SERVER_VERSION
            else "legacy-extended" if self.server_version >= MIN_SERVER_VERSION
            else "unsupported"
        )
        self._thread = threading.Thread(target=app.run, name="official-ib-execution-reader", daemon=True)
        self._thread.start()
        self._execution_filter = ExecutionFilter

    def request_executions(self, request_id: int, account: str, day: str) -> None:
        execution_filter = self._execution_filter()
        execution_filter.acctCode = account
        execution_filter.specificDates = [int(day)]
        self._app.reqExecutions(request_id, execution_filter)

    def stop(self) -> None:
        if self._app is not None:
            self._app.disconnect()
        if self._thread is not None and self._thread is not threading.current_thread():
            self._thread.join(timeout=2.0)


def encode_result(reader: ExecutionReader, result: dict[str, Any]) -> bytes:
    try:
        encoded = json.dumps(result, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError):
        encoded = json.dumps(reader.error_result(result.get("cycleId"), "result is not JSON-safe"), separators=(",", ":")).encode()
    if len(encoded) > MAX_OUTPUT_BYTES:
        encoded = json.dumps(reader.error_result(result.get("cycleId"), "result exceeds output limit"), separators=(",", ":")).encode()
    return encoded + b"\n"


def handle_line(reader: ExecutionReader, raw: bytes) -> bytes:
    if len(raw) > MAX_INPUT_BYTES:
        return encode_result(reader, reader.error_result(None, "request exceeds input limit"))
    try:
        value = json.loads(raw, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
    except (UnicodeDecodeError, ValueError):
        return encode_result(reader, reader.error_result(None, "malformed JSON request"))
    return encode_result(reader, reader.process(value))


def serve_jsonl(
    reader: ExecutionReader,
    input_stream: Any,
    output_stream: Any,
    *,
    poll_timeout: float = 0.25,
) -> None:
    """Serve complete JSONL requests while remaining interruptible when the session retires."""
    selector = selectors.DefaultSelector()
    selector.register(input_stream, selectors.EVENT_READ)
    pending = bytearray()

    def write_result(raw: bytes) -> None:
        output_stream.write(handle_line(reader, raw))
        output_stream.flush()

    try:
        while not reader.retired:
            if not selector.select(timeout=poll_timeout):
                continue
            chunk = os.read(input_stream.fileno(), MAX_INPUT_BYTES + 1 - len(pending))
            if not chunk:
                if pending:
                    write_result(bytes(pending))
                break
            pending.extend(chunk)
            while newline_at := pending.find(b"\n") + 1:
                raw = bytes(pending[:newline_at])
                del pending[:newline_at]
                write_result(raw)
                if reader.retired:
                    return
            if len(pending) > MAX_INPUT_BYTES:
                write_result(bytes(pending[: MAX_INPUT_BYTES + 1]))
                return
    finally:
        selector.close()


def parse_args(argv: list[str] | None = None) -> ReaderConfig:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--client-id", required=True, type=int)
    parser.add_argument("--account", required=True)
    args = parser.parse_args(argv)
    return validate_runtime(args.host, args.port, args.client_id, args.account)


def main(argv: list[str] | None = None, broker_factory: Callable[[], Any] = OfficialBroker) -> int:
    try:
        config = parse_args(argv)
        reader = ExecutionReader(config, broker_factory())
        reader.start()
    except (ProtocolError, OSError) as error:
        print(f"execution-reader startup failed: {str(error)[:MAX_TEXT]}", file=sys.stderr, flush=True)
        return 2

    def stop(_signum: int, _frame: Any) -> None:
        reader.close()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        serve_jsonl(reader, sys.stdin.buffer, sys.stdout.buffer)
    finally:
        reader.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
