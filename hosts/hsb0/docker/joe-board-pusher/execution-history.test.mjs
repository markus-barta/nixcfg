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

  const first = spawnSync(process.execPath, [CLI, "import", ...args], { encoding: "utf8" });
  assert.equal(first.status, 0, first.stderr);
  const firstResult = JSON.parse(first.stdout);
  assert.equal(firstResult.receiptCount, 1);
  assert.equal(fs.statSync(state).mode & 0o777, 0o600);

  const second = spawnSync(process.execPath, [CLI, "import", ...args], { encoding: "utf8" });
  assert.equal(second.status, 0, second.stderr);
  assert.equal(JSON.parse(second.stdout).receiptCount, 1);
});
