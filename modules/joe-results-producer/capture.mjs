import { decimalUnits } from './contracts/decimal.mjs';
import { validInstant } from './contracts/schema-validator.mjs';
import { DESKS, unavailable } from './fifo.mjs';
import { hash, openJournal } from './journal.mjs';
import { historyIntervals } from './results-validation.mjs';

// Runs inside the executor, BEFORE retention/compaction; producer itself only
// reads this file. No account, broker/order ID, orderRef or receipt is written.
export function createCapture(filename, config, { account, attribute, executionTime, now = () => new Date().toISOString(), keepSymbols = ['SXR8', 'TSLA'] } = {}) {
  if (!account || typeof attribute !== 'function' || typeof executionTime !== 'function') throw unavailable();
  let journal, known, closeFx, lastAuthority, ordinals, nextOrdinal = 0;
  function initialize() {
    if (journal) return;
    journal = openJournal(filename);
    if (!journal.entries.length) journal.append({ type: 'start', at: now() });
    known = new Map(); closeFx = new Map(); ordinals = new Map();
    for (const event of journal.entries) for (const fill of event.fills || []) {
      known.set(fill.key, hash(fill));
      if (fill.closeFx) closeFx.set(fill.key, fill.closeFx);
      if (fill.ordinal) { ordinals.set(fill.key, fill.ordinal); nextOrdinal = Math.max(nextOrdinal, fill.ordinal); }
    }
    const previous = journal.entries.at(-1);
    if (previous?.type === 'cut') lastAuthority = hash([previous.authoritative, previous.disagreement, previous.evidence, previous.historyCoverage ?? null]);
  }
  function capture(state) {
    initialize();
    const at = now();
    const changed = [];
    const commissions = new Map((state.commissions || []).map(row => [row.execId, row]));
    // Preserve broker ordering for same-instant fills WITHOUT retaining the
    // broker identifier as the sort key. Corrections retain the original rank.
    const ordered = [...(state.executions || [])].sort((a, b) => executionTime(a.execution?.time) - executionTime(b.execution?.time) || String(a.execution?.execId).localeCompare(String(b.execution?.execId)));
    for (const row of ordered) {
      const e = row.execution, c = row.contract;
      if (!e?.execId || !c) throw unavailable();
      // Corrections replace one logical fill in the accumulated projection.
      const key = hash(String(e.execId).replace(/\.\d+$/, '.'));
      const exclude = () => {
        const tombstone = { key, desk: null, scope: 'excluded' };
        if (known.has(key) && known.get(key) !== hash(tombstone)) changed.push(tombstone);
      };
      const ownership = attribute(row, config);
      if (e.acctNumber !== account || !DESKS.includes(ownership.desk) || ownership.needsAttribution || ownership.method === 'external') { exclude(); continue; }
      if (keepSymbols.includes(c.symbol)) { exclude(); continue; }
      const epoch = executionTime(e.time);
      if (!Number.isFinite(epoch)) throw unavailable();
      // Legacy scope and retired client ownership are not Stage-0 results.
      if (epoch < Date.parse(config.foreignAlertSince) || (ownership.method !== 'admin' && Number(e.clientId) !== config.executorClientId)) { exclude(); continue; }
      let fx = closeFx.get(key) || null;
      const observed = state.resultsFx?.[c.currency];
      if (!fx && c.currency === 'EUR') fx = { base: 'EUR', quote: 'EUR', rate: '1', source: 'identity', observedAt: new Date(epoch).toISOString() };
      // Never stamp today's FX onto a historical fill. Close evidence must
      // actually have been observed within the capture window at execution.
      if (!fx && observed && validInstant(observed.observedAt) && Math.abs(Date.parse(observed.observedAt) - epoch) <= 60_000) fx = structuredClone(observed);
      if (fx) closeFx.set(key, fx);
      const commission = commissions.get(e.execId);
      if (!ordinals.has(key)) ordinals.set(key, ++nextOrdinal);
      const fill = {
        key, ordinal: ordinals.get(key), desk: ownership.desk, scope: 'stage0', instrument: hash([c.conId, c.symbol, c.currency]),
        symbol: c.symbol, currency: c.currency, side: { BOT: 'BUY', BUY: 'BUY', SLD: 'SELL', SELL: 'SELL' }[e.side],
        at: new Date(epoch).toISOString(), quantity: e.shares, price: e.price,
        commission: commission ? { amount: commission.commission, currency: commission.currency } : null,
        closeFx: fx,
      };
      decimalUnits(fill.quantity); decimalUnits(fill.price);
      if (fill.commission) decimalUnits(fill.commission.amount);
      if (known.get(key) !== hash(fill)) changed.push(fill);
    }
    const authority = state.ownershipComplete === true;
    const evidence = reconciliationEvidence(state, config, keepSymbols, { account, attribute, executionTime });
    // One line is one committed cut: a concurrent reader cannot combine a
    // half-imported fill batch with the preceding cut's authority statement.
    const coverage = state.resultsHistoryCoverage;
    // Copy only value-free coverage metadata, never the history payload.
    const historyCoverage = authority && historyIntervals(coverage, at).length ? {
      status: coverage.status,
      target: { fromInclusive: coverage.target.fromInclusive, toExclusive: coverage.target.toExclusive },
      gaps: coverage.gaps.map(({ fromInclusive, toExclusive }) => ({ fromInclusive, toExclusive })),
    } : null;
    const event = { type: 'cut', at, fills: changed, authoritative: authority, disagreement: evidence.length > 0, evidence, historyCoverage };
    const authorityHash = hash([event.authoritative, event.disagreement, event.evidence, historyCoverage]);
    if (!changed.length && authorityHash === lastAuthority) return;
    journal.append(event);
    for (const fill of changed) known.set(fill.key, hash(fill));
    lastAuthority = authorityHash;
  }
  capture.close = () => journal?.close();
  return capture;
}

// A broker reachability change is deliberately absent from this predicate.
// Only a fully attributed fill book vs a complete broker position cut can
// disagree. Foreign/netted residuals are outside this comparison.
export function reconciliationEvidence(state, config, keepSymbols, { account, attribute, executionTime = Date.parse }) {
  if (state.ownershipComplete !== true || state.ownershipSnapshot?.ownershipComplete !== true || !Array.isArray(state.ownershipSnapshot.positions)) return [];
  const owned = new Map(), foreign = new Set();
  for (const row of state.executions || []) {
    const c = row.contract, e = row.execution;
    if (!c || !e || e.acctNumber !== account || keepSymbols.includes(c.symbol)) continue;
    const attribution = attribute(row, config);
    const key = String(c.conId);
    if (!DESKS.includes(attribution.desk) || attribution.needsAttribution || Number(e.clientId) !== config.executorClientId
      || !Number.isFinite(executionTime(e.time)) || Date.parse(config.foreignAlertSince) > executionTime(e.time)) { foreign.add(key); continue; }
    const previous = owned.get(key) || { quantity: 0n, fills: [] };
    const sign = { BOT: 1n, BUY: 1n, SLD: -1n, SELL: -1n }[e.side];
    if (!sign) continue;
    previous.quantity += decimalUnits(e.shares) * sign;
    previous.fills.push(hash(String(e.execId)));
    owned.set(key, previous);
  }
  const broker = new Map((state.ownershipSnapshot.positions || []).map(row => [String(row.conId), decimalUnits(row.position ?? row.pos)]));
  return [...owned].filter(([key, row]) => !foreign.has(key) && row.quantity !== (broker.get(key) || 0n)).map(([key, row]) => ({ kind: 'fill_position_mismatch', instrument: hash(key), fills: row.fills }));
}
