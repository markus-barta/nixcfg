import { CONTRACTS, REASONS } from './index.mjs';
import { validInstant } from './schema-validator.mjs';
import { gatewayReason, gatewayCheckAgeMs, GATEWAY_CHECK_MAX_AGE_MS } from './gateway.mjs';

export const MONEY_FIELDS = Object.freeze(['equity', 'dayPnl', 'openPnl', 'totalPnl']);
export const DATA_PANELS = Object.freeze([
  ...MONEY_FIELDS.map(f => `today.${f}`), 'paperAccount',
  ...['j', 'joe', 'joel'].flatMap(id => MONEY_FIELDS.map(f => `desks.${id}.${f}`)),
  'positions', 'kept', 'gateway', 'halt', 'executor',
]);
export const PANELS = Object.freeze([...DATA_PANELS, 'history', 'results', 'fleet-config']);
export function feedAge(feed, now) {
  const receivedAt = feed?.value?.receivedAt ?? feed?.receivedAt;
  if (!validInstant(receivedAt)) return null;
  return Math.max(0, (Date.parse(now) - Date.parse(receivedAt)) / 1000);
}

// Per-field pure selector, with optional prior accepted value for null/error
// retention. Presence, errors and freshness stay independent for every cell.
export function panelState(feed, value, reason, now, lastGood = null, lastGoodReceivedAt = null) {
  if (!validInstant(now)) throw new TypeError('A current instant is required');
  if (reason && !REASONS.includes(reason)) throw new TypeError('Unknown panel reason');
  // Older P2 history envelopes used a reason for successful compaction.
  // Compaction is metadata; its presence cannot hide receipt age or a stall.
  if (reason === 'history_compacted' && feed?.value?.schema === CONTRACTS.contracts.history) reason = null;
  const age = feedAge(feed, now);
  const receivedAt = feed?.value?.receivedAt ?? feed?.receivedAt ?? null;
  if (value == null && feed?.reason === 'feed_not_received') return {
    state: 'not reported', ageSeconds: null, reason: 'feed_not_received', value: null, retained: false, valueReceivedAt: null,
  };
  if (feed?.reason || reason) {
    const shown = value ?? lastGood;
    const valueReceivedAt = value == null && lastGood != null ? lastGoodReceivedAt : receivedAt;
    const retained = shown != null && (Boolean(feed?.reason) || value == null);
    return {
      // Non-identical replays are advisory; exact duplicates never set a feed
      // rejection. Explicit field/session failures and failed writes are broken.
      state: feed?.reason === 'sequence_replayed' && !reason && shown != null ? 'stale' : 'broken',
      ageSeconds: retained ? (valueReceivedAt ? Math.max(0, (Date.parse(now) - Date.parse(valueReceivedAt)) / 1000) : null) : age,
      reason: feed?.reason || reason, value: shown, retained, valueReceivedAt,
    };
  }
  if (value == null) return { state: 'not reported', ageSeconds: null, reason: null, value: null, retained: false, valueReceivedAt: null };
  const frozenAge = feed?.generatedAdvancedAt ? Math.max(0, (Date.parse(now) - Date.parse(feed.generatedAdvancedAt)) / 1000) : age;
  const frozen = frozenAge >= 60 && frozenAge > age;
  return {
    state: frozen || age >= 60 ? 'stale' : 'fresh', ageSeconds: frozen ? frozenAge : age,
    reason: frozen ? 'producer_frozen' : age >= 60 ? 'snapshot_stale' : null,
    value, retained: false, valueReceivedAt: receivedAt,
  };
}

export function panelStates(feeds, now, previousValues = {}, keepSymbols = feeds['fleet-config']?.value?.desks.keep ?? []) {
  const data = feeds.data?.value;
  const output = {};
  // Fleet policy owns routing. The mandatory safety floor also applies before
  // policy is available. Producer scope is evidence to check, not authority.
  const keep = new Set(['SXR8', 'TSLA', ...keepSymbols]);
  const mismatched = data?.positions?.rows.filter(p => keep.has(p.symbol) !== (p.scope === 'keep') ||
    (keep.has(p.symbol) && p.desk !== null)) ?? [];
  const affectedDesks = new Set(mismatched.flatMap(p => p.desk ? [p.desk] : ['j', 'joe', 'joel']));
  const scopeReason = mismatched.length ? 'source_not_authoritative' : null;
  const sourceReason = field => data?.pnlSources?.[field === 'dayPnl' ? 'day' : field === 'openPnl' ? 'open' : '']?.reason;
  const receiptAge = feedAge(feeds.data, now);
  const generationAnchor = feeds.data?.generatedAdvancedAt === undefined ? data?.receivedAt : feeds.data.generatedAdvancedAt;
  const generationElapsedMs = data ? Math.max(0, Date.parse(now) -
    Date.parse(generationAnchor)) : 0;
  const invalidTiming = data && (!validInstant(data.receivedAt) || !validInstant(generationAnchor));
  // Only an otherwise fresh feed needs independent expiry between receipts.
  // Generation-time gateway failures apply at every feed age; stale/frozen
  // feeds otherwise keep their values and freshness reasons.
  const freshFeed = receiptAge !== null && receiptAge < 60 && generationElapsedMs < GATEWAY_CHECK_MAX_AGE_MS;
  const progress = feeds.data?.gatewayProgress;
  const checkElapsedMs = progress ? Math.max(0, Date.parse(now) - Date.parse(progress.advancedAt)) : null;
  const trackedAgeMs = progress ? progress.initialAgeMs + checkElapsedMs : null;
  const invalidProgress = progress && (!validInstant(progress.advancedAt) || !validInstant(progress.checkedAt) ||
    !Number.isFinite(progress.initialAgeMs) || progress.initialAgeMs < 0);
  const regressed = data && (Date.parse(now) < Date.parse(data.receivedAt) ||
    (progress && Date.parse(now) < Date.parse(progress.advancedAt)));
  const sessionReason = data ? (
    invalidTiming || invalidProgress ? 'contract_invalid' : regressed ? 'clock_regressed' : gatewayReason(data.safety.gateway, data.generatedAt) ||
      (freshFeed ? gatewayReason(data.safety.gateway, data.generatedAt, generationElapsedMs) ||
        (trackedAgeMs !== null && trackedAgeMs >= GATEWAY_CHECK_MAX_AGE_MS ? 'gateway_unconfirmed' : null) : null)
  ) : null;
  const select = (name, feed, value, reason) => {
    output[name] = panelState(feed, value, reason, now, previousValues[name]?.value, previousValues[name]?.valueReceivedAt);
  };
  for (const field of MONEY_FIELDS) select(`today.${field}`, feeds.data, sessionReason || scopeReason ? null : data?.totals[field],
    sessionReason || scopeReason || data?.totals.reasons?.[field] || sourceReason(field));
  select('paperAccount', feeds.data, sessionReason ? null : data?.brokerAccount?.equity, sessionReason || data?.brokerAccount?.reason);
  for (const id of ['j', 'joe', 'joel']) {
    const desk = data?.desks.find(d => d.id === id);
    for (const field of MONEY_FIELDS) select(`desks.${id}.${field}`, feeds.data, sessionReason || affectedDesks.has(id) ? null : desk?.money[field],
      sessionReason || (affectedDesks.has(id) ? scopeReason : desk?.money.reasons?.[field] || sourceReason(field)));
  }
  const positionReason = sessionReason || data?.positions?.reason || scopeReason;
  const rows = sessionReason && data?.positions?.rows.some(p =>
    ['mark', 'marketValue', 'dayPnl', 'openPnl'].some(field => p[field] != null)) ? null : data?.positions?.rows;
  select('positions', feeds.data, rows?.filter(p => !keep.has(p.symbol)), positionReason);
  select('kept', feeds.data, rows?.filter(p => keep.has(p.symbol)), positionReason);
  select('gateway', feeds.data, data?.safety.gateway, sessionReason || data?.safety.gateway?.reason);
  if (data?.safety.gateway) {
    const checkAgeMs = gatewayCheckAgeMs(data.safety.gateway, data.generatedAt, generationElapsedMs);
    output.gateway.ageSeconds = invalidProgress || checkAgeMs === null ? null : Math.max(checkAgeMs, trackedAgeMs ?? 0) / 1000;
  }
  select('halt', feeds.data, data?.safety.halt, data?.safety.halt ? data.safety.haltReason : null);
  const executor = data?.safety.executor;
  select('executor', feeds.data, executor, executor?.reason);
  for (const name of ['history', 'results', 'fleet-config']) {
    select(name, feeds[name], feeds[name]?.value, feeds[name]?.value?.reason);
  }
  return output;
}

export function stateTable(states) {
  return Object.fromEntries(Object.entries(states).map(([k, { state, ageSeconds, reason, retained }]) => [k, { state, ageSeconds, reason, retained }]));
}
