#!/usr/bin/env node
/** Synthetic local-artifact adapter tests. No broker connection or real account data. */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  J_FAMILY_CLASSIFIER,
  captureFromFamilyLedgerFile,
  captureFromOfficialProbeFile,
  capturesFromOfficialWindowEvidence,
  normalizeEconomicCommission,
  normalizeEconomicExecution,
} from "./execution-history.mjs";
import { reconcileExecutionCapture } from "./execution-reconciliation.mjs";
import { calculateCapturedRealizedSubtotal } from "./family-history.mjs";

const ACCOUNT = "SYNTHETIC-PAPER";
const WINDOW = { fromInclusive: "2026-09-10T04:00:00Z", toExclusive: "2026-09-11T04:00:00Z" };
const CLI = path.join(path.dirname(fileURLToPath(import.meta.url)), "family-history-cli.mjs");

test("default J classifier preserves the proven production client family", () => {
  assert.deepEqual(J_FAMILY_CLASSIFIER.familyClientIds, [27, 28, 29, 50, 51, 52, 53, 54, 55, 56]);
});

test("economic numeric fields reject JavaScript coercions while SDK numeric strings remain valid", () => {
  const row = {
    contract: { conId: "1001", symbol: "MSFT", secType: "STK", currency: "USD", multiplier: "1" },
    execution: {
      execId: "strict.trade.01",
      time: "20260910 12:00:00 US/Eastern",
      acctNumber: ACCOUNT,
      clientId: "51",
      side: "BOT",
      shares: "2.5",
      price: "10.25",
    },
  };
  assert.equal(normalizeEconomicExecution(row).execution.shares, 2.5);
  for (const invalid of [false, true, null, [], {}, "", " ", " 1"]) {
    const changed = structuredClone(row);
    changed.execution.shares = invalid;
    assert.throws(() => normalizeEconomicExecution(changed), /execution shares is invalid/);
  }
  for (const invalid of [false, true, [], {}, " "]) {
    const changed = structuredClone(row);
    changed.contract.multiplier = invalid;
    assert.throws(() => normalizeEconomicExecution(changed), /contract multiplier is invalid/);
  }
  for (const accepted of [undefined, null, "", 0, "0", 1, "1"]) {
    const changed = structuredClone(row);
    changed.contract.multiplier = accepted;
    assert.equal(normalizeEconomicExecution(changed).contract.multiplier, 1);
  }
  assert.deepEqual(normalizeEconomicCommission({
    execId: "strict.trade.01",
    commissionAndFees: "0.25",
    currency: "USD",
    realizedPNL: null,
  }), { execId: "strict.trade.01", commission: 0.25, currency: "USD", realizedPNL: null });
  for (const invalid of [false, true, null, [], {}, "", " "]) {
    assert.throws(() => normalizeEconomicCommission({
      execId: "strict.trade.01",
      commission: invalid,
      currency: "USD",
    }), /commission amount is invalid/);
  }
  for (const invalid of [false, true, [], {}, "", " "]) {
    assert.throws(() => normalizeEconomicCommission({
      execId: "strict.trade.01",
      commission: 0.25,
      currency: "USD",
      realizedPNL: invalid,
    }), /commission realizedPNL is invalid/);
  }
});

test("classifier IDs reject coercible booleans, nulls, and containers", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "execution-history-classifier-test-"));
  const filePath = writeJson(directory, "ledger.json", {
    account: ACCOUNT,
    coverageThrough: "2026-09-10T20:30:00Z",
    executions: [{
      contract: { conId: 1001, symbol: "MSFT", secType: "STK", currency: "USD", multiplier: 0 },
      execution: { execId: "classifier.trade.01", time: "20260910 12:00:00 US/Eastern", acctNumber: ACCOUNT, clientId: 51, side: "BOT", shares: 1, price: 10 },
    }],
    commissions: [{ execId: "classifier.trade.01", commission: 0.1, currency: "USD" }],
  });
  for (const invalid of [false, true, null, [], {}]) {
    assert.throws(() => captureFromFamilyLedgerFile({
      filePath,
      window: WINDOW,
      classifier: { familyClientIds: [27, invalid], excludedSymbols: [] },
    }), /classifier client ID is invalid/);
  }
  assert.deepEqual(captureFromFamilyLedgerFile({
    filePath,
    window: WINDOW,
    classifier: { familyClientIds: ["27", "56"], excludedSymbols: [] },
  }).classifier.familyClientIds, [27, 56]);
});

function writeJson(directory, name, value) {
  const file = path.join(directory, name);
  fs.writeFileSync(file, `${JSON.stringify(value)}\n`, { mode: 0o600 });
  return file;
}

test("persisted-ledger and official-probe adapters normalize representation-only differences", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "execution-history-test-"));
  const execId = "synthetic.trade.01";
  const oldRow = {
    contract: { conId: 1001, symbol: "MSFT", secType: "STK", currency: "USD", multiplier: 0, exchange: "SMART" },
    execution: {
      execId,
      time: "20260910 12:00:00 US/Eastern",
      acctNumber: ACCOUNT,
      clientId: 51,
      side: "BOT",
      shares: 1,
      price: 10,
      avgPrice: 10,
    },
  };
  const officialRow = {
    contract: { conId: 1001, symbol: "MSFT", secType: "STK", currency: "USD", exchange: "SMART" },
    execution: {
      execId,
      time: "20260910 18:00:00 Europe/Vienna",
      acctNumber: ACCOUNT,
      clientId: 51,
      side: "BUY",
      shares: "1",
      price: 10,
      avgPrice: 999,
    },
    observedAt: "2026-09-11T07:00:00Z",
  };
  const ledgerPath = writeJson(directory, "family-ledger.json", {
    account: ACCOUNT,
    coverageThrough: "2026-09-10T20:30:00Z",
    executions: [oldRow],
    commissions: [{ execId, commission: 0.1, currency: "USD" }],
  });
  const probePath = writeJson(directory, "probe-evidence.json", {
    sdk: { package: "ibapi", version: "10.45.1" },
    negotiated: { serverVersion: 223, executionRequestFraming: "protobuf" },
    requests: {
      9310: {
        label: "specific-date",
        requestedAt: "2026-09-11T07:00:00Z",
        endedAt: "2026-09-11T07:00:01Z",
        timedOut: false,
        errors: [],
        executions: [officialRow],
      },
    },
    commissionsByExecId: {
      [execId]: { execId, commissionAndFees: "0.1", currency: "USD", realizedPNL: "0" },
    },
  });

  const ledgerCapture = captureFromFamilyLedgerFile({ filePath: ledgerPath, window: WINDOW });
  const probeCapture = captureFromOfficialProbeFile({ filePath: probePath, requestId: 9310, window: WINDOW });
  assert.deepEqual(ledgerCapture.executions, probeCapture.executions);
  assert.equal(ledgerCapture.executions[0].execution.time, "2026-09-10T16:00:00.000Z");
  assert.equal(ledgerCapture.executions[0].execution.shares, 1);
  assert.equal(ledgerCapture.executions[0].contract.multiplier, 1);
  assert.equal(probeCapture.coverageStatus, "known");
  assert.equal(probeCapture.source.metadata.completenessClaimed, false);

  const first = reconcileExecutionCapture({ capture: ledgerCapture, target: WINDOW });
  const state = reconcileExecutionCapture({ prior: first, capture: probeCapture, target: WINDOW });
  assert.equal(state.executions.length, 1);
  assert.equal(state.commissions.length, 1);
  assert.equal(state.commissions[0].realizedPNL, 0);
  assert.equal(state.receipts.length, 2);
  assert.equal(state.coverage.status, "known");
  assert.deepEqual(state.classifier, J_FAMILY_CLASSIFIER);
});

test("immutable economic differences conflict after normalization", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "execution-history-test-"));
  const execId = "synthetic.conflict.01";
  const base = {
    contract: { conId: 1001, symbol: "MSFT", secType: "STK", currency: "USD", multiplier: 0 },
    execution: {
      execId,
      time: "20260910 12:00:00 US/Eastern",
      acctNumber: ACCOUNT,
      clientId: 51,
      side: "BOT",
      shares: 1,
      price: 10,
    },
  };
  const firstPath = writeJson(directory, "first.json", {
    account: ACCOUNT,
    coverageThrough: "2026-09-10T20:30:00Z",
    executions: [base],
    commissions: [{ execId, commission: 0.1, currency: "USD" }],
  });
  const changed = structuredClone(base);
  changed.execution.price = 11;
  const secondPath = writeJson(directory, "second.json", {
    account: ACCOUNT,
    coverageThrough: "2026-09-10T20:31:00Z",
    executions: [changed],
    commissions: [{ execId, commission: 0.1, currency: "USD" }],
  });
  const first = reconcileExecutionCapture({
    capture: captureFromFamilyLedgerFile({ filePath: firstPath, window: WINDOW }),
    target: WINDOW,
  });
  assert.throws(() => reconcileExecutionCapture({
    prior: first,
    capture: captureFromFamilyLedgerFile({ filePath: secondPath, window: WINDOW }),
    target: WINDOW,
  }), /conflicting execution/);
  assert.equal(first.executions[0].execution.price, 10);
});

test("official broker realizedPNL stays supplementary while family FIFO computes money", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "execution-history-test-"));
  const rows = [
    {
      contract: { conId: 1001, symbol: "INTC", secType: "STK", currency: "USD" },
      execution: { execId: "teach.buy.01", time: "20260910 18:00:00 Europe/Vienna", acctNumber: ACCOUNT, clientId: 29, side: "BOT", shares: "9", price: 101.61 },
    },
    {
      contract: { conId: 1001, symbol: "INTC", secType: "STK", currency: "USD" },
      execution: { execId: "teach.sell.01", time: "20260910 18:01:00 Europe/Vienna", acctNumber: ACCOUNT, clientId: 29, side: "SLD", shares: "9", price: 101.27 },
    },
  ];
  const filePath = writeJson(directory, "probe.json", {
    sdk: { package: "ibapi", version: "10.45.1" },
    negotiated: { serverVersion: 223, executionRequestFraming: "protobuf" },
    requests: { 9310: { label: "specific-date", endedAt: "2026-09-11T07:00:01Z", timedOut: false, errors: [], executions: rows } },
    commissionsByExecId: {
      "teach.buy.01": { execId: "teach.buy.01", commissionAndFees: 1.000027, currency: "USD", realizedPNL: 0 },
      "teach.sell.01": { execId: "teach.sell.01", commissionAndFees: 1.020557, currency: "USD", realizedPNL: -5.080584 },
    },
  });
  const state = reconcileExecutionCapture({
    capture: captureFromOfficialProbeFile({ filePath, requestId: 9310, window: WINDOW }),
    target: WINDOW,
  });
  const subtotal = calculateCapturedRealizedSubtotal(state);
  assert.equal(state.commissions.find((row) => row.execId === "teach.sell.01").realizedPNL, -5.080584);
  assert.equal(subtotal.method, "captured-fifo-matched-roundtrips");
  assert.ok(Math.abs(subtotal.nativeRealizedPnl[0].realizedPnl - -5.080584) < 1e-10);
  assert.equal(subtotal.points[0].at, "2026-09-10T16:01:00.000Z");
  assert.equal(subtotal.points[0].realizedPnl, subtotal.nativeRealizedPnl[0].realizedPnl);
  assert.equal(subtotal.pointsTruncated, false);
  assert.equal(subtotal.matchedQuantity, 9);
  assert.deepEqual(subtotal.endingOpenQuantities, []);
  assert.deepEqual(subtotal.missingOpeningLots, []);
});

function officialWindowEvidence({ pendingPriceRevision = false, fee = true, account = ACCOUNT } = {}) {
  const row = {
    contract: { conId: 1001, symbol: "MSFT", secType: "STK", currency: "USD" },
    execution: {
      execId: "official.complete.01", time: "20260910 12:00:00 US/Eastern",
      acctNumber: account, clientId: 51, side: "BOT", shares: "1", price: "10",
      pendingPriceRevision,
    },
  };
  return {
    schemaVersion: 1,
    endpoint: { host: "paper.invalid", port: 4002, clientId: 94, account: ACCOUNT },
    sdk: { package: "ibapi", version: "10.45.1" },
    negotiated: {
      serverVersion: 223,
      executionRequestFraming: "protobuf",
      parameterizedExecutionFilters: true,
    },
    managedAccounts: [ACCOUNT],
    foreignAccountViolation: false,
    startedAt: "2026-09-11T08:54:59Z",
    requestedCoverage: {
      fromInclusive: "2026-09-10T04:00:00.000Z",
      toExclusive: "2026-09-11T09:00:00.000Z",
    },
    actualWindows: [
      {
        requestId: 9341,
        newYorkDate: 20260910,
        fromInclusive: "2026-09-10T04:00:00.000Z",
        toExclusive: "2026-09-11T04:00:00.000Z",
        filter: { acctCode: ACCOUNT, specificDates: [20260910], time: "20260910-04:00:00" },
      },
      {
        requestId: 9340,
        newYorkDate: 20260911,
        fromInclusive: "2026-09-11T04:00:00.000Z",
        toExclusive: "2026-09-11T09:00:00.000Z",
        filter: { acctCode: ACCOUNT, specificDates: [20260911], time: "20260911-04:00:00" },
      },
    ],
    requests: {
      9341: {
        label: "specific-date",
        filter: { acctCode: ACCOUNT, specificDates: [20260910], time: "20260910-04:00:00" },
        actualWindow: { fromInclusive: "2026-09-10T04:00:00.000Z", toExclusive: "2026-09-11T04:00:00.000Z" },
        requestedAt: "2026-09-11T08:55:00Z", endedAt: "2026-09-11T08:55:01Z",
        timedOut: false, errors: [], executions: [row],
      },
      9340: {
        label: "specific-date",
        filter: { acctCode: ACCOUNT, specificDates: [20260911], time: "20260911-04:00:00" },
        actualWindow: { fromInclusive: "2026-09-11T04:00:00.000Z", toExclusive: "2026-09-11T09:00:00.000Z" },
        requestedAt: "2026-09-11T08:55:17Z", endedAt: "2026-09-11T08:55:18Z",
        timedOut: false, errors: [], executions: [],
      },
    },
    commissionsByExecId: fee ? {
      "official.complete.01": { execId: "official.complete.01", commissionAndFees: "0.1", currency: "USD", realizedPNL: "0" },
    } : {},
    finishedAt: "2026-09-11T08:55:20Z",
    disconnected: true,
    exitCode: 0,
  };
}

test("official date windows create complete receipts and empty today advances only through request start", () => {
  const requestedWindow = { fromInclusive: "2026-09-10T04:00:00Z", toExclusive: "2026-09-11T09:00:00Z" };
  const captures = capturesFromOfficialWindowEvidence({
    evidence: officialWindowEvidence(), requestedWindow, targetAccount: ACCOUNT,
  });
  assert.equal(captures.length, 2);
  assert.deepEqual(captures.map((capture) => capture.window), [
    { fromInclusive: "2026-09-10T04:00:00.000Z", toExclusive: "2026-09-11T04:00:00.000Z" },
    { fromInclusive: "2026-09-11T04:00:00.000Z", toExclusive: "2026-09-11T08:55:17.000Z" },
  ]);
  assert.deepEqual(captures.map((capture) => capture.executions.length), [1, 0]);
  assert.ok(captures.every((capture) => capture.coverageStatus === "complete"));
  let state = null;
  for (const capture of captures) state = reconcileExecutionCapture({ prior: state, capture, target: requestedWindow });
  assert.equal(state.coverage.status, "known");
  assert.deepEqual(state.coverage.gaps, [{
    fromInclusive: "2026-09-11T08:55:17.000Z",
    toExclusive: "2026-09-11T09:00:00.000Z",
    reason: "no authoritative completeness receipt",
  }]);
  const replay = captures.reduce((prior, capture) => reconcileExecutionCapture({ prior, capture, target: requestedWindow }), state);
  assert.deepEqual(replay, state);
});

test("official complete adapter rejects pending prices, missing fees, wrong accounts, and unsupported capability", () => {
  const requestedWindow = { fromInclusive: "2026-09-10T04:00:00Z", toExclusive: "2026-09-11T09:00:00Z" };
  assert.throws(() => capturesFromOfficialWindowEvidence({
    evidence: officialWindowEvidence({ pendingPriceRevision: true }), requestedWindow, targetAccount: ACCOUNT,
  }), /pending or unproven/);
  assert.throws(() => capturesFromOfficialWindowEvidence({
    evidence: officialWindowEvidence({ fee: false }), requestedWindow, targetAccount: ACCOUNT,
  }), /lacks a commission/);
  const wrong = officialWindowEvidence();
  wrong.requests[9341].filter.acctCode = "OTHER";
  assert.throws(() => capturesFromOfficialWindowEvidence({ evidence: wrong, requestedWindow, targetAccount: ACCOUNT }), /scope or completion/);
  const old = officialWindowEvidence();
  old.negotiated.serverVersion = 222;
  assert.throws(() => capturesFromOfficialWindowEvidence({ evidence: old, requestedWindow, targetAccount: ACCOUNT }), /capability/);
  const legacyFraming = officialWindowEvidence();
  legacyFraming.negotiated.parameterizedExecutionFilters = false;
  assert.throws(() => capturesFromOfficialWindowEvidence({ evidence: legacyFraming, requestedWindow, targetAccount: ACCOUNT }), /capability/);
  const wrongEndpoint = officialWindowEvidence();
  wrongEndpoint.endpoint.clientId = 92;
  assert.throws(() => capturesFromOfficialWindowEvidence({ evidence: wrongEndpoint, requestedWindow, targetAccount: ACCOUNT }), /endpoint identity/);
  const planDrift = officialWindowEvidence();
  planDrift.actualWindows[0].toExclusive = "2026-09-10T20:00:00.000Z";
  assert.throws(() => capturesFromOfficialWindowEvidence({ evidence: planDrift, requestedWindow, targetAccount: ACCOUNT }), /scope or completion/);
});

test("CLI previews and idempotently imports only a validated official complete window", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "execution-history-official-cli-test-"));
  const source = writeJson(directory, "official-window.json", officialWindowEvidence());
  const state = path.join(directory, "history.json");
  const args = [
    "--source-type", "official-window",
    "--source", source,
    "--state", state,
    "--account", ACCOUNT,
    "--from", "2026-09-10T04:00:00Z",
    "--to", "2026-09-11T09:00:00Z",
  ];
  const preview = spawnSync(process.execPath, [CLI, "preview", ...args], { encoding: "utf8" });
  assert.equal(preview.status, 0, preview.stderr);
  assert.equal(JSON.parse(preview.stdout).coverage.status, "known");
  assert.equal(fs.existsSync(state), false);

  const first = spawnSync(process.execPath, [CLI, "import", ...args], { encoding: "utf8" });
  assert.equal(first.status, 0, first.stderr);
  assert.equal(JSON.parse(first.stdout).receiptCount, 2);
  const second = spawnSync(process.execPath, [CLI, "import", ...args], { encoding: "utf8" });
  assert.equal(second.status, 0, second.stderr);
  assert.equal(JSON.parse(second.stdout).receiptCount, 2);
});

test("CLI previews without writes, imports atomically, and reruns idempotently", () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "execution-history-cli-test-"));
  const execId = "cli.trade.01";
  const source = writeJson(directory, "ledger.json", {
    account: ACCOUNT,
    coverageThrough: "2026-09-10T20:30:00Z",
    executions: [{
      contract: { conId: 1001, symbol: "MSFT", secType: "STK", currency: "USD", multiplier: 0 },
      execution: { execId, time: "20260910 12:00:00 US/Eastern", acctNumber: ACCOUNT, clientId: 51, side: "BOT", shares: 1, price: 10 },
    }],
    commissions: [{ execId, commission: 0.1, currency: "USD" }],
  });
  const state = path.join(directory, "history.json");
  const args = [
    "--source-type", "family-ledger",
    "--source", source,
    "--state", state,
    "--from", WINDOW.fromInclusive,
    "--to", WINDOW.toExclusive,
  ];
  const preview = spawnSync(process.execPath, [CLI, "preview", ...args], { encoding: "utf8" });
  assert.equal(preview.status, 0, preview.stderr);
  assert.equal(JSON.parse(preview.stdout).action, "preview");
  assert.equal(fs.existsSync(state), false);

  for (const flag of ["--__proto__", "--constructor", "--prototype", "--unknown"]) {
    const rejected = spawnSync(process.execPath, [CLI, "preview", flag, "polluted", ...args], { encoding: "utf8" });
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.stderr, new RegExp(`unsupported option ${flag}`));
  }
  const missingValue = spawnSync(process.execPath, [CLI, "preview", "--source-type"], { encoding: "utf8" });
  assert.notEqual(missingValue.status, 0);
  assert.match(missingValue.stderr, /missing value for --source-type/);
  const duplicate = spawnSync(process.execPath, [CLI, "preview", ...args, "--to", WINDOW.toExclusive], { encoding: "utf8" });
  assert.notEqual(duplicate.status, 0);
  assert.match(duplicate.stderr, /duplicate option --to/);
  assert.equal(fs.existsSync(state), false);

  const first = spawnSync(process.execPath, [CLI, "import", ...args], { encoding: "utf8" });
  assert.equal(first.status, 0, first.stderr);
  const firstResult = JSON.parse(first.stdout);
  assert.equal(firstResult.receiptCount, 1);
  assert.equal(fs.statSync(state).mode & 0o777, 0o600);

  const second = spawnSync(process.execPath, [CLI, "import", ...args], { encoding: "utf8" });
  assert.equal(second.status, 0, second.stderr);
  assert.equal(JSON.parse(second.stdout).receiptCount, 1);
});
