#!/usr/bin/env node
// Offline deploy gate. Never logs input data, exceptions, prices or money.
import path from "node:path";
import { pathToFileURL } from "node:url";
import { isDeepStrictEqual } from "node:util";
import { CURRENT_DESK_OWNERSHIP_POLICY } from "./desk-ledger.mjs";
import { effectiveExecutionRecords, validateBestAvailableHistoryState } from "./execution-reconciliation.mjs";
import { normalizeEconomicExecution } from "./execution-history.mjs";
import { createExecutorAttribution } from "./executor-attribution.mjs";
import { createExecutorAttributionMemory, readBoundedJson, MAX_MEMORY_BYTES } from "./executor-attribution-memory.mjs";
import { calculateFamily, VIRTUAL_SHARED_ACCOUNT_OWNERSHIP } from "./family-ledger.mjs";

const POLICY = CURRENT_DESK_OWNERSHIP_POLICY;
const DESKS = ["j", "joe", "joel"];
// Independent transcription of the reviewed README table; deliberately no prices.
const EXPECTED = [
  { execId: "0000dc8f.6bb0d852.01.01", desk: "j", conId: 4815747, symbol: "NVDA", clientId: 119, side: "SELL", shares: 4, time: "2026-09-23T13:30:04.000Z" },
  { execId: "0000dc8f.6bd3bc59.01.01", desk: "j", conId: 4815747, symbol: "NVDA", clientId: 229, side: "BUY", shares: 1, time: "2026-10-06T13:40:47.000Z" },
  { execId: "00025b45.6ace1f95.01.01", desk: "joe", conId: 4815747, symbol: "NVDA", clientId: 28, side: "BUY", shares: 4, time: "2026-10-12T19:50:12.000Z" },
];

function owner(row, policy, attribution) {
  const override = policy.fillAttributionOverrides.find(rule => rule.execId === row.execution.execId);
  if (override) return override.desk;
  if (policy.executorClientIds.includes(row.execution.clientId)) return attribution.attribute(row.execution).desk;
  const rules = policy.assignments.filter(rule => rule.clientId === row.execution.clientId &&
    Date.parse(rule.fromInclusive) <= Date.parse(row.execution.time) &&
    (rule.toExclusive === null || Date.parse(row.execution.time) < Date.parse(rule.toExclusive)));
  if (rules.length !== 1) throw new Error("replay ownership unavailable");
  return rules[0].desk;
}

// Run the production FIFO on one instrument at a time. Neutral marks/FX are
// internal comparison inputs, never a claim about current account valuation.
// Identical owned fills and fees also prove identical opening FIFO lots, which
// calculateFamily intentionally does not expose in its public position rows.
export function replayDeskHistory(history, attribution, policy = POLICY) {
  const byContract = new Map();
  for (const raw of effectiveExecutionRecords(history)) {
    const row = normalizeEconomicExecution(raw);
    if (policy.excludedSymbols.includes(row.contract.symbol)) continue;
    if (raw.execution.pendingPriceRevision === true || row.execution.time < new Date(policy.periodStart).toISOString()) {
      throw new Error("replay history unavailable");
    }
    const desk = owner(row, policy, attribution);
    // A proven, flat OPS-test group is the runtime's explicit exclusion.
    if (desk === null) continue;
    if (!DESKS.includes(desk)) throw new Error("replay ownership unavailable");
    const key = `conId:${row.contract.conId}`;
    if (!byContract.has(key)) byContract.set(key, []);
    byContract.get(key).push({ row, desk });
  }
  const report = Object.fromEntries(DESKS.map(desk => [desk, {}]));
  for (const [key, group] of [...byContract].sort(([a], [b]) => a.localeCompare(b))) {
    group.sort((a, b) => a.row.execution.time.localeCompare(b.row.execution.time) ||
      a.row.execution.execId.localeCompare(b.row.execution.execId));
    const contract = group[0].row.contract;
    if (group.some(({ row }) => !isDeepStrictEqual(row.contract, contract))) throw new Error("replay contract unavailable");
    const ids = new Set(group.map(({ row }) => row.execution.execId));
    const fees = history.commissions.filter(fee => ids.has(fee.execId));
    const currencies = new Set(["EUR", contract.currency, ...fees.map(fee => fee.currency)]);
    const quantity = group.reduce((sum, { row }) => sum + (row.execution.side === "BUY" ? 1 : -1) * row.execution.shares, 0);
    const portfolio = [{ contract, pos: quantity, marketPrice: 1, markObservedAt: history.updatedAt }];
    const positions = [{ contract, pos: quantity, account: history.account }];
    for (const desk of DESKS) {
      const owned = group.filter(fill => fill.desk === desk).map(fill => fill.row);
      const ownedIds = new Set(owned.map(row => row.execution.execId));
      const result = calculateFamily({
        executions: group.map(({ row, desk: owner }) => ({ contract: row.contract,
          execution: { ...row.execution, clientId: owner === desk ? 1 : 2 } })),
        commissions: fees, account: history.account, familyClientIds: [1],
        excludedSymbols: policy.excludedSymbols, periodStart: policy.periodStart,
        portfolio, positions, observedAt: history.updatedAt,
        fx: { baseCurrency: "EUR", observedAt: history.updatedAt,
          rates: Object.fromEntries([...currencies].map(currency => [currency, 1])) },
        ownershipMode: VIRTUAL_SHARED_ACCOUNT_OWNERSHIP,
      });
      if (!result.ok) throw new Error("replay FIFO unavailable");
      report[desk][key] = { symbol: contract.symbol,
        quantity: result.positions.reduce((sum, position) => sum + position.quantity, 0),
        lotInputs: { executions: owned, commissions: fees.filter(fee => ownedIds.has(fee.execId)) },
        realizedPnl: result.realizedPnl };
    }
  }
  return report;
}

// Separate evaluator makes every economic acceptance check testable with a
// deliberately wrong replay result, including non-NVDA FIFO/realised changes.
export function checkReplayResults(before, after) {
  const checks = [];
  const add = (name, pass) => checks.push({ name, pass });
  add("J NVDA before=+8", before.j["conId:4815747"]?.quantity === 8);
  add("J NVDA after=0", after.j["conId:4815747"]?.quantity === 0);
  add("Joe NVDA after=0", after.joe["conId:4815747"]?.quantity === 0);
  let lots = true, realized = true, count = 0;
  for (const desk of DESKS) {
    for (const key of new Set([...Object.keys(before[desk]), ...Object.keys(after[desk])])) {
      const left = before[desk][key], right = after[desk][key];
      if (key === "conId:4815747" && left?.symbol === "NVDA" && right?.symbol === "NVDA") continue;
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

export function ops557ReplayGate({ history, executorLedger, memoryState }) {
  const checks = [];
  try {
    validateBestAvailableHistoryState(history);
    if (executorLedger?.schema !== "barta.paper-desk-executor-state.v1" || executorLedger.account !== history.account ||
        !executorLedger.intents || typeof executorLedger.intents !== "object" || Array.isArray(executorLedger.intents) ||
        !Array.isArray(executorLedger.executions)) throw new Error("replay inputs unavailable");
    if (!memoryState) throw new Error("replay memory unavailable");
    const memory = createExecutorAttributionMemory({ account: history.account, state: memoryState });
    const rows = effectiveExecutionRecords(history);
    const attribution = createExecutorAttribution({ ledger: executorLedger, account: history.account,
      memory, executionRows: rows, onEvent() {} });
    checks.push({ name: "inputs", pass: true });
    checks.push({ name: "override policy table", pass: POLICY.fillAttributionOverrides.length === EXPECTED.length &&
      EXPECTED.every(expected => POLICY.fillAttributionOverrides.some(rule => rule.execId === expected.execId && rule.desk === expected.desk)) });
    EXPECTED.forEach((expected, index) => {
      const matches = rows.filter(row => row.execution.execId === expected.execId);
      checks.push({ name: `override[${index}] matches count=${matches.length}`, pass: matches.length === 1 });
      const match = matches[0] && normalizeEconomicExecution(matches[0]);
      const metadata = match && { execId: match.execution.execId, desk: expected.desk,
        conId: match.contract.conId, symbol: match.contract.symbol, clientId: match.execution.clientId,
        side: match.execution.side, shares: match.execution.shares, time: match.execution.time };
      checks.push({ name: `override[${index}] README fill`, pass: matches.length === 1 && isDeepStrictEqual(metadata, expected) });
    });
    const before = replayDeskHistory(history, attribution, { ...POLICY, fillAttributionOverrides: [] });
    const after = replayDeskHistory(history, attribution);
    checks.push({ name: "FIFO replay", pass: true }, ...checkReplayResults(before, after));
  } catch {
    checks.push({ name: "inputs or FIFO replay", pass: false });
  }
  return { ok: checks.every(check => check.pass), checks };
}

export function runReplayGate(files, write = line => console.log(line)) {
  let result;
  try {
    if (files.length !== 3) throw new Error("three input files required");
    result = ops557ReplayGate({ history: readBoundedJson(files[0], 64 * 1024 * 1024),
      executorLedger: readBoundedJson(files[1], 16 * 1024 * 1024), memoryState: readBoundedJson(files[2], MAX_MEMORY_BYTES) });
  } catch { result = { ok: false, checks: [{ name: "three input files", pass: false }] }; }
  for (const { name, pass } of result.checks) write(`${pass ? "PASS" : "FAIL"} ${name}`);
  write(`${result.ok ? "PASS" : "FAIL"} OPS-557 deploy gate`);
  return result.ok ? 0 : 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  process.exitCode = runReplayGate(process.argv.slice(2));
}
