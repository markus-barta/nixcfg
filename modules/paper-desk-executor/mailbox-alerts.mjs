import { createHash } from "node:crypto";
import { statSync } from "node:fs";
import { postLocalMessage } from "./local-mailbox-client.mjs";
export { postLocalMessage, DELIVERY_TIMEOUT_MS } from "./local-mailbox-client.mjs";
import { MAX_STATE_BYTES, CAPTURE_DEGRADED_ADMISSION_BYTES } from "./state.mjs";

export const MAX_DELIVERY_ATTEMPTS = 5;
const BACKOFF_MS = [250, 1000, 4000, 15000];

const outageKey = receipt => receipt.outageId ?? `${receipt.code}:${receipt.at}`;
const events = receipt => receipt.resolvedAt ? ["failure", "resolution"] : ["failure"];

export function deliveryHealth(state, configured) {
  if (!configured) return { alertDelivery: "unconfigured" };
  const deliveries = (state.resultsCaptureAlerts ?? []).flatMap(row => events(row).map(event => row.delivery?.[event]));
  const pending = deliveries.some(row => !row || row.status === "pending");
  const failed = deliveries.some(row => row?.status === "failed");
  const lastAttemptAt = deliveries.map(row => row?.lastAttemptAt).filter(Boolean).sort().at(-1);
  return { alertDelivery: failed ? "failed" : pending ? "pending" : "delivered", ...(lastAttemptAt ? { lastAttemptAt } : {}) };
}

export function createAlertDelivery({ socketPath, ledger, exclusive, post = postLocalMessage, now = Date.now, pollMs = 250 }) {
  if (!socketPath || !ledger.beforePrune) return { start() {}, close() {} };
  let closed = false, running = false, timer, cached;
  async function tick() {
    if (closed || running) return;
    running = true;
    try {
      // Snapshot only while no intent is using the ledger; network delivery is
      // deliberately outside that queue. Restart resumes persisted attempts.
      const snapshot = await exclusive(() => {
        // Atomic ledger publication changes the inode. Idle/backoff polls do
        // only a stat instead of repeatedly parsing a degraded 16 MiB ledger.
        const info = statSync(ledger.statePath, { bigint: true });
        const revision = `${info.ino}:${info.mtimeNs}:${info.size}`;
        if (cached?.revision === revision) return cached;
        cached = { revision, state: ledger.load({ initialize: false, readOnly: true }), bytes: Number(info.size) };
        return cached;
      });
      for (const receipt of snapshot.state.resultsCaptureAlerts ?? []) {
        for (const event of events(receipt)) {
          if (closed) return;
          if (event === "resolution" && !["delivered", "failed"].includes(receipt.delivery?.failure?.status)) continue;
          const prior = receipt.delivery?.[event];
          if (prior?.status === "delivered" || prior?.status === "failed" || (prior?.nextAttemptAt ?? 0) > now()) continue;
          const prepared = await exclusive(() => ledger.updateCaptureDelivery(outageKey(receipt), event, current => {
            if (current?.status === "delivered" || current?.status === "failed") return current;
            if ((current?.attempts ?? 0) >= MAX_DELIVERY_ATTEMPTS) return { ...current, status: "failed" };
            const body = current?.body ?? JSON.stringify({ event: event === "failure" ? "results_capture_failed" : "results_capture_resolved",
              code: receipt.code, since: receipt.at, at: event === "failure" ? receipt.at : receipt.resolvedAt,
              ledgerBytes: snapshot.bytes, ledgerCapBytes: MAX_STATE_BYTES,
              newAdmissionsBlocked: snapshot.state.resultsCapture?.ok === false && snapshot.bytes >= CAPTURE_DEGRADED_ADMISSION_BYTES });
            return { ...current, body, status: "pending", attempts: (current?.attempts ?? 0) + 1, lastAttemptAt: new Date(now()).toISOString() };
          }));
          if (!prepared || prepared.status !== "pending") continue;
          const key = createHash("sha256").update(`${outageKey(receipt)}:${event}`).digest("hex");
          let delivered = false;
          try { await post(socketPath, prepared.body, key); delivered = true; } catch { /* Best effort, value-free. */ }
          if (closed) return;
          await exclusive(() => ledger.updateCaptureDelivery(outageKey(receipt), event, current => ({ ...current,
            status: delivered ? "delivered" : current.attempts >= MAX_DELIVERY_ATTEMPTS ? "failed" : "pending",
            nextAttemptAt: now() + (BACKOFF_MS[current.attempts - 1] ?? 15000),
          })));
          // A later poll handles resolution after the outage was delivered or
          // exhausted its budget; it cannot overtake a retried failure.
          break;
        }
      }
    } catch { /* Missing/unwritable ledger cannot escape into any request. */ }
    finally { running = false; }
  }
  return {
    start() { if (!timer) { timer = setInterval(() => { void tick(); }, pollMs); timer.unref(); void tick(); } },
    close() { closed = true; clearInterval(timer); },
  };
}
