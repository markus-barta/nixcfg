import assert from "node:assert/strict";
import test from "node:test";
import { executorHealth } from "./producer.mjs";
import { CONTRACTS, validateContract } from "./contracts/index.mjs";

const at = "2026-10-18T12:00:00.000Z";
const health = { status: "ok", halt: { active: false }, brakes: { newPerDay: 1, notionalEur: 100 }, gatewayReachable: true };
const boardResult = executor => validateContract("data", {
  schema: "inspr.joe.household.v2", seq: 1, generatedAt: at, mode: "PAPER", currency: "EUR",
  source: { kind: "live-ib-api", label: "synthetic capture health" },
  safety: { halt: false, haltReason: null, executor },
  desks: ["j", "joe", "joel"].map(id => ({ id, label: id, state: "sit-out", action: "Waiting", money: {} })),
  totals: {},
}, { stage: "ingress", receivedAt: at });
const assertBoard = value => {
  assert.equal(CONTRACTS.revision, 8);
  assert.equal(CONTRACTS.contracts.data, "inspr.joe.household.v2");
  assert.deepEqual(boardResult(value), { ok: true, status: 200, reason: null, errors: [] });
};

for (const [label, resultsCapture, reason] of [
  ["capture degradation", { state: "degraded", ok: false, reason: "results_capture_failed" }, "results_capture_failed"],
  ["capture state alone", { state: "degraded" }, "results_capture_failed"],
  ["capture failure flag alone", { ok: false }, "results_capture_failed"],
  ["capture reason alone", { reason: "results_capture_failed" }, "results_capture_failed"],
  ["admission cap", { newAdmissionsBlocked: true }, "ledger_size_limit"],
  ["cap reason alias", { reason: "ledger_size_limit" }, "ledger_size_limit"],
  ["cap before capture failure", { state: "degraded", reason: "results_capture_failed", newAdmissionsBlocked: true }, "ledger_size_limit"],
]) {
  test(`${label} maps to rev-8 safety.executor`, () => {
    const value = executorHealth({ ...health, resultsCapture: { ...resultsCapture, ledgerBytes: 15100000, ledgerCapBytes: 16777216 } }, at);
    assert.equal(value.status, "degraded");
    assert.equal(value.reason, reason);
    assert.equal(value.halt, false);
    assert.equal(value.brakes, true);
    assert.equal(value.gatewayReachable, true);
    assert.equal(value.ledgerBytes, 15100000);
    assert.equal(value.ledgerCapBytes, 16777216);
    assertBoard(value);
  });
}

for (const newAdmissionsBlocked of [false, true]) {
  test(`broker disagreement takes priority over capture failure; blocked=${newAdmissionsBlocked}`, () => {
    const value = executorHealth({ ...health, status: "degraded", resultsCapture: {
      state: "degraded", ok: false, newAdmissionsBlocked,
      reason: newAdmissionsBlocked ? "ledger_size_limit" : "results_capture_failed",
      ledgerBytes: 17000000, ledgerCapBytes: 16777216,
    } }, at, true);
    assert.equal(value.status, "degraded");
    assert.equal(value.reason, "executor_broker_disagreement");
    assert.equal(value.ledgerBytes, 17000000);
    assert.equal(value.ledgerCapBytes, 16777216);
    assertBoard(value);
  });
}

for (const [label, ledgerBytes, ledgerCapBytes] of [
  ["empty ledger", 0, 1],
  ["below cap", 50, 100],
  ["at cap", 100, 100],
  ["over cap", 101, 100],
  ["largest safe integer", Number.MAX_SAFE_INTEGER, 100],
]) {
  test(`${label} preserves both byte fields without inferring an admission block`, () => {
    const value = executorHealth({ ...health, resultsCapture: { state: "ok", ledgerBytes, ledgerCapBytes } }, at);
    assert.deepEqual(value, { ...executorHealth(health, at), ledgerBytes, ledgerCapBytes });
    assertBoard(value);
  });
}

for (const [label, resultsCapture] of [
  ["unknown capture", undefined],
  ["no byte telemetry", { state: "ok" }],
  ["cap without bytes", { ledgerCapBytes: 100 }],
  ["bytes without cap", { ledgerBytes: 0 }],
  ["legacy cap alias only", { ledgerBytes: 0, ledgerMaxBytes: 100 }],
  ["null bytes", { ledgerBytes: null, ledgerCapBytes: 100 }],
  ["null cap", { ledgerBytes: 0, ledgerCapBytes: null }],
  ["negative bytes", { ledgerBytes: -1, ledgerCapBytes: 100 }],
  ["zero cap", { ledgerBytes: 0, ledgerCapBytes: 0 }],
  ["negative cap", { ledgerBytes: 0, ledgerCapBytes: -1 }],
  ["fractional bytes", { ledgerBytes: 0.5, ledgerCapBytes: 100 }],
  ["fractional cap", { ledgerBytes: 0, ledgerCapBytes: 1.5 }],
  ["string bytes", { ledgerBytes: "0", ledgerCapBytes: 100 }],
  ["string cap", { ledgerBytes: 0, ledgerCapBytes: "100" }],
  ["boolean bytes", { ledgerBytes: false, ledgerCapBytes: 100 }],
  ["boolean cap", { ledgerBytes: 0, ledgerCapBytes: true }],
  ["unsafe bytes", { ledgerBytes: Number.MAX_SAFE_INTEGER + 1, ledgerCapBytes: 100 }],
  ["unsafe cap", { ledgerBytes: 0, ledgerCapBytes: Number.MAX_SAFE_INTEGER + 1 }],
  ["nonfinite bytes", { ledgerBytes: NaN, ledgerCapBytes: 100 }],
  ["nonfinite cap", { ledgerBytes: 0, ledgerCapBytes: Infinity }],
]) {
  test(`${label} omits both byte fields`, () => {
    const value = executorHealth({ ...health, resultsCapture }, at);
    assert.deepEqual(value, executorHealth(health, at));
    assert.equal(Object.hasOwn(value, "ledgerBytes"), false);
    assert.equal(Object.hasOwn(value, "ledgerCapBytes"), false);
    assertBoard(value);
  });
}

test("unknown bytes do not suppress a capture failure reason", () => {
  const value = executorHealth({ ...health, resultsCapture: { state: "degraded", ledgerCapBytes: 100 } }, at);
  assert.deepEqual(value, { ...executorHealth(health, at), status: "degraded", reason: "results_capture_failed" });
  assertBoard(value);
});

test("unrelated degradation keeps its existing reasonless shape", () => {
  for (const input of [{ ...health, status: "degraded" }, { ...health, gatewayReachable: false }]) {
    const value = executorHealth(input, at);
    assert.equal(value.status, "degraded");
    assert.equal(Object.hasOwn(value, "reason"), false);
    assertBoard(value);
  }
});

test("rev-8 board semantics reject a cap without bytes and allow bytes above cap", () => {
  const base = executorHealth(health, at);
  const invalid = boardResult({ ...base, ledgerCapBytes: 100 });
  assert.equal(invalid.status, 422);
  assert.deepEqual(invalid.errors, [{ path: "$.safety.executor.ledgerBytes", rule: "required" }]);
  assertBoard({ ...base, ledgerBytes: 101, ledgerCapBytes: 100 });
});
