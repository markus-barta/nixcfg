import { sdkDecimal } from './sdk-decimal.mjs';
import { decimalUnits, unitsDecimal } from './contracts/decimal.mjs';
import { validInstant } from './contracts/schema-validator.mjs';
import { hash } from './journal.mjs';
import { DESKS } from './fifo.mjs';
import { viennaDate } from './results-validation.mjs';

const instrument = c => hash([c.conId, c.symbol, c.currency]);
export function brokerQuantity(value) {
  const result = sdkDecimal(value);
  if (result.refused || result.unset) throw new TypeError('inexact_position');
  return decimalUnits(result.amount);
}

// The executor's complete positionEnd snapshot is the evidence, never a poll's
// timestamp or the absence of a mismatch diagnostic. Persist no broker IDs.
export function capturePositionProof(state, config, keepSymbols, { account, attribute, onIssue = () => {} }, knownInstruments, at) {
  const snapshot = state.ownershipSnapshot;
  if (state.ownershipComplete !== true || snapshot?.ownershipComplete !== true || snapshot.account !== account
    || !validInstant(snapshot.observedAt) || Date.parse(snapshot.observedAt) > Date.parse(at) || !Array.isArray(snapshot.positions)) return null;
  const instruments = new Set(knownInstruments), foreign = new Set(), broker = new Map();
  for (const row of state.executions || []) {
    const c = row.contract, e = row.execution;
    if (!c || !e || e.acctNumber !== account || keepSymbols.includes(c.symbol)) continue;
    const key = instrument(c), ownership = attribute(row, config);
    instruments.add(key);
    if (!DESKS.includes(ownership.desk) || ownership.needsAttribution || ownership.method === 'external'
      || (ownership.method !== 'admin' && Number(e.clientId) !== config.executorClientId)) foreign.add(key);
  }
  const sources = new Map();
  let unusable = false;
  for (const row of snapshot.positions) {
    if (keepSymbols.includes(row.symbol)) continue;
    if (!Number.isSafeInteger(row.conId) || row.conId <= 0 || typeof row.symbol !== 'string'
      || !/^[A-Z0-9][A-Z0-9._-]{0,15}$/.test(row.symbol) || !/^[A-Z]{3}$/.test(row.currency || '')) return null;
    const key = instrument(row), quantity = row.position ?? row.pos;
    instruments.add(key);
    // The same SDK boundary policy applies to broker quantity evidence.
    try {
      if (broker.has(key)) return null;
      const converted = sdkDecimal(quantity);
      if (converted.refused || converted.unset) { onIssue(key, converted.refused === true); unusable = true; continue; }
      if (converted.src) sources.set(key, converted.src);
      broker.set(key, brokerQuantity(quantity));
    } catch { return null; }
  }
  if (unusable) return null;
  return { at: snapshot.observedAt, foreign: [...foreign].sort(), positions: [...instruments].sort()
    .map(key => ({ instrument: key, quantity: unitsDecimal(broker.get(key) ?? 0n), ...(sources.has(key) ? { src: sources.get(key) } : {}) })) };
}

// First entry at or after epoch. Equal-time fills/proofs stay strictly outside
// a query for evidence before an execution.
function lowerBound(rows, epoch) {
  let low = 0, high = rows.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (rows[middle].at < epoch) low = middle + 1;
    else high = middle;
  }
  return low;
}

function insert(rows, row) {
  if (!rows.length || rows.at(-1).at <= row.at) rows.push(row);
  else rows.splice(lowerBound(rows, row.at), 0, row);
}

// Parsed once as each cut is applied/replayed. Explicit rows have an instrument
// index; complete receipts also prove omissions flat unless marked foreign.
// Old receipts without a foreign set prove only their explicit positions.
export class PositionProofIndex {
  constructor() { this.instruments = new Map(); this.complete = []; }
  add(proof) {
    if (!validInstant(proof?.at) || !Array.isArray(proof.positions)) return;
    const receipt = { at: Date.parse(proof.at), positions: new Map(), foreign: new Set(proof.foreign || []) };
    for (const row of proof.positions) {
      let quantity = null;
      try { quantity = decimalUnits(row.quantity); } catch { /* unusable evidence */ }
      receipt.positions.set(row.instrument, receipt.positions.has(row.instrument) ? null : quantity);
    }
    for (const key of new Set([...receipt.positions.keys(), ...receipt.foreign])) {
      const rows = this.instruments.get(key) || [];
      insert(rows, receipt); this.instruments.set(key, rows);
    }
    if (Array.isArray(proof.foreign)) insert(this.complete, receipt);
  }
  latest(instrument, begin, before) {
    const candidates = [];
    for (const rows of [this.instruments.get(instrument) || [], this.complete]) {
      let i = lowerBound(rows, before) - 1;
      if (i < 0 || rows[i].at < begin) continue;
      const latest = rows[i].at;
      while (i >= 0 && rows[i].at === latest) candidates.push(rows[i--]);
    }
    const latest = Math.max(...candidates.map(row => row.at));
    return [...new Set(candidates.filter(row => row.at === latest))];
  }
}

// Evaluate every captured Stage-0 fill, even an apparent opening: an omitted
// entry can make its captured stop look like a new short position.
export function earlierGapDays(fills, executions, intervals, proofs, start) {
  const partial = new Set(), books = new Map(), firstFill = new Map();
  for (const fill of fills) {
    if (!DESKS.includes(fill.desk) || fill.scope !== 'stage0') continue;
    const rows = books.get(fill.instrument) || [];
    const at = Date.parse(fill.at), quantity = decimalUnits(fill.quantity) * (fill.side === 'BUY' ? 1n : -1n);
    rows.push({ at, desk: DESKS.indexOf(fill.desk), quantity }); books.set(fill.instrument, rows);
    firstFill.set(fill.instrument, Math.min(firstFill.get(fill.instrument) ?? Infinity, at));
  }
  // Prefix quantities avoid rescanning all fills for each proof lookup.
  for (const rows of books.values()) {
    rows.sort((a, b) => a.at - b.at);
    let quantities = DESKS.map(() => 0n), total = 0n;
    for (const row of rows) {
      quantities = [...quantities]; quantities[row.desk] += row.quantity;
      total += row.quantity;
      row.quantities = quantities; row.total = total;
    }
  }
  const origin = Date.parse(start);
  for (const execution of executions) {
    const epoch = Date.parse(execution.at), last = intervals.at(-1);
    const interval = intervals.find(([a, b]) => a <= epoch && epoch < b)
      || (last && epoch >= last[1] ? last : null);
    // Trailing fills use the last interval's baseline under the open day's
    // "so far" rule. Fills in a real hole already fail day coverage.
    if (!interval) continue;
    const [begin] = interval, rows = books.get(execution.instrument) || [];
    if (begin <= origin && (firstFill.get(execution.instrument) ?? Infinity) >= begin) continue;
    const candidates = proofs.latest(execution.instrument, begin, epoch);
    // Contradictory receipts at the same instant are ambiguous. A later
    // mismatch must not be hidden by an earlier matching receipt either.
    const trusted = candidates.length > 0 && candidates.every(proof => {
      const observed = proof.at;
      if (proof.foreign.has(execution.instrument)) return false;
      const broker = proof.positions.has(execution.instrument) ? proof.positions.get(execution.instrument) : 0n;
      if (broker === null) return false;
      // Equal-time executions have ambiguous ordering relative to positionEnd.
      const cursor = lowerBound(rows, observed);
      if (rows[cursor]?.at === observed) return false;
      const prior = rows[cursor - 1];
      const owned = prior?.quantities || [], ownedAtStart = rows[lowerBound(rows, begin) - 1]?.total ?? 0n;
      const capturedSinceStart = (prior?.total ?? 0n) - ownedAtStart;
      // (a) Broker-flat AND every desk flat after the last gap. Account netting
      // of opposing desk lots is not a proven flat instrument.
      if (broker === 0n && owned.every(quantity => quantity === 0n)) return true;
      // (b) Roll both sides back to the interval start using the same captured
      // deltas in [begin, observed). Continuous proof makes this equivalent to
      // comparing quantities at begin; lot prices remain a documented risk.
      // Opposing desks are ambiguous even when the account net happens to fit.
      const brokerAtStart = broker - capturedSinceStart;
      return ownedAtStart === brokerAtStart
        && !(owned.some(quantity => quantity > 0n) && owned.some(quantity => quantity < 0n));
    });
    if (!trusted) partial.add(viennaDate(execution.at));
  }
  return partial;
}
