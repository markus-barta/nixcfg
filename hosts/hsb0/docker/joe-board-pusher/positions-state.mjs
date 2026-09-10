/** IB position subscription lifecycle → account-matched rows keyed by contract identity. */

export const J_DESK_SYMBOLS = new Set(["INTC"]);
export const JOEL_DESK_SYMBOLS = new Set(["SXR8", "TSLA"]);

/** Reject null/empty-string/NaN; only accept genuinely finite supplied numbers. */
export function strictFinite(value) {
  if (value === null || value === undefined) return undefined;
  if (typeof value === "string" && value.trim() === "") return undefined;
  if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
  const n = Number(value);
  return Number.isFinite(n) ? n : undefined;
}

export function isConnectionFailure(code, message) {
  return code === 502 || /ECONNREFUSED|connect/i.test(String(message || ""));
}

export function contractKey(contract) {
  if (!contract || typeof contract !== "object") return "invalid";
  if (contract.conId) return `conId:${contract.conId}`;
  return [
    contract.secType || "",
    contract.symbol || "",
    contract.exchange || "",
    contract.primaryExch || "",
    contract.currency || "",
  ].join("|");
}

export function deskForSymbol(symbol) {
  if (J_DESK_SYMBOLS.has(symbol)) return "j";
  if (JOEL_DESK_SYMBOLS.has(symbol)) return "joel";
  return null;
}

export function createPositionTracker(targetAccount) {
  const rows = new Map();
  let status = "unavailable";
  let epoch = 0;

  function resetRows() {
    rows.clear();
  }

  function bumpEpoch() {
    epoch += 1;
    return epoch;
  }

  function matchesAccount(account) {
    return account === targetAccount;
  }

  function isLive(sessionEpoch) {
    return sessionEpoch === epoch;
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
      status = "partial";
      return epoch;
    },

    onDisconnected() {
      bumpEpoch();
      resetRows();
      status = "unavailable";
      return epoch;
    },

    onPosition(sessionEpoch, account, contract, pos, avgCost, observedAt) {
      if (!isLive(sessionEpoch)) return;
      if (!matchesAccount(account)) return;
      if (status === "unavailable") status = "partial";
      const key = contractKey(contract);
      const qty = strictFinite(pos);
      if (qty === undefined) return;
      if (qty === 0) {
        rows.delete(key);
        return;
      }
      const prev = rows.get(key) || {};
      const nextAvg = strictFinite(avgCost);
      rows.set(key, {
        account,
        contract,
        symbol: contract.symbol,
        secType: contract.secType,
        exchange: contract.exchange || contract.primaryExch || null,
        currency: contract.currency || null,
        pos: qty,
        avgCost: nextAvg !== undefined ? nextAvg : prev.avgCost,
        marketPrice: prev.marketPrice,
        marketValue: prev.marketValue,
        unrealizedPNL: prev.unrealizedPNL,
        realizedPNL: prev.realizedPNL,
        observedAt: observedAt || prev.observedAt || null,
      });
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
      if (!isLive(sessionEpoch)) return;
      if (accountName !== targetAccount) return;
      const key = contractKey(contract);
      const qty = strictFinite(pos);
      const prev = rows.get(key);
      if (!prev) {
        if (qty === undefined || qty === 0) return;
        rows.set(key, {
          account: targetAccount,
          contract,
          symbol: contract.symbol,
          secType: contract.secType,
          exchange: contract.exchange || contract.primaryExch || null,
          currency: contract.currency || null,
          pos: qty,
          avgCost: strictFinite(avgCost) ?? null,
          marketPrice: strictFinite(marketPrice) ?? null,
          marketValue: strictFinite(marketValue) ?? null,
          unrealizedPNL: strictFinite(unrealizedPNL) ?? null,
          realizedPNL: strictFinite(realizedPNL) ?? null,
          observedAt: observedAt || null,
        });
        return;
      }
      const nextAvg = strictFinite(avgCost);
      const nextPrice = strictFinite(marketPrice);
      const nextMv = strictFinite(marketValue);
      const nextUnreal = strictFinite(unrealizedPNL);
      const nextReal = strictFinite(realizedPNL);
      rows.set(key, {
        ...prev,
        pos: qty !== undefined ? qty : prev.pos,
        avgCost: nextAvg !== undefined ? nextAvg : prev.avgCost,
        marketPrice: nextPrice !== undefined ? nextPrice : prev.marketPrice,
        marketValue: nextMv !== undefined ? nextMv : prev.marketValue,
        unrealizedPNL: nextUnreal !== undefined ? nextUnreal : prev.unrealizedPNL,
        realizedPNL: nextReal !== undefined ? nextReal : prev.realizedPNL,
        observedAt: observedAt || prev.observedAt,
      });
    },

    onPositionEnd(sessionEpoch) {
      if (!isLive(sessionEpoch)) return;
      if (status === "partial") status = "complete";
    },

    listRows() {
      return [...rows.values()];
    },

    snapshot() {
      return { status, rows: this.listRows() };
    },
  };
}
