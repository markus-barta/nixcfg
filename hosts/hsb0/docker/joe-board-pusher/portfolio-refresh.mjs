import { contractKey, strictFinite } from "./positions-state.mjs";

/**
 * IB's portfolio subscription is change-driven, not a price heartbeat. Poll
 * source ages independently of socket traffic and request a bounded same-session
 * account download. Only actual finite-price callbacks may advance mark ages.
 * No broker connections, orders, prices or baseline writes originate here.
 */
export function createPortfolioRefreshController({
  refresh,
  onEvent = () => {},
  nowMs = Date.now,
  refreshAfterMs = 240_000,
  responseTimeoutMs = 30_000,
  retryBaseMs = 60_000,
  maxRetryMs = 900_000,
}) {
  for (const value of [refreshAfterMs, responseTimeoutMs, retryBaseMs, maxRetryMs]) {
    if (!Number.isFinite(value) || value <= 0) throw new Error("invalid portfolio refresh interval");
  }
  const excluded = new Set(["SXR8", "TSLA"]);
  let pending = null;
  let failures = 0;
  let nextAttemptAt = 0;

  function defer(reason, at) {
    failures = Math.min(failures + 1, 20);
    const delayMs = Math.min(maxRetryMs, retryBaseMs * 2 ** (failures - 1));
    pending = null;
    nextAttemptAt = at + delayMs;
    onEvent({ event: "portfolio_refresh_deferred", reason, attempt: failures, delayMs });
  }

  return {
    // Called only when the connection supervisor installs a new generation.
    reset() { pending = null; failures = 0; nextAttemptAt = 0; },

    subscriptionConflict(code) {
      // IB also emits 2100 for our own false/true refresh. It is not proof of
      // failure or success: keep the original deadline and require genuine
      // finite-price callbacks after this acknowledgement before recovering.
      if (code === 2100 && pending) {
        pending.cancelAcknowledged = true;
        pending.marksAfter = nowMs();
        onEvent({ event: "portfolio_refresh_cancel_acknowledged", reason: "awaiting_mark_callbacks" });
        return;
      }
      pending = null;
      nextAttemptAt = nowMs() + maxRetryMs;
      onEvent({ event: "portfolio_refresh_deferred", reason: "account_subscription_conflict", delayMs: maxRetryMs });
    },

    tick(snapshot) {
      const at = nowMs();
      if (!snapshot?.gateway || snapshot.positionsCoverage?.status !== "complete") {
        pending = null;
        return false;
      }
      const active = new Map();
      for (const row of snapshot.positionsCoverage.rows || []) {
        const key = contractKey(row.contract);
        const qty = strictFinite(row.pos);
        if (key && qty !== undefined && qty !== 0 && !excluded.has(row.contract?.symbol?.trim())) {
          active.set(key, row);
        }
      }
      const marks = new Map((snapshot.portfolio || []).map((row) => [contractKey(row.contract), row]));
      const observed = (key) => {
        const row = marks.get(key);
        const timestamp = typeof row?.markObservedAt === "string" ? Date.parse(row.markObservedAt) : NaN;
        return strictFinite(row?.marketPrice) !== undefined && timestamp <= at ? timestamp : NaN;
      };
      if (pending) {
        const recovered = pending.keys.every((key) => !active.has(key) || observed(key) >= pending.marksAfter);
        if (recovered) {
          onEvent({ event: "portfolio_refresh_recovered", count: pending.keys.length, elapsedMs: at - pending.at });
          pending = null;
          failures = 0;
          nextAttemptAt = 0;
        } else if (at - pending.at >= responseTimeoutMs) {
          if (pending.cancelAcknowledged) {
            pending = null;
            nextAttemptAt = at + maxRetryMs;
            onEvent({ event: "portfolio_refresh_deferred", reason: "mark_callbacks_missing_after_cancel", delayMs: maxRetryMs });
          } else {
            defer("mark_callbacks_timeout", at);
          }
        }
        return false;
      }
      if (at < nextAttemptAt) return false;
      const stale = [...active.keys()].filter((key) => !Number.isFinite(observed(key)) || at - observed(key) >= refreshAfterMs);
      if (!stale.length) return false;
      pending = { at, marksAfter: at, keys: stale };
      onEvent({ event: "portfolio_refresh_requested", count: stale.length, attempt: failures + 1 });
      try {
        if (refresh() === false) {
          defer("account_refresh_unavailable", at);
          return false;
        }
      } catch {
        defer("account_refresh_failed", at);
        return false;
      }
      return true;
    },
  };
}
