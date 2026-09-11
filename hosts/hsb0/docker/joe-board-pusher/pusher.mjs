#!/usr/bin/env node
/**
 * Read-only paper IB client (clientId 92) → household v1 → HTTPS POST inbox.
 * Never connects to live 4001. Never places orders.
 */
import fs from "node:fs";
import net from "node:net";
import { IBApi, EventName } from "@stoqey/ib";
import {
  EXECUTION_CAPTURE_SCHEMA,
  reconcileExecutionCapture,
} from "./execution-reconciliation.mjs";
import {
  captureFromFamilyLedgerFile,
  capturesFromOfficialWindowEvidence,
  normalizeEconomicCommission,
  normalizeEconomicExecution,
} from "./execution-history.mjs";
import { calculateFamily } from "./family-ledger.mjs";
import {
  createFileFamilyHistoryStore,
  projectBestAvailableHistory,
} from "./family-history.mjs";
import {
  createFamilyHistorySessionAdapter,
  createOfficialHistoryRefresher,
} from "./family-history-session.mjs";
import { readOfficialExecutionWindow } from "./official-window-reader.mjs";
import {
  FAMILY_BASELINE_PERIOD_START,
  createFamilySessionAdapter,
  createFileFamilyStateStore,
} from "./family-state.mjs";
import { projectBook } from "./project.mjs";
import { createConnectionSupervisor } from "./pusher-recovery.mjs";
import { createBrokerSessionAdapter } from "./pusher-state.mjs";

const HOST = "100.64.0.6";
const PORT = 4002;
const LIVE_PORT = 4001;
const CLIENT_ID = 92;
const OFFICIAL_HISTORY_CLIENT_ID = 94;
const ACCOUNT = "DUR970597";
const FAMILY_CLIENT_IDS = [27, 28, 29, 50, 51, 52, 53, 54, 55, 56];
const FAMILY_STATE_PATH = "/var/lib/joe-board-pusher/family-ledger.json";
const FAMILY_HISTORY_PATH = "/var/lib/joe-board-pusher/family-history.json";
const INBOX_URL = "https://cs0.barta.cm/joe/inbox";
const TOKEN_FILE = "/run/secrets/joe-board-push-token";
const RETRY_BASE_MS = 5_000;
const RETRY_MAX_MS = 300_000;
const CONNECT_TIMEOUT_MS = 15_000;
const COMPLETE_SNAPSHOT_TIMEOUT_MS = 60_000;
const HEALTH_INTERVAL_MS = 60_000;
const HEALTH_TIMEOUT_MS = 15_000;
const UPSTREAM_LOSS_DEADLINE_MS = 300_000;

function parseIntervalSec() {
  const raw = process.env.JOE_PUSH_INTERVAL_SEC;
  const n = raw === undefined || raw === "" ? 30 : Number(raw);
  if (!Number.isFinite(n) || n < 5 || n > 3600) return 30;
  return Math.floor(n);
}

const INTERVAL_SEC = parseIntervalSec();
let connectionSupervisor = null;

const adapter = createBrokerSessionAdapter({
  targetAccount: ACCOUNT,
  eventNames: EventName,
  hooks: {
    onConnected({ api }) {
      connectionSupervisor?.socketConnected(api);
      console.log(JSON.stringify({ event: "local_socket_connected", host: HOST, port: PORT, clientId: CLIENT_ID }));
    },
    onDisconnected() {
      console.warn(JSON.stringify({ event: "local_socket_disconnected" }));
    },
    onError(_detail, code, message) {
      if (code && Number(code) >= 2000) return;
      console.warn(JSON.stringify({ event: "ib_error", code, message: String(message).slice(0, 160) }));
    },
    onBrokerNotice({ route, code, state, action }) {
      console.warn(JSON.stringify({ event: "ib_notice", route, code, state, action }));
    },
    onSocketActivity({ api }) {
      connectionSupervisor?.socketActivity(api);
    },
    onStableData({ api, observedAt }) {
      connectionSupervisor?.stable(api);
      console.log(JSON.stringify({ event: "broker_snapshot_complete", observedAt }));
    },
    onReconnectNeeded({ api, reason }) {
      familyAdapter.retire(`broker socket unavailable: ${reason}`);
      familyHistoryAdapter.retire(`broker socket unavailable: ${reason}`);
      connectionSupervisor?.reconnect(api, reason);
    },
    onUpstreamUnavailable({ api, reason }) {
      connectionSupervisor?.upstreamUnavailable(api);
      familyAdapter.upstreamUnavailable(reason);
      familyHistoryAdapter.upstreamUnavailable(reason);
    },
    onResyncNeeded({ reason }) {
      console.warn(JSON.stringify({ event: "ib_resync", reason }));
    },
  },
});

const familyStateStore = createFileFamilyStateStore(FAMILY_STATE_PATH);

const familyAdapter = createFamilySessionAdapter({
  targetAccount: ACCOUNT,
  familyClientIds: FAMILY_CLIENT_IDS,
  excludedSymbols: ["SXR8", "TSLA"],
  periodStart: FAMILY_BASELINE_PERIOD_START,
  calculateFamily,
  eventNames: EventName,
  store: familyStateStore,
  pollIntervalMs: 30_000,
  requestTimeoutMs: 20_000,
  fxFreshMs: 300_000,
  requestManagedAccounts: false,
  getVerifiedHistoryState: () => familyHistoryAdapter.inspectState(),
  hooks: {
    onUnavailable(reason) {
      console.warn(JSON.stringify({ event: "family_unavailable", reason }));
    },
    onLedgerUpdated({ changed, observedAt }) {
      if (changed) console.log(JSON.stringify({ event: "family_ledger_updated", observedAt }));
    },
  },
});

const familyHistoryAdapter = createFamilyHistorySessionAdapter({
  targetAccount: ACCOUNT,
  brokerClientId: CLIENT_ID,
  familyClientIds: FAMILY_CLIENT_IDS,
  excludedSymbols: ["SXR8", "TSLA"],
  historyStart: FAMILY_BASELINE_PERIOD_START,
  captureSchema: EXECUTION_CAPTURE_SCHEMA,
  captureSourceKind: "paper-api",
  normalizeExecutionRow: normalizeEconomicExecution,
  normalizeCommissionReport: normalizeEconomicCommission,
  reconcileCapture: reconcileExecutionCapture,
  projectHistory: projectBestAvailableHistory,
  eventNames: EventName,
  store: createFileFamilyHistoryStore(FAMILY_HISTORY_PATH),
  loadBootstrapCapture({ targetAccount, classifier, historyStart }) {
    const legacy = familyStateStore.load({
      account: targetAccount,
      periodStart: historyStart,
      classifier,
    });
    if (!legacy.ok) {
      return { ok: false, freshInstall: false, reason: `legacy family ledger is invalid: ${legacy.reason}` };
    }
    if (!legacy.state) {
      return { ok: false, freshInstall: true, reason: "legacy family ledger is absent; starting with unknown past history" };
    }
    return {
      ok: true,
      capture: captureFromFamilyLedgerFile({
        filePath: FAMILY_STATE_PATH,
        window: {
          fromInclusive: legacy.state.periodStart,
          toExclusive: legacy.state.coverageThrough,
        },
        classifier,
      }),
    };
  },
  pollIntervalMs: 30_000,
  requestTimeoutMs: 20_000,
  commissionDrainMs: 3_000,
  retryBaseMs: RETRY_BASE_MS,
  retryMaxMs: RETRY_MAX_MS,
  requestManagedAccounts: false,
  hooks: {
    onSeeded({ capturedAt, executionCount, commissionCount }) {
      console.log(JSON.stringify({
        event: "family_history_seeded",
        capturedAt,
        executionCount,
        commissionCount,
      }));
    },
    onUnavailable(reason) {
      console.warn(JSON.stringify({ event: "family_history_unavailable", reason }));
    },
    onUpdated({ capturedAt, executionCount, commissionCount, missingCommissionCount }) {
      console.log(JSON.stringify({
        event: "family_history_updated",
        capturedAt,
        executionCount,
        commissionCount,
        missingCommissionCount,
      }));
    },
  },
});

const officialHistoryRefresher = createOfficialHistoryRefresher({
  readOfficialExecutionWindow,
  makeCaptures: capturesFromOfficialWindowEvidence,
  importCaptures: (captures, target) => familyHistoryAdapter.importCaptures(captures, target),
  targetAccount: ACCOUNT,
  host: HOST,
  port: PORT,
  clientId: OFFICIAL_HISTORY_CLIENT_ID,
  historyStart: FAMILY_BASELINE_PERIOD_START,
  getHistoryState: () => familyHistoryAdapter.inspectState(),
  retryBaseMs: 15_000,
  retryMaxMs: RETRY_MAX_MS,
  hooks: {
    onUpdated({ captureCount, through }) {
      console.log(JSON.stringify({ event: "official_family_history_updated", captureCount, through }));
    },
    onUnavailable(reason) {
      console.warn(JSON.stringify({ event: "official_family_history_unavailable", reason }));
    },
  },
});

function readToken() {
  try {
    return fs.readFileSync(TOKEN_FILE, "utf8").trim();
  } catch (err) {
    console.error("token file read failed", err?.code || err);
    return "";
  }
}

function portUp(host, port) {
  return new Promise((resolve) => {
    const socket = net.connect({ host, port }, () => {
      socket.destroy();
      resolve(true);
    });
    socket.on("error", () => resolve(false));
    socket.setTimeout(800, () => {
      socket.destroy();
      resolve(false);
    });
  });
}

function bookSnapshot() {
  const broker = adapter.snapshot();
  if (!broker) return null;
  return {
    ...broker,
    source: "joe-board-pusher",
    clientId: CLIENT_ID,
    account: ACCOUNT,
    live4001: false,
  };
}

async function pushOnce() {
  const liveUp = await portUp(HOST, LIVE_PORT);
  if (liveUp) {
    console.warn("live 4001 appears up on host — ignoring; this pusher stays on paper", PORT);
  }

  const book = bookSnapshot();
  if (!book) {
    console.warn(JSON.stringify({ event: "push_skipped", reason: "broker snapshot incomplete" }));
    return { ok: false, error: "broker snapshot incomplete" };
  }
  const family = familyAdapter.project(book);
  if (!family.ok) {
    console.warn(JSON.stringify({ event: "family_projection_unavailable", reason: family.reason }));
  }
  const familyHistory = familyHistoryAdapter.project();
  if (!familyHistory.ok) {
    console.warn(JSON.stringify({ event: "family_history_projection_unavailable", reason: familyHistory.reason }));
  }
  const snap = projectBook(book, {
    halt: false,
    publisherAt: new Date(),
    familyRuntimeEnabled: true,
    family,
    familyHistory,
  });
  if (!snap) {
    console.warn(JSON.stringify({ event: "push_skipped", reason: "broker timestamp unavailable" }));
    return { ok: false, error: "broker timestamp unavailable" };
  }
  const token = readToken();
  if (!token) {
    console.error("push skipped: no token");
    return { ok: false, error: "no token" };
  }

  const res = await fetch(INBOX_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "User-Agent": "joe-board-pusher/1.0",
    },
    body: JSON.stringify(snap),
  });
  const text = await res.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    body = { raw: text.slice(0, 200) };
  }
  const line = {
    ok: res.ok,
    status: res.status,
    equity: snap.totals.equity,
    generatedAt: snap.generatedAt,
    gateway: adapter.connected,
    inbox: body,
  };
  console.log(JSON.stringify(line));
  return line;
}

connectionSupervisor = createConnectionSupervisor({
  createApi: () => new IBApi({ host: HOST, port: PORT, clientId: CLIENT_ID }),
  attachApi(next) {
    adapter.attach(next);
    familyAdapter.attach(next);
    familyHistoryAdapter.attach(next);
  },
  requestHealth(api) {
    api.reqCurrentTime();
  },
  onAttemptFailure(api, reason) {
    if (api) adapter.fail(api, reason);
    console.warn(JSON.stringify({ event: "socket_attempt_failed", reason }));
  },
  onRetryScheduled({ reason, attempt, delayMs }) {
    console.warn(JSON.stringify({ event: "socket_retry_scheduled", reason, attempt, delayMs }));
  },
  baseDelayMs: RETRY_BASE_MS,
  maxDelayMs: RETRY_MAX_MS,
  jitterRatio: 0.2,
  connectTimeoutMs: CONNECT_TIMEOUT_MS,
  snapshotTimeoutMs: COMPLETE_SNAPSHOT_TIMEOUT_MS,
  healthIntervalMs: HEALTH_INTERVAL_MS,
  healthTimeoutMs: HEALTH_TIMEOUT_MS,
  upstreamLossDeadlineMs: UPSTREAM_LOSS_DEADLINE_MS,
});

function shutdown() {
  adapter.retire("shutdown");
  familyAdapter.retire("shutdown");
  familyHistoryAdapter.retire("shutdown");
  officialHistoryRefresher.stop();
  connectionSupervisor.shutdown();
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

connectionSupervisor.start();
officialHistoryRefresher.start();

setTimeout(() => {
  pushOnce().catch((error) => console.error("push error", error.message || error));
}, 8000);

setInterval(() => {
  pushOnce().catch((error) => console.error("push error", error.message || error));
}, INTERVAL_SEC * 1000);

console.log(
  JSON.stringify({
    service: "joe-board-pusher",
    host: HOST,
    port: PORT,
    clientId: CLIENT_ID,
    intervalSec: INTERVAL_SEC,
    inbox: INBOX_URL,
  })
);
