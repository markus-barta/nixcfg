import {
  brokerConnectivityState,
  contractKey,
  createPositionTracker,
  currencyCode,
  isConnectionFailure,
  strictFinite,
} from "./positions-state.mjs";

export { createReconnectScheduler } from "./pusher-recovery.mjs";

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
  let socketConnected = false;
  let upstreamConnected = false;
  let connecting = false;
  let resyncing = false;
  let upstreamLossObserved = false;
  let working = null;
  let published = null;
  let publishedGeneration = null;
  let lastError = null;
  let gatewayLastSeenAt = null;

  function isCurrent(api, attachedGeneration) {
    return activeApi === api && generation === attachedGeneration;
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
      positionsCoverage: {
        status: "complete",
        rows: cloneRows(rows),
      },
    };
    publishedGeneration = generation;
    gatewayLastSeenAt = observedAt;
    const becameStable = !upstreamConnected;
    upstreamConnected = true;
    resyncing = false;
    lastError = null;
    if (becameStable) hooks.onStableData?.({ api: activeApi, generation, observedAt });
    return true;
  }

  function publishIfReady(observedAt) {
    if (tracker.status === "complete" && working?.netLiquidationSeen &&
        working.accountComplete && working.summaryComplete) {
      publishCurrent(observedAt);
    }
  }

  function markFinancialUnavailable(reason) {
    upstreamConnected = false;
    resyncing = false;
    working = null;
    lastError = reason;
    trackerEpoch = tracker.onDisconnected();
  }

  function invalidate(api, reason, requestReconnect) {
    generation += 1;
    activeApi = null;
    socketConnected = false;
    connecting = false;
    markFinancialUnavailable(reason);
    if (requestReconnect) hooks.onReconnectNeeded?.({ api, reason });
  }

  function requestCompleteSnapshot(api) {
    if (api !== activeApi || !socketConnected) return false;
    working = emptyWorkingState();
    trackerEpoch = tracker.onConnected();
    upstreamConnected = false;
    resyncing = true;
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
      invalidate(api, detail, true);
      return false;
    }
    return true;
  }

  function handleBrokerNotice(route, code) {
    const numericCode = Number(code);
    const normalizedCode = Number.isInteger(numericCode) ? numericCode : null;
    const state = brokerConnectivityState(normalizedCode);
    if (!state && route !== "info") return false;
    let action = "none";
    if (state === "upstream_lost") {
      action = "local_socket_retained";
    } else if (state) {
      action = upstreamLossObserved
        ? "fresh_generation_scheduled"
        : "ignored_without_observed_loss";
    }
    const notice = {
      route,
      code: normalizedCode,
      state: state || "informational",
      action,
    };
    hooks.onBrokerNotice?.(notice);
    if (!state) return false;

    const reason = `broker ${state} (code ${normalizedCode})`;
    if (state === "upstream_lost") {
      upstreamLossObserved = true;
      if (upstreamConnected || resyncing || working) {
        markFinancialUnavailable(reason);
        hooks.onUpstreamUnavailable?.({ api: activeApi, reason, notice });
      }
      return true;
    }

    if (upstreamLossObserved) {
      upstreamLossObserved = false;
      invalidate(activeApi, reason, true);
    }
    return true;
  }

  function handleInvalidData() {
    const reason = "invalid broker quantity; reconnecting for a fresh generation";
    hooks.onResyncNeeded?.({ reason, api: activeApi });
    invalidate(activeApi, reason, true);
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
      markObservedAt: nextPrice !== undefined
        ? observedAt
        : prev.markObservedAt || null,
    };
    if (qty !== 0 || row.realizedPNL) working.portfolio.set(key, row);
    else working.portfolio.delete(key);
  }

  function attach(api) {
    generation += 1;
    const attachedGeneration = generation;
    activeApi = api;
    socketConnected = false;
    upstreamConnected = false;
    connecting = true;
    resyncing = false;
    upstreamLossObserved = false;
    working = null;
    trackerEpoch = tracker.onDisconnected();

    const guard = (event, handler) => (...args) => {
      if (!isCurrent(api, attachedGeneration)) return;
      hooks.onSocketActivity?.({ api, generation: attachedGeneration, event });
      handler(...args);
    };

    api.on(eventNames.connected, guard("connected", () => {
      socketConnected = true;
      connecting = false;
      hooks.onConnected?.({ api, generation: attachedGeneration });
      requestCompleteSnapshot(api);
    }));

    api.on(eventNames.disconnected, guard("disconnected", () => {
      hooks.onDisconnected?.("disconnected");
      invalidate(api, "disconnected", true);
    }));

    if (eventNames.connectionClosed) {
      api.on(eventNames.connectionClosed, guard("connectionClosed", () => {
        hooks.onDisconnected?.("connectionClosed");
        invalidate(api, "connectionClosed", true);
      }));
    }

    api.on(eventNames.info, guard("info", (_message, code) => {
      handleBrokerNotice("info", code);
    }));

    api.on(eventNames.error, guard("error", (error, code) => {
      const message = String(error?.message || error);
      const detail = `${code || ""} ${message}`.trim();
      if (handleBrokerNotice("error", code)) return;
      hooks.onError?.(detail, code, message);
      if (isConnectionFailure(code, message)) {
        invalidate(api, detail, true);
      } else {
        lastError = detail;
      }
    }));

    api.on(eventNames.managedAccounts, guard("managedAccounts", (accounts) => {
      if (!working) return;
      working.accounts = accounts;
      if (!tracker.onManagedAccounts(trackerEpoch, accounts)) return;
      const observedAt = now();
      publishIfReady(observedAt);
    }));

    api.on(eventNames.accountSummary, guard("accountSummary", (reqId, account, tag, value, currency) => {
      if (!working || reqId !== accountSummaryRequestId || account !== targetAccount) return;
      working.summary[tag] = { account, value, currency };
      if (tag === "NetLiquidation" && validSummaryNumber(value)) {
        working.netLiquidationSeen = true;
      }
      const observedAt = now();
      publishIfReady(observedAt);
    }));

    api.on(eventNames.accountSummaryEnd, guard("accountSummaryEnd", (reqId) => {
      if (!working || reqId !== accountSummaryRequestId) return;
      working.summaryComplete = true;
      const observedAt = now();
      publishIfReady(observedAt);
    }));

    api.on(eventNames.position, guard("position", (account, contract, pos, avgCost) => {
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
      publishIfReady(observedAt);
    }));

    api.on(eventNames.positionEnd, guard("positionEnd", () => {
      if (!working) return;
      if (!tracker.onPositionEnd(trackerEpoch)) return;
      const observedAt = now();
      publishIfReady(observedAt);
    }));

    api.on(eventNames.updatePortfolio, guard("updatePortfolio", (
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
      publishIfReady(observedAt);
    }));

    api.on(eventNames.accountDownloadEnd, guard("accountDownloadEnd", (account) => {
      if (!working || account !== targetAccount) return;
      working.accountComplete = true;
      const observedAt = now();
      publishIfReady(observedAt);
    }));

    api.on(eventNames.openOrder, guard("openOrder", (orderId, contract, order, orderState) => {
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

    if (eventNames.currentTime) {
      api.on(eventNames.currentTime, guard("currentTime", () => {}));
    }

    return attachedGeneration;
  }

  return {
    attach,

    retire(reason = "reconnecting") {
      invalidate(activeApi, reason, false);
    },

    fail(api, reason) {
      if (api !== activeApi) return;
      invalidate(api, reason, true);
    },

    get connected() {
      return upstreamConnected;
    },

    get socketConnected() {
      return socketConnected;
    },

    get upstreamConnected() {
      return upstreamConnected;
    },

    get connecting() {
      return connecting;
    },

    snapshot() {
      if (!published) return null;
      const currentCoverage = tracker.snapshot();
      const coverageAccepted = publishedGeneration === generation &&
        currentCoverage.status === "complete";
      return {
        ...published,
        accounts: published.accounts,
        summary: { ...published.summary },
        positions: cloneRows(published.positions),
        portfolio: cloneRows(published.portfolio),
        openOrders: published.openOrders.map((row) => ({ ...row })),
        positionsCoverage: {
          status: coverageAccepted ? "complete" : "unavailable",
          rows: coverageAccepted ? cloneRows(published.positionsCoverage.rows) : [],
        },
        gateway: upstreamConnected,
        localSocket: socketConnected,
        gatewayLastSeenAt,
        lastError,
      };
    },
  };
}
