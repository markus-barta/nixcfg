import {
  contractKey,
  createPositionTracker,
  currencyCode,
  isConnectionFailure,
  strictFinite,
} from "./positions-state.mjs";

function cloneRow(row) {
  return {
    ...row,
    contract: row.contract && typeof row.contract === "object" ? { ...row.contract } : row.contract,
  };
}

function cloneRows(rows) {
  return rows.map(cloneRow);
}

function emptyWorkingState() {
  return {
    accounts: null,
    summary: {},
    netLiquidationSeen: false,
    accountComplete: false,
    summaryComplete: false,
    openOrders: [],
    portfolio: new Map(),
  };
}

function validSummaryNumber(value) {
  if (typeof value !== "string" || value.trim() === "") return false;
  const parsed = Number(value);
  return Number.isFinite(parsed) && Math.abs(parsed) !== Number.MAX_VALUE;
}

/**
 * Generation-scoped adapter for @stoqey/ib EventEmitter callbacks.
 * This module has no network, process, or timer side effects and is safe to import in tests.
 */
export function createBrokerSessionAdapter({
  targetAccount,
  eventNames,
  accountSummaryRequestId = 9501,
  now = () => new Date().toISOString(),
  hooks = {},
}) {
  const tracker = createPositionTracker(targetAccount);
  let trackerEpoch = tracker.epoch;
  let activeApi = null;
  let generation = 0;
  let connected = false;
  let connecting = false;
  let working = null;
  let published = null;
  let lastError = null;
  let gatewayLastSeenAt = null;

  function isCurrent(api, attachedGeneration) {
    return activeApi === api && generation === attachedGeneration;
  }

  function observeBroker() {
    const observedAt = now();
    gatewayLastSeenAt = observedAt;
    return observedAt;
  }

  function publishCurrent(observedAt) {
    if (!working || tracker.status !== "complete" || !working.netLiquidationSeen ||
        !working.accountComplete || !working.summaryComplete) {
      return false;
    }
    const rows = cloneRows(tracker.listRows());
    const portfolio = cloneRows([...working.portfolio.values()]);
    published = {
      ts: observedAt,
      accounts: working.accounts,
      summary: { ...working.summary },
      positions: cloneRows(rows),
      portfolio,
      openOrders: working.openOrders.map((row) => ({ ...row })),
    };
    return true;
  }

  function publishIfReady(observedAt) {
    if (tracker.status === "complete" && working?.netLiquidationSeen &&
        working.accountComplete && working.summaryComplete) {
      publishCurrent(observedAt);
    }
  }

  function invalidate(reason, requestReconnect) {
    generation += 1;
    activeApi = null;
    connected = false;
    connecting = false;
    working = null;
    lastError = reason;
    trackerEpoch = tracker.onDisconnected();
    if (requestReconnect) hooks.onReconnectNeeded?.();
  }

  function handleInvalidData() {
    hooks.onResyncNeeded?.();
  }

  function updateAccountingPortfolio(
    contract,
    pos,
    marketPrice,
    marketValue,
    avgCost,
    unrealizedPNL,
    realizedPNL,
    observedAt
  ) {
    const key = contractKey(contract);
    const qty = strictFinite(pos);
    if (!working || !key || qty === undefined) return;
    const prev = working.portfolio.get(key) || {};
    const nextCurrency = currencyCode(contract.currency);
    const nextPrice = strictFinite(marketPrice);
    const nextMarketValue = strictFinite(marketValue);
    const nextAvgCost = strictFinite(avgCost);
    const nextUnrealized = strictFinite(unrealizedPNL);
    const nextRealized = strictFinite(realizedPNL);
    const row = {
      ...prev,
      account: targetAccount,
      contract,
      symbol: contract.symbol.trim(),
      secType: contract.secType,
      exchange: contract.exchange || contract.primaryExch || null,
      currency: nextCurrency !== undefined ? nextCurrency : prev.currency,
      pos: qty,
      marketPrice: nextPrice !== undefined ? nextPrice : prev.marketPrice,
      marketValue: nextMarketValue !== undefined ? nextMarketValue : prev.marketValue,
      avgCost: nextAvgCost !== undefined ? nextAvgCost : prev.avgCost,
      unrealizedPNL: nextUnrealized !== undefined ? nextUnrealized : prev.unrealizedPNL,
      realizedPNL: nextRealized !== undefined ? nextRealized : prev.realizedPNL,
      observedAt,
    };
    if (qty !== 0 || row.realizedPNL) working.portfolio.set(key, row);
    else working.portfolio.delete(key);
  }

  function attach(api) {
    generation += 1;
    const attachedGeneration = generation;
    activeApi = api;
    connected = false;
    connecting = true;
    working = null;
    trackerEpoch = tracker.onDisconnected();

    const guard = (handler) => (...args) => {
      if (!isCurrent(api, attachedGeneration)) return;
      handler(...args);
    };

    api.on(eventNames.connected, guard(() => {
      connected = true;
      connecting = false;
      lastError = null;
      working = emptyWorkingState();
      trackerEpoch = tracker.onConnected();
      observeBroker();
      hooks.onConnected?.();
      try {
        api.reqManagedAccts();
        api.reqPositions();
        api.reqAllOpenOrders();
        api.reqAccountSummary(
          accountSummaryRequestId,
          "All",
          "NetLiquidation,TotalCashValue,BuyingPower,AccountType"
        );
        api.reqAccountUpdates(true, targetAccount);
      } catch (error) {
        const detail = String(error?.message || error);
        hooks.onError?.(detail);
        invalidate(detail, true);
      }
    }));

    api.on(eventNames.disconnected, guard(() => {
      hooks.onDisconnected?.("disconnected");
      invalidate("disconnected", true);
    }));

    api.on(eventNames.error, guard((error, code) => {
      const message = String(error?.message || error);
      const detail = `${code || ""} ${message}`.trim();
      hooks.onError?.(detail, code, message);
      if (isConnectionFailure(code, message)) {
        invalidate(detail, true);
      } else {
        lastError = detail;
      }
    }));

    api.on(eventNames.managedAccounts, guard((accounts) => {
      if (!working) return;
      working.accounts = accounts;
      if (!tracker.onManagedAccounts(trackerEpoch, accounts)) return;
      const observedAt = observeBroker();
      publishIfReady(observedAt);
    }));

    api.on(eventNames.accountSummary, guard((reqId, account, tag, value, currency) => {
      if (!working || reqId !== accountSummaryRequestId || account !== targetAccount) return;
      working.summary[tag] = { account, value, currency };
      if (tag === "NetLiquidation" && validSummaryNumber(value)) {
        working.netLiquidationSeen = true;
      }
      const observedAt = observeBroker();
      publishIfReady(observedAt);
    }));

    api.on(eventNames.accountSummaryEnd, guard((reqId) => {
      if (!working || reqId !== accountSummaryRequestId) return;
      working.summaryComplete = true;
      const observedAt = observeBroker();
      publishIfReady(observedAt);
    }));

    api.on(eventNames.position, guard((account, contract, pos, avgCost) => {
      if (!working || account !== targetAccount) return;
      const observedAt = now();
      const result = tracker.onPosition(
        trackerEpoch,
        account,
        contract,
        pos,
        avgCost,
        observedAt
      );
      if (result.invalid) {
        handleInvalidData();
        return;
      }
      if (!result.accepted) return;
      gatewayLastSeenAt = observedAt;
      publishIfReady(observedAt);
    }));

    api.on(eventNames.positionEnd, guard(() => {
      if (!working) return;
      if (!tracker.onPositionEnd(trackerEpoch)) return;
      const observedAt = observeBroker();
      publishIfReady(observedAt);
    }));

    api.on(eventNames.updatePortfolio, guard((
      contract,
      pos,
      marketPrice,
      marketValue,
      avgCost,
      unrealizedPNL,
      realizedPNL,
      accountName
    ) => {
      if (!working || accountName !== targetAccount) return;
      const observedAt = now();
      const result = tracker.onPortfolio(
        trackerEpoch,
        accountName,
        contract,
        pos,
        marketPrice,
        marketValue,
        avgCost,
        unrealizedPNL,
        realizedPNL,
        observedAt
      );
      if (result.invalid) {
        handleInvalidData();
        return;
      }
      if (!result.accepted) return;
      updateAccountingPortfolio(
        contract,
        pos,
        marketPrice,
        marketValue,
        avgCost,
        unrealizedPNL,
        realizedPNL,
        observedAt
      );
      gatewayLastSeenAt = observedAt;
      publishIfReady(observedAt);
    }));

    api.on(eventNames.accountDownloadEnd, guard((account) => {
      if (!working || account !== targetAccount) return;
      working.accountComplete = true;
      const observedAt = observeBroker();
      publishIfReady(observedAt);
    }));

    api.on(eventNames.openOrder, guard((orderId, contract, order, orderState) => {
      if (!working || order?.account !== targetAccount) return;
      const row = {
        orderId,
        symbol: contract?.symbol,
        action: order.action,
        qty: order.totalQuantity,
        type: order.orderType,
        status: orderState?.status,
        account: order.account,
      };
      working.openOrders = working.openOrders.filter((item) => item.orderId !== orderId);
      working.openOrders.push(row);
    }));

    return attachedGeneration;
  }

  return {
    attach,

    retire(reason = "reconnecting") {
      invalidate(reason, false);
    },

    fail(api, reason) {
      if (api !== activeApi) return;
      invalidate(reason, true);
    },

    get connected() {
      return connected;
    },

    get connecting() {
      return connecting;
    },

    snapshot() {
      if (!published) return null;
      const coverage = tracker.snapshot();
      return {
        ...published,
        accounts: published.accounts,
        summary: { ...published.summary },
        positions: cloneRows(published.positions),
        portfolio: cloneRows(published.portfolio),
        openOrders: published.openOrders.map((row) => ({ ...row })),
        positionsCoverage: {
          status: coverage.status,
          rows: coverage.status === "complete" ? cloneRows(coverage.rows) : [],
        },
        gateway: connected,
        gatewayLastSeenAt,
        lastError,
      };
    },
  };
}
