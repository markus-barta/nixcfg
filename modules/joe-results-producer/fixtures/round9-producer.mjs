import { openJournal, readJournal, hash, createJournalReader } from './journal.mjs';
import { roundTrips, dayCloses, viennaDate, unavailable, DESKS } from './fifo.mjs';
import { validInstant } from './contracts/schema-validator.mjs';
import { validateResults, historyGaps, updateHistoryIntervals } from './results-validation.mjs';
import { earlierGapDays, PositionProofIndex } from './position-proof.mjs';
import { dayFx, fxDayPartial } from './fx.mjs';
import { brokerMismatches } from './broker-backstop.mjs';

export const CADENCE_MS = 25_000; // room for source/transport time inside 30 s

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
  let sourceReader, sourcePath;
  let authority = null, latestHealth = null, fxStatus = null;
  const fxDays = new Map();
  let coverageIntervals = [];
  let historyStart = Infinity;
  const positionProofs = new PositionProofIndex();
  function apply(event) {
    if (event.type === 'start') start = event.at;
    else if (event.type === 'source') {
      sourceCount = event.count;
      sourceDigest = hash([sourceDigest, event.entry]);
      const row = event.entry;
      if (row.type === 'fill') fills.set(row.fill.key, row.fill);
      else if (row.type === 'authority') authority = row;
      else if (row.type === 'cut') {
        for (const fill of row.fills) fills.set(fill.key, fill);
        authority = row;
        if (row.fxSampler) {
          fxStatus = { enabled: row.fxSampler.enabled, reason: row.fxSampler.reason };
          for (const [date, day] of Object.entries(row.fxSampler.days || {})) {
            const frozen = fxDays.get(date)?.samples?.find(sample => sample.kind === 'close');
            fxDays.set(date, frozen ? { ...day, samples: [...(day.samples || []).filter(sample => sample.kind !== 'close'), frozen] } : day);
          }
        }
        if (row.authoritative) {
          coverageIntervals = updateHistoryIntervals(coverageIntervals, row.historyCoverage, row.at);
          if (historyGaps(row.historyCoverage, row.at)) historyStart = Math.min(historyStart, Date.parse(row.historyCoverage.target.fromInclusive));
        }
        if (row.authoritative && row.positionProof) positionProofs.add(row.positionProof);
      }
    } else if (event.type === 'conversion-exclusion') exclusions.add(hash(event.record));
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
      if (!fxStatus || fill.currency !== 'USD') return fill;
      const fx = dayFx(fxDays.get(viennaDate(fill.at)), viennaDate(fill.at), at);
      return { ...fill, closeFx: fx };
    });
    const excluded = [];
    const trades = roundTrips(captured, start, keepSymbols, () => {}, record => excluded.push(record));
    if (trades.some(trade => Date.parse(trade.closedAt) > Date.parse(at))) throw unavailable();
    const proofFrom = new Date(Math.min(Date.parse(start), historyStart)).toISOString();
    const stage0 = captured.filter(fill => DESKS.includes(fill.desk) && fill.scope === 'stage0' && !keepSymbols.includes(fill.symbol));
    const executions = stage0.filter(fill => fill.at >= start).map(({ instrument, at }) => ({ instrument, at }));
    const earlierGaps = earlierGapDays(stage0, executions, coverageIntervals, positionProofs, proofFrom);
    const { days } = dayCloses(stage0, trades, viennaDate(start), { from: start, through: at, intervals: coverageIntervals, earlierGaps });
    // Gaps without an attributed desk remain visible without inventing ownership.
    for (const [a, b] of historyGaps(authority.historyCoverage, authority.at) || []) {
      const first = viennaDate(new Date(Math.max(a, Date.parse(start))).toISOString());
      const last = viennaDate(new Date(Math.min(b - 1, Date.parse(at))).toISOString());
      for (let noon = Date.parse(`${first}T12:00:00Z`); ; noon += 86400_000) {
        const date = new Date(noon).toISOString().slice(0, 10);
        if (date > last) break;
        if (!days.some(day => day.date === date)) days.push({ date, desks: {}, coverage: 'partial' });
      }
    }
    days.sort((a, b) => a.date.localeCompare(b.date));
    const usdDays = new Set(stage0.filter(fill => fill.currency === 'USD').map(fill => viennaDate(fill.at)));
    const excludedDays = new Set(excluded.map(record => record.day));
    const backstop = brokerMismatches(days, stage0, start, at);
    const partial = new Set(backstop.map(record => record.day));
    for (const day of days) {
      if (partial.has(day.date) || excludedDays.has(day.date) || fxStatus && usdDays.has(day.date) && fxDayPartial(fxDays.get(day.date), day.date, fxStatus, at)) day.coverage = 'partial';
    }
    const candidate = { schema: 'inspr.joe.household.results.v2', seq: seq + 1, generatedAt: at, currency: 'EUR', timeZone: 'Europe/Vienna', trackingStart: viennaDate(start), days, trades, benchmark: null };
    if (authority.disagreement) candidate.reason = 'executor_broker_disagreement';
    const checked = validateResults(candidate);
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
      // Loopback executor health only; no household/account handoff in v1.
      append({ type: 'health', value });
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
        const source = await readSource();
        if (typeof source === 'string') producer.ingestJournal(source);
        else producer.ingest(source);
        producer.health(await readHealth(), new Date(now()).toISOString());
        await transport.send(producer.snapshot(new Date(now()).toISOString()));
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
