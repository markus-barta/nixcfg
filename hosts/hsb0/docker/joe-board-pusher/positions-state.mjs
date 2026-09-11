/** IB position subscription lifecycle → account-matched rows keyed by contract identity. */

export const J_DESK_SYMBOLS = new Set(["INTC"]);
export const JOEL_DESK_SYMBOLS = new Set(["SXR8", "TSLA"]);

/** @stoqey/ib decodes callback quantities and prices as numbers. */
export function strictFinite(value) {
  return typeof value === "number" &&
    Number.isFinite(value) &&
    Math.abs(value) !== Number.MAX_VALUE
    ? value
    : undefined;
}

export function currencyCode(value) {
  if (typeof value !== "string") return undefined;
  const normalized = value.trim().toUpperCase();
  return /^[A-Z]{3}$/.test(normalized) ? normalized : undefined;
}

export function brokerConnectivityState(code) {
  switch (Number(code)) {
    case 1100:
    case 2110:
      return "upstream_lost";
    case 1101:
      return "restored_data_lost";
    case 1102:
      return "restored_data_maintained";
    default:
      return null;
  }
}

export function isConnectionFailure(code, message) {
  return [502, 504].includes(Number(code)) ||
    /ECONNREFUSED|ECONNRESET|EHOSTUNREACH|ENETUNREACH|ETIMEDOUT|EPIPE|\bEOF\b|socket (?:hang up|closed)|connection closed/i.test(
      String(message || "")
    );
}

export function contractKey(contract) {
  if (!contract || typeof contract !== "object") return null;
  const conId = strictFinite(contract.conId);
  if (conId !== undefined && conId > 0) return `conId:${conId}`;
  const symbol = typeof contract.symbol === "string" ? contract.symbol.trim() : "";
  const secType = typeof contract.secType === "string" ? contract.secType.trim() : "";
  if (!symbol || !secType) return null;
  return [
    secType,
    symbol,
    typeof contract.exchange === "string" ? contract.exchange : "",
    typeof contract.primaryExch === "string" ? contract.primaryExch : "",
    currencyCode(contract.currency) || "",
  ].join("|");
}

export function deskForSymbol(symbol) {
  if (J_DESK_SYMBOLS.has(symbol)) return "j";
  if (JOEL_DESK_SYMBOLS.has(symbol)) return "joel";
  return null;
}

function managedAccountSet(accounts) {
  if (typeof accounts !== "string") return new Set();
  return new Set(accounts.split(",").map((account) => account.trim()).filter(Boolean));
}

export function createPositionTracker(targetAccount) {
  const rows = new Map();
  let status = "unavailable";
  let epoch = 0;
  let targetRecognized = false;
  let validCycle = false;
  let endSeen = false;

  function resetRows() {
    rows.clear();
  }

  function bumpEpoch() {
    epoch += 1;
    return epoch;
  }

  function isLive(sessionEpoch) {
    return sessionEpoch === epoch;
  }

  function invalidateCycle() {
    validCycle = false;
    status = "partial";
  }

  function completeIfProven() {
    if (validCycle && targetRecognized && endSeen) {
      status = "complete";
      return true;
    }
    status = "partial";
    return false;
  }

  function validContract(contract) {
    return contractKey(contract) !== null &&
      typeof contract.symbol === "string" &&
      contract.symbol.trim().length > 0;
  }

  return {
    get status() {
      return status;
    },

    get epoch() {
      return epoch;
    },

    isLive,

    onConnected() {
      bumpEpoch();
      resetRows();
      targetRecognized = false;
      validCycle = true;
      endSeen = false;
      status = "partial";
      return epoch;
    },

    onDisconnected() {
      bumpEpoch();
      resetRows();
      targetRecognized = false;
      validCycle = false;
      endSeen = false;
      status = "unavailable";
      return epoch;
    },

    onManagedAccounts(sessionEpoch, accounts) {
      if (!isLive(sessionEpoch)) return false;
      targetRecognized = managedAccountSet(accounts).has(targetAccount);
      completeIfProven();
      return targetRecognized;
    },

    onPosition(sessionEpoch, account, contract, pos, avgCost, observedAt) {
      if (!isLive(sessionEpoch) || account !== targetAccount) return { accepted: false };
      const qty = strictFinite(pos);
      const key = contractKey(contract);
      if (qty === undefined || !key || !validContract(contract)) {
        invalidateCycle();
        return { accepted: false, invalid: true };
      }
      if (qty === 0) {
        rows.delete(key);
        return { accepted: true, removed: true };
      }
      const prev = rows.get(key) || {};
      const nextAvg = strictFinite(avgCost);
      const nextCurrency = currencyCode(contract.currency);
      rows.set(key, {
        ...prev,
        account,
        contract,
        symbol: contract.symbol.trim(),
        secType: contract.secType,
        exchange: contract.exchange || contract.primaryExch || null,
        currency: nextCurrency !== undefined ? nextCurrency : prev.currency,
        pos: qty,
        avgCost: nextAvg !== undefined ? nextAvg : prev.avgCost,
        positionObservedAt: observedAt || prev.positionObservedAt || null,
      });
      return { accepted: true };
    },

    onPortfolio(
      sessionEpoch,
      accountName,
      contract,
      pos,
      marketPrice,
      marketValue,
      avgCost,
      unrealizedPNL,
      realizedPNL,
      observedAt
    ) {
      if (!isLive(sessionEpoch) || accountName !== targetAccount) return { accepted: false };
      const qty = strictFinite(pos);
      const key = contractKey(contract);
      if (qty === undefined || !key || !validContract(contract)) {
        invalidateCycle();
        return { accepted: false, invalid: true };
      }
      if (qty === 0) {
        rows.delete(key);
        return { accepted: true, removed: true };
      }
      const prev = rows.get(key) || {};
      const nextAvg = strictFinite(avgCost);
      const nextPrice = strictFinite(marketPrice);
      const nextMv = strictFinite(marketValue);
      const nextUnreal = strictFinite(unrealizedPNL);
      const nextReal = strictFinite(realizedPNL);
      const nextCurrency = currencyCode(contract.currency);
      rows.set(key, {
        ...prev,
        account: targetAccount,
        contract,
        symbol: contract.symbol.trim(),
        secType: contract.secType,
        exchange: contract.exchange || contract.primaryExch || null,
        currency: nextCurrency !== undefined ? nextCurrency : prev.currency,
        pos: qty,
        avgCost: nextAvg !== undefined ? nextAvg : prev.avgCost,
        marketPrice: nextPrice !== undefined ? nextPrice : prev.marketPrice,
        marketValue: nextMv !== undefined ? nextMv : prev.marketValue,
        unrealizedPNL: nextUnreal !== undefined ? nextUnreal : prev.unrealizedPNL,
        realizedPNL: nextReal !== undefined ? nextReal : prev.realizedPNL,
        positionObservedAt: observedAt || prev.positionObservedAt || null,
        markObservedAt: nextPrice !== undefined
          ? observedAt || prev.markObservedAt || null
          : prev.markObservedAt,
      });
      return { accepted: true, markAccepted: nextPrice !== undefined };
    },

    onPositionEnd(sessionEpoch) {
      if (!isLive(sessionEpoch)) return false;
      endSeen = true;
      return completeIfProven();
    },

    listRows() {
      return [...rows.values()];
    },

    snapshot() {
      return { status, rows: this.listRows() };
    },
  };
}
