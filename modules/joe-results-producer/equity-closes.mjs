// OPS-556 side-file input. No broker, pusher state, ledger or credential reader.
import { constants, openSync, fstatSync, readFileSync, closeSync } from 'node:fs';
import { validDate } from './contracts/schema-validator.mjs';
import { viennaDate } from './results-validation.mjs';

const DESKS = ['j', 'joe', 'joel'];
const SCHEMA = 'inspr.joe.desk-equity-close.v1';
const REASONS = ['no_observation', 'stale', 'inexact', 'restart_gap', 'recorder_gap', 'contract_unsupported'];
const fields = ['schema', 'vienna_day', 'desk', 'closeAt', 'observedAt', 'oldestInputAt', 'equityClose', 'reason', 'maxAgeMs'];
const keys = (v, names) => v && typeof v === 'object' && !Array.isArray(v)
  && Object.keys(v).sort().join(',') === [...names].sort().join(',');
const instant = v => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(v)
  && Number.isFinite(Date.parse(v)) && new Date(v).toISOString() === v;
const decimal = v => typeof v === 'string' && v.length <= 32 && /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]{1,8})?$/.test(v);
function validOutcome(row) {
  if (!keys(row, fields) || row.schema !== SCHEMA || !validDate(row.vienna_day) || !DESKS.includes(row.desk)
    || !instant(row.closeAt) || !Number.isInteger(row.maxAgeMs) || row.maxAgeMs < 10_000 || row.maxAgeMs > 7_200_000
    || row.maxAgeMs % 2000 !== 0) return false;
  const boundary = Date.parse(row.closeAt), next = new Date(Date.parse(`${row.vienna_day}T12:00:00Z`) + 86400_000).toISOString().slice(0, 10);
  if (viennaDate(row.closeAt) !== next || viennaDate(new Date(boundary - 1).toISOString()) !== row.vienna_day) return false;
  if (row.equityClose === null) return REASONS.includes(row.reason) && row.observedAt === null && row.oldestInputAt === null;
  return row.reason === null && keys(row.equityClose, ['amount', 'currency']) && row.equityClose.currency === 'EUR'
    && decimal(row.equityClose.amount) && instant(row.observedAt) && instant(row.oldestInputAt)
    && viennaDate(row.observedAt) === row.vienna_day && row.oldestInputAt <= row.observedAt && row.observedAt < row.closeAt
    && boundary - Date.parse(row.observedAt) <= row.maxAgeMs;
}

export function readEquityCloses(filename, at, { fromDay } = {}) {
  const diagnostics = [], closes = new Map();
  function result(seen = new Set(), extra = []) {
    const missing = [];
    if (validDate(fromDay)) {
      const today = viennaDate(at);
      for (let noon = Date.parse(`${fromDay}T12:00:00Z`); ; noon += 86400_000) {
        const day = new Date(noon).toISOString().slice(0, 10);
        if (day >= today) break;
        for (const desk of DESKS) if (!seen.has(`${day}:${desk}`)) missing.push({ reason: 'no_record', day, desk });
      }
    }
    return { closes, diagnostics: [...missing, ...diagnostics, ...extra] };
  }
  let fd;
  try {
    fd = openSync(filename, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const info = fstatSync(fd);
    if (!info.isFile() || info.size > 64 * 1024 * 1024) throw new Error('invalid_stream');
    const bytes = readFileSync(fd, 'utf8');
    if (bytes && !bytes.endsWith('\n')) throw new Error('invalid_stream');
    const seen = new Set();
    for (const line of bytes.split('\n').filter(Boolean)) {
      const row = JSON.parse(line);
      if (!validOutcome(row)) throw new Error('invalid_stream');
      const key = `${row.vienna_day}:${row.desk}`;
      if (seen.has(key)) {
        // Even identical duplicate lines are not a unique outcome proof.
        closes.delete(key);
        diagnostics.push({ reason: 'duplicate_outcome', day: row.vienna_day, desk: row.desk });
        continue;
      }
      seen.add(key);
      if (row.vienna_day >= viennaDate(at)) {
        diagnostics.push({ reason: 'day_not_closed', day: row.vienna_day, desk: row.desk });
        continue;
      }
      if (row.equityClose !== null) closes.set(key, row.equityClose);
      if (row.reason) diagnostics.push({ reason: row.reason, day: row.vienna_day, desk: row.desk });
    }
    return result(seen);
  } catch (error) {
    // Never retain a formerly readable value through an unreadable/invalid input.
    closes.clear(); diagnostics.length = 0;
    return result(new Set(), [{ reason: error.code === 'ENOENT' ? 'stream_missing'
      : error.message === 'invalid_stream' || error instanceof SyntaxError ? 'stream_invalid' : 'stream_unreadable' }]);
  } finally { if (fd !== undefined) closeSync(fd); }
}
