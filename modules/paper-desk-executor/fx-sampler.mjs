import { constants } from 'node:fs';
import { open, rename } from 'node:fs/promises';
import path from 'node:path';
import { openMarketDataSession } from './ib.mjs';

export const FX_CLIENT_ID = 709;
export const FX_RETENTION_DAYS = 14;
const MAX_BYTES = 256 * 1024;
const ny = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit', weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });

// Reviewed NYSE cash-equity calendar; no network/calendar IB requests.
// https://ir.theice.com/press/news-details/2025/NYSE-Group-Announces-2026-2027-and-2028-Holiday-and-Early-Closings-Calendar/
// Unknown years fail closed until OPS reviews the next published calendar.
const holidays = {
  2026: '01-01 01-19 02-16 04-03 05-25 06-19 07-03 09-07 11-26 12-25',
  2027: '01-01 01-18 02-15 03-26 05-31 06-18 07-05 09-06 11-25 12-24',
  2028: '01-17 02-21 04-14 05-29 06-19 07-04 09-04 11-23 12-25',
};
const earlyCloses = new Set(['2026-11-27', '2026-12-24', '2027-11-26', '2028-07-03', '2028-11-24']);

// Wall-clock slots in New York, independent of workstation/Vienna DST.
export function fxSlot(epoch) {
  const p = Object.fromEntries(ny.formatToParts(new Date(epoch)).map(p => [p.type, p.value]));
  const date = `${p.year}-${p.month}-${p.day}`, minute = Number(p.hour) * 60 + Number(p.minute);
  const calendarKnown = Object.hasOwn(holidays, p.year);
  const weekday = calendarKnown && !['Sat', 'Sun'].includes(p.weekday) && !holidays[p.year].split(' ').includes(`${p.month}-${p.day}`);
  const rth = weekday && minute >= 570 && minute < (earlyCloses.has(date) ? 780 : 960);
  const bucket = rth ? Math.floor((minute - 570) / 15) : weekday && minute === 965 ? 26 : null;
  return { date, rth, bucket, calendarKnown, kind: bucket === 26 ? 'close' : 'rth' };
}

const failure = reason => Object.assign(new Error(reason), { reason });
const reasons = new Set(['pending', 'ok', 'timeout', 'missing_quote', 'pacing_rejected', 'quote_failed', 'disconnected', 'invalid_quote', 'sample_failed']);
const keysAre = (value, keys) => value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).sort().join(',') === [...keys].sort().join(',');
function validState(saved) {
  if (!keysAre(saved, ['schema', 'days']) || saved.schema !== 1 || !saved.days || typeof saved.days !== 'object' || Array.isArray(saved.days) || Object.keys(saved.days).length > FX_RETENTION_DAYS) return false;
  return Object.entries(saved.days).every(([date, day]) => {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !keysAre(day, ['attempts', 'samples']) || !day.attempts || typeof day.attempts !== 'object' || Array.isArray(day.attempts) || Object.keys(day.attempts).length > 27 || !Array.isArray(day.samples) || day.samples.length > 27) return false;
    if (!Object.entries(day.attempts).every(([bucket, attempt]) => {
      if (!/^(?:[0-9]|1[0-9]|2[0-6])$/.test(bucket) || !keysAre(attempt, ['at', 'reason']) || !reasons.has(attempt.reason) || !Number.isFinite(Date.parse(attempt.at))) return false;
      const slot = fxSlot(Date.parse(attempt.at));
      return slot.date === date && slot.bucket === Number(bucket);
    })) return false;
    const seen = new Set();
    return day.samples.every(sample => {
      if (!keysAre(sample, ['rate', 'sampleAt', 'kind']) || typeof sample.rate !== 'string' || !/^\d+\.\d{8}$/.test(sample.rate) || Number(sample.rate) <= 0 || Number(sample.rate) > 100 || !Number.isFinite(Date.parse(sample.sampleAt))) return false;
      const slot = fxSlot(Date.parse(sample.sampleAt));
      if (slot.date !== date || slot.kind !== sample.kind || slot.bucket === null || seen.has(slot.bucket) || day.attempts[slot.bucket]?.reason !== 'ok') return false;
      seen.add(slot.bucket); return true;
    });
  });
}

// EUR/USD is the IB CASH convention; invert its contemporaneous bid/ask
// midpoint once to obtain a USD -> EUR observation at eight decimal places.
export async function requestFxSnapshot({ id, signal, runtime = {}, allowed = () => true }) {
  let session;
  try {
    session = await openMarketDataSession(FX_CLIENT_ID, runtime, signal);
    signal.throwIfAborted();
    if (!allowed()) throw failure('timeout');
    const { api, events } = session;
    return await new Promise((resolve, reject) => {
      let bid, ask, requested = false, settled = false;
      const finish = (error) => {
        if (settled) return;
        settled = true;
        for (const [event, fn] of listeners) api.off(event, fn);
        signal.removeEventListener('abort', abort);
        // Even an error/timeout/throw may have opened a market-data line.
        if (requested) { try { api.cancelMktData(id); } catch { /* close disconnects this dedicated client */ } }
        if (error) reject(error);
        else resolve((2 / (bid + ask)).toFixed(8));
      };
      const abort = () => finish(failure('timeout'));
      const listeners = [
        [events.tickPrice, (requestId, field, value) => {
          if (Number(requestId) !== id || ![1, 2].includes(Number(field))) return;
          const price = Number(value);
          if (!Number.isFinite(price) || price <= 0) return;
          if (Number(field) === 1) bid = price; else ask = price;
          if (bid && ask && ask >= bid) finish();
        }],
        [events.tickSnapshotEnd, requestId => { if (Number(requestId) === id) finish(failure('missing_quote')); }],
        [events.error, (_error, code, requestId) => {
          if (Number(requestId) !== id && ![100, 1100, 2110].includes(Number(code))) return;
          finish(failure([100, 420].includes(Number(code)) ? 'pacing_rejected' : 'quote_failed'));
        }],
        [events.disconnected, () => finish(failure('disconnected'))],
      ];
      for (const [event, fn] of listeners) api.on(event, fn);
      signal.addEventListener('abort', abort, { once: true });
      try {
        requested = true;
        api.reqMktData(id, { symbol: 'EUR', secType: 'CASH', exchange: 'IDEALPRO', currency: 'USD' }, '', true, false);
      } catch { finish(failure('quote_failed')); }
    });
  } finally { session?.close(); }
}

async function readRegular(filename, limit) {
  const fd = await open(filename, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const info = await fd.stat();
    if (!info.isFile() || info.size > limit) throw failure('invalid_file');
    return await fd.readFile('utf8');
  } finally { await fd.close(); }
}

export function createFxSampler({ root, now = Date.now, request = requestFxSnapshot, timeoutMs = 10_000, runtime, onUpdate = () => {} } = {}) {
  // No ID collision with order/recon, book, quote, or historical readers.
  let configurationReason = null;
  try {
    const parseIds = text => {
      const value = JSON.parse(text || '{}');
      if (!value || typeof value !== 'object' || Array.isArray(value)
        || !Object.values(value).flat().every(id => Number.isInteger(Number(id)) && Number(id) > 0)) throw failure('fx_config_invalid');
      return Object.values(value).flat();
    };
    const configured = [707, 708, ...parseIds(process.env.IB_DESK_CLIENT_IDS), ...parseIds(process.env.IB_DESK_OWNERSHIP_CLIENT_IDS),
      Number(process.env.IB_DESK_BOOK_CLIENT_ID || 708), Number(process.env.IB_DESK_MARKET_DATA_CLIENT_ID || 707)];
    if (configured.some(id => !Number.isInteger(Number(id)) || Number(id) <= 0)) configurationReason = 'fx_config_invalid';
    else if (configured.some(id => Number(id) === FX_CLIENT_ID)) configurationReason = 'fx_client_conflict';
  } catch { configurationReason = 'fx_config_invalid'; }
  const filename = path.join(root, 'results-fx.json');
  const switchPath = path.join(root, 'FX-SAMPLER-OFF');
  let state = { schema: 1, days: {} }, enabled = !configurationReason, reason = configurationReason || 'missing_sample', busy = false, timer, controller, loaded = false, closed = false, lastNotification;
  const snapshot = () => structuredClone({ enabled, reason, days: Object.fromEntries(Object.entries(state.days).map(([date, day]) => [date, { samples: day.samples }])) });
  const notify = () => {
    const value = snapshot(), serialized = JSON.stringify(value);
    if (serialized === lastNotification) return;
    try { onUpdate(value); lastNotification = serialized; } catch { /* Results capture must never reach intent/health logic. */ }
  };
  async function persist() {
    const body = JSON.stringify(state);
    if (Buffer.byteLength(body) > MAX_BYTES) throw failure('state_full');
    const fd = await open(`${filename}.tmp`, constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o600);
    try {
      if (!(await fd.stat()).isFile()) throw failure('invalid_file');
      await fd.writeFile(body); await fd.sync();
    } finally { await fd.close(); }
    await rename(`${filename}.tmp`, filename);
    const directory = await open(root, constants.O_RDONLY);
    try { await directory.sync(); } finally { await directory.close(); }
  }
  async function tick() {
    if (busy || closed) return;
    if (configurationReason) {
      // This configuration cannot recover during this process. Even a failed
      // capture must not cause a ledger read and notification every second.
      if (lastNotification === undefined) { notify(); lastNotification = JSON.stringify(snapshot()); }
      return;
    }
    busy = true;
    try {
      let restored = false;
      if (!loaded) {
        try {
          const saved = JSON.parse(await readRegular(filename, MAX_BYTES));
          if (!validState(saved)) throw failure('invalid_state');
          state = saved;
          const day = saved.days[fxSlot(now()).date];
          const latest = Object.entries(day?.attempts || {}).sort(([a], [b]) => Number(a) - Number(b)).at(-1)?.[1];
          reason = latest?.reason === 'ok' ? null : latest?.reason === 'pending' ? 'missing_sample' : latest?.reason || 'missing_sample';
        } catch (error) { if (error.code !== 'ENOENT') throw failure('state_unavailable'); }
        loaded = true; restored = true;
      }
      const previous = enabled;
      try { await readRegular(switchPath, 1024); enabled = false; }
      catch (error) { enabled = error.code === 'ENOENT'; }
      if (!enabled) { reason = 'disabled'; if (previous) notify(); return; }
      if (!previous) { reason = 'missing_sample'; notify(); }
      else if (restored) notify();
      const slot = fxSlot(now());
      if (!slot.calendarKnown) { reason = 'calendar_unavailable'; if (restored) notify(); return; }
      if (slot.bucket === null) return;
      const day = state.days[slot.date] ||= { attempts: {}, samples: [] };
      if (day.attempts[slot.bucket]) return;
      // Also enforce a rolling 15-minute gap when startup lands late in a
      // bucket. The separately approved 16:05 close remains unconditional.
      const prior = Object.entries(day.attempts).filter(([bucket]) => Number(bucket) < 26).map(([, attempt]) => Date.parse(attempt.at));
      if (slot.kind === 'rth' && prior.some(at => now() - at < 15 * 60_000)) return;
      // Reserve durably BEFORE any IB call. Zero retries is intentional: the
      // approval allows at most one; one total attempt is the stricter ceiling.
      const attempt = day.attempts[slot.bucket] = { at: new Date(now()).toISOString(), reason: 'pending' };
      for (const key of Object.keys(state.days).sort().slice(0, -FX_RETENTION_DAYS)) delete state.days[key];
      await persist();
      // A durable reservation is internal pacing state, never a Results update.
      controller = new AbortController();
      const deadline = setTimeout(() => controller.abort(), timeoutMs);
      let rejectTimeout;
      const timedOut = new Promise((_, reject) => { rejectTimeout = () => reject(failure('timeout')); controller.signal.addEventListener('abort', rejectTimeout, { once: true }); });
      try {
        // Reserved range 920000000..929999999, unrelated to order/recon IDs.
        const id = 920000000 + Math.floor(Date.parse(`${slot.date}T00:00:00Z`) / 86400_000) * 32 + slot.bucket;
        const rate = await Promise.race([request({ id, signal: controller.signal, runtime, allowed: () => { const launch = fxSlot(now()); return !closed && launch.date === slot.date && launch.bucket === slot.bucket; } }), timedOut]);
        const sampledAt = now();
        if (controller.signal.aborted || fxSlot(sampledAt).date !== slot.date || fxSlot(sampledAt).bucket !== slot.bucket) throw failure('timeout');
        if (typeof rate !== 'string' || !/^\d+\.\d{8}$/.test(rate) || Number(rate) <= 0 || Number(rate) > 100) throw failure('invalid_quote');
        day.samples.push({ rate, sampleAt: new Date(sampledAt).toISOString(), kind: slot.kind });
        attempt.reason = 'ok'; reason = null;
      } catch (error) {
        attempt.reason = controller.signal.aborted ? 'timeout' : ['timeout', 'missing_quote', 'pacing_rejected', 'quote_failed', 'disconnected', 'invalid_quote'].includes(error.reason) ? error.reason : 'sample_failed';
        reason = attempt.reason;
      } finally { clearTimeout(deadline); controller.signal.removeEventListener('abort', rejectTimeout); controller = null; }
      await persist(); notify();
    } catch { reason = 'state_unavailable'; notify(); }
    finally { busy = false; }
  }
  return {
    tick, snapshot,
    start() { void tick(); timer = setInterval(() => { void tick(); }, 1000); timer.unref(); },
    close() { closed = true; clearInterval(timer); controller?.abort(); },
  };
}
