import { openJournal, readJournal, hash, createJournalReader } from './journal.mjs';
import { roundTrips, dayCloses, viennaDate, unavailable, DESKS, invalidFillField } from './fifo.mjs';
import { validInstant, validDate } from './contracts/schema-validator.mjs';
import { validateResults, historyGaps, updateHistoryIntervals, subtractIntervals, mergeIntervals, markPartial, withFillGaps, reportedHistoryCoverage } from './results-validation.mjs';
import { earlierGapDays, PositionProofIndex } from './position-proof.mjs';
import { dayFx, fxDayPartial } from './fx.mjs';
import { brokerMismatches } from './broker-backstop.mjs';
import { IngressError } from './transport.mjs';

export const CADENCE_MS = 25_000; // room for source/transport time inside 30 s
export const MIDNIGHT_RETRIES = 1;

// Local executor loopback diagnostics, never a household health/account input
// and never proof for the broker Results comparison.
export function executorHealth(health, checkedAt, disagreement = false) {
  if (!validInstant(checkedAt)) throw unavailable();
  const valid = health?.status === 'ok' && typeof health.halt?.active === 'boolean' && health.brakes && typeof health.gatewayReachable === 'boolean';
  const brakes = valid && !health.brakes.placementBlockedOnInitDay && Number.isFinite(health.brakes.newPerDay) && Number.isFinite(health.brakes.notionalEur) && health.brakes.newPerDay > 0 && health.brakes.notionalEur > 0;
  const result = { status: !valid ? 'down' : disagreement || !brakes || !health.gatewayReachable ? 'degraded' : 'running', halt: health?.halt?.active === true, brakes: !!brakes, gatewayReachable: health?.gatewayReachable === true, checkedAt };
  if (disagreement) result.reason = 'executor_broker_disagreement';
  return result;
}

export function openProducer(filename, { keepSymbols = ['SXR8', 'TSLA'], now = () => new Date().toISOString() } = {}) {
  if (!keepSymbols.includes('SXR8') || !keepSymbols.includes('TSLA')) throw unavailable();
  let start, sourceCount = 0, sourceDigest = '0'.repeat(64), seq = 0, generatedAt = null;
  const fills = new Map(), mismatches = new Set(), exclusions = new Set();
  const portionExclusions = new Map();
  let sourceReader, sourcePath;
  let authority = null, latestHealth = null, fxStatus = null;
  const fxDays = new Map(), captureIssues = new Map();
  let coverageIntervals = [];
  let historyOnlyIntervals = [], fillGaps = [];
  let historyStart = Infinity, historyEnd = -Infinity;
  const positionProofs = new PositionProofIndex();
  function apply(event) {
    if (event.type === 'start') start = event.at;
    else if (event.type === 'source') {
      sourceCount = event.count;
      sourceDigest = hash([sourceDigest, event.entry]);
      const row = event.entry;
      if (row.type === 'fill') fills.set(row.fill.key, row.fill);
      else if (row.type === 'authority') authority = row;
      else if (row.type === 'cut' || row.type === 'fx') {
        for (const issue of row.captureIssues || []) {
          if (!validDate(issue.day) || !/^[a-f0-9]{64}$/.test(issue.id) || !['capture_gap', 'broker_evidence_missing', 'fx_missing'].includes(issue.kind)) throw unavailable();
          captureIssues.set(issue.id, issue);
        }
        if (row.fxSampler) {
          fxStatus = { enabled: row.fxSampler.enabled, reason: row.fxSampler.reason };
          for (const [date, day] of Object.entries(row.fxSampler.days || {})) {
            if (!validDate(date)) throw unavailable();
            const frozen = fxDays.get(date)?.samples?.find(sample => sample.kind === 'close');
            fxDays.set(date, frozen ? { ...day, samples: [...(day.samples || []).filter(sample => sample.kind !== 'close'), frozen] } : day);
          }
        }
        if (row.type === 'fx') return;
        for (const fill of row.fills) fills.set(fill.key, fill);
        authority = row;
        if (row.authoritative) {
          const effective = withFillGaps(row.historyCoverage, row.fillGaps);
          coverageIntervals = updateHistoryIntervals(coverageIntervals, effective, row.at);
          const reported = reportedHistoryCoverage(row);
          historyOnlyIntervals = updateHistoryIntervals(historyOnlyIntervals, reported, row.at);
          if (historyGaps(reported, row.at)) historyEnd = Math.max(historyEnd, Date.parse(reported.target.toExclusive));
          if (historyGaps(effective, row.at)) {
            const a = Date.parse(effective.target.fromInclusive), b = Date.parse(effective.target.toExclusive);
            historyStart = Math.min(historyStart, a);
            for (const gap of row.fillGaps || []) {
              if (!['capture_gap', 'unattributed_activity'].includes(gap.kind) || Date.parse(gap.toExclusive) - Date.parse(gap.fromInclusive) !== 1) throw unavailable();
            }
            fillGaps = [...fillGaps.filter(gap => Date.parse(gap.toExclusive) <= a || Date.parse(gap.fromInclusive) >= b), ...(row.fillGaps || [])];
          }
        }
        if (row.authoritative && row.positionProof) positionProofs.add(row.positionProof);
      }
    } else if (event.type === 'conversion-exclusion') {
      exclusions.add(hash(event.record));
      if (event.record.kind === 'source_not_authoritative') portionExclusions.set(hash(event.record), event.record);
    }
    else if (event.type === 'broker-mismatch') mismatches.add(hash(event.record));
    else if (event.type === 'sequence') { seq = event.seq; generatedAt = event.at; }
    else if (event.type === 'health') latestHealth = event.value;
  }
  // Heartbeats never accumulate in memory; startup streams and verifies their
  // hash chain while retaining only the latest sequence and health projection.
  const journal = openJournal(filename, { retain: () => false, onEntry: apply });
  function append(event) { journal.append(event); apply(event); }
  function ingest(entries) {
    if (!entries.length || entries[0].type !== 'start' || !validInstant(entries[0].at)) throw unavailable();
    if (!start) append({ type: 'start', at: entries[0].at });
    if (entries[0].at !== start || entries.length < sourceCount) throw new Error('capture_history_regressed');
    // Detect a rewritten prefix as well as a truncated capture source.
    let digest = '0'.repeat(64);
    for (let i = 0; i < sourceCount; i++) digest = hash([digest, entries[i]]);
    if (digest !== sourceDigest) throw new Error('capture_history_rewritten');
    for (let i = sourceCount; i < entries.length; i++) append({ type: 'source', count: i + 1, entry: entries[i] });
  }
  function ingestJournal(filename) {
    if (sourcePath && filename !== sourcePath) throw new Error('capture_history_rewritten');
    sourcePath = filename;
    sourceReader ||= createJournalReader(filename);
    let digest = '0'.repeat(64);
    const priorCount = sourceCount;
    const count = sourceReader((entry, n) => {
      if (n <= priorCount) {
        digest = hash([digest, entry]);
        if (n === priorCount && digest !== sourceDigest) throw new Error('capture_history_rewritten');
        return;
      }
      if (n === 1) {
        if (entry.type !== 'start' || !validInstant(entry.at)) throw unavailable();
        if (!start) append({ type: 'start', at: entry.at });
        if (entry.at !== start) throw new Error('capture_history_rewritten');
      }
      append({ type: 'source', count: n, entry });
    });
    if (!count || count < sourceCount) throw new Error('capture_history_regressed');
  }

  function snapshot(at = now()) {
    const current = now();
    if (!validInstant(at) || !validInstant(current)) throw new Error('clock_regressed');
    // Never manufacture a future generation to work around a clock rollback.
    at = new Date(Math.min(Date.parse(at), Date.parse(current))).toISOString();
    if (generatedAt && Date.parse(at) < Date.parse(generatedAt)) throw new Error('clock_regressed');
    if (!start || !authority?.authoritative || !validInstant(authority.at) || Date.parse(authority.at) > Date.parse(at)) throw unavailable();
    if (seq >= Number.MAX_SAFE_INTEGER) throw new Error('sequence_exhausted');
    const captured = [...fills.values()].map(fill => {
      if (!fxStatus || fill.currency !== 'USD' || invalidFillField(fill)) return fill;
      const fx = dayFx(fxDays.get(viennaDate(fill.at)), viennaDate(fill.at), at);
      return fx ? { ...fill, closeFx: fx } : fill;
    });
    const excluded = [];
    const trades = roundTrips(captured, start, keepSymbols, () => {}, record => excluded.push(record));
    if (trades.some(trade => Date.parse(trade.closedAt) > Date.parse(at))) throw unavailable();
    const proofFrom = new Date(Math.min(Date.parse(start), historyStart)).toISOString();
    const stage0 = captured.filter(fill => DESKS.includes(fill.desk) && fill.scope === 'stage0' && !keepSymbols.includes(fill.symbol) && !invalidFillField(fill));
    const executions = stage0.filter(fill => fill.at >= start).map(({ desk, instrument, at }) => ({ desk, instrument, at }));
    const earlierGaps = earlierGapDays(stage0, executions, coverageIntervals, positionProofs, proofFrom);
    // Keep fill gaps in proof maths; their own day is explained by the fill's
    // reason. Earlier fill gaps and real history gaps can still taint that day.
    const fillGapDays = new Set(fillGaps.map(gap => viennaDate(gap.fromInclusive)));
    for (const date of fillGapDays) {
      const priorGaps = fillGaps.filter(gap => viennaDate(gap.fromInclusive) !== date)
        .map(gap => [Date.parse(gap.fromInclusive), Date.parse(gap.toExclusive)]);
      const labelIntervals = subtractIntervals(historyOnlyIntervals, mergeIntervals(priorGaps));
      const affected = executions.filter(fill => viennaDate(fill.at) === date);
      if (!earlierGapDays(stage0, affected, labelIntervals, positionProofs, proofFrom).has(date)) earlierGaps.delete(date);
    }
    // Containment gaps are scoped to the affected desk/instrument. Keep the
    // full quantity book for position proofs, without tainting other books.
    // Durable records preserve the gap across corrections and producer replay.
    const guarded = new Map(portionExclusions);
    for (const record of excluded) if (record.kind === 'source_not_authoritative') guarded.set(hash(record), record);
    const gapsByBook = new Map();
    for (const record of guarded.values()) {
      const key = `${record.deskHash}:${record.instrumentHash}`, gaps = gapsByBook.get(key) || [];
      const epoch = Date.parse(record.at);
      gaps.push([epoch, epoch + 1]); gapsByBook.set(key, gaps);
    }
    for (const [key, gaps] of gapsByBook) {
      const affected = executions.filter(fill => `${hash(fill.desk)}:${hash(fill.instrument)}` === key);
      const intervals = subtractIntervals(coverageIntervals, mergeIntervals(gaps));
      for (const day of earlierGapDays(stage0, affected, intervals, positionProofs, proofFrom)) earlierGaps.add(day);
    }
    const { days } = dayCloses(stage0, trades, viennaDate(start), { from: start, through: at, intervals: historyOnlyIntervals, historyEnd, earlierGaps });
    // Gaps without an attributed desk remain visible without inventing ownership.
    for (const [a, b] of historyGaps(reportedHistoryCoverage(authority), authority.at) || []) {
      const first = viennaDate(new Date(Math.max(a, Date.parse(start))).toISOString());
      const last = viennaDate(new Date(Math.min(b - 1, Date.parse(at))).toISOString());
      for (let noon = Date.parse(`${first}T12:00:00Z`); ; noon += 86400_000) {
        const date = new Date(noon).toISOString().slice(0, 10);
        if (date > last) break;
        let day = days.find(day => day.date === date);
        if (!day) { day = { date, desks: {} }; days.push(day); }
        markPartial(day, 'history_gap');
      }
    }
    for (const gap of fillGaps) {
      const a = Math.max(Date.parse(gap.fromInclusive), Date.parse(start));
      if (a >= Math.min(Date.parse(gap.toExclusive), Date.parse(at))) continue;
      const date = viennaDate(new Date(a).toISOString());
      let day = days.find(day => day.date === date);
      if (!day) { day = { date, desks: {} }; days.push(day); }
      markPartial(day, gap.kind);
    }
    for (const issue of captureIssues.values()) {
      let day = days.find(day => day.date === issue.day);
      if (!day) { day = { date: issue.day, desks: {} }; days.push(day); }
      const reason = issue.kind === 'broker_evidence_missing' && ['sample.rate', 'closeFx.rate'].includes(issue.field)
        ? 'fx_missing' : issue.kind;
      markPartial(day, reason);
    }
    for (const record of [...excluded, ...guarded.values()]) {
      let day = days.find(day => day.date === record.day);
      if (!day) { day = { date: record.day, desks: {} }; days.push(day); }
      // A guarded conversion or old-journal fill creates a scoped history gap.
      markPartial(day, record.kind === 'source_not_authoritative' ? 'history_gap' : record.kind);
    }
    for (const [date, count] of Object.entries(authority.unattributedActivity || {})) {
      if (!validDate(date) || !Number.isSafeInteger(count) || count < 1) throw unavailable();
      let day = days.find(day => day.date === date);
      if (!day) { day = { date, desks: {} }; days.push(day); }
      markPartial(day, 'unattributed_activity');
      day.unattributedCount = count;
    }
    days.sort((a, b) => a.date.localeCompare(b.date));
    const usdDays = new Set(stage0.filter(fill => fill.currency === 'USD').map(fill => viennaDate(fill.at)));
    const backstop = brokerMismatches(days, stage0, start, at);
    for (const record of backstop) markPartial(days.find(day => day.date === record.day), record.kind);
    for (const day of days) {
      if (fxStatus && usdDays.has(day.date) && fxDayPartial(fxDays.get(day.date), day.date, fxStatus, at)) {
        markPartial(day, fxStatus.enabled ? 'fx_missing' : 'fx_disabled');
      }
    }
    const candidate = { schema: 'inspr.joe.household.results.v2', seq: seq + 1, generatedAt: at, currency: 'EUR', timeZone: 'Europe/Vienna', trackingStart: viennaDate(start), days, trades, benchmark: null };
    if (authority.disagreement) candidate.reason = 'executor_broker_disagreement';
    const checked = validateResults(candidate, { requirePartialReasons: true, receivedAt: at });
    if (!checked.ok) throw new Error(checked.reason);
    for (const record of excluded) if (!exclusions.has(hash(record))) append({ type: 'conversion-exclusion', record });
    for (const record of backstop) if (!mismatches.has(hash(record))) append({ type: 'broker-mismatch', record });
    // Reserve durably BEFORE transmission. A failed/ambiguous send burns the
    // sequence; restart cannot replay it or reset it from a compacted ledger.
    append({ type: 'sequence', seq: candidate.seq, at });
    return candidate;
  }
  return {
    ingest, ingestJournal, snapshot, close: () => journal.close(),
    health(health, at = now()) {
      const value = executorHealth(health, at, authority?.disagreement === true);
      value.captureRefusals = [...captureIssues.values()].filter(row => row.refused).length;
      value.portionExclusions = portionExclusions.size;
      // Loopback executor health only; no household/account handoff in v1.
      const { checkedAt: _previousAt, ...previous } = latestHealth || {};
      const { checkedAt: _currentAt, ...current } = value;
      if (hash(current) !== hash(previous)) append({ type: 'health', value });
      latestHealth = value;
      return value;
    },
    get latestHealth() { return latestHealth; },
    get retainedEntries() { return journal.entries.length; },
    get sourceCount() { return sourceCount; },
  };
}

export function createRunner({ producer, readSource, readHealth, transport, now = Date.now }) {
  let next = -Infinity, busy = false, failures = 0;
  return {
    async tick() {
      if (busy || now() < next) return false;
      busy = true; next = now() + CADENCE_MS;
      try {
        for (let retries = 0; ; retries++) {
          const source = await readSource();
          if (typeof source === 'string') producer.ingestJournal(source);
          else producer.ingest(source);
          const snapshot = producer.snapshot(new Date(now()).toISOString());
          producer.health(await readHealth(), new Date(now()).toISOString());
          try { await transport.send(snapshot); break; }
          catch (error) {
            // Recompute once, silently, with a newly reserved sequence. This
            // benign race never reaches the failure counter or main's log.
            if (!(error instanceof IngressError && error.midnightStraddle === true && retries < MIDNIGHT_RETRIES)) throw error;
          }
        }
        failures = 0;
        return true;
      } catch (error) {
        // A new snapshot (and durably reserved seq) on each retry. Never replay
        // rejected bytes; bounded retries also leave room inside the 30 s SLA.
        failures = Math.min(failures + 1, 6);
        next = Math.min(next, now() + Math.min(CADENCE_MS, 1000 * 2 ** (failures - 1)));
        throw error;
      } finally { busy = false; }
    },
  };
}

export { readJournal };
