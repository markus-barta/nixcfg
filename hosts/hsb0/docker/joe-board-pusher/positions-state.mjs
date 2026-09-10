/** IB position subscription lifecycle → account-matched rows keyed by contract identity. */

export const J_DESK_SYMBOLS = new Set(["INTC"]);
export const JOEL_DESK_SYMBOLS = new Set(["SXR8", "TSLA"]);

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

  function resetRows() {
    rows.clear();
  }

  function matchesAccount(account) {
    return account === targetAccount;
  }

  return {
    get status() {
      return status;
    },

    onConnected() {
      resetRows();
      status = "partial";
    },

    onDisconnected() {
      resetRows();
      status = "unavailable";
    },

    onPosition(account, contract, pos, avgCost, observedAt) {
      if (!matchesAccount(account)) return;
      if (status === "unavailable") status = "partial";
      const key = contractKey(contract);
      const qty = Number(pos);
      if (!Number.isFinite(qty) || qty === 0) {
        rows.delete(key);
        return;
      }
      const prev = rows.get(key) || {};
      rows.set(key, {
        account,
        contract,
        symbol: contract.symbol,
        secType: contract.secType,
        exchange: contract.exchange || contract.primaryExch || null,
        currency: contract.currency || null,
        pos: qty,
        avgCost: Number.isFinite(Number(avgCost)) ? Number(avgCost) : prev.avgCost,
        marketPrice: prev.marketPrice,
        marketValue: prev.marketValue,
        unrealizedPNL: prev.unrealizedPNL,
        realizedPNL: prev.realizedPNL,
        observedAt: observedAt || prev.observedAt || null,
      });
    },

    onPortfolio(contract, pos, marketPrice, marketValue, avgCost, unrealizedPNL, realizedPNL, observedAt) {
      const key = contractKey(contract);
      const qty = Number(pos);
      const prev = rows.get(key);
      if (!prev) {
        if (!Number.isFinite(qty) || qty === 0) return;
        rows.set(key, {
          account: targetAccount,
          contract,
          symbol: contract.symbol,
          secType: contract.secType,
          exchange: contract.exchange || contract.primaryExch || null,
          currency: contract.currency || null,
          pos: qty,
          avgCost: Number.isFinite(Number(avgCost)) ? Number(avgCost) : null,
          marketPrice: Number.isFinite(Number(marketPrice)) ? Number(marketPrice) : null,
          marketValue: Number.isFinite(Number(marketValue)) ? Number(marketValue) : null,
          unrealizedPNL: Number.isFinite(Number(unrealizedPNL)) ? Number(unrealizedPNL) : null,
          realizedPNL: Number.isFinite(Number(realizedPNL)) ? Number(realizedPNL) : null,
          observedAt: observedAt || null,
        });
        return;
      }
      rows.set(key, {
        ...prev,
        pos: Number.isFinite(qty) ? qty : prev.pos,
        avgCost: Number.isFinite(Number(avgCost)) ? Number(avgCost) : prev.avgCost,
        marketPrice: Number.isFinite(Number(marketPrice)) ? Number(marketPrice) : prev.marketPrice,
        marketValue: Number.isFinite(Number(marketValue)) ? Number(marketValue) : prev.marketValue,
        unrealizedPNL: Number.isFinite(Number(unrealizedPNL)) ? Number(unrealizedPNL) : prev.unrealizedPNL,
        realizedPNL: Number.isFinite(Number(realizedPNL)) ? Number(realizedPNL) : prev.realizedPNL,
        observedAt: observedAt || prev.observedAt,
      });
    },

    onPositionEnd() {
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
