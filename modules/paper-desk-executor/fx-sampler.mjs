import { constants } from 'node:fs';
import { open, rename } from 'node:fs/promises';
import path from 'node:path';
import { openMarketDataSession } from './ib.mjs';
import { ACCOUNT } from './policy.mjs';

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

const SOURCE = 'ib-account-exchange-rate';
const failure = (reason, code) => Object.assign(new Error(reason), { reason, ...(Number.isInteger(code) ? { code } : {}) });
const reasons = new Set(['pending', 'ok', 'timeout', 'missing_quote', 'pacing_rejected', 'quote_failed', 'disconnected', 'invalid_quote', 'sample_failed']);
const keysAre = (value, keys) => value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).sort().join(',') === [...keys].sort().join(',');
function validState(saved) {
  if (!keysAre(saved, ['schema', 'days']) || saved.schema !== 1 || !saved.days || typeof saved.days !== 'object' || Array.isArray(saved.days) || Object.keys(saved.days).length > FX_RETENTION_DAYS) return false;
  return Object.entries(saved.days).every(([date, day]) => {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || !keysAre(day, ['attempts', 'samples']) || !day.attempts || typeof day.attempts !== 'object' || Array.isArray(day.attempts) || Object.keys(day.attempts).length > 27 || !Array.isArray(day.samples) || day.samples.length > 27) return false;
    if (!Object.entries(day.attempts).every(([bucket, attempt]) => {
      if (!/^(?:[0-9]|1[0-9]|2[0-6])$/.test(bucket)
        || !(keysAre(attempt, ['at', 'reason']) || keysAre(attempt, ['at', 'reason', 'code']) && Number.isInteger(attempt.code))
        || !reasons.has(attempt.reason) || !Number.isFinite(Date.parse(attempt.at))) return false;
      const slot = fxSlot(Date.parse(attempt.at));
      return slot.date === date && slot.bucket === Number(bucket);
    })) return false;
    const seen = new Set();
    return day.samples.every(sample => {
      if (!(keysAre(sample, ['rate', 'sampleAt', 'kind'])
        || keysAre(sample, ['rate', 'sampleAt', 'kind', 'source']) && sample.source === SOURCE
        || keysAre(sample, ['rate', 'sampleAt', 'kind', 'source', 'staleFx', 'staleSeconds']) && sample.source === SOURCE
          && sample.staleFx === true && Number.isInteger(sample.staleSeconds) && sample.staleSeconds >= 1800 && sample.staleSeconds <= 86400)
        || typeof sample.rate !== 'string' || !/^\d+\.\d{8}$/.test(sample.rate) || Number(sample.rate) <= 0 || Number(sample.rate) > 100 || !Number.isFinite(Date.parse(sample.sampleAt))) return false;
      const slot = fxSlot(Date.parse(sample.sampleAt));
      if (slot.date !== date || slot.kind !== sample.kind || slot.bucket === null || seen.has(slot.bucket) || day.attempts[slot.bucket]?.reason !== 'ok') return false;
      seen.add(slot.bucket); return true;
    });
  });
}

// Exact decimal -> eight places, rounding ties to even without binary floats.
function accountRate(value) {
  if (typeof value !== 'string' || !/^\d+(?:\.\d+)?$/.test(value)) throw failure('invalid_quote');
  const [whole, fraction = ''] = value.split('.');
  const scale = 100000000n;
  let units = BigInt(whole) * scale + BigInt(fraction.slice(0, 8).padEnd(8, '0'));
  const discarded = fraction.slice(8);
  if (discarded[0] > '5' || discarded[0] === '5' && (/[1-9]/.test(discarded.slice(1)) || units % 2n === 1n)) units++;
  if (units <= 0n) throw failure('invalid_quote');
  return `${units / scale}.${String(units % scale).padStart(8, '0')}`;
}

// IB's account valuation rate needs no market-data subscription. Its receipt
// time, rather than the end callback, is the observation time we can prove.
export async function requestFxSnapshot({ id, signal, runtime = {}, allowed = () => true, now = Date.now }) {
  let session, requested = false;
  try {
    session = await openMarketDataSession(FX_CLIENT_ID, runtime, signal);
    signal.throwIfAborted();
    if (!allowed()) throw failure('timeout');
    const { api, events } = session;
    return await new Promise((resolve, reject) => {
      let eur, usd, sampleAt, settled = false;
      const finish = (error, sample) => {
        if (settled) return;
        settled = true;
        for (const [event, fn] of listeners) api.off(event, fn);
        signal.removeEventListener('abort', abort);
        if (error) reject(error);
        else resolve(sample);
      };
      const abort = () => finish(failure('timeout'));
      const listeners = [
        [events.accountUpdateMulti, (requestId, account, _model, key, value, currency) => {
          if (Number(requestId) !== id || account !== ACCOUNT || key !== 'ExchangeRate') return;
          if (String(currency).toUpperCase() === 'EUR') eur = value;
          if (String(currency).toUpperCase() === 'USD') { usd = value; sampleAt = new Date(now()).toISOString(); }
        }],
        [events.accountUpdateMultiEnd, requestId => {
          if (Number(requestId) !== id) return;
          if (usd === undefined) return finish(failure('missing_quote'));
          if (typeof eur !== 'string' || !/^0*1(?:\.0+)?$/.test(eur)) return finish(failure('invalid_quote'));
          try { finish(null, { rate: accountRate(usd), sampleAt }); }
          catch { finish(failure('invalid_quote')); }
        }],
        [events.error, (_error, code, requestId) => {
          if (Number(requestId) !== id && ![1100, 2110, 504].includes(Number(code))) return;
          finish(failure('quote_failed', Number(code)));
        }],
        [events.disconnected, () => finish(failure('disconnected'))],
      ];
      for (const [event, fn] of listeners) api.on(event, fn);
      signal.addEventListener('abort', abort, { once: true });
      try {
        requested = true;
        api.reqAccountUpdatesMulti(id, ACCOUNT, '', true);
      } catch { finish(failure('quote_failed')); }
    });
  } catch (error) {
    if (signal.aborted) throw failure('timeout');
    if (error.reason) throw error;
    if (error.message === 'market data connection closed') throw failure('disconnected');
    throw failure('quote_failed', [1100, 2110, 504].includes(error.ibCode) ? error.ibCode : undefined);
  } finally {
    // Even a throw/timeout may have opened an account-update subscription.
    if (requested) { try { session.api.cancelAccountUpdatesMulti(id); } catch { /* close disconnects this dedicated client */ } }
    session?.close();
  }
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
        const sample = await Promise.race([request({ id, signal: controller.signal, runtime, now, allowed: () => { const launch = fxSlot(now()); return !closed && launch.date === slot.date && launch.bucket === slot.bucket; } }), timedOut]);
        const completedAt = now();
        // Rate-only injected readers retain their existing receipt-time seam.
        const rate = typeof sample === 'string' ? sample : sample?.rate;
        const sampledAt = typeof sample === 'string' ? completedAt : Date.parse(sample?.sampleAt);
        if (controller.signal.aborted || !Number.isFinite(sampledAt) || sampledAt > completedAt
          || fxSlot(completedAt).date !== slot.date || fxSlot(completedAt).bucket !== slot.bucket
          || fxSlot(sampledAt).date !== slot.date || fxSlot(sampledAt).bucket !== slot.bucket) throw failure('timeout');
        if (typeof rate !== 'string' || !/^\d+\.\d{8}$/.test(rate) || Number(rate) <= 0 || Number(rate) > 100) throw failure('invalid_quote');
        // Only earlier samples in this NY day count; failed attempts never
        // change the contiguous run of exactly equal rate strings.
        let runStart = sampledAt;
        const earlier = day.samples.filter(previous => Date.parse(previous.sampleAt) < sampledAt)
          .sort((a, b) => Date.parse(b.sampleAt) - Date.parse(a.sampleAt));
        for (const previous of earlier) {
          if (previous.rate !== rate) break;
          runStart = Date.parse(previous.sampleAt);
        }
        const staleSeconds = Math.floor((sampledAt - runStart) / 1000);
        day.samples.push({ rate, sampleAt: new Date(sampledAt).toISOString(), kind: slot.kind, source: SOURCE,
          ...(staleSeconds >= 1800 ? { staleFx: true, staleSeconds } : {}) });
        attempt.reason = 'ok'; reason = null;
      } catch (error) {
        attempt.reason = controller.signal.aborted ? 'timeout' : ['timeout', 'missing_quote', 'pacing_rejected', 'quote_failed', 'disconnected', 'invalid_quote'].includes(error.reason) ? error.reason : 'sample_failed';
        if (attempt.reason === 'quote_failed' && Number.isInteger(error.code)) attempt.code = error.code;
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
