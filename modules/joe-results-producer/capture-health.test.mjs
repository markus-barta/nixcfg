import assert from "node:assert/strict";
import test from "node:test";
import { executorHealth } from "./producer.mjs";
import { SCHEMAS, SCHEMA_FILES } from "./contracts/index.mjs";
import { checkSchema } from "./contracts/schema-validator.mjs";

const at = "2026-10-18T12:00:00.000Z";
const health = { status: "ok", halt: { active: false }, brakes: { newPerDay: 1, notionalEur: 100 }, gatewayReachable: true };
const schema = SCHEMAS.data.properties.safety.properties.executor;

for (const [label, resultsCapture, reason] of [
  ["capture degradation", { state: "degraded", ok: false, reason: "results_capture_failed" }, undefined],
  ["admission cap", { newAdmissionsBlocked: true }, "ledger_size_limit"],
  ["cap reason alias", { reason: "ledger_size_limit" }, "ledger_size_limit"],
]) {
  test(`${label} maps to rev-6 safety.executor without extending the contract`, () => {
    const value = executorHealth({ ...health, resultsCapture: { ...resultsCapture, ledgerBytes: 15100000, ledgerCapBytes: 16777216 } }, at);
    assert.equal(value.status, "degraded");
    assert.equal(value.reason, reason);
    assert.equal(value.halt, false);
    assert.equal(value.brakes, true);
    assert.equal(value.gatewayReachable, true);
    assert.equal(Object.hasOwn(value, "ledgerBytes"), false);
    assert.equal(Object.hasOwn(value, "ledgerCapBytes"), false);
    assert.deepEqual(checkSchema(schema, value, SCHEMA_FILES, [], "$", SCHEMAS.data), []);
  });
}

test("broker disagreement takes priority over the capture ledger cap", () => {
  const value = executorHealth({ ...health, status: "degraded", resultsCapture: { ok: false, newAdmissionsBlocked: true, reason: "ledger_size_limit" } }, at, true);
  assert.equal(value.status, "degraded");
  assert.equal(value.reason, "executor_broker_disagreement");
  assert.deepEqual(checkSchema(schema, value, SCHEMA_FILES, [], "$", SCHEMAS.data), []);
});
