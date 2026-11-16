#!/usr/bin/env node
// Offline JOED-196 deploy gate. Never logs input data, exceptions, quantities,
// prices or money: fixed check names, contract counts and PASS/FAIL only.
import { realpathSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { isDeepStrictEqual } from "node:util";
import { CURRENT_DESK_OWNERSHIP_POLICY } from "./desk-ledger.mjs";
import { effectiveExecutionRecords, validateBestAvailableHistoryState } from "./execution-reconciliation.mjs";
import { assertFillAttributionOverrides, normalizeEconomicExecution } from "./execution-history.mjs";
import { createExecutorAttribution, validatedExecutionTime } from "./executor-attribution.mjs";
import { createExecutorAttributionMemory } from "./executor-attribution-memory.mjs";
import { mergeExecutionRecords, reconcileDeskOpenLots } from "./family-ledger.mjs";
import { MAX_COPY_AGE_MS, ops557ReplayGate, replayDeskHistory, runReplayGate } from "./replay-ops557.mjs";

const POLICY = CURRENT_DESK_OWNERSHIP_POLICY;
const DESKS = ["j", "joe", "joel"];
const BASIS = "JOED-196 cross-booked AVGO/AMD close, 2026-11-17";
const DATE = "2026-11-17";
const QUANTITY_EPSILON = 1e-9;
// Independent transcription of the reviewed README table. Deliberately no
// quantities or prices: those are only compared between the copied sources.
const EXPECTED = [
  { execId: "0000e0d5.6ab27b67.01.01", desk: "j", conId: 313130367, symbol: "AVGO", clientId: 79, side: "BUY", time: "2026-09-22T16:08:51.000Z" },
  { execId: "0000dc8f.6bb12ac9.01.01", desk: "j", conId: 313130367, symbol: "AVGO", clientId: 91, side: "SELL", time: "2026-09-23T13:43:58.000Z" },
  { execId: "0000dc8f.6bb12336.01.01", desk: "joe", conId: 4391, symbol: "AMD", clientId: 89, side: "SELL", time: "2026-09-23T13:42:17.000Z" },
  { execId: "0000e0d5.6abb75ef.01.01", desk: "joe", conId: 4391, symbol: "AMD", clientId: 27, side: "BUY", time: "2026-09-29T13:30:25.000Z" },
];
const CONTRACTS = [{ key: "conId:313130367", symbol: "AVGO" }, { key: "conId:4391", symbol: "AMD" }];
// The table as deployed before this change: every row except the JOED-196 ones.
const BEFORE_POLICY = { ...POLICY, fillAttributionOverrides: POLICY.fillAttributionOverrides.filter(rule => rule.basis !== BASIS) };

function policyTable() {
  const rows = POLICY.fillAttributionOverrides.filter(rule => rule.basis === BASIS);
  return rows.length === EXPECTED.length &&
    EXPECTED.every(expected => rows.some(rule => rule.execId === expected.execId && rule.desk === expected.desk && rule.date === DATE)) &&
    // Both fills of a pair belong to one desk, whichever desk is decided.
    CONTRACTS.every(({ symbol }) => new Set(EXPECTED.filter(expected => expected.symbol === symbol).map(expected => expected.desk)).size === 1);
}

// Separate evaluator: every acceptance check is testable with a deliberately
// wrong replay result. Quantities are compared, never named in a check.
export function checkReplayResults(before, after) {
  const checks = [];
  const add = (name, pass) => checks.push({ name, pass });
  const flat = quantity => Math.abs(quantity) <= QUANTITY_EPSILON;
  for (const { key, symbol } of CONTRACTS) {
    const named = report => DESKS.every(desk => report[desk][key]?.symbol === symbol);
    const [j, joe, joel] = DESKS.map(desk => before[desk][key]?.quantity);
    add(`${symbol} before J long and Joe equal short`, named(before) && j > QUANTITY_EPSILON && flat(j + joe) && flat(joel));
    add(`${symbol} after flat on every desk`, named(after) && DESKS.every(desk => flat(after[desk][key].quantity)));
  }
  let lots = true, realized = true, count = 0;
  for (const desk of DESKS) {
    for (const key of new Set([...Object.keys(before[desk]), ...Object.keys(after[desk])])) {
      const left = before[desk][key], right = after[desk][key];
      if (CONTRACTS.some(contract => contract.key === key && left?.symbol === contract.symbol && right?.symbol === contract.symbol)) continue;
      count++;
      lots &&= !!left && !!right && left.symbol === right.symbol && left.quantity === right.quantity &&
        isDeepStrictEqual(left.lotInputs, right.lotInputs);
      realized &&= !!left && !!right && left.realizedPnl === right.realizedPnl;
    }
  }
  add(`other-symbol lots unchanged count=${count}`, lots);
  add(`other-symbol realised unchanged count=${count}`, realized);
  return checks;
}

// The production guard on a replayed state. The four copies hold no broker
// positions, so the account position is the replayed net of every desk's
// fills, which production reconciles to the broker separately. That leaves
// exactly the flat-contract rule to prove here.
export function replayFlatContractGuard(report, account, policy = POLICY) {
  const lots = [];
  const held = new Map();
  for (const desk of DESKS) {
    for (const [key, entry] of Object.entries(report[desk])) {
      for (const row of entry.lotInputs.executions) {
        lots.push({ desk, contract: row.contract, execution: row.execution });
        const position = held.get(key) || { contract: row.contract, pos: 0, account };
        position.pos += (row.execution.side === "BUY" ? 1 : -1) * row.execution.shares;
        held.set(key, position);
      }
    }
  }
  return reconcileDeskOpenLots({ lots, positions: [...held.values()], account, excludedSymbols: policy.excludedSymbols });
}

export function joed196ReplayGate({ history, executorLedger, memoryState, familyLedger, deployDate }) {
  const checks = [];
  try {
    validateBestAvailableHistoryState(history);
    if (familyLedger?.schema !== "inspr.joe.family-execution-ledger.v1" || familyLedger.version !== 1 ||
        familyLedger.account !== history.account || familyLedger.periodStart !== POLICY.periodStart ||
        !Array.isArray(familyLedger.executions) || !Array.isArray(familyLedger.commissions)) {
      throw new Error("replay family ledger unavailable");
    }
    // Same source clocks and bound as the OPS-557 gate: coverageThrough advances
    // with the family execution query; a copy's mtime proves nothing.
    const deployAt = typeof deployDate === "string" && /^\d{4}-\d{2}-\d{2}T/.test(deployDate)
      ? validatedExecutionTime(deployDate) : null;
    if (!deployAt) throw new Error("replay deploy date unavailable");
    for (const [name, value] of [["history freshness", history.updatedAt], ["family ledger freshness", familyLedger.coverageThrough]]) {
      const at = typeof value === "string" && /^\d{4}-\d{2}-\d{2}T/.test(value) ? validatedExecutionTime(value) : null;
      const age = at ? Date.parse(deployAt) - Date.parse(at) : NaN;
      checks.push({ name, pass: Number.isFinite(age) && age >= 0 && age <= MAX_COPY_AGE_MS });
    }
    if (executorLedger?.schema !== "barta.paper-desk-executor-state.v1" || executorLedger.account !== history.account ||
        !executorLedger.intents || typeof executorLedger.intents !== "object" || Array.isArray(executorLedger.intents) ||
        !Array.isArray(executorLedger.executions)) throw new Error("replay inputs unavailable");
    if (!memoryState) throw new Error("replay memory unavailable");
    const memory = createExecutorAttributionMemory({ account: history.account, state: memoryState });
    const attribution = createExecutorAttribution({ ledger: executorLedger, account: history.account,
      memory, executionRows: familyLedger.executions, onEvent() {} });
    checks.push({ name: "inputs", pass: true });
    checks.push({ name: "override policy table", pass: policyTable() });
    const historyQuantity = new Map();
    for (const [prefix, sourceRows] of [["", () => effectiveExecutionRecords(history)], ["ledger raw ", () => familyLedger.executions],
      ["ledger merged ", () => mergeExecutionRecords([], familyLedger.executions).map(normalizeEconomicExecution)
        .filter(row => !POLICY.excludedSymbols.includes(row.contract.symbol))]]) {
      const source = sourceRows();
      EXPECTED.forEach((expected, index) => {
        const matches = source.filter(row => row.execution.execId === expected.execId);
        checks.push({ name: `${prefix}override[${index}] matches count=${matches.length}`, pass: matches.length === 1 });
        const match = matches[0] && normalizeEconomicExecution(matches[0]);
        const metadata = match && { execId: match.execution.execId, desk: expected.desk,
          conId: match.contract.conId, symbol: match.contract.symbol, clientId: match.execution.clientId,
          side: match.execution.side, time: match.execution.time };
        checks.push({ name: `${prefix}override[${index}] README fill`, pass: matches.length === 1 && isDeepStrictEqual(metadata, expected) });
        // The reviewed table carries no quantity. History's fill is the reference.
        if (!prefix) historyQuantity.set(expected.execId, matches.length === 1 ? match.execution.shares : undefined);
        else checks.push({ name: `${prefix}override[${index}] quantity matches history`,
          pass: matches.length === 1 && match.execution.shares === historyQuantity.get(expected.execId) });
      });
      // The production raw/merged cardinality guards over the whole table,
      // OPS-557 rows included, with canonicalLedgerSource's KEEP filtering.
      assertFillAttributionOverrides(source, POLICY.fillAttributionOverrides);
    }
    const before = replayDeskHistory(history, attribution, BEFORE_POLICY);
    const after = replayDeskHistory(history, attribution, POLICY);
    checks.push({ name: "FIFO replay", pass: true }, ...checkReplayResults(before, after));
    const caught = replayFlatContractGuard(before, history.account);
    checks.push({ name: `flat-contract guard rejects before state count=${caught.crossBooked}`,
      pass: !caught.ok && caught.crossBooked === CONTRACTS.length && caught.accountMismatch === 0 });
    checks.push({ name: "flat-contract guard passes after state", pass: replayFlatContractGuard(after, history.account).ok });
    // Codex gate r1 (P2): the older OPS-557 rows must keep their full validation on
    // the same copies (fill metadata, quantities, NVDA expectations), not only cardinality.
    checks.push({ name: "OPS-557 deploy gate on the same copies",
      pass: ops557ReplayGate({ history, executorLedger, memoryState, familyLedger, deployDate }).ok });
  } catch {
    checks.push({ name: "inputs or FIFO replay", pass: false });
  }
  return { ok: checks.every(check => check.pass), checks };
}

export function runJoed196ReplayGate(args, write) {
  return runReplayGate(args, write, joed196ReplayGate, "JOED-196");
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  process.exitCode = runJoed196ReplayGate(process.argv.slice(2));
}
