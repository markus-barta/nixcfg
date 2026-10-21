import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { executorUnclaimedDiagnostic, summarizeExecutorUnclaimed } from "./diag-executor-unclaimed.mjs";
import { createExecutorAttribution } from "./executor-attribution.mjs";
import { J_FAMILY_CLASSIFIER } from "./execution-history.mjs";
import { FAMILY_BASELINE_PERIOD_START, createFileFamilyStateStore } from "./family-state.mjs";

const account = "DUSENTINELACCOUNT";
const root = path.dirname(fileURLToPath(import.meta.url));
const row = (name, orderId, side = "BOT", conId = 99123, orderRef = "SENTINELREF|ops-test-ko") => ({
  contract: { conId, symbol: "SENTINELSYMBOL", currency: "USD", secType: "STK", multiplier: 1 },
  execution: { execId: `SENTINELEXEC.${name}.01`, acctNumber: account, clientId: 705, orderId,
    orderRef, time: "2026-10-06T18:16:10Z", side, shares: 98765, price: 45678.125 },
});
const intent = (orderId, desk = "joe") => ({ action: "flatten", desk, result: { flattened: [{ clientId: 705, orderId }] } });

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "joed39-diag-"));
  t.after(() => spawnSync("trash", [directory]));
  const rows = [row("buy", 901), row("sell", 902, "SLD"), row("nonflat", 903, "BUY", 99124),
    row("unmatched", 904, "BUY", 99125, "SENTINELREF|xops-test-ko"),
    row("matched", 905, "BUY", 99126, "SENTINELREF"), row("bad-desk", 906, "BUY", 99127, "SENTINELREF"),
    row("bad-time", 907, "BUY", 99128), row("ambiguous", 908, "BUY", 99129, "SENTINELREF")];
  rows[1].execution.time = "2026-10-06T21:10:30+02:00";
  rows[6].execution.time = "2026-02-30T10:00:00Z";
  const ignored = [row("keep", 909), row("legacy", 910)];
  ignored[0].contract.symbol = "SXR8";
  ignored[1].execution.clientId = 22;
  rows.push(...ignored);
  const ledger = { schema: "barta.paper-desk-executor-state.v1", account,
    intents: { SENTINELINTENT: intent(905), BADINTENT: intent(906, "SENTINELDESK"),
      AMBIGUOUSA: intent(908), AMBIGUOUSB: intent(908) }, executions: rows };
  const state = { schema: "inspr.joe.family-execution-ledger.v1", version: 1, account,
    periodStart: FAMILY_BASELINE_PERIOD_START, initializedAt: "2026-10-06T17:55:49Z", classifier: J_FAMILY_CLASSIFIER,
    executions: rows, commissions: [], queryExecutionIdentities: rows.map(row => row.execution.execId).sort(),
    ledgerObservedAt: "2026-10-06T20:00:00Z", coverageThrough: "2026-10-06T20:00:00Z", coverageTradingDay: "2026-10-06", family: null };
  const familyFile = path.join(directory, "family-ledger.json"), executorFile = path.join(directory, "executor-ledger.json");
  createFileFamilyStateStore(familyFile).save(state);
  fs.writeFileSync(executorFile, JSON.stringify(ledger));
  return { rows, ledger, state, familyFile, executorFile };
}

test("diagnostic uses the pusher loaders, counts every cause and round-trips clocks without leaking sentinel fields", t => {
  const input = fixture(t);
  const before = [input.familyFile, input.executorFile].map(file => fs.readFileSync(file));
  const report = executorUnclaimedDiagnostic({ account, familyFile: input.familyFile, executorFile: input.executorFile });
  assert.equal(report.ok, true);
  assert.deepEqual(report.causes.ops_test, { count: 2, first: "2026-10-06T18:16:10.000Z", last: "2026-10-06T19:10:30.000Z" });
  assert.equal(report.causes.ops_test_not_flat.count, 1);
  assert.equal(report.causes.intent_unmatched.count, 2);
  assert.equal(report.causes.matched.count, 1);
  assert.equal(report.causes.intent_desk_invalid.count, 1);
  assert.equal(report.causes.intent_ambiguous.count, 1);
  assert.equal(report.instrumentsNotFlat, 1);
  assert.deepEqual(Object.keys(report).sort(), ["ok", "causes", "instrumentsNotFlat"].sort());
  for (const value of Object.values(report.causes)) assert.deepEqual(Object.keys(value).sort(), ["count", "first", "last"]);
  const body = JSON.stringify(report);
  for (const sentinel of ["SENTINEL", "98765", "45678", "99123", "orderRef", "intentId", "clientId", "symbol", "shares", "price", "acctNumber"]) {
    assert.equal(body.includes(sentinel), false, sentinel);
  }
  assert.deepEqual([input.familyFile, input.executorFile].map(file => fs.readFileSync(file)), before, "read-only inputs");
  const result = spawnSync(process.execPath, ["--input-type=module", "-e",
    'import { executorUnclaimedDiagnostic } from "./diag-executor-unclaimed.mjs"; console.log(JSON.stringify(executorUnclaimedDiagnostic(JSON.parse(process.argv[1]))));',
    JSON.stringify({ account, familyFile: input.familyFile, executorFile: input.executorFile })], { cwd: root, encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, "", "suppresses even invalid-desk events");
  assert.deepEqual(JSON.parse(result.stdout), report, "one value-free JSON report");
});

test("diagnostic does not manufacture ISO bounds for a rolled civil time", () => {
  const rows = [row("invalid", 901)];
  rows[0].execution.time = "2026-04-31T24:00:00Z";
  const source = createExecutorAttribution({ account, executionRows: rows,
    ledger: { schema: "barta.paper-desk-executor-state.v1", account, intents: {}, executions: rows }, onEvent() {} });
  assert.deepEqual(summarizeExecutorUnclaimed(rows, source).causes.intent_unmatched, { count: 1, first: null, last: null });
});

test("diagnostic input failures stay fixed, value-free JSON; missing executor evidence retains its cause", t => {
  const input = fixture(t);
  assert.deepEqual(executorUnclaimedDiagnostic({ account, familyFile: path.join(path.dirname(input.familyFile), "absent.json") }),
    { ok: false, cause: "family_ledger_unavailable" });
  fs.writeFileSync(input.familyFile, "SENTINELCORRUPT");
  assert.deepEqual(executorUnclaimedDiagnostic({ account, familyFile: input.familyFile }), { ok: false, cause: "family_ledger_unavailable" });
  const source = createExecutorAttribution({ account, ledger: null, executionRows: input.rows, onEvent() {} });
  assert.equal(summarizeExecutorUnclaimed(input.rows, source).causes.ledger_unavailable.count, 8);
  const result = spawnSync(process.execPath, ["diag-executor-unclaimed.mjs"], {
    cwd: root, encoding: "utf8", env: { ...process.env, IB_DESK_ACCOUNT: "SENTINELINVALIDACCOUNT" },
  });
  assert.equal(result.status, 1);
  assert.equal(result.stderr, "");
  assert.deepEqual(JSON.parse(result.stdout), { ok: false, cause: "diagnostic_inputs_unavailable" });
});
