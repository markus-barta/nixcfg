import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { J_FAMILY_CLASSIFIER } from "./execution-history.mjs";
import { EXECUTION_CAPTURE_SCHEMA, reconcileExecutionCapture } from "./execution-reconciliation.mjs";
import { ATTRIBUTION_MEMORY_SCHEMA, createExecutorAttributionMemory } from "./executor-attribution-memory.mjs";
import { createExecutorAttribution } from "./executor-attribution.mjs";
import { CURRENT_DESK_OWNERSHIP_POLICY as POLICY } from "./desk-ledger.mjs";
import { checkReplayResults, ops557ReplayGate, replayDeskHistory, runReplayGate } from "./replay-ops557.mjs";

function fixture(change = () => {}) {
  const source = JSON.parse(fs.readFileSync(new URL("./fixtures/ops557-nvda.json", import.meta.url)));
  const rows = source.fills.map(fill => ({ contract: source.contract, execution: { ...fill, acctNumber: source.account } }));
  // Include both open and realised non-NVDA economics in the comparison.
  for (const [execId, side, shares, price] of [["other.open.01", "BOT", 3, 9876.54321], ["other.close.01", "SLD", 1, 9877.65432]]) {
    rows.push({ contract: { ...source.contract, symbol: "OTHER", conId: 567 },
      execution: { execId, acctNumber: source.account, clientId: 27, side, shares, price, time: "2026-10-13T12:00:00Z" } });
  }
  change(rows);
  const commissions = rows.map(row => ({ execId: row.execution.execId, commission: 0.1, currency: "USD", realizedPNL: null }));
  const toExclusive = "2026-11-10T20:00:00.000Z";
  const window = { fromInclusive: POLICY.periodStart, toExclusive };
  const history = reconcileExecutionCapture({ capture: {
    schema: EXECUTION_CAPTURE_SCHEMA, account: source.account, classifier: J_FAMILY_CLASSIFIER,
    source: { kind: "persisted-ledger", id: "synthetic-replay", sha256: "a".repeat(64) },
    capturedAt: toExclusive, window, coverageStatus: "known", completenessAssertion: null,
    executions: rows, commissions,
  }, target: window });
  const executorLedger = { schema: "barta.paper-desk-executor-state.v1", account: source.account,
    executions: rows.filter(row => row.execution.clientId === 705),
    intents: { synthetic: { action: "place", desk: "joe",
      result: { bracket: { clientId: 705, parentOrderId: 557, stopOrderId: 558 } } } } };
  const memoryState = { schema: ATTRIBUTION_MEMORY_SCHEMA, account: source.account, entries: {}, conflicts: [] };
  return { history, executorLedger, memoryState };
}

const check = (result, name) => result.checks.find(check => check.name.startsWith(name));

test("deploy replay passes with executor routing, proves +8 -> 0 and leaves all three inputs unchanged", () => {
  const input = fixture(), saved = structuredClone(input);
  const result = ops557ReplayGate(input);
  assert.equal(result.ok, true, JSON.stringify(result));
  for (const name of ["J NVDA before=+8", "J NVDA after=0", "Joe NVDA after=0", "other-symbol lots", "other-symbol realised"]) {
    assert.equal(check(result, name).pass, true, name);
  }
  assert.deepEqual(input, saved);
});

test("deploy replay uses exact attribution memory after intent retention", () => {
  const input = fixture();
  const execution = input.executorLedger.executions[0].execution;
  const key = JSON.stringify([input.history.account, execution.clientId, execution.execId]);
  input.memoryState.entries[key] = { clientId: execution.clientId, execId: execution.execId,
    orderId: execution.orderId, desk: "joe", subDesk: "joe", source: "intent", provenAt: input.history.updatedAt };
  input.executorLedger.intents = {};
  const saved = structuredClone(input);
  const result = ops557ReplayGate(input);
  assert.equal(result.ok, true, JSON.stringify(result));
  assert.deepEqual(input, saved);
});

for (const [field, value] of [["conId", 567], ["symbol", "WRONG"], ["clientId", 22], ["side", "BOT"],
  ["shares", 3], ["time", "2026-09-23T13:30:05Z"]]) {
  test(`deploy replay rejects an override whose README ${field} disagrees`, () => {
    const input = fixture(rows => {
      const row = rows[1];
      if (["conId", "symbol"].includes(field)) row.contract = { ...row.contract, [field]: value };
      else row.execution[field] = value;
    });
    const result = ops557ReplayGate(input);
    assert.equal(result.ok, false);
    assert.equal(check(result, "override[0] README fill").pass, false);
  });
}

for (const index of [0, 1, 2]) test(`deploy replay rejects a missing override[${index}]`, () => {
  const id = POLICY.fillAttributionOverrides[index].execId;
  const result = ops557ReplayGate(fixture(rows => rows.splice(rows.findIndex(row => row.execution.execId === id), 1)));
  assert.equal(result.ok, false);
  assert.equal(check(result, `override[${index}] matches count=0`).pass, false);
});

test("deploy replay rejects an override superseded by an IB correction", () => {
  const result = ops557ReplayGate(fixture(rows => {
    const correction = structuredClone(rows[1]);
    correction.execution.execId = correction.execution.execId.replace(/01$/, "02");
    rows.push(correction);
  }));
  assert.equal(result.ok, false);
  assert.equal(check(result, "override[0] matches count=0").pass, false);
});

for (const [name, change] of [
  ["J NVDA before=+8", rows => { rows[0].execution.shares = 5; }],
  ["J NVDA after=0", rows => { rows[3].execution.shares = 2; }],
  ["Joe NVDA after=0", rows => { rows[4].execution.shares = 5; }],
]) test(`deploy replay rejects wrong ${name}`, () => {
  const result = ops557ReplayGate(fixture(change));
  assert.equal(result.ok, false);
  assert.equal(check(result, name).pass, false);
});

function replays() {
  const { history, executorLedger, memoryState } = fixture();
  const attribution = createExecutorAttribution({ ledger: executorLedger, account: history.account,
    memory: createExecutorAttributionMemory({ account: history.account, state: memoryState }), onEvent() {} });
  return { before: replayDeskHistory(history, attribution, { ...POLICY, fillAttributionOverrides: [] }),
    after: replayDeskHistory(history, attribution) };
}

for (const [name, change] of [
  ["other-symbol lots", result => { result.after.j["conId:567"].quantity++; }],
  ["other-symbol lots", result => { result.after.j["conId:567"].lotInputs.executions[0].execution.price++; }],
  ["other-symbol realised", result => { result.after.j["conId:567"].realizedPnl++; }],
  ["other-symbol lots", result => { delete result.after.j["conId:567"]; }],
]) test(`deploy evaluator rejects changed ${name}`, () => {
  const result = replays();
  change(result);
  assert.equal(check({ checks: checkReplayResults(result.before, result.after) }, name).pass, false);
});

test("an unclaimed executor fill blocks the entire replay", () => {
  const input = fixture();
  input.executorLedger.intents = {};
  const result = ops557ReplayGate(input);
  assert.equal(result.ok, false);
  assert.equal(check(result, "inputs or FIFO replay").pass, false);
});

for (const change of [
  input => { input.history.executions.push(structuredClone(input.history.executions[0])); },
  input => { input.executorLedger.account = "WRONG-SYNTHETIC"; },
  input => { input.memoryState = undefined; },
  input => { input.memoryState.account = "WRONG-SYNTHETIC"; },
]) test("invalid or duplicate source evidence fails the deploy gate", () => {
  const input = structuredClone(fixture());
  change(input);
  const result = ops557ReplayGate(input);
  assert.equal(result.ok, false);
  assert.equal(check(result, "inputs or FIFO replay").pass, false);
});

test("deploy command reads exactly three copies, changes no bytes, returns nonzero on failure and prints only gate checks", t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ops557-replay-"));
  t.after(() => spawnSync("trash", [root], { timeout: 5_000 }));
  const input = fixture();
  const files = Object.keys(input).map(key => path.join(root, `${key}.json`));
  const bytes = Object.values(input).map(value => JSON.stringify(value));
  files.forEach((file, index) => fs.writeFileSync(file, bytes[index], { mode: 0o600 }));
  const run = args => {
    const lines = [];
    const status = runReplayGate(args, line => lines.push(line));
    return { status, stdout: `${lines.join("\n")}\n`, stderr: "" };
  };
  const passed = run(files);
  assert.equal(passed.status, 0, passed.stdout + passed.stderr);
  assert.match(passed.stdout, /PASS J NVDA before=\+8\nPASS J NVDA after=0\nPASS Joe NVDA after=0/);
  assert.match(passed.stdout, /PASS OPS-557 deploy gate\n$/);
  for (const line of passed.stdout.trim().split("\n")) assert.match(line, /^(PASS|FAIL) [A-Za-z0-9 [\]=+.-]+$/);
  for (const value of [input.history.account, "9876.54321", "9877.65432", "228.02", "OTHER", "ops557.j-open.01"]) {
    assert.equal(passed.stdout.includes(value), false);
  }
  files.forEach((file, index) => assert.equal(fs.readFileSync(file, "utf8"), bytes[index]));
  input.executorLedger.intents = {};
  fs.writeFileSync(files[1], JSON.stringify(input.executorLedger));
  const failed = run(files);
  assert.equal(failed.status, 1);
  assert.match(failed.stdout, /FAIL OPS-557 deploy gate\n$/);
  assert.equal(failed.stderr, "");
  const lines = [];
  assert.equal(runReplayGate([], line => lines.push(line)), 1);
  assert.deepEqual(lines, ["FAIL three input files", "FAIL OPS-557 deploy gate"]);
  assert.equal(run([...files, files[0]]).status, 1);
  assert.equal(run([path.join(root, "absent"), ...files.slice(1)]).status, 1);
});
