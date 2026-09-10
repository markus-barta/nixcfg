#!/usr/bin/env node
/**
 * Read-only paper IB client (clientId 92) → household v1 → HTTPS POST inbox.
 * Never connects to live 4001. Never places orders.
 */
import fs from "node:fs";
import net from "node:net";
import { IBApi, EventName } from "@stoqey/ib";
import { calculateFamily } from "./family-ledger.mjs";
import {
  FAMILY_BASELINE_PERIOD_START,
  createFamilySessionAdapter,
  createFileFamilyStateStore,
} from "./family-state.mjs";
import { projectBook } from "./project.mjs";
import {
  createBrokerSessionAdapter,
  createReconnectScheduler,
} from "./pusher-state.mjs";

const HOST = "100.64.0.6";
const PORT = 4002;
const LIVE_PORT = 4001;
const CLIENT_ID = 92;
const ACCOUNT = "DUR970597";
const FAMILY_CLIENT_IDS = [27, 28, 29, 50, 51, 52, 53, 54, 55, 56];
const FAMILY_STATE_PATH = "/var/lib/joe-board-pusher/family-ledger.json";
const INBOX_URL = "https://cs0.barta.cm/joe/inbox";
const TOKEN_FILE = "/run/secrets/joe-board-push-token";
const RETRY_MS = 5000;

function parseIntervalSec() {
  const raw = process.env.JOE_PUSH_INTERVAL_SEC;
  const n = raw === undefined || raw === "" ? 30 : Number(raw);
  if (!Number.isFinite(n) || n < 5 || n > 3600) return 30;
  return Math.floor(n);
}

const INTERVAL_SEC = parseIntervalSec();
let ib = null;
const reconnectScheduler = createReconnectScheduler({
  retryMs: RETRY_MS,
  onRetry: () => connect(),
});

function scheduleReconnect() {
  reconnectScheduler.schedule();
}

function requestResync() {
  adapter.retire("invalid broker quantity; resynchronizing");
  familyAdapter.retire("invalid broker quantity; resynchronizing");
  console.warn(JSON.stringify({ event: "ib_resync", reason: "invalid broker quantity" }));
  scheduleReconnect();
}

const adapter = createBrokerSessionAdapter({
  targetAccount: ACCOUNT,
  eventNames: EventName,
  hooks: {
    onConnected() {
      console.log(JSON.stringify({ event: "connected", host: HOST, port: PORT, clientId: CLIENT_ID }));
    },
    onDisconnected() {
      console.warn(JSON.stringify({ event: "disconnected" }));
    },
    onError(_detail, code, message) {
      if (code && Number(code) >= 2000) return;
      console.warn(JSON.stringify({ event: "ib_error", code, message: String(message).slice(0, 160) }));
    },
    onBrokerNotice({ route, code, state, action }) {
      console.warn(JSON.stringify({ event: "ib_notice", route, code, state, action }));
    },
    onReconnectNeeded() {
      scheduleReconnect();
    },
    onResyncNeeded() {
      requestResync();
    },
  },
});

const familyAdapter = createFamilySessionAdapter({
  targetAccount: ACCOUNT,
  familyClientIds: FAMILY_CLIENT_IDS,
  excludedSymbols: ["SXR8", "TSLA"],
  periodStart: FAMILY_BASELINE_PERIOD_START,
  calculateFamily,
  eventNames: EventName,
  store: createFileFamilyStateStore(FAMILY_STATE_PATH),
  pollIntervalMs: 30_000,
  requestTimeoutMs: 20_000,
  fxFreshMs: 300_000,
  requestManagedAccounts: false,
  hooks: {
    onUnavailable(reason) {
      console.warn(JSON.stringify({ event: "family_unavailable", reason }));
    },
    onLedgerUpdated({ changed, observedAt }) {
      if (changed) console.log(JSON.stringify({ event: "family_ledger_updated", observedAt }));
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
  const snap = projectBook(book, {
    halt: false,
    publisherAt: new Date(),
    familyRuntimeEnabled: true,
    family,
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

function connect() {
  if (adapter.connecting || adapter.connected) return;
  const previous = ib;
  let next = null;
  try {
    next = new IBApi({ host: HOST, port: PORT, clientId: CLIENT_ID });
    ib = next;
    adapter.attach(next);
    familyAdapter.attach(next);
    if (previous && previous !== next) {
      try {
        previous.disconnect();
      } catch {}
    }
    next.connect();
  } catch (error) {
    const detail = String(error?.message || error);
    if (next) adapter.fail(next, detail);
    else scheduleReconnect();
  }
}

function shutdown() {
  adapter.retire("shutdown");
  familyAdapter.retire("shutdown");
  try {
    ib?.disconnect();
  } catch {}
  process.exit(0);
}

process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

connect();

setTimeout(() => {
  pushOnce().catch((error) => console.error("push error", error.message || error));
}, 8000);

setInterval(() => {
  pushOnce().catch((error) => console.error("push error", error.message || error));
}, INTERVAL_SEC * 1000);

setInterval(() => {
  if (!adapter.connected && !adapter.connecting) connect();
}, 60000);

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
