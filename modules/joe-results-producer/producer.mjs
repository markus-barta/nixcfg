import { openJournal, readJournal, hash } from './journal.mjs';
import { roundTrips, dayCloses, viennaDate, unavailable, DESKS } from './fifo.mjs';
import { validateContract, SCHEMA_FILES } from './contracts/index.mjs';
import { checkSchema, validInstant } from './contracts/schema-validator.mjs';
import { validateResults } from './results-validation.mjs';

export const CADENCE_MS = 25_000; // room for source/transport time inside 30 s

// Contract-owned household safety.executor projection; NOT a second household
// producer. The household owner must merge this fragment at its own boundary.
export function executorHealth(health, checkedAt, disagreement = false) {
  if (!validInstant(checkedAt)) throw unavailable();
  const valid = health?.status === 'ok' && typeof health.halt?.active === 'boolean' && health.brakes && typeof health.gatewayReachable === 'boolean';
  const brakes = valid && !health.brakes.placementBlockedOnInitDay && Number.isFinite(health.brakes.newPerDay) && Number.isFinite(health.brakes.notionalEur) && health.brakes.newPerDay > 0 && health.brakes.notionalEur > 0;
  const result = { status: !valid ? 'down' : disagreement || !brakes || !health.gatewayReachable ? 'degraded' : 'running', halt: health?.halt?.active === true, brakes: !!brakes, gatewayReachable: health?.gatewayReachable === true, checkedAt };
  if (disagreement) result.reason = 'executor_broker_disagreement';
  const errors = [];
  checkSchema(SCHEMA_FILES['data.schema.json'].properties.safety.properties.executor, result, SCHEMA_FILES, errors);
  if (errors.length) throw unavailable();
  return result;
}

// Input is a VALIDATED authoritative household v2 snapshot from its producer,
// never the legacy pusher JSON. No account equity is treated as desk equity.
export function householdObservation(payload, keepSymbols) {
  if (!validateContract('data', payload, { stage: 'ingress' }).ok) throw unavailable();
  if (payload.safety.gateway?.apiSessionReady !== true) throw unavailable();
  const desks = {};
  for (const desk of payload.desks) {
    if (!DESKS.includes(desk.id) || !desk.money.equity || !desk.moneyEvidence) continue;
    const evidence = desk.moneyEvidence;
    if (evidence.status !== 'observed' || !validInstant(evidence.observedAt) || !desk.historyBasis) continue;
    const age = Date.parse(payload.generatedAt) - Date.parse(evidence.observedAt);
    if (age < 0 || age >= 60_000) continue;
    const scopeRows = payload.positions?.rows?.filter(row => row.desk === desk.id) || [];
    if (scopeRows.some(row => keepSymbols.includes(row.symbol) || row.scope !== 'stage0')) throw unavailable();
    desks[desk.id] = { equity: structuredClone(desk.money.equity), at: evidence.observedAt, basisId: desk.historyBasis };
  }
  return { at: payload.generatedAt, desks };
}

export function openProducer(filename, { keepSymbols = ['SXR8', 'TSLA'], now = () => new Date().toISOString() } = {}) {
  if (!keepSymbols.includes('SXR8') || !keepSymbols.includes('TSLA')) throw unavailable();
  let start, sourceCount = 0, seq = 0, generatedAt = null;
  const fills = new Map(), observations = new Map();
  let authority = null, latestHealth = null;
  function apply(event) {
    if (event.type === 'start') start = event.at;
    else if (event.type === 'source') {
      sourceCount = event.count;
      const row = event.entry;
      if (row.type === 'fill') fills.set(row.fill.key, row.fill);
      else if (row.type === 'authority') authority = row;
      else if (row.type === 'cut') { for (const fill of row.fills) fills.set(fill.key, fill); authority = row; }
    } else if (event.type === 'observation') observations.set(event.key, event.value);
    else if (event.type === 'sequence') { seq = event.seq; generatedAt = event.at; }
    else if (event.type === 'health') latestHealth = event.value;
  }
  // Heartbeats never accumulate in memory; startup streams and verifies their
  // hash chain while retaining only the latest sequence and health projection.
  const journal = openJournal(filename, { retain: event => !['sequence', 'health'].includes(event.type), onEntry: apply });
  function append(event) { journal.append(event); apply(event); }
  function ingest(entries) {
    if (!entries.length || entries[0].type !== 'start' || !validInstant(entries[0].at)) throw unavailable();
    if (!start) append({ type: 'start', at: entries[0].at });
    if (entries[0].at !== start || entries.length < sourceCount) throw new Error('capture_history_regressed');
    // Detect a rewritten prefix as well as a truncated capture source.
    const prior = journal.entries.filter(row => row.type === 'source');
    for (let i = 0; i < sourceCount; i++) if (hash(prior[i].entry) !== hash(entries[i])) throw new Error('capture_history_rewritten');
    for (let i = sourceCount; i < entries.length; i++) append({ type: 'source', count: i + 1, entry: entries[i] });
  }
  function observe(value) {
    if (!Object.keys(value.desks || {}).length) return;
    const key = hash(Object.entries(value.desks).map(([desk, close]) => [desk, close.at || value.at, close.equity, close.basisId]));
    if (!observations.has(key)) append({ type: 'observation', key, value });
  }
  function snapshot(at = now()) {
    const current = now();
    if (!validInstant(at) || !validInstant(current)) throw new Error('clock_regressed');
    // Never manufacture a future generation to work around a clock rollback.
    at = new Date(Math.min(Date.parse(at), Date.parse(current))).toISOString();
    if (generatedAt && Date.parse(at) < Date.parse(generatedAt)) throw new Error('clock_regressed');
    if (!start || !authority?.authoritative || !validInstant(authority.at) || Date.parse(authority.at) > Date.parse(at)) throw unavailable();
    if (seq >= Number.MAX_SAFE_INTEGER) throw new Error('sequence_exhausted');
    const trades = roundTrips([...fills.values()], start, keepSymbols);
    if (trades.some(trade => Date.parse(trade.closedAt) > Date.parse(at))) throw unavailable();
    const { days } = dayCloses([...observations.values()], trades, viennaDate(start), { from: start, through: at });
    const candidate = { schema: 'inspr.joe.household.results.v2', seq: seq + 1, generatedAt: at, currency: 'EUR', timeZone: 'Europe/Vienna', trackingStart: viennaDate(start), days, trades, benchmark: null };
    if (authority.disagreement) candidate.reason = 'executor_broker_disagreement';
    const checked = validateResults(candidate);
    if (!checked.ok) throw new Error(checked.reason);
    // Reserve durably BEFORE transmission. A failed/ambiguous send burns the
    // sequence; restart cannot replay it or reset it from a compacted ledger.
    append({ type: 'sequence', seq: candidate.seq, at });
    return candidate;
  }
  return {
    ingest, observe, snapshot, close: () => journal.close(),
    health(health, at = now()) {
      const value = executorHealth(health, at, authority?.disagreement === true);
      // Household brokerAccount.accountHint is the contract home. Never copy
      // the raw executor account into ANY journal, fragment or diagnostic.
      append({ type: 'health', value, accountHint: 'DU…0597' });
      return value;
    },
    get latestHealth() { return latestHealth; },
    get entries() { return journal.entries; },
  };
}

export function createRunner({ producer, readSource, readHousehold, readHealth, transport, now = Date.now }) {
  let next = -Infinity, busy = false, failures = 0;
  return {
    async tick() {
      if (busy || now() < next) return false;
      busy = true; next = now() + CADENCE_MS;
      try {
        producer.ingest(await readSource());
        if (readHousehold) producer.observe(householdObservation(await readHousehold(), transport.keepSymbols));
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
