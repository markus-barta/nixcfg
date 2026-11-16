import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { Worker } from "node:worker_threads";
import test from "node:test";
import { J_FAMILY_CLASSIFIER, normalizeEconomicExecution } from "./execution-history.mjs";
import { EXECUTION_CAPTURE_SCHEMA, reconcileExecutionCapture } from "./execution-reconciliation.mjs";
import { ATTRIBUTION_MEMORY_SCHEMA, createExecutorAttributionMemory } from "./executor-attribution-memory.mjs";
import { createExecutorAttribution } from "./executor-attribution.mjs";
import { CURRENT_DESK_OWNERSHIP_POLICY as POLICY } from "./desk-ledger.mjs";
import { MAX_COPY_AGE_MS, ops557ReplayGate, replayDeskHistory } from "./replay-ops557.mjs";
import { checkReplayResults, joed196ReplayGate, replayFlatContractGuard, runJoed196ReplayGate } from "./replay-joed196.mjs";
import nvdaFixture from "./fixtures/ops557-nvda.json" with { type: "json" };
import crossBookedFixture from "./fixtures/joed196-avgo-amd.json" with { type: "json" };

const JOED196 = POLICY.fillAttributionOverrides.filter(rule => rule.basis.startsWith("JOED-196 "));
const BEFORE_POLICY = { ...POLICY, fillAttributionOverrides: POLICY.fillAttributionOverrides.filter(rule => !JOED196.includes(rule)) };
// Rows 0-5 NVDA (OPS-557), 6-7 AVGO, 8-9 AMD, 10-11 an unrelated instrument.
const AVGO_BUY = 6, AVGO_SELL = 7, AMD_SELL = 8, AMD_BUY = 9;

function fixture(change = () => {}) {
  const nvda = structuredClone(nvdaFixture), cross = structuredClone(crossBookedFixture);
  const account = nvda.account;
  const rows = nvda.fills.map(fill => ({ contract: nvda.contract, execution: { ...fill, acctNumber: account } }));
  for (const { symbol, ...fill } of cross.fills) {
    rows.push({ contract: structuredClone(cross.contracts[symbol]), execution: { ...fill, acctNumber: account } });
  }
  // Include both open and realised economics outside the corrected contracts.
  for (const [execId, side, shares, price] of [["other.open.01", "BOT", 3, 9876.54321], ["other.close.01", "SLD", 1, 9877.65432]]) {
    rows.push({ contract: { ...nvda.contract, symbol: "OTHER", conId: 567 },
      execution: { execId, acctNumber: account, clientId: 27, side, shares, price, time: "2026-10-13T12:00:00Z" } });
  }
  change(rows);
  const commissions = rows.map(row => ({ execId: row.execution.execId, commission: 0.1, currency: "USD", realizedPNL: null }));
  const toExclusive = "2026-11-17T08:00:00.000Z";
  const window = { fromInclusive: POLICY.periodStart, toExclusive };
  const history = reconcileExecutionCapture({ capture: {
    schema: EXECUTION_CAPTURE_SCHEMA, account, classifier: J_FAMILY_CLASSIFIER,
    source: { kind: "persisted-ledger", id: "synthetic-replay", sha256: "a".repeat(64) },
    capturedAt: toExclusive, window, coverageStatus: "known", completenessAssertion: null,
    executions: rows.map(normalizeEconomicExecution), commissions,
  }, target: window });
  const executorLedger = { schema: "barta.paper-desk-executor-state.v1", account,
    executions: rows.filter(row => row.execution.clientId === 705),
    intents: { synthetic: { action: "place", desk: "joe",
      result: { bracket: { clientId: 705, parentOrderId: 557, stopOrderId: 558 } } } } };
  const memoryState = { schema: ATTRIBUTION_MEMORY_SCHEMA, account, entries: {}, conflicts: [] };
  const familyLedger = { schema: "inspr.joe.family-execution-ledger.v1", version: 1,
    account, periodStart: POLICY.periodStart, coverageThrough: toExclusive,
    executions: structuredClone(rows), commissions: structuredClone(commissions) };
  return { history, executorLedger, memoryState, familyLedger, deployDate: "2026-11-17T08:25:00.000Z" };
}

const check = (result, name) => result.checks.find(check => check.name.startsWith(name));
const RESULT_CHECKS = ["AVGO before J long and Joe equal short", "AVGO after flat on every desk",
  "AMD before J long and Joe equal short", "AMD after flat on every desk",
  "other-symbol lots unchanged count=6", "other-symbol realised unchanged count=6",
  "flat-contract guard rejects before state count=2", "flat-contract guard passes after state",
  "OPS-557 deploy gate on the same copies"];

test("deploy replay proves both mirrors, their closure and the guard, and leaves all four inputs unchanged", () => {
  const input = fixture(), saved = structuredClone(input);
  const result = joed196ReplayGate(input);
  assert.equal(result.ok, true, JSON.stringify(result));
  const names = result.checks.map(row => row.name);
  assert.deepEqual(names.slice(0, 4), ["history freshness", "family ledger freshness", "inputs", "override policy table"]);
  for (const index of [0, 1, 2, 3]) {
    for (const prefix of ["", "ledger raw ", "ledger merged "]) {
      assert.ok(names.includes(`${prefix}override[${index}] matches count=1`));
      assert.ok(names.includes(`${prefix}override[${index}] README fill`));
      assert.equal(names.includes(`${prefix}override[${index}] quantity matches history`), prefix !== "");
    }
  }
  assert.deepEqual(names.slice(-10), ["FIFO replay", ...RESULT_CHECKS]);
  assert.equal(names.length, 4 + 4 * (2 + 3 + 3) + 10);
  assert.deepEqual(input, saved);
});

test("the gate's reviewed fills are exactly the JOED-196 policy rows and their synthetic fixture", () => {
  assert.equal(JOED196.length, 4);
  assert.deepEqual(crossBookedFixture.fills.map(fill => fill.execId).sort(), JOED196.map(rule => rule.execId).sort());
  for (const symbol of ["AVGO", "AMD"]) {
    const fills = crossBookedFixture.fills.filter(fill => fill.symbol === symbol);
    assert.deepEqual(fills.map(fill => fill.side).sort(), ["BOT", "SLD"]);
    assert.equal(fills[0].shares, fills[1].shares, "a synthetic pair that leaves the account flat");
    // Which desk is a reviewed decision, pinned once in desk-ledger.test.mjs.
    const desks = new Set(fills.map(fill => JOED196.find(rule => rule.execId === fill.execId).desk));
    assert.equal(desks.size, 1, `both ${symbol} fills are booked to one desk`);
    assert.ok(["j", "joe"].includes([...desks][0]));
  }
});

test("the OPS-557 gate still proves its own rows on the same copies", () => {
  const input = fixture(), saved = structuredClone(input);
  const result = ops557ReplayGate({ ...input, deployDate: input.deployDate });
  assert.equal(result.ok, true, JSON.stringify(result));
  assert.deepEqual(input, saved);
});

for (const [label, change, expected] of [
  ["raw missing", rows => rows.splice(AVGO_SELL, 1), "ledger raw override[1] matches count=0"],
  ["raw duplicate", rows => rows.push(structuredClone(rows[AVGO_SELL])), "ledger raw override[1] matches count=2"],
  ["merged corrected away", rows => {
    const correction = structuredClone(rows[AVGO_SELL]);
    correction.execution.execId = correction.execution.execId.replace(/01$/, "02");
    rows.push(correction);
  }, "ledger merged override[1] matches count=0"],
]) test(`deploy replay rejects family-ledger override ${label} with unchanged valid history`, () => {
  const input = fixture();
  change(input.familyLedger.executions);
  const result = joed196ReplayGate(input);
  assert.equal(result.ok, false);
  assert.equal(check(result, expected).pass, false);
  assert.equal(check(result, "override[1] README fill").pass, true);
  if (label.startsWith("merged")) assert.equal(check(result, "ledger raw override[1] matches count=1").pass, true);
});

test("deploy replay also requires the full OPS-557 gate (an OPS-557 fill quantity drift fails it)", () => {
  const good = joed196ReplayGate(fixture());
  assert.equal(check(good, "OPS-557 deploy gate on the same copies").pass, true);
  const input = fixture();
  const row = input.familyLedger.executions.find(r => r.execution.execId === "0000dc8f.6bb0d852.01.01");
  assert.ok(row, "fixture carries the OPS-557 NVDA override fill");
  row.execution.shares += 1;
  const result = joed196ReplayGate(input);
  assert.equal(result.ok, false);
  assert.equal(check(result, "OPS-557 deploy gate on the same copies").pass, false);
});

test("deploy replay rejects a family-ledger quantity disagreeing with history without naming it", () => {
  const input = fixture();
  input.familyLedger.executions[AMD_BUY].execution.shares += 1;
  const result = joed196ReplayGate(input);
  assert.equal(result.ok, false);
  assert.equal(check(result, "ledger raw override[3] README fill").pass, true, "the reviewed table carries no quantity");
  assert.equal(check(result, "ledger raw override[3] quantity matches history").pass, false);
  assert.equal(check(result, "ledger merged override[3] quantity matches history").pass, false);
  assert.equal(check(result, "ledger raw override[2] quantity matches history").pass, true);
});

for (const [field, value] of [["conId", 567], ["symbol", "WRONG"], ["clientId", 22], ["side", "SLD"],
  ["time", "2026-09-22T16:08:52Z"]]) {
  test(`deploy replay rejects an override whose README ${field} disagrees`, () => {
    const input = fixture(rows => {
      const row = rows[AVGO_BUY];
      if (["conId", "symbol"].includes(field)) row.contract = { ...row.contract, [field]: value };
      else row.execution[field] = value;
    });
    const result = joed196ReplayGate(input);
    assert.equal(result.ok, false);
    assert.equal(check(result, "override[0] README fill").pass, false);
  });
}

for (const index of [0, 1, 2, 3]) test(`deploy replay rejects a missing override[${index}]`, () => {
  const id = JOED196[index].execId;
  const result = joed196ReplayGate(fixture(rows => rows.splice(rows.findIndex(row => row.execution.execId === id), 1)));
  assert.equal(result.ok, false);
  assert.equal(check(result, `override[${index}] matches count=0`).pass, false);
});

test("deploy replay rejects an override superseded by an IB correction", () => {
  const result = joed196ReplayGate(fixture(rows => {
    const correction = structuredClone(rows[AMD_SELL]);
    correction.execution.execId = correction.execution.execId.replace(/01$/, "02");
    rows.push(correction);
  }));
  assert.equal(result.ok, false);
  assert.equal(check(result, "override[2] matches count=0").pass, false);
});

test("a missing OPS-557 fill fails the whole-table cardinality guard, as production would", () => {
  const id = BEFORE_POLICY.fillAttributionOverrides[0].execId;
  const result = joed196ReplayGate(fixture(rows => rows.splice(rows.findIndex(row => row.execution.execId === id), 1)));
  assert.equal(result.ok, false);
  for (const index of [0, 1, 2, 3]) assert.equal(check(result, `override[${index}] README fill`).pass, true);
  assert.equal(check(result, "inputs or FIFO replay").pass, false);
  assert.equal(check(result, "FIFO replay"), undefined);
});

for (const [name, change, failing] of [
  ["a pair that is not an equal mirror", rows => { rows[AVGO_SELL].execution.shares = 1; },
    ["AVGO before J long and Joe equal short", "AVGO after flat on every desk", "flat-contract guard rejects before state count=1"]],
  ["a pair whose J leg is not long", rows => { [rows[AMD_SELL].execution.side, rows[AMD_BUY].execution.side] = ["BOT", "SLD"]; },
    ["AMD before J long and Joe equal short"]],
  ["a third cross-booked contract outside the table", rows => {
    for (const [execId, clientId, side] of [["third.open.01", 27, "BOT"], ["third.close.01", 22, "SLD"]]) {
      rows.push({ contract: { ...rows[0].contract, symbol: "THIRD", conId: 568 },
        execution: { execId, acctNumber: rows[0].execution.acctNumber, clientId, side, shares: 5, price: 10, time: "2026-10-14T12:00:00Z" } });
    }
  }, ["flat-contract guard rejects before state count=3", "flat-contract guard passes after state"]],
]) test(`deploy replay rejects ${name}`, () => {
  const result = joed196ReplayGate(fixture(change));
  assert.equal(result.ok, false);
  for (const expected of failing) assert.equal(check(result, expected)?.pass, false, expected);
  assert.equal(check(result, "FIFO replay").pass, true);
});

function replays() {
  const { history, executorLedger, memoryState } = fixture();
  const attribution = createExecutorAttribution({ ledger: executorLedger, account: history.account,
    memory: createExecutorAttributionMemory({ account: history.account, state: memoryState }), onEvent() {} });
  return { account: history.account, before: replayDeskHistory(history, attribution, BEFORE_POLICY),
    after: replayDeskHistory(history, attribution, POLICY) };
}

test("the replayed states carry the mirror before and the production guard's verdict on both", () => {
  const { account, before, after } = replays();
  assert.deepEqual(checkReplayResults(before, after).map(row => [row.name, row.pass]), RESULT_CHECKS.slice(0, 6).map(name => [name, true]));
  for (const key of ["conId:313130367", "conId:4391"]) {
    assert.equal(before.j[key].quantity, -before.joe[key].quantity);
    assert.ok(before.j[key].quantity > 0);
    for (const desk of ["j", "joe", "joel"]) assert.equal(after[desk][key].quantity, 0);
  }
  assert.deepEqual(replayFlatContractGuard(before, account), { ok: false, contracts: 4, accountMismatch: 0, crossBooked: 2 });
  assert.deepEqual(replayFlatContractGuard(after, account), { ok: true, contracts: 4, accountMismatch: 0, crossBooked: 0 });
  assert.equal(after.j["conId:567"].quantity, 2, "an owned open lot outside the corrected contracts passes the guard");
});

for (const [name, change] of [
  ["AVGO before J long and Joe equal short", result => { result.before.joe["conId:313130367"].quantity += 1; }],
  ["AVGO before J long and Joe equal short", result => { result.before.joel["conId:313130367"].quantity = 1; }],
  ["AVGO before J long and Joe equal short", result => { result.before.j["conId:313130367"].symbol = "OTHER"; }],
  ["AMD before J long and Joe equal short", result => { delete result.before.j["conId:4391"]; }],
  ["AMD after flat on every desk", result => { result.after.joe["conId:4391"].quantity = -3; }],
  ["AVGO after flat on every desk", result => { result.after.joel["conId:313130367"].quantity = 1e-6; }],
  ["other-symbol lots", result => { result.after.j["conId:567"].quantity++; }],
  ["other-symbol lots", result => { result.after.j["conId:567"].lotInputs.executions[0].execution.price++; }],
  ["other-symbol lots", result => { result.after.joe["conId:4815747"].lotInputs.executions.pop(); }],
  ["other-symbol realised", result => { result.after.j["conId:567"].realizedPnl++; }],
  ["other-symbol realised", result => { result.after.joe["conId:4815747"].realizedPnl++; }],
  ["other-symbol lots", result => { delete result.after.j["conId:567"]; }],
]) test(`deploy evaluator rejects changed ${name}`, () => {
  const result = replays();
  change(result);
  assert.equal(check({ checks: checkReplayResults(result.before, result.after) }, name).pass, false);
});

for (const [name, field] of [["history freshness", "history"], ["family ledger freshness", "familyLedger"]]) {
  for (const [label, offset, pass] of [["at bound", MAX_COPY_AGE_MS, true], ["older than bound", MAX_COPY_AGE_MS + 1, false],
    ["at deployment", 0, true], ["after deployment", -1, false]]) {
    test(`${name} ${label}`, () => {
      const input = structuredClone(fixture());
      input[field][field === "history" ? "updatedAt" : "coverageThrough"] = new Date(Date.parse(input.deployDate) - offset).toISOString();
      const result = joed196ReplayGate(input);
      assert.equal(check(result, name).pass, pass);
      assert.equal(result.ok, pass);
    });
  }
}

for (const deployDate of [undefined, "2026-11-17", "invalid", "2026-11-17T08:25:00", "2026-11-31T08:25:00Z"]) {
  test("deploy replay requires a valid deployment instant with an explicit timezone", () => {
    assert.equal(joed196ReplayGate({ ...fixture(), deployDate }).ok, false);
  });
}

test("deploy replay rejects an invalid family-ledger freshness clock", () => {
  const input = fixture();
  input.familyLedger.coverageThrough = "invalid";
  const result = joed196ReplayGate(input);
  assert.equal(result.ok, false);
  assert.equal(check(result, "family ledger freshness").pass, false);
});

test("an unclaimed executor fill blocks the entire replay", () => {
  const input = fixture();
  input.executorLedger.intents = {};
  const result = joed196ReplayGate(input);
  assert.equal(result.ok, false);
  assert.equal(check(result, "inputs or FIFO replay").pass, false);
});

for (const change of [
  input => { input.history.executions.push(structuredClone(input.history.executions[0])); },
  input => { input.executorLedger.account = "WRONG-SYNTHETIC"; },
  input => { input.memoryState = undefined; },
  input => { input.memoryState.account = "WRONG-SYNTHETIC"; },
  input => { input.familyLedger = undefined; },
  input => { input.familyLedger.account = "WRONG-SYNTHETIC"; },
]) test("invalid or duplicate source evidence fails the deploy gate", () => {
  const input = structuredClone(fixture());
  change(input);
  const result = joed196ReplayGate(input);
  assert.equal(result.ok, false);
  assert.equal(check(result, "inputs or FIFO replay").pass, false);
});

test("deploy command reads exactly four copies, changes no bytes, returns nonzero on failure and prints only gate checks", t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "joed196-replay-"));
  t.after(() => spawnSync("trash", [root], { timeout: 5_000 }));
  // Distinctive synthetic quantities and prices: none may reach the output.
  const input = fixture(rows => {
    for (const [index, shares, price] of [[AVGO_BUY, 4177, 311.07], [AVGO_SELL, 4177, 313.09], [AMD_SELL, 5233, 151.03], [AMD_BUY, 5233, 149.01]]) {
      Object.assign(rows[index].execution, { shares, price });
    }
  });
  const keys = ["history", "executorLedger", "memoryState", "familyLedger"];
  const files = keys.map(key => path.join(root, `${key}.json`));
  const bytes = keys.map(key => JSON.stringify(input[key]));
  files.forEach((file, index) => fs.writeFileSync(file, bytes[index], { mode: 0o600 }));
  const run = args => {
    const lines = [];
    const status = runJoed196ReplayGate(["--deploy-date", input.deployDate, ...args], line => lines.push(line));
    return { status, stdout: `${lines.join("\n")}\n` };
  };
  const passed = run(files);
  assert.equal(passed.status, 0, passed.stdout);
  assert.ok(passed.stdout.endsWith(`PASS FIFO replay\n${RESULT_CHECKS.map(name => `PASS ${name}`).join("\n")}\nPASS JOED-196 deploy gate\n`));
  for (const line of passed.stdout.trim().split("\n")) assert.match(line, /^PASS [A-Za-z0-9 [\]=-]+$/);
  for (const value of [input.history.account, "4177", "5233", "311.07", "313.09", "151.03", "149.01", "9876.54321",
    "OTHER", "NVDA", "0000e0d5", "0000dc8f", "313130367", "4391"]) {
    assert.equal(passed.stdout.includes(value), false, value);
  }
  files.forEach((file, index) => assert.equal(fs.readFileSync(file, "utf8"), bytes[index]));
  const staleLines = [];
  assert.equal(runJoed196ReplayGate(["--deploy-date", "2026-11-17T10:25:00Z", ...files], line => staleLines.push(line)), 1);
  assert.ok(staleLines.includes("FAIL history freshness"));
  assert.ok(staleLines.includes("FAIL family ledger freshness"));
  assert.equal(staleLines.at(-1), "FAIL JOED-196 deploy gate");
  assert.equal(runJoed196ReplayGate([...files, "--deploy-date", input.deployDate], () => {}), 0);
  input.executorLedger.intents = {};
  fs.writeFileSync(files[1], JSON.stringify(input.executorLedger));
  const failed = run(files);
  assert.equal(failed.status, 1);
  assert.match(failed.stdout, /FAIL inputs or FIFO replay\nFAIL JOED-196 deploy gate\n$/);
  const lines = [];
  assert.equal(runJoed196ReplayGate([], line => lines.push(line)), 1);
  assert.deepEqual(lines, ["FAIL four input files and deploy date", "FAIL JOED-196 deploy gate"]);
  assert.equal(runJoed196ReplayGate(files, () => {}), 1, "deployment time is required");
  assert.equal(run([...files, files[0]]).status, 1);
  assert.equal(run([path.join(root, "absent"), ...files.slice(1)]).status, 1);
});

test("symlinked CLI executes the JOED-196 gate and returns nonzero with missing arguments", { timeout: 10_000 }, async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "joed196-replay-link-"));
  t.after(() => spawnSync("trash", [root], { timeout: 5_000 }));
  const link = path.join(root, "gate.mjs");
  fs.symlinkSync(fs.realpathSync(new URL("./replay-joed196.mjs", import.meta.url)), link);
  // A worker uses Node's real module loader and argv entry path, with its own
  // exit code and output, without needing a child-process permission.
  const result = await new Promise((resolve, reject) => {
    const worker = new Worker(link, { stdout: true, stderr: true, execArgv: [] });
    let stdout = "", stderr = "";
    worker.stdout.on("data", bytes => { stdout += bytes; });
    worker.stderr.on("data", bytes => { stderr += bytes; });
    worker.once("error", reject);
    worker.once("exit", status => resolve({ status, stdout, stderr }));
  });
  assert.equal(result.status, 1);
  assert.equal(result.stdout, "FAIL four input files and deploy date\nFAIL JOED-196 deploy gate\n");
  assert.equal(result.stderr, "");
});
