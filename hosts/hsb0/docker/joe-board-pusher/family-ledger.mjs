/** Pure, deterministic J-family execution ledger. No broker or wall-clock access. */

const BASE_CURRENCY = "EUR";
const FIXED_PERIOD_START = "2026-09-10T04:00:00Z";
const METHOD = "execution-fifo-net-current-fx";
const OPEN_METHOD = "owned-lots-current-mark-fx";
const DETAIL = "Net of recorded fees; converted at observed FX. Earlier results unavailable.";
const ALWAYS_EXCLUDED = new Set(["SXR8", "TSLA"]);
const QUANTITY_EPSILON = 1e-9;

class LedgerError extends Error {}

function fail(reason) {
  throw new LedgerError(reason);
}

function finiteNumber(value, label) {
  if (
    typeof value !== "number" ||
    !Number.isFinite(value) ||
    Math.abs(value) === Number.MAX_VALUE
  ) {
    fail(`${label} must be a finite broker number`);
  }
  return value;
}

function positiveNumber(value, label) {
  const number = finiteNumber(value, label);
  if (number <= 0) fail(`${label} must be positive`);
  return number;
}

function currencyCode(value, label) {
  if (typeof value !== "string") fail(`${label} is missing`);
  const currency = value.trim().toUpperCase();
  if (!/^[A-Z]{3}$/.test(currency)) fail(`${label} is invalid`);
  return currency;
}

function symbolCode(value, label = "contract symbol") {
  if (typeof value !== "string" || value.trim() === "") fail(`${label} is missing`);
  return value.trim().toUpperCase();
}

function validCalendarParts(year, month, day, hour, minute, second) {
  if (
    !Number.isInteger(year) ||
    month < 1 || month > 12 ||
    day < 1 ||
    hour < 0 || hour > 23 ||
    minute < 0 || minute > 59 ||
    second < 0 || second > 59
  ) return false;
  const lastDay = new Date(Date.UTC(year, month, 0)).getUTCDate();
  return day <= lastDay;
}

function parseIsoInstant(value, label) {
  if (typeof value !== "string") fail(`${label} must be an ISO timestamp`);
  const match = value.match(
    /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?(Z|[+-](\d{2}):(\d{2}))$/
  );
  if (!match) fail(`${label} must be an unambiguous ISO timestamp`);
  const [, y, mo, d, h, mi, s, , zone, offsetHour, offsetMinute] = match;
  const parts = [y, mo, d, h, mi, s].map(Number);
  if (!validCalendarParts(...parts)) fail(`${label} is invalid`);
  if (zone !== "Z") {
    const oh = Number(offsetHour);
    const om = Number(offsetMinute);
    if (oh > 14 || om > 59 || (oh === 14 && om !== 0)) fail(`${label} has an invalid offset`);
  }
  const epoch = Date.parse(value);
  if (!Number.isFinite(epoch)) fail(`${label} is invalid`);
  return epoch;
}

const newYorkFormatter = new Intl.DateTimeFormat("en-CA", {
  timeZone: "America/New_York",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hourCycle: "h23",
});

function newYorkParts(epoch) {
  const result = {};
  for (const part of newYorkFormatter.formatToParts(new Date(epoch))) {
    if (part.type !== "literal") result[part.type] = Number(part.value);
  }
  return [result.year, result.month, result.day, result.hour, result.minute, result.second];
}

function parseNewYorkLocal(parts, label) {
  if (!validCalendarParts(...parts)) fail(`${label} is invalid`);
  const naive = Date.UTC(parts[0], parts[1] - 1, parts[2], parts[3], parts[4], parts[5]);
  const matches = [];
  // Offset candidates are deliberately resolved through IANA data. Two matches mean
  // the local time is in the fall-back fold; no matches mean it is in the spring gap.
  for (let offsetMinutes = -14 * 60; offsetMinutes <= 14 * 60; offsetMinutes += 15) {
    const candidate = naive - offsetMinutes * 60_000;
    if (newYorkParts(candidate).every((value, index) => value === parts[index])) {
      matches.push(candidate);
    }
  }
  if (matches.length !== 1) fail(`${label} is unsupported or ambiguous`);
  return matches[0];
}

function parseExecutionTime(value) {
  if (typeof value !== "string") fail("execution time is missing");
  const ib = value.match(
    /^(\d{4})(\d{2})(\d{2})\s+(\d{2}):(\d{2}):(\d{2})\s+(US\/Eastern|America\/New_York)$/
  );
  if (ib) return parseNewYorkLocal(ib.slice(1, 7).map(Number), "execution time");
  if (/^\d{4}-\d{2}-\d{2}T/.test(value)) return parseIsoInstant(value, "execution time");
  fail("execution time has an unsupported or ambiguous timezone");
}

function normalizedQuantity(value) {
  return Math.abs(value) <= QUANTITY_EPSILON ? 0 : value;
}

function quantitiesEqual(left, right) {
  return Math.abs(left - right) <= QUANTITY_EPSILON;
}

function sideQuantity(execution) {
  const shares = positiveNumber(execution.shares, "execution quantity");
  const side = typeof execution.side === "string" ? execution.side.trim().toUpperCase() : "";
  if (side === "BOT" || side === "BUY") return shares;
  if (side === "SLD" || side === "SELL") return -shares;
  fail("execution side is unsupported");
}

function stableJson(value) {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJson(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

function executionIdentity(record) {
  const execId = record?.execution?.execId;
  if (typeof execId !== "string" || execId.trim() !== execId || execId === "") {
    fail("execution execId is missing or invalid");
  }
  const match = execId.match(/^(.*\.)(\d+)$/);
  if (!match || match[1] === ".") fail("execution execId has no correction segment");
  return { execId, prefix: match[1], revision: BigInt(match[2]) };
}

/** Merge replay batches, deduplicating exact repeats and keeping the latest IB correction. */
export function mergeExecutionRecords(existing = [], incoming = []) {
  if (!Array.isArray(existing) || !Array.isArray(incoming)) {
    fail("execution replay batches must be arrays");
  }
  const exact = new Map();
  const latest = new Map();
  for (const record of [...existing, ...incoming]) {
    if (!record || typeof record !== "object" || !record.contract || !record.execution) {
      fail("execution record is malformed");
    }
    const identity = executionIdentity(record);
    const fingerprint = stableJson(record);
    const priorExact = exact.get(identity.execId);
    if (priorExact !== undefined) {
      if (priorExact !== fingerprint) fail("conflicting duplicate execution ID");
      continue;
    }
    exact.set(identity.execId, fingerprint);
    const prior = latest.get(identity.prefix);
    if (prior && identity.revision === prior.revision && identity.execId !== prior.execId) {
      fail("conflicting execution correction revision");
    }
    if (!prior || identity.revision > prior.revision) {
      latest.set(identity.prefix, { ...identity, record });
    }
  }
  return [...latest.values()]
    .sort((left, right) => left.execId < right.execId ? -1 : left.execId > right.execId ? 1 : 0)
    .map(({ record }) => record);
}

function configSet(values, label, normalize) {
  if (values === undefined && label === "excludedSymbols") return new Set();
  if (!Array.isArray(values) && !(values instanceof Set)) fail(`${label} must be an array or Set`);
  const result = new Set();
  for (const value of values) result.add(normalize(value));
  return result;
}

function clientId(value) {
  if (!Number.isInteger(value) || value < 0) fail("familyClientIds contains an invalid client ID");
  return value;
}

function executionClientId(value) {
  if (!Number.isInteger(value) || value < 0) fail("execution clientId is invalid");
  return value;
}

function targetAccount(value) {
  if (typeof value !== "string" || value.trim() === "") fail("account config is missing");
  return value.trim();
}

function rowBelongsToAccount(row, account) {
  const supplied = row.account ?? row.accountName ?? row.acctNumber;
  return supplied === undefined || supplied === account;
}

function contractDescription(contract) {
  if (!contract || typeof contract !== "object") fail("contract is missing");
  const symbol = symbolCode(contract.symbol);
  const secType = typeof contract.secType === "string" ? contract.secType.trim().toUpperCase() : "";
  if (secType !== "STK") fail("unsupported family secType");
  const multiplier = finiteNumber(contract.multiplier, "STK multiplier");
  // IB decodes an unset/blank stock multiplier as numeric zero. STK semantics make
  // both that decoder sentinel and explicit 1 an effective multiplier of one.
  if (multiplier !== 0 && multiplier !== 1) fail("unsupported STK multiplier");
  const currency = currencyCode(contract.currency, "contract currency");
  const conId = contract.conId;
  let key;
  if (typeof conId === "number" && Number.isFinite(conId) && Number.isInteger(conId) && conId > 0) {
    key = `conId:${conId}`;
  } else if (conId === undefined || conId === null || conId === 0) {
    key = `STK:${symbol}:${currency}`;
  } else {
    fail("contract conId is invalid");
  }
  return {
    key,
    conId: key.startsWith("conId:") ? conId : null,
    symbol,
    secType,
    currency,
    multiplier: 1,
  };
}

function registerContract(registry, description) {
  const prior = registry.get(description.key);
  if (
    prior &&
    (prior.symbol !== description.symbol ||
      prior.secType !== description.secType ||
      prior.currency !== description.currency)
  ) {
    fail("conflicting contract identity");
  }
  if (!prior) registry.set(description.key, description);
  return prior || description;
}

function roundEur(value) {
  const rounded = Math.round((value + Number.EPSILON) * 100) / 100;
  return Object.is(rounded, -0) ? 0 : rounded;
}

function addLot(state, signedQuantity, price) {
  let remaining = normalizedQuantity(signedQuantity);
  while (remaining !== 0 && state.lots.length && Math.sign(state.lots[0].quantity) !== Math.sign(remaining)) {
    const lot = state.lots[0];
    const closed = Math.min(Math.abs(lot.quantity), Math.abs(remaining));
    state.realizedQuote += lot.quantity > 0
      ? (price - lot.price) * closed
      : (lot.price - price) * closed;
    if (lot.quantity > 0) {
      lot.quantity = normalizedQuantity(lot.quantity - closed);
      remaining = normalizedQuantity(remaining + closed);
    } else {
      lot.quantity = normalizedQuantity(lot.quantity + closed);
      remaining = normalizedQuantity(remaining - closed);
    }
    if (lot.quantity === 0) state.lots.shift();
  }
  if (remaining !== 0) state.lots.push({ quantity: remaining, price });
}

function fxTable(fx) {
  if (!fx || typeof fx !== "object") fail("FX snapshot is missing");
  if (currencyCode(fx.baseCurrency, "FX baseCurrency") !== BASE_CURRENCY) {
    fail("FX base currency is not proven EUR");
  }
  parseIsoInstant(fx.observedAt, "FX observedAt");
  if (!fx.rates || typeof fx.rates !== "object" || Array.isArray(fx.rates)) {
    fail("FX rates are missing");
  }
  const rates = new Map();
  for (const [rawCurrency, rawRate] of Object.entries(fx.rates)) {
    const currency = currencyCode(rawCurrency, "FX currency");
    rates.set(currency, positiveNumber(rawRate, `FX rate for ${currency}`));
  }
  if (rates.get(BASE_CURRENCY) !== 1) fail("FX EUR rate must equal 1");
  return {
    rate(currency) {
      const rate = rates.get(currency);
      if (rate === undefined) fail(`missing FX rate for ${currency}`);
      return rate;
    },
  };
}

function commissionIndex(reports, requiredExecIds) {
  if (!Array.isArray(reports)) fail("commissions must be an array");
  const byId = new Map();
  const fingerprints = new Map();
  for (const report of reports) {
    if (!report || typeof report !== "object" || !requiredExecIds.has(report.execId)) continue;
    const fingerprint = stableJson(report);
    if (byId.has(report.execId)) {
      if (fingerprints.get(report.execId) !== fingerprint) fail("conflicting duplicate commission report");
      continue;
    }
    byId.set(report.execId, report);
    fingerprints.set(report.execId, fingerprint);
  }
  return byId;
}

function observedPositionMap(rows, account, excluded, registry) {
  if (!Array.isArray(rows)) fail("positions must be an array");
  const result = new Map();
  for (const row of rows) {
    if (!row || typeof row !== "object") fail("position row is malformed");
    if (!rowBelongsToAccount(row, account)) continue;
    const rawSymbol = symbolCode(row.contract?.symbol, "position contract symbol");
    if (excluded.has(rawSymbol)) continue;
    const contract = registerContract(registry, contractDescription(row.contract));
    const quantity = normalizedQuantity(finiteNumber(row.pos, "observed position quantity"));
    if (result.has(contract.key)) fail("duplicate observed position contract");
    result.set(contract.key, quantity);
  }
  return result;
}

function excludedPositionRows(rows, account, excluded) {
  const result = [];
  const seen = new Set();
  for (const row of rows) {
    if (!row || typeof row !== "object" || !rowBelongsToAccount(row, account)) continue;
    const symbol = symbolCode(row.contract?.symbol, "position contract symbol");
    if (!excluded.has(symbol)) continue;
    const quantity = normalizedQuantity(finiteNumber(row.pos, "observed position quantity"));
    const conId = row.contract?.conId;
    const contractKey = Number.isInteger(conId) && conId > 0
      ? `conId:${conId}`
      : `excluded:${symbol}`;
    if (seen.has(contractKey)) fail("duplicate observed excluded position contract");
    seen.add(contractKey);
    if (quantity !== 0) result.push({ contractKey, symbol, quantity });
  }
  return result.sort((left, right) => left.contractKey.localeCompare(right.contractKey));
}

function portfolioMap(rows, account, excluded, registry) {
  if (!Array.isArray(rows)) fail("portfolio must be an array");
  const result = new Map();
  for (const row of rows) {
    if (!row || typeof row !== "object") fail("portfolio row is malformed");
    if (!rowBelongsToAccount(row, account)) continue;
    const rawSymbol = symbolCode(row.contract?.symbol, "portfolio contract symbol");
    if (excluded.has(rawSymbol)) continue;
    const contract = registerContract(registry, contractDescription(row.contract));
    if (row.symbol !== undefined && symbolCode(row.symbol, "portfolio symbol") !== contract.symbol) {
      fail("portfolio symbol conflicts with contract");
    }
    finiteNumber(row.pos, "portfolio position quantity");
    if (result.has(contract.key)) fail("duplicate portfolio contract");
    result.set(contract.key, row);
  }
  return result;
}

function assertReconciled(replayed, observed) {
  const keys = new Set([...replayed.keys(), ...observed.keys()]);
  for (const key of keys) {
    if (!quantitiesEqual(replayed.get(key) || 0, observed.get(key) || 0)) {
      fail("execution replay does not reconcile with observed broker positions");
    }
  }
}

/** Calculate the verified-period J-family ledger from complete broker evidence. */
export function calculateFamily({
  executions,
  commissions,
  portfolio,
  positions,
  fx,
  account,
  familyClientIds,
  excludedSymbols,
  periodStart,
  virtualEquity = 5000,
  observedAt,
} = {}) {
  try {
    const accountId = targetAccount(account);
    const observedEpoch = parseIsoInstant(observedAt, "observedAt");
    const periodEpoch = parseIsoInstant(periodStart, "periodStart");
    if (periodEpoch !== Date.parse(FIXED_PERIOD_START)) {
      fail(`periodStart must equal ${FIXED_PERIOD_START}`);
    }
    if (observedEpoch < periodEpoch) fail("observedAt predates periodStart");
    const virtualCapital = finiteNumber(virtualEquity, "virtualEquity");
    const familyIds = configSet(familyClientIds, "familyClientIds", clientId);
    if (familyIds.size === 0) fail("familyClientIds must not be empty");
    const configuredExcluded = configSet(excludedSymbols, "excludedSymbols", (value) => symbolCode(value, "excluded symbol"));
    const excluded = new Set([...ALWAYS_EXCLUDED, ...configuredExcluded]);
    const rates = fxTable(fx);
    const merged = mergeExecutionRecords([], executions);
    const registry = new Map();
    const fills = [];

    for (const record of merged) {
      const execution = record.execution;
      if (typeof execution.acctNumber !== "string" || execution.acctNumber.trim() === "") {
        fail("execution account is missing");
      }
      if (execution.acctNumber !== accountId) continue;
      const symbol = symbolCode(record.contract?.symbol);
      if (excluded.has(symbol)) continue;
      const time = parseExecutionTime(execution.time);
      if (time < periodEpoch) continue;
      if (time > observedEpoch) fail("execution occurs after observedAt");
      const contract = registerContract(registry, contractDescription(record.contract));
      const signedQuantity = sideQuantity(execution);
      const price = positiveNumber(execution.price, "execution price");
      const included = familyIds.has(executionClientId(execution.clientId));
      if (included && execution.pendingPriceRevision === true) {
        fail("included execution has a pending price revision");
      }
      fills.push({
        contract,
        execution,
        execId: execution.execId,
        time,
        signedQuantity,
        price,
        included,
      });
    }

    fills.sort((left, right) => left.time - right.time ||
      (left.execId < right.execId ? -1 : left.execId > right.execId ? 1 : 0));

    const requiredCommissionIds = new Set(fills.filter((fill) => fill.included).map((fill) => fill.execId));
    const reportByExecId = commissionIndex(commissions, requiredCommissionIds);
    const replayed = new Map();
    const ownership = new Map();
    const latestFillAt = new Map();
    const familyStates = new Map();
    let commissionExpenseEur = 0;
    let executionCount = 0;

    for (const fill of fills) {
      let owners = ownership.get(fill.contract.key);
      if (!owners) {
        owners = { family: 0, foreign: 0 };
        ownership.set(fill.contract.key, owners);
      }
      if (fill.included && owners.foreign !== 0) {
        fail("ambiguous cross-family ownership on contract");
      }
      if (!fill.included && owners.family !== 0) {
        fail("ambiguous cross-family ownership on contract");
      }
      const owner = fill.included ? "family" : "foreign";
      owners[owner] = normalizedQuantity(owners[owner] + fill.signedQuantity);
      replayed.set(
        fill.contract.key,
        normalizedQuantity((replayed.get(fill.contract.key) || 0) + fill.signedQuantity)
      );
      latestFillAt.set(fill.contract.key, fill.time);
      if (!fill.included) continue;
      const report = reportByExecId.get(fill.execId);
      if (!report) fail("missing commission report for included execution");
      const commission = finiteNumber(report.commission, "commission");
      const commissionCurrency = currencyCode(report.currency, "commission currency");
      commissionExpenseEur += commission * rates.rate(commissionCurrency);
      let state = familyStates.get(fill.contract.key);
      if (!state) {
        state = { contract: fill.contract, lots: [], realizedQuote: 0 };
        familyStates.set(fill.contract.key, state);
      }
      addLot(state, fill.signedQuantity, fill.price);
      executionCount += 1;
    }

    const observed = observedPositionMap(positions, accountId, excluded, registry);
    assertReconciled(replayed, observed);
    if (executionCount === 0 && [...observed.values()].some((quantity) => quantity !== 0)) {
      fail("empty family ledger requires all non-excluded broker positions to be flat");
    }

    const excludedPositions = excludedPositionRows(positions, accountId, excluded);
    const residualNonKeepPositions = [...ownership.entries()]
      .filter(([, owners]) => owners.foreign !== 0)
      .map(([contractKey, owners]) => ({
        contractKey,
        symbol: registry.get(contractKey).symbol,
        quantity: owners.foreign,
      }))
      .sort((left, right) => left.contractKey.localeCompare(right.contractKey));
    const portfolioByContract = portfolioMap(portfolio, accountId, excluded, registry);
    let grossRealizedEur = 0;
    let unrealizedEur = 0;
    const outputPositions = [];

    for (const state of familyStates.values()) {
      const rate = rates.rate(state.contract.currency);
      grossRealizedEur += state.realizedQuote * rate;
      const quantity = normalizedQuantity(
        state.lots.reduce((sum, lot) => sum + lot.quantity, 0)
      );
      if (quantity === 0) continue;
      const quote = portfolioByContract.get(state.contract.key);
      if (!quote) fail("missing portfolio mark for open family lot");
      const mark = positiveNumber(quote.marketPrice, "portfolio marketPrice");
      // Generic portfolio callbacks can carry account/P&L changes without a
      // new price. Only the explicit valid-price clock proves mark freshness.
      const updatedAt = quote.markObservedAt;
      const markEpoch = parseIsoInstant(updatedAt, "portfolio markObservedAt");
      if (markEpoch < latestFillAt.get(state.contract.key)) {
        fail("portfolio mark predates the latest execution");
      }
      let positionOpenEur = 0;
      for (const lot of state.lots) {
        positionOpenEur += (lot.quantity > 0
          ? (mark - lot.price) * lot.quantity
          : (lot.price - mark) * Math.abs(lot.quantity)) * rate;
      }
      unrealizedEur += positionOpenEur;
      outputPositions.push({
        desk: "j",
        symbol: state.contract.symbol,
        side: quantity > 0 ? "Long" : "Short",
        quantity,
        accountingScope: "stage0",
        dayPnl: null,
        openPnl: roundEur(positionOpenEur),
        currency: state.contract.currency,
        mark,
        updatedAt,
        _key: state.contract.key,
      });
    }

    outputPositions.sort((left, right) =>
      left.symbol < right.symbol ? -1 : left.symbol > right.symbol ? 1 :
        left._key < right._key ? -1 : left._key > right._key ? 1 : 0
    );
    for (const row of outputPositions) delete row._key;

    const realizedPnl = roundEur(grossRealizedEur - commissionExpenseEur);
    const unrealizedPnl = roundEur(unrealizedEur);
    if (outputPositions.length) {
      const positionTotal = roundEur(outputPositions.reduce((sum, row) => sum + row.openPnl, 0));
      const roundingDelta = roundEur(unrealizedPnl - positionTotal);
      if (roundingDelta !== 0) {
        const last = outputPositions.at(-1);
        last.openPnl = roundEur(last.openPnl + roundingDelta);
      }
    }
    const totalPnl = roundEur(grossRealizedEur - commissionExpenseEur + unrealizedEur);
    const equity = roundEur(virtualCapital + grossRealizedEur - commissionExpenseEur + unrealizedEur);

    return {
      ok: true,
      equity,
      totalPnl,
      realizedPnl,
      unrealizedPnl,
      positions: outputPositions,
      openPnlEvidence: {
        method: OPEN_METHOD,
        currency: BASE_CURRENCY,
        ownershipCoverage: "complete",
        residualNonKeepPositions,
        excludedPositions,
      },
      accounting: { periodStart: FIXED_PERIOD_START, method: METHOD, detail: DETAIL },
      observedAt,
      executionCount,
    };
  } catch (error) {
    if (error instanceof LedgerError) return { ok: false, reason: error.message };
    return { ok: false, reason: "unexpected family ledger input failure" };
  }
}
