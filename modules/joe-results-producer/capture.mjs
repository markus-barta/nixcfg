import { sdkDecimal } from './sdk-decimal.mjs';
import { validDate, validInstant } from './contracts/schema-validator.mjs';
import { decimalUnits } from './contracts/decimal.mjs';
import { DESKS, unavailable, invalidFillField } from './fifo.mjs';
import { hash, openJournal } from './journal.mjs';
import { dayCoverage, historyGaps, historyIntervals, mergeIntervals, updateHistoryIntervals, viennaDate, withFillGaps } from './results-validation.mjs';
import { brokerQuantity, capturePositionProof } from './position-proof.mjs';
import { captureBrokerRealised } from './broker-backstop.mjs';

export function authorityHash(event) {
  const proof = event.positionProof, epoch = Date.parse(proof?.at);
  const interval = historyIntervals(withFillGaps(event.historyCoverage, event.fillGaps), event.at).find(([a, b]) => a <= epoch && epoch < b);
  // New quantities or a post-gap baseline matter; moving snapshot timestamps
  // alone must not restore the old one-cut-per-poll journal growth.
  return hash([event.authoritative, event.disagreement, event.evidence, proof?.positions ?? null, proof?.foreign ?? null, interval?.[0] ?? null, event.unattributedActivity ?? {}]);
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
  let journal, known, closeFx, lastAuthority, lastGaps, lastFx, ordinals, captureStart, nextOrdinal = 0;
  let proven = [], days = new Set();
  const instruments = new Set(), fxHashes = new Map(), issues = new Map(), closeFxSources = new Set();
  const refusedInstants = new Map();
  function initialize() {
    if (journal) return;
    known = new Map(); closeFx = new Map(); ordinals = new Map();
    let previous, lastCut;
    journal = openJournal(filename, { retain: () => false, onEntry: event => {
      previous = event;
      if (event.type === 'start') captureStart = event.at;
      for (const issue of event.captureIssues || []) issues.set(issue.id, issue);
      if (event.type === 'cut') lastCut = event;
      if (event.authoritative) proven = updateHistoryIntervals(proven, withFillGaps(event.historyCoverage, event.fillGaps), event.at);
      for (const fill of event.fills || []) {
        if (fill.scope === 'excluded' && (event.captureIssues || []).some(issue => issue.field === 'at'
          && issue.id === hash([fill.key, 'at', 'capture_gap', issue.day, true]))) {
          refusedInstants.set(fill.key, Math.max(Date.parse(captureStart), Date.parse(event.at) - 1));
        }
        if (fill.scope === 'stage0') instruments.add(fill.instrument);
        known.set(fill.key, hash(fill));
        if (fill.closeFx) closeFx.set(fill.key, fill.closeFx);
        if (fill.provenance?.some(row => row.field === 'closeFx.rate' && row.src === 'sdk_number_roundtrip')) closeFxSources.add(fill.key);
        if (fill.ordinal) { ordinals.set(fill.key, fill.ordinal); nextOrdinal = Math.max(nextOrdinal, fill.ordinal); }
      }
      if (event.fxSampler) {
        lastFx = hash([event.fxSampler.enabled, event.fxSampler.reason]);
        for (const [date, day] of Object.entries(event.fxSampler.days || {})) {
          if (!validDate(date)) throw unavailable();
          fxHashes.set(date, hash(day.samples || []));
        }
      }
    } });
    if (!previous) { captureStart = now(); journal.append({ type: 'start', at: captureStart }); }
    if (lastCut) {
      lastAuthority = authorityHash(lastCut);
      lastGaps = hash([lastCut.historyCoverage?.gaps ?? null, lastCut.fillGaps || []]);
      days = closedDays(proven, lastCut.at);
    }
  }
  function capture(state) {
    initialize();
    const at = now();
    const changed = [], unattributed = new Map(), captureIssues = [], unattributedKeys = new Map();
    function issue(day, desk, kind, key, field, refused = true) {
      const record = { id: hash([key, field, kind, day, refused]), day, deskHash: hash(desk), kind, field, refused };
      if (!issues.has(record.id) && !captureIssues.some(row => row.id === record.id)) captureIssues.push(record);
    }
    const commissions = new Map((state.commissions || []).map(row => [row.execId, row]));
    const epochFor = row => {
      try { return executionTime(row.execution?.time); } catch { return NaN; }
    };
    // An unusable execution instant cannot be assigned a historical day.
    // Refuse it at the last millisecond before this capture instead of stopping
    // every fill; never publish a fabricated execution timestamp.
    function refuseInstant(key, desk) {
      const epoch = refusedInstants.get(key) ?? Math.max(Date.parse(captureStart), Date.parse(at) - 1);
      refusedInstants.set(key, epoch);
      issue(viennaDate(new Date(epoch).toISOString()), desk, 'capture_gap', key, 'at');
      unattributed.set(epoch, 'capture_gap');
    }
    // Preserve broker ordering for same-instant fills WITHOUT retaining the
    // broker identifier as the sort key. Corrections retain the original rank.
    const ordered = [...(state.executions || [])].sort((a, b) => epochFor(a) - epochFor(b) || String(a.execution?.execId).localeCompare(String(b.execution?.execId)));
    for (const row of ordered) {
      const e = row.execution, c = row.contract;
      if (!e?.execId || !c) throw unavailable();
      // Corrections replace one logical fill in the accumulated projection.
      const key = hash(String(e.execId).replace(/\.\d+$/, '.'));
      const exclude = (refused = false) => {
        const tombstone = { key, desk: null, scope: 'excluded' };
        if ((refused || known.has(key)) && known.get(key) !== hash(tombstone)) changed.push(tombstone);
      };
      const ownership = attribute(row, config);
      const epoch = epochFor(row);
      const fillAt = Number.isFinite(epoch) && Math.abs(epoch) <= 8640000000000000 ? new Date(epoch).toISOString() : null;
      if (e.acctNumber === account && !keepSymbols.includes(c.symbol) && ownership.needsAttribution) {
        if (!validInstant(fillAt)) {
          refuseInstant(key, null); exclude(true); continue;
        }
        if (epoch >= Date.parse(config.foreignAlertSince)) {
          unattributed.set(epoch, 'unattributed_activity');
          unattributedKeys.set(key, epoch);
        }
      }
      if (e.acctNumber !== account || !DESKS.includes(ownership.desk) || ownership.needsAttribution || ownership.method === 'external') { exclude(); continue; }
      if (keepSymbols.includes(c.symbol)) { exclude(); continue; }
      if (!validInstant(fillAt)) {
        refuseInstant(key, ownership.desk); exclude(true); continue;
      }
      // Legacy scope and retired client ownership are not Stage-0 results.
      if (epoch < Date.parse(config.foreignAlertSince) || (ownership.method !== 'admin' && Number(e.clientId) !== config.executorClientId)) { exclude(); continue; }
      const day = viennaDate(new Date(epoch).toISOString()), provenance = [];
      const convert = (value, field, kind = 'capture_gap') => {
        const result = sdkDecimal(value);
        if (result.refused || result.unset) issue(day, ownership.desk, kind, key, field, result.refused === true);
        if (result.src) provenance.push({ field, src: result.src });
        return result.amount;
      };
      const quantity = convert(e.shares, 'quantity'), price = convert(e.price, 'price');
      const fields = { symbol: c.symbol, side: { BOT: 'BUY', BUY: 'BUY', SLD: 'SELL', SELL: 'SELL' }[e.side], at: fillAt, quantity, price };
      const invalid = invalidFillField(fields);
      if (invalid && (!['quantity', 'price'].includes(invalid) || fields[invalid] !== undefined)) issue(day, ownership.desk, 'capture_gap', key, invalid);
      const commission = commissions.get(e.execId);
      const amount = commission ? convert(commission.commission, 'commission.amount') : undefined;
      const brokerRealised = captureBrokerRealised(commission);
      if (commission && sdkDecimal(commission.realizedPNL).refused) issue(day, ownership.desk, 'broker_evidence_missing', key, 'brokerRealised.amount');
      if (invalid || commission && amount === undefined) {
        // A refused opening must remain a history gap even when a later close
        // reports exactly zero PnL and therefore cannot reveal the missing lot.
        unattributed.set(epoch, 'capture_gap');
        // Replace an earlier usable correction; never leave its old value live.
        exclude(true);
        continue;
      }
      let fx = closeFx.get(key) || null;
      const observed = state.resultsFx?.[c.currency];
      if (!fx && c.currency === 'EUR') fx = { base: 'EUR', quote: 'EUR', rate: '1', source: 'identity', observedAt: new Date(epoch).toISOString() };
      // Never stamp today's FX onto a historical fill. Close evidence must
      // actually have been observed within the capture window at execution.
      if (!fx && observed && validInstant(observed.observedAt) && Math.abs(Date.parse(observed.observedAt) - epoch) <= 60_000) fx = structuredClone(observed);
      if (fx) {
        if (sdkDecimal(fx.rate).src) closeFxSources.add(key);
        const rate = convert(fx.rate, 'closeFx.rate', 'broker_evidence_missing');
        if (closeFxSources.has(key) && !provenance.some(row => row.field === 'closeFx.rate')) provenance.push({ field: 'closeFx.rate', src: 'sdk_number_roundtrip' });
        fx = rate === undefined ? null : { ...fx, rate };
      }
      if (fx) closeFx.set(key, fx);
      if (!ordinals.has(key)) ordinals.set(key, ++nextOrdinal);
      const fill = {
        key, ordinal: ordinals.get(key), desk: ownership.desk, scope: 'stage0', instrument: hash([c.conId, c.symbol, c.currency]),
        symbol: fields.symbol, currency: c.currency, side: fields.side,
        at: fields.at, quantity, price,
        commission: commission ? { amount, currency: commission.currency } : null,
        brokerRealised,
        ...(provenance.length ? { provenance } : {}),
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
    const fillGaps = [];
    if (historyCoverage) {
      for (const [epoch, kind] of [...unattributed].sort(([a], [b]) => a - b)) {
        if (epoch >= Date.parse(historyCoverage.target.fromInclusive) && epoch < Date.parse(historyCoverage.target.toExclusive)) {
          fillGaps.push({ fromInclusive: new Date(epoch).toISOString(), toExclusive: new Date(epoch + 1).toISOString(), kind });
        }
      }
      historyCoverage.gaps = mergeIntervals(historyCoverage.gaps.map(gap => [Date.parse(gap.fromInclusive), Date.parse(gap.toExclusive)]))
        .map(([from, to]) => ({ fromInclusive: new Date(from).toISOString(), toExclusive: new Date(to).toISOString() }));
    }
    for (const fill of changed) if (fill.scope === 'stage0') instruments.add(fill.instrument);
    const positionProof = capturePositionProof(state, config, keepSymbols, { account, attribute,
      onIssue: (key, refused) => issue(viennaDate(state.ownershipSnapshot.observedAt), null, 'broker_evidence_missing', key, 'position.quantity', refused),
    }, instruments, at);
    const fxSampler = state.resultsFxSampler ? {
      enabled: state.resultsFxSampler.enabled,
      reason: state.resultsFxSampler.reason === 'pending' ? 'missing_sample' : state.resultsFxSampler.reason,
      days: Object.create(null),
    } : null;
    const changedFx = new Map();
    for (const [date, day] of Object.entries(state.resultsFxSampler?.days || {})) {
      if (!validDate(date)) throw unavailable(); // IB/journal keys cannot select object properties.
      const samples = (day.samples || []).flatMap(sample => {
        const converted = sdkDecimal(sample.rate);
        if (converted.refused || converted.unset) {
          issue(date, null, 'broker_evidence_missing', date + sample.sampleAt, 'sample.rate', converted.refused === true);
          return [];
        }
        return [{ ...sample, rate: converted.amount, ...(converted.src ? { src: converted.src } : {}) }];
      });
      const digest = hash(samples);
      if (fxHashes.get(date) !== digest) {
        fxSampler.days[date] = { samples };
        changedFx.set(date, digest);
      }
    }
    // Current, deduplicated counts only: corrections/admin attribution may heal
    // them. No broker IDs cross this boundary and capture-off state is untouched.
    const unattributedActivity = Object.create(null);
    const countFrom = Math.max(Date.parse(captureStart), historyCoverage ? Date.parse(historyCoverage.target.fromInclusive) : -Infinity);
    const countThrough = Math.min(Date.parse(at), historyCoverage ? Date.parse(historyCoverage.target.toExclusive) : Infinity);
    for (const epoch of unattributedKeys.values()) {
      if (epoch < countFrom || epoch >= countThrough) continue;
      const day = viennaDate(new Date(epoch).toISOString());
      unattributedActivity[day] = (unattributedActivity[day] || 0) + 1;
    }
    const event = { type: 'cut', at, fills: changed, authoritative: authority, disagreement: evidence.length > 0, evidence,
      historyCoverage: withFillGaps(historyCoverage, fillGaps), historyGaps: historyCoverage?.gaps ?? null, fillGaps,
      positionProof, unattributedActivity, ...(captureIssues.length ? { captureIssues } : {}), ...(fxSampler ? { fxSampler } : {}) };
    const nextAuthority = authorityHash(event);
    const gapHash = hash([event.historyCoverage?.gaps ?? null, fillGaps]);
    const fxHash = fxSampler ? hash([fxSampler.enabled, fxSampler.reason]) : lastFx;
    const nextProven = authority ? updateHistoryIntervals(proven, withFillGaps(historyCoverage, fillGaps), at) : proven;
    const nextDays = closedDays(nextProven, at);
    // Moving intraday bounds alone do not justify another durable cut. Keep
    // authority/fill changes and changed gaps immediate, including on restart.
    const realCut = captureIssues.length > 0 || changed.length > 0 || nextAuthority !== lastAuthority || gapHash !== lastGaps || [...nextDays].some(day => !days.has(day));
    if (!realCut && fxHash === lastFx && !changedFx.size) return;
    // FX-only updates carry no position/history authority. Older producers
    // ignore the new type; real cuts retain their existing replay shape.
    const update = realCut ? event : { type: 'fx', at, fxSampler };
    const fxDates = Object.keys(fxSampler?.days || {});
    if (fxDates.length <= 1) journal.append(update);
    else for (const [index, date] of fxDates.entries()) journal.append({
      ...(index === 0 ? update : { type: 'fx', at }),
      fxSampler: { ...fxSampler, days: { [date]: fxSampler.days[date] } },
    });
    for (const record of captureIssues) issues.set(record.id, record);
    for (const fill of changed) known.set(fill.key, hash(fill));
    lastAuthority = nextAuthority;
    for (const [date, digest] of changedFx) fxHashes.set(date, digest);
    lastGaps = gapHash; lastFx = fxHash; proven = nextProven; days = nextDays;
  }
  capture.health = () => ({ refusals: [...issues.values()].filter(row => row.refused).length });
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
    const quantity = sdkDecimal(e.shares);
    if (quantity.refused || quantity.unset) continue;
    previous.quantity += decimalUnits(quantity.amount) * sign;
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
