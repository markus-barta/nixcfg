import { decimalUnits } from './contracts/decimal.mjs';
import { validInstant } from './contracts/schema-validator.mjs';
import { DESKS, unavailable } from './fifo.mjs';
import { hash, openJournal } from './journal.mjs';
import { dayCoverage, historyGaps, historyIntervals, mergeIntervals, updateHistoryIntervals, viennaDate } from './results-validation.mjs';
import { brokerQuantity, capturePositionProof } from './position-proof.mjs';
import { captureBrokerRealised } from './broker-backstop.mjs';

function authorityHash(event) {
  const proof = event.positionProof, epoch = Date.parse(proof?.at);
  const interval = historyIntervals(event.historyCoverage, event.at).find(([a, b]) => a <= epoch && epoch < b);
  // New quantities or a post-gap baseline matter; moving snapshot timestamps
  // alone must not restore the old one-cut-per-poll journal growth.
  return hash([event.authoritative, event.disagreement, event.evidence, proof?.positions ?? null, proof?.foreign ?? null, interval?.[0] ?? null]);
}

function closedDays(intervals, at) {
  const result = new Set();
  for (const [from, to] of intervals) {
    const first = viennaDate(new Date(from).toISOString()), last = viennaDate(new Date(to).toISOString());
    for (let noon = Date.parse(`${first}T12:00:00.000Z`); ; noon += 86400_000) {
      const date = new Date(noon).toISOString().slice(0, 10);
      if (date >= last) break;
      if (dayCoverage(date, new Date(from).toISOString(), at, [[from, to]]) === 'full') result.add(date);
    }
  }
  return result;
}

// Runs inside the executor, BEFORE retention/compaction; producer itself only
// reads this file. No account, broker/order ID, orderRef or receipt is written.
export function createCapture(filename, config, { account, attribute, executionTime, now = () => new Date().toISOString(), keepSymbols = ['SXR8', 'TSLA'] } = {}) {
  if (!account || typeof attribute !== 'function' || typeof executionTime !== 'function') throw unavailable();
  let journal, known, closeFx, lastAuthority, lastGaps, lastFx, ordinals, nextOrdinal = 0;
  let proven = [], days = new Set();
  const instruments = new Set(), fxHashes = new Map();
  function initialize() {
    if (journal) return;
    known = new Map(); closeFx = new Map(); ordinals = new Map();
    let previous;
    journal = openJournal(filename, { retain: () => false, onEntry: event => {
      previous = event;
      if (event.authoritative) proven = updateHistoryIntervals(proven, event.historyCoverage, event.at);
      for (const fill of event.fills || []) {
        if (fill.scope === 'stage0') instruments.add(fill.instrument);
        known.set(fill.key, hash(fill));
        if (fill.closeFx) closeFx.set(fill.key, fill.closeFx);
        if (fill.ordinal) { ordinals.set(fill.key, fill.ordinal); nextOrdinal = Math.max(nextOrdinal, fill.ordinal); }
      }
      if (event.fxSampler) {
        lastFx = hash([event.fxSampler.enabled, event.fxSampler.reason]);
        for (const [date, day] of Object.entries(event.fxSampler.days || {})) fxHashes.set(date, hash(day.samples || []));
      }
    } });
    if (!previous) journal.append({ type: 'start', at: now() });
    if (previous?.type === 'cut') {
      lastAuthority = authorityHash(previous);
      lastGaps = hash(previous.historyCoverage?.gaps ?? null);
      days = closedDays(proven, previous.at);
    }
  }
  function capture(state) {
    initialize();
    const at = now();
    const changed = [], unattributed = new Set();
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
      if (e.acctNumber === account && !keepSymbols.includes(c.symbol) && ownership.needsAttribution) {
        const epoch = executionTime(e.time);
        if (!Number.isFinite(epoch)) throw unavailable();
        if (epoch >= Date.parse(config.foreignAlertSince)) unattributed.add(epoch);
      }
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
        brokerRealised: captureBrokerRealised(commission),
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
    const historyCoverage = authority && historyGaps(coverage, at) ? {
      status: coverage.status,
      target: { fromInclusive: coverage.target.fromInclusive, toExclusive: coverage.target.toExclusive },
      gaps: coverage.gaps.map(({ fromInclusive, toExclusive }) => ({ fromInclusive, toExclusive })),
    } : null;
    if (historyCoverage) {
      for (const epoch of [...unattributed].sort((a, b) => a - b)) {
        if (epoch >= Date.parse(historyCoverage.target.fromInclusive) && epoch < Date.parse(historyCoverage.target.toExclusive)) {
          historyCoverage.gaps.push({ fromInclusive: new Date(epoch).toISOString(), toExclusive: new Date(epoch + 1).toISOString() });
          historyCoverage.status = 'known';
        }
      }
      historyCoverage.gaps = mergeIntervals(historyCoverage.gaps.map(gap => [Date.parse(gap.fromInclusive), Date.parse(gap.toExclusive)]))
        .map(([from, to]) => ({ fromInclusive: new Date(from).toISOString(), toExclusive: new Date(to).toISOString() }));
    }
    for (const fill of changed) if (fill.scope === 'stage0') instruments.add(fill.instrument);
    const positionProof = capturePositionProof(state, config, keepSymbols, { account, attribute }, instruments, at);
    const fxSampler = state.resultsFxSampler ? {
      enabled: state.resultsFxSampler.enabled,
      reason: state.resultsFxSampler.reason === 'pending' ? null : state.resultsFxSampler.reason,
      days: {},
    } : null;
    const changedFx = new Map();
    for (const [date, day] of Object.entries(state.resultsFxSampler?.days || {})) {
      const digest = hash(day.samples || []);
      if (fxHashes.get(date) !== digest) {
        fxSampler.days[date] = { samples: structuredClone(day.samples || []) };
        changedFx.set(date, digest);
      }
    }
    const event = { type: 'cut', at, fills: changed, authoritative: authority, disagreement: evidence.length > 0, evidence, historyCoverage, positionProof, ...(fxSampler ? { fxSampler } : {}) };
    const nextAuthority = authorityHash(event);
    const gapHash = hash(historyCoverage?.gaps ?? null);
    const fxHash = fxSampler ? hash([fxSampler.enabled, fxSampler.reason]) : lastFx;
    const nextProven = authority ? updateHistoryIntervals(proven, historyCoverage, at) : proven;
    const nextDays = closedDays(nextProven, at);
    // Moving intraday bounds alone do not justify another durable cut. Keep
    // authority/fill changes and changed gaps immediate, including on restart.
    if (!changed.length && nextAuthority === lastAuthority && gapHash === lastGaps && fxHash === lastFx && !changedFx.size && ![...nextDays].some(day => !days.has(day))) return;
    const fxDates = Object.keys(fxSampler?.days || {});
    if (fxDates.length <= 1) journal.append(event);
    else for (const [index, date] of fxDates.entries()) journal.append({
      ...event, fills: index === 0 ? changed : [],
      fxSampler: { ...fxSampler, days: { [date]: fxSampler.days[date] } },
    });
    for (const fill of changed) known.set(fill.key, hash(fill));
    lastAuthority = nextAuthority;
    for (const [date, digest] of changedFx) fxHashes.set(date, digest);
    lastGaps = gapHash; lastFx = fxHash; proven = nextProven; days = nextDays;
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
  const broker = new Map(), unavailable = [];
  for (const row of state.ownershipSnapshot.positions) {
    if (keepSymbols.includes(row.symbol)) continue;
    const key = String(row.conId);
    try { broker.set(key, brokerQuantity(row.position ?? row.pos)); }
    catch { unavailable.push({ kind: 'position_unavailable', instrument: hash(key) }); }
  }
  return [...unavailable, ...[...owned].filter(([key, row]) => !foreign.has(key) && row.quantity !== (broker.get(key) || 0n))
    .map(([key, row]) => ({ kind: 'fill_position_mismatch', instrument: hash(key), fills: row.fills }))];
}
