// Bounded scalar evidence only. No broker, ledger, filesystem or contract imports.
export const MONEY_FIELDS = ["equity", "dayPnl", "openPnl", "totalPnl"];
export const exactDeskAction = money => MONEY_FIELDS.every(field => money[field] !== null)
  ? "Paper desk values are available."
  : MONEY_FIELDS.some(field => money[field] !== null)
    ? "Some paper desk values are unavailable." : "Valuation is not exact yet.";
const DESKS = ["j", "joe", "joel"];
const POSITION_FIELDS = ["quantity", "mark", "marketValue", "openPnl"];
const MAX_AGE_MS = 300_000;
const decimalPattern = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]{1,8})?$/;
export const contractRevision = (value = process.env.JOE_V2_CONTRACT_REV) => value === "10" ? 10 : 9;
const instant = value => typeof value === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(value)
  && Number.isFinite(Date.parse(value)) && new Date(value).toISOString() === value;
const fresh = (at, now) => instant(at) && Date.parse(now) >= Date.parse(at) && Date.parse(now) - Date.parse(at) <= MAX_AGE_MS;
const canonical = value => {
  const ms = typeof value === "string" ? Date.parse(value) : NaN;
  return Number.isFinite(ms) ? new Date(ms).toISOString() : null;
};
const nyParts = value => Object.fromEntries(new Intl.DateTimeFormat("en-CA", {
  timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
}).formatToParts(new Date(value)).map(part => [part.type, part.value]));
const sameNewYorkPeriod = (at, period) => {
  if (!instant(at) || !instant(period)) return false;
  const a = nyParts(at), p = nyParts(period);
  return ["year", "month", "day"].every(key => a[key] === p[key])
    && p.hour === "00" && p.minute === "00" && p.second === "00" && period.endsWith(".000Z");
};
// Never round an IB price/rate to fit the wire's eight-decimal precision.
export function decimal(value) {
  if (typeof value === "string") return value.length <= 32 && decimalPattern.test(value) ? value : null;
  if (typeof value !== "number" || !Number.isFinite(value) || Math.abs(value) === Number.MAX_VALUE) return null;
  const raw = String(Object.is(value, -0) ? 0 : value);
  if (raw.length <= 32 && decimalPattern.test(raw)) return raw;
  const expanded = value.toFixed(8);
  return expanded.length <= 32 && decimalPattern.test(expanded) && Number(expanded) === value ? expanded : null;
}
const money = (amount, currency = "EUR", fx = null) => {
  const value = decimal(amount);
  return value === null ? null : { amount: value, currency, ...(fx ? { fx } : {}) };
};
const units = value => {
  const [whole, fraction = ""] = value.split(".");
  return BigInt(whole + fraction.padEnd(8, "0"));
};
const amountFromUnits = value => {
  const digits = (value < 0n ? -value : value).toString().padStart(9, "0");
  return `${value < 0n ? "-" : ""}${digits.slice(0, -8)}.${digits.slice(-8)}`;
};
const closed = (value, keys) => value && typeof value === "object" && !Array.isArray(value)
  && Object.keys(value).every(key => keys.includes(key));
const keys = (value, names) => closed(value, names) && Object.keys(value).length === names.length;
const nullableDecimal = value => value === null || decimal(value) === value;
const nullableInstant = value => value === null || instant(value);
const validFx = value => value === null || value === false || (keys(value, ["base", "quote", "rate", "source", "observedAt"])
  && /^[A-Z]{3}$/.test(value.base) && value.quote === "EUR" && nullableDecimal(value.rate)
  && typeof value.source === "string" && value.source.length > 0 && value.source.length <= 80 && nullableInstant(value.observedAt));
const copyFx = value => value && typeof value === "object" ? {
  base: value.base, quote: value.quote, rate: decimal(value.rate),
  source: value.source, observedAt: canonical(value.observedAt),
} : value;

function copyDay(day) {
  const source = day?.source;
  const proof = day?.evidence;
  const period = canonical(source?.periodStart);
  const baseline = canonical(proof?.sourceObservedAt);
  const oldest = canonical(proof?.oldestSourceObservedAt);
  const proved = canonical(proof?.proofObservedAt);
  // The day producer's durable baseline state machine proves the boundary;
  // a proxy, reseed, missed snapshot or malformed proof cannot become exact.
  if (day?.ok !== true || source?.status !== "available" || source.method !== "sod-virtual-equity"
    || source.sodSource !== "new_york_midnight_exact" || source.approximate !== false
    || source.currency !== "EUR" || source.scope !== "virtual-desks" || !period || !baseline || !oldest || !proved
    || baseline > period || oldest > baseline || proved < period
    || !Number.isSafeInteger(proof.maxAgeMs) || proof.maxAgeMs <= 0 || !Number.isSafeInteger(proof.ageAtBoundaryMs)
    || proof.ageAtBoundaryMs < 0 || proof.ageAtBoundaryMs > proof.maxAgeMs
    || proof.ageAtBoundaryMs !== Date.parse(period) - Date.parse(oldest)
    || !/^[0-9a-f]{64}$/.test(proof.historyRevision || "") || typeof proof.historyRevisionMethod !== "string") return null;
  const at = canonical(source.observedAt);
  const values = Object.fromEntries(DESKS.map(id => [id, decimal(day.values?.[id])]));
  if (!at || !sameNewYorkPeriod(at, period) || proved > at || Object.values(values).some(value => value === null)
    || decimal(day.values?.total) === null || DESKS.reduce((sum, id) => sum + units(values[id]), 0n) !== units(decimal(day.values.total))) return null;
  const sodFx = proof.sodFx == null ? null : Object.fromEntries(DESKS.map(id => {
    const fx = copyFx(proof.sodFx[id]);
    return [id, fx === null ? null : validFx(fx) && fx && fx.rate && units(fx.rate) > 0n
      && instant(fx.observedAt) && fx.observedAt >= oldest && fx.observedAt <= baseline ? fx : false];
  }));
  return { observedAt: at, periodStart: period, values, sodFx };
}

export function copyExactValues({ book, deskEquities, dayPnl } = {}) {
  const desks = Object.fromEntries(DESKS.map(id => {
    const row = deskEquities?.phaseBDesks?.[id];
    if (row?.reconciled !== true) return [id, { reconciled: false }];
    const fx = copyFx(row.fx);
    return [id, { reconciled: true, base: decimal(row.base), equity: decimal(row.equity),
      openPnl: decimal(row.openPnl), totalPnl: decimal(row.totalPnl),
      observedAt: canonical(row.observedAt),
      oldestInputAt: [canonical(row.oldestInputAt), canonical(book?.positionsCoverage?.observedAt)].every(Boolean)
        ? [canonical(row.oldestInputAt), canonical(book.positionsCoverage.observedAt)].sort()[0] : null, fx }];
  }));
  const callbacks = new Map();
  for (const row of book?.portfolio || []) {
    const conId = row?.contract?.conId;
    if (!Number.isSafeInteger(conId) || conId <= 0) continue;
    // Duplicate callbacks cannot prove which contract observation is current.
    callbacks.set(conId, callbacks.has(conId) ? null : row);
  }
  const positions = (book?.positions || []).filter(row => row.pos !== 0).map(row => {
    const callback = callbacks.get(row.contract?.conId);
    const currency = callback?.currency ?? callback?.contract?.currency;
    if (!callback || callback.symbol !== row.symbol || callback.pos !== row.pos
      || !/^[A-Z]{3}$/.test(currency || "")) return null;
    const clocks = callback.portfolioFieldObservedAt;
    // Only explicit per-field callback clocks prove monetary input ages.
    return { currency, updatedAt: canonical(callback.observedAt),
      values: { quantity: decimal(callback.pos), mark: decimal(callback.marketPrice),
        marketValue: decimal(callback.marketValue), openPnl: decimal(callback.unrealizedPNL) },
      observedAt: Object.fromEntries(POSITION_FIELDS.map(field => [field, canonical(clocks?.[field])])) };
  });
  return { desks, day: copyDay(dayPnl), positions };
}

export function validExactValues(value, count) {
  return keys(value, ["desks", "day", "positions"]) && keys(value.desks, DESKS) && DESKS.every(id => {
    const row = value.desks[id];
    return row?.reconciled === false ? keys(row, ["reconciled"]) : row?.reconciled === true
      && keys(row, ["reconciled", "base", "equity", "openPnl", "totalPnl", "observedAt", "oldestInputAt", "fx"])
      && [row.base, row.equity, row.openPnl, row.totalPnl].every(nullableDecimal)
      && [row.observedAt, row.oldestInputAt].every(nullableInstant) && validFx(row.fx);
  }) && (value.day === null || (keys(value.day, ["observedAt", "periodStart", "values", "sodFx"])
    && sameNewYorkPeriod(value.day.observedAt, value.day.periodStart) && keys(value.day.values, DESKS)
    && (value.day.sodFx === null || keys(value.day.sodFx, DESKS) && Object.values(value.day.sodFx).every(validFx))
    && Object.values(value.day.values).every(item => typeof item === "string" && decimal(item) === item)))
    && Array.isArray(value.positions) && value.positions.length === count && value.positions.every(row => row === null
      || (keys(row, ["currency", "updatedAt", "values", "observedAt"]) && /^[A-Z]{3}$/.test(row.currency)
        && nullableInstant(row.updatedAt) && keys(row.values, POSITION_FIELDS) && Object.values(row.values).every(nullableDecimal)
        && keys(row.observedAt, POSITION_FIELDS) && Object.values(row.observedAt).every(nullableInstant)));
}
const source = (kind, value, reason, observedAt, periodStart) => ({
  status: value ? "available" : "unavailable", method: value ? kind === "day" ? "sod-virtual-equity" : "owned-lots-current-mark-fx" : null,
  currency: "EUR", scope: "virtual-desks", observedAt: value ? observedAt : null,
  ...(kind === "day" ? { periodStart: value ? periodStart : null } : {}), ...(!value ? { reason } : {}),
});
const sameDayFx = (day, id, fx) => {
  const sodFx = day.sodFx?.[id];
  // DAY subtracts two EUR snapshots. A single rate can describe it only when
  // that rate actually produced both snapshots; legacy SOD has no FX proof.
  if (fx === null) return day.sodFx === null || sodFx === null;
  return sodFx && fx && sodFx.base === fx.base && sodFx.quote === fx.quote
    && sodFx.rate && fx.rate && units(sodFx.rate) > 0n && units(sodFx.rate) === units(fx.rate)
    && instant(sodFx.observedAt) && sodFx.observedAt <= day.periodStart;
};

export function applyExactValues(candidate, observation, generatedAt) {
  const evidence = observation.exactValues;
  const ready = candidate.safety.gateway?.apiSessionReady === true;
  const valid = validExactValues(evidence, observation.positions?.length || 0);
  for (const desk of candidate.desks) {
    const row = valid ? evidence.desks[desk.id] : null;
    let reason = !ready ? "source_unavailable" : row?.reconciled !== true ? "ledger_unreconciled"
      : !fresh(row.observedAt, generatedAt) || !fresh(row.oldestInputAt, generatedAt) || row.oldestInputAt > row.observedAt ? "source_unavailable" : null;
    let fx = row?.fx;
    if (!reason && fx !== null && (!fx || !fx.rate || units(fx.rate) <= 0n || !fresh(fx.observedAt, generatedAt)
      || fx.observedAt > row.observedAt)) reason = "not_exact_yet";
    for (const field of MONEY_FIELDS) {
      const day = valid ? evidence.day : null;
      const fieldReason = reason || (field === "dayPnl" && (!day || !fresh(day.observedAt, generatedAt)
        || day.observedAt !== row.observedAt) ? "sod_missing"
        : field === "dayPnl" && !sameDayFx(day, desk.id, fx) ? "not_exact_yet"
          : field === "totalPnl" && row.base !== "5000" ? "not_exact_yet" : null);
      desk.money[field] = fieldReason ? null : money(field === "dayPnl" ? day.values[desk.id] : row[field], "EUR", fx);
      if (desk.money[field]) delete desk.money.reasons[field];
      else desk.money.reasons[field] = fieldReason || "not_exact_yet";
    }
    if (!Object.keys(desk.money.reasons).length) delete desk.money.reasons;
    desk.action = exactDeskAction(desk.money);
    desk.pnlSources = Object.fromEntries([["day", "dayPnl"], ["open", "openPnl"]].map(([kind, field]) =>
      [kind, source(kind, desk.money[field], desk.money.reasons?.[field], kind === "day" ? evidence?.day?.observedAt : row?.observedAt, evidence?.day?.periodStart)]));
  }
  candidate.totals = { reasons: {} };
  for (const field of MONEY_FIELDS) {
    const parts = candidate.desks.map(desk => desk.money[field]);
    candidate.totals[field] = parts.every(Boolean) ? money(amountFromUnits(parts.reduce((sum, part) => sum + units(part.amount), 0n))) : null;
    if (!candidate.totals[field]) candidate.totals.reasons[field] = candidate.desks.find(desk => !desk.money[field])?.money.reasons[field] || "not_exact_yet";
  }
  if (!Object.keys(candidate.totals.reasons).length) delete candidate.totals.reasons;
  candidate.pnlSources = Object.fromEntries([["day", "dayPnl"], ["open", "openPnl"]].map(([kind, field]) =>
    [kind, source(kind, candidate.totals[field], candidate.totals.reasons?.[field],
      kind === "day" ? evidence?.day?.observedAt : candidate.desks.map(desk => desk.pnlSources.open.observedAt).filter(Boolean).sort()[0], evidence?.day?.periodStart)]));
  candidate.positions.rows.forEach((row, index) => {
    const callback = valid && index < observation.positions.length ? evidence.positions[index] : null;
    const updatedAt = callback?.updatedAt;
    if (instant(updatedAt)) row.updatedAt = updatedAt;
    for (const field of POSITION_FIELDS) {
      const at = callback?.observedAt[field];
      const reason = !ready || candidate.positions.reason === "source_unavailable" ? "source_unavailable" : !callback ? "not_exact_yet"
        : !fresh(at, generatedAt) || !fresh(updatedAt, generatedAt) ? "position_stale" : null;
      const value = callback?.values[field];
      row[field] = reason || value === null || value === undefined ? null
        : field === "quantity" ? value : money(value, callback.currency);
      if (row[field] !== null) delete row.reasons[field];
      else row.reasons[field] = reason || "not_exact_yet";
    }
  });
  return candidate;
}
