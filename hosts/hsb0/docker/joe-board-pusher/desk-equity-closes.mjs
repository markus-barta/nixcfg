// OPS-556: private observation state + a narrow, logically append-only handoff.
import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { copyObservation } from "./v2-stage-handoff.mjs";
import { buildCandidate } from "./v2-stage-worker.mjs";
import { contractRevision } from "./v2-exact-values.mjs";

export const DESKS = ["j", "joe", "joel"];
export const CLOSE_SCHEMA = "inspr.joe.desk-equity-close.v1";
const STATE_SCHEMA = "ops556.desk-equity-observations.v1";
const REASONS = ["no_observation", "stale", "inexact", "restart_gap", "recorder_gap", "contract_unsupported"];
const keys = (v, names) => v && typeof v === "object" && !Array.isArray(v)
  && Object.keys(v).sort().join(",") === [...names].sort().join(",");
export const validDay = v => typeof v === "string" && /^\d{4}-\d{2}-\d{2}$/.test(v)
  && Number.isFinite(Date.parse(`${v}T12:00:00Z`)) && new Date(`${v}T12:00:00Z`).toISOString().slice(0, 10) === v;
const instant = v => typeof v === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(v)
  && Number.isFinite(Date.parse(v)) && new Date(v).toISOString() === v;
const decimal = v => typeof v === "string" && v.length <= 32 && /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]{1,8})?$/.test(v);
const formatter = new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Vienna", year: "numeric", month: "2-digit", day: "2-digit" });
export function viennaDay(at) {
  if (!instant(at)) throw new Error("invalid_clock");
  const p = Object.fromEntries(formatter.formatToParts(new Date(at)).map(p => [p.type, p.value]));
  return `${p.year}-${p.month}-${p.day}`;
}
export const nextDay = day => new Date(Date.parse(`${day}T12:00:00Z`) + 86400_000).toISOString().slice(0, 10);
export function closeBoundary(day) {
  if (!validDay(day)) throw new Error("invalid_day");
  const next = nextDay(day);
  // Search civil dates, not elapsed 24-hour periods (23/25-hour DST days).
  let ms = Date.parse(`${next}T00:00:00Z`) - 3 * 3600_000;
  while (viennaDay(new Date(ms).toISOString()) < next) ms += 3600_000;
  return new Date(ms).toISOString();
}

// Four publication intervals allow poll/push drift and a missed push.
// pusher.mjs passes its actual INTERVAL_SEC; compose-spec.nix pins it to 30 s.
export function closeMaxAgeMs(intervalSec) {
  if (!Number.isInteger(intervalSec) || intervalSec < 5 || intervalSec > 3600) throw new Error("invalid_cadence");
  return Math.min(4 * intervalSec * 1000, 300_000);
}

const outcomeFields = ["schema", "vienna_day", "desk", "closeAt", "observedAt", "oldestInputAt", "equityClose", "reason", "maxAgeMs"];
export function validOutcome(row) {
  if (!keys(row, outcomeFields) || row.schema !== CLOSE_SCHEMA || !validDay(row.vienna_day) || !DESKS.includes(row.desk)
    || row.closeAt !== closeBoundary(row.vienna_day) || !Number.isSafeInteger(row.maxAgeMs)
    || row.maxAgeMs < 10_000 || row.maxAgeMs > 7_200_000 || row.maxAgeMs % 2000 !== 0) return false;
  if (row.equityClose === null) return REASONS.includes(row.reason) && row.observedAt === null && row.oldestInputAt === null;
  return row.reason === null && keys(row.equityClose, ["amount", "currency"]) && row.equityClose.currency === "EUR"
    && decimal(row.equityClose.amount) && instant(row.observedAt) && instant(row.oldestInputAt)
    && viennaDay(row.observedAt) === row.vienna_day && row.oldestInputAt <= row.observedAt && row.observedAt < row.closeAt
    && Date.parse(row.closeAt) - Date.parse(row.observedAt) <= row.maxAgeMs;
}
const outcomeKey = row => `${row.vienna_day}:${row.desk}`;
const canonicalOutcome = row => JSON.stringify(outcomeFields.map(key => key === "equityClose" && row[key]
  ? [row[key].amount, row[key].currency] : row[key]));

function read(filename) {
  let fd;
  try {
    fd = fs.openSync(filename, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    const info = fs.fstatSync(fd);
    if (!info.isFile() || info.size > 64 * 1024 * 1024) throw new Error("invalid_file");
    return fs.readFileSync(fd, "utf8");
  } catch (error) { if (error.code === "ENOENT") return null; throw error; }
  finally { if (fd !== undefined) fs.closeSync(fd); }
}

export function atomicWrite(filename, bytes, io = fs) {
  const temp = `${filename}.${randomUUID()}.tmp`;
  try {
    const fd = io.openSync(temp, "wx", 0o600);
    try { io.writeFileSync(fd, bytes); io.fsyncSync(fd); } finally { io.closeSync(fd); }
    io.renameSync(temp, filename);
    const dir = io.openSync(path.dirname(filename), "r");
    try { io.fsyncSync(dir); } finally { io.closeSync(dir); }
  } catch (error) {
    try { io.unlinkSync(temp); } catch { /* Preserve the original storage error. */ }
    throw error;
  }
}

function syncDirectory(filename) {
  const dir = fs.openSync(path.dirname(filename), "r");
  try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
}

// Only our atomic writer's UUID names, never arbitrary files or symlinks.
function cleanStaleTemps(filename) {
  const dir = path.dirname(filename), prefix = path.basename(filename) + ".";
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
  catch (error) { if (error.code === "ENOENT") return; throw error; }
  for (const entry of entries) {
    if (entry.isFile() && entry.name.startsWith(prefix)
      && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.tmp$/.test(entry.name.slice(prefix.length))) {
      fs.unlinkSync(path.join(dir, entry.name));
    }
  }
}

function boundedDiagnostic(report) {
  const last = new Map();
  return event => {
    const at = Date.now(), previous = last.get(event.reason);
    if (previous !== undefined && at - previous < 15 * 60_000) return;
    last.set(event.reason, at);
    report(event);
  };
}

function readOutcomes(filename) {
  const bytes = read(filename) ?? "";
  if (bytes && !bytes.endsWith("\n")) throw new Error("invalid_stream");
  const existing = new Map();
  for (const line of bytes.split("\n").filter(Boolean)) {
    const row = JSON.parse(line);
    if (!validOutcome(row) || existing.has(outcomeKey(row))) throw new Error("invalid_stream");
    existing.set(outcomeKey(row), row);
  }
  return { bytes, existing };
}

export function createOutcomeStore(filename, diagnostic = () => {}) {
  return {
    append(rows) {
      const { bytes, existing } = readOutcomes(filename);
      let suffix = "", accepted = true;
      for (const row of rows) {
        if (!validOutcome(row)) throw new Error("invalid_outcome");
        const key = outcomeKey(row), previous = existing.get(key);
        if (previous) {
          if (canonicalOutcome(previous) !== canonicalOutcome(row)) {
            diagnostic({ event: "desk_equity_close", reason: "outcome_conflict", day: row.vienna_day, desk: row.desk });
            accepted = false;
          }
          continue;
        }
        existing.set(key, row); suffix += JSON.stringify(row) + "\n";
      }
      // Replace atomically while preserving every committed byte in the prefix.
      if (suffix) atomicWrite(filename, bytes + suffix);
      // A prior rename may have succeeded before its directory fsync failed.
      // Replay must settle that durability before the private state advances.
      else if (rows.length) syncDirectory(filename);
      return accepted;
    },
  };
}

const emptyDesks = () => Object.fromEntries(DESKS.map(id => [id, { seen: false, lastExact: null, unavailableReason: null }]));
function validState(s) {
  return keys(s, ["schema", "firstDay", "day", "lastTickAt", "apiHighWater", "desks"])
    && s.schema === STATE_SCHEMA && validDay(s.firstDay) && validDay(s.day) && instant(s.lastTickAt)
    && viennaDay(s.lastTickAt) === s.day && (s.apiHighWater === null || instant(s.apiHighWater)) && keys(s.desks, DESKS)
    && DESKS.every(id => {
      const row = s.desks[id], exact = row?.lastExact;
      return (keys(row, ["seen", "lastExact"]) || keys(row, ["seen", "lastExact", "unavailableReason"]))
        && (row.unavailableReason === undefined || row.unavailableReason === null
          || row.seen && ["inexact", "contract_unsupported"].includes(row.unavailableReason))
        && typeof row.seen === "boolean" && (exact === null
        || row.seen && keys(exact, ["amount", "observedAt", "oldestInputAt"]) && decimal(exact.amount)
          && instant(exact.observedAt) && instant(exact.oldestInputAt) && exact.oldestInputAt <= exact.observedAt
          && viennaDay(exact.observedAt) === s.day && exact.observedAt <= s.lastTickAt);
    });
}

export function createDeskEquityCloseRecorder({ firstDay, intervalSec, statePath, outcomePath,
  diagnostic = event => console.warn(JSON.stringify(event)), revision = contractRevision() } = {}) {
  diagnostic = boundedDiagnostic(diagnostic);
  if (!validDay(firstDay)) {
    diagnostic({ event: "desk_equity_close", reason: firstDay ? "start_guard_invalid" : "start_guard_unset" });
    return { observe: () => false };
  }
  const maxAgeMs = closeMaxAgeMs(intervalSec), outcomes = createOutcomeStore(outcomePath, diagnostic);
  let firstAttemptDay, cleaned = false;
  return {
    observe(source, at = new Date().toISOString()) {
      try {
        const today = viennaDay(at);
        firstAttemptDay ??= today;
        if (!cleaned) {
          cleanStaleTemps(statePath); cleanStaleTemps(outcomePath); cleaned = true;
        }
        const bytes = read(statePath);
        let state = bytes === null ? { schema: STATE_SCHEMA, firstDay, day: today, lastTickAt: at, apiHighWater: null, desks: emptyDesks() } : JSON.parse(bytes);
        if (!validState(state)) throw new Error("invalid_state");
        if (state.firstDay !== firstDay) throw new Error("start_guard_changed");
        if (at < state.lastTickAt) throw new Error("clock_regressed");
        const observation = source?.book && revision >= 10 ? copyObservation(source, revision) : null;
        // Validate at delivery time, but attribute by the valuation's own clock.
        const live = observation && buildCandidate(1, at, observation, at, state.apiHighWater, revision);
        const bookAt = observation?.bookTs ?? source?.book?.ts;
        const bookDay = instant(bookAt) ? viennaDay(bookAt) : null;
        function credit(desks, day) {
          if (day < firstDay || !source?.book) return;
          for (const desk of DESKS) {
            const row = desks[desk], evidence = observation?.exactValues?.desks?.[desk];
            const money = live?.desks.find(row => row.id === desk)?.money.equity;
            const observedDay = instant(evidence?.observedAt) ? viennaDay(evidence.observedAt) : null;
            if (bookDay === day || observedDay === day) {
              row.seen = true; row.unavailableReason = revision < 10 ? "contract_unsupported" : "inexact";
            }
            if (money && observedDay === day && (!row.lastExact || evidence.observedAt > row.lastExact.observedAt)) {
              row.lastExact = { amount: money.amount, observedAt: evidence.observedAt, oldestInputAt: evidence.oldestInputAt };
            }
          }
        }
        if (today > state.day) {
          const rows = [], committed = readOutcomes(outcomePath).existing;
          for (let day = state.day; day < today; day = nextDay(day)) {
            if (day < firstDay) continue;
            const closeAt = closeBoundary(day);
            const closingDesks = day === state.day ? state.desks : emptyDesks();
            // A 23:59:58 valuation delivered at 00:00:02 still closes yesterday.
            credit(closingDesks, day);
            for (const desk of DESKS) {
              // The handoff commits first. A crash can lose the late-delivered
              // observation or this process's gap classification; replay the
              // committed outcome rather than make a second close decision.
              const previous = committed.get(`${day}:${desk}`);
              if (previous) { rows.push(previous); continue; }
              const old = closingDesks[desk], exact = old.lastExact;
              let reason;
              if (exact) reason = Date.parse(closeAt) - Date.parse(exact.observedAt) > maxAgeMs ? "stale" : null;
              else if (old.seen) reason = old.unavailableReason ?? "inexact";
              else if (day === state.day) reason = "no_observation";
              else reason = day < firstAttemptDay ? "restart_gap" : "recorder_gap";
              rows.push({ schema: CLOSE_SCHEMA, vienna_day: day, desk, closeAt,
                observedAt: reason ? null : exact.observedAt, oldestInputAt: reason ? null : exact.oldestInputAt,
                equityClose: reason ? null : { amount: exact.amount, currency: "EUR" }, reason, maxAgeMs });
            }
          }
          // Outcomes commit before advancing state. A crash replays the same keys.
          if (!outcomes.append(rows)) throw new Error("outcome_conflict");
          state.day = today; state.desks = emptyDesks();
        }
        credit(state.desks, today);
        const checkedAt = observation?.apiReplyCheckedAt;
        if (instant(checkedAt) && checkedAt <= at && (!state.apiHighWater || checkedAt > state.apiHighWater)) state.apiHighWater = checkedAt;
        state.lastTickAt = at;
        atomicWrite(statePath, JSON.stringify(state) + "\n");
        return true;
      } catch (error) {
        const reason = ["start_guard_changed", "clock_regressed", "invalid_state", "outcome_conflict"].includes(error.message) ? error.message : "storage_or_observation_unavailable";
        diagnostic({ event: "desk_equity_close", reason });
        return false;
      }
    },
  };
}
