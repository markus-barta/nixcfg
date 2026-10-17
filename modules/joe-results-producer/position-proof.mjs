import { decimalUnits, unitsDecimal } from './contracts/decimal.mjs';
import { validInstant } from './contracts/schema-validator.mjs';
import { hash } from './journal.mjs';
import { DESKS } from './fifo.mjs';
import { viennaDate } from './results-validation.mjs';

const instrument = c => hash([c.conId, c.symbol, c.currency]);
export function brokerQuantity(value) {
  if (typeof value === 'number' && !Number.isSafeInteger(value)) throw new TypeError('inexact_position');
  return decimalUnits(typeof value === 'number' ? String(value) : value);
}

// The executor's complete positionEnd snapshot is the evidence, never a poll's
// timestamp or the absence of a mismatch diagnostic. Persist no broker IDs.
export function capturePositionProof(state, config, keepSymbols, { account, attribute }, knownInstruments, at) {
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
  for (const row of snapshot.positions) {
    if (keepSymbols.includes(row.symbol)) continue;
    if (!Number.isSafeInteger(row.conId) || row.conId <= 0 || typeof row.symbol !== 'string'
      || !/^[A-Z0-9][A-Z0-9._-]{0,15}$/.test(row.symbol) || !/^[A-Z]{3}$/.test(row.currency || '')) return null;
    const key = instrument(row), quantity = row.position ?? row.pos;
    // The IB adapter currently supplies Numbers. Only exact safe integers may
    // cross that boundary; decimal strings retain all eight fractional digits.
    try {
      if (broker.has(key)) return null;
      broker.set(key, brokerQuantity(quantity));
    } catch { return null; }
  }
  return { at: snapshot.observedAt, positions: [...instruments].filter(key => !foreign.has(key)).sort()
    .map(key => ({ instrument: key, quantity: unitsDecimal(broker.get(key) ?? 0n) })) };
}

// Evaluate every FIFO close, including multiple desks/contracts sharing a
// symbol. A proof after the close cannot retroactively prove a flat baseline.
export function earlierGapDays(fills, closes, intervals, proofs, start) {
  const partial = new Set(), books = new Map(), firstFill = new Map();
  for (const fill of fills) {
    if (!DESKS.includes(fill.desk) || fill.scope !== 'stage0') continue;
    const rows = books.get(fill.instrument) || [];
    rows.push(fill); books.set(fill.instrument, rows);
    firstFill.set(fill.instrument, Math.min(firstFill.get(fill.instrument) ?? Infinity, Date.parse(fill.at)));
  }
  for (const close of closes) {
    const epoch = Date.parse(close.at), interval = intervals.find(([a, b]) => a <= epoch && epoch < b);
    if (!interval) continue; // the enclosing day already fails interval coverage
    const [begin] = interval, rows = books.get(close.instrument) || [];
    if (begin <= Date.parse(start) && (firstFill.get(close.instrument) ?? Infinity) >= begin) continue;
    const eligible = proofs.filter(proof => validInstant(proof?.at) && Array.isArray(proof.positions)
      && Date.parse(proof.at) >= begin && Date.parse(proof.at) < epoch
      && proof.positions.some(row => row.instrument === close.instrument));
    const latest = eligible.reduce((latest, proof) => Math.max(latest, Date.parse(proof.at)), -Infinity);
    const candidates = eligible.filter(proof => Date.parse(proof.at) === latest);
    // Contradictory receipts at the same instant are ambiguous. A later
    // mismatch must not be hidden by an earlier matching receipt either.
    const trusted = candidates.length > 0 && candidates.every(proof => {
      if (!validInstant(proof?.at) || !Array.isArray(proof.positions)) return false;
      const observed = Date.parse(proof.at);
      if (observed < begin || observed >= epoch) return false;
      const positions = proof.positions.filter(row => row.instrument === close.instrument);
      if (positions.length !== 1) return false;
      // Equal-time executions have ambiguous ordering relative to positionEnd.
      if (rows.some(row => Date.parse(row.at) === observed)) return false;
      const quantities = new Map();
      let ownedAtStart = 0n, capturedSinceStart = 0n;
      for (const fill of rows) {
        if (Date.parse(fill.at) >= observed) continue;
        const quantity = decimalUnits(fill.quantity) * (fill.side === 'BUY' ? 1n : -1n);
        quantities.set(fill.desk, (quantities.get(fill.desk) || 0n) + quantity);
        if (Date.parse(fill.at) < begin) ownedAtStart += quantity;
        else capturedSinceStart += quantity;
      }
      let broker;
      try { broker = decimalUnits(positions[0].quantity); } catch { return false; }
      const owned = [...quantities.values()];
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
    if (!trusted) partial.add(viennaDate(close.at));
  }
  return partial;
}
