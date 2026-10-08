import { createServer as createHttpServer } from "node:http";
import net from "node:net";
import path from "node:path";
import { pathToFileURL } from "node:url";

import {
  activeHalt,
  assertSideEffect,
  brakeUsage,
  digest,
  parseIntent,
  validateKey,
} from "./policy.mjs";
import {
  DEFAULT_PEERS,
  LISTEN_HOST,
  LISTEN_PORT,
  PAPER_PORT,
  assertGatewayHost,
  assertListen,
  assertPaperPort,
  assertPeerAllowlist,
  peerAllowed,
} from "./security.mjs";
import { admitIntent, openLedger } from "./state.mjs";

const BODY_LIMIT = 65_536;

const PUBLIC_ERRORS = new Map([
  ["invalid_schema", "intent schema is invalid"],
  ["unsupported_field", "intent has unsupported field(s)"],
  ["keep_protected", "KEEP symbols can never be traded"],
  ["invalid_order", "order is allowed only for place"],
  ["invalid_intent", "intent validation failed"],
  ["intent_conflict", "intentId was already used with different content"],
  ["body_too_large", "body is too large"],
  ["uncertain", "broker outcome is uncertain; reconcile before another attempt"],
  ["executor_error", "executor operation failed"],
  ["modify_stop_refused", "modify-stop preflight refused"],
]);
function publicFailure(error) {
  const code = error?.code === "uncertain" ? "uncertain"
    : PUBLIC_ERRORS.has(error?.publicCode) ? error.publicCode : "executor_error";
  return { code, reason: code === "modify_stop_refused" ? error.publicReason || PUBLIC_ERRORS.get(code) : PUBLIC_ERRORS.get(code) };
}

function send(response, status, body) {
  const payload = JSON.stringify(body);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
    "cache-control": "no-store",
  });
  response.end(payload);
}

function httpStatus(result) {
  if (result?.status === "ok") return 200;
  if (result?.status === "uncertain") return 409;
  if (result?.status === "rejected") return 422;
  return 500;
}

async function readBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > BODY_LIMIT) {
      const error = new Error("body is too large");
      error.statusCode = 413;
      error.publicCode = "body_too_large";
      throw error;
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

export function probeGateway(host = LISTEN_HOST, port = PAPER_PORT, timeoutMs = 2000) {
  assertGatewayHost(host);
  assertPaperPort(port);
  return new Promise((resolve) => {
    const socket = net.connect({ host, port });
    let settled = false;
    const finish = (reachable) => {
      if (settled) return;
      settled = true;
      socket.removeAllListeners();
      socket.destroy();
      resolve(reachable);
    };
    socket.setTimeout(timeoutMs);
    socket.once("connect", () => finish(true));
    socket.once("timeout", () => finish(false));
    socket.once("error", () => finish(false));
  });
}

function storedResult(record) {
  if (!record?.result) return null;
  const { idempotentReplay: _ignored, ...result } = record.result;
  return result;
}

function claimRecord(state, intent) {
  const hash = digest(intent);
  const prior = state.intents.get(intent.intentId);
  if (prior) {
    if (prior.hash !== hash) {
      const error = new Error("intentId was already used with different content");
      error.statusCode = 409;
      error.publicCode = "intent_conflict";
      error.intentId = intent.intentId;
      throw error;
    }
    if (!prior.result || prior.status === "claimed") {
      return {
        replay: {
          status: "uncertain",
          intentId: intent.intentId,
          reason: "intent was claimed before a durable result; no automatic replay is allowed",
          idempotentReplay: true,
        },
      };
    }
    return { replay: { ...storedResult(prior), idempotentReplay: true } };
  }
  admitIntent(state);
  state.intents.set(intent.intentId, {
    hash,
    action: intent.action,
    desk: intent.desk,
    orderRef: intent.orderRef || null,
    orderId: intent.orderId || null,
    status: "claimed",
    claimedAt: new Date().toISOString(),
  });
  return { hash, replay: null };
}

function finish(state, intent, status, result) {
  const { idempotentReplay: _ignored, ...stored } = result;
  state.intents.set(intent.intentId, {
    ...state.intents.get(intent.intentId),
    status,
    finishedAt: new Date().toISOString(),
    result: stored,
  });
}

export function createServer(options) {
  const testMode = options.testMode === true;
  const gatewayPort = assertPaperPort(options.gatewayPort ?? process.env.IB_DESK_GATEWAY_PORT ?? PAPER_PORT);
  const gatewayHost = assertGatewayHost(options.gatewayHost ?? process.env.IB_DESK_GATEWAY_HOST ?? LISTEN_HOST);
  const listen = assertListen(
    options.listenHost ?? process.env.PAPER_DESK_BIND ?? LISTEN_HOST,
    options.listenPort ?? process.env.PAPER_DESK_PORT ?? LISTEN_PORT,
    { testMode },
  );
  const allowlist = assertPeerAllowlist(
    options.allowlist ?? (process.env.PAPER_DESK_ALLOW ? JSON.parse(process.env.PAPER_DESK_ALLOW) : DEFAULT_PEERS),
    { testMode },
  );
  const ledger = openLedger(options.stateDir ?? process.env.PAPER_DESK_STATE_DIR ?? "/state");
  const execute = options.execute ?? null;
  const gatewayReachable = options.gatewayReachable ?? (() => probeGateway(gatewayHost, gatewayPort));
  let chain = Promise.resolve();

  function logError(error) {
    console.error(error);
    try {
      ledger.audit({ event: "executor_error", error: { name: error?.name, message: String(error?.message || error), stack: error?.stack, code: error?.code } });
    } catch (auditError) { console.error(auditError); }
  }

  function exclusive(work) {
    const run = chain.then(work, work);
    chain = run.then(() => {}, () => {});
    return run;
  }

  async function handle(request, response) {
    const peer = request.socket?.remoteAddress;
    if (!peerAllowed(peer, allowlist)) {
      request.resume();
      send(response, 403, { status: "rejected", reason: "source is not allowed" });
      return;
    }
    try {
      const url = new URL(request.url || "/", "http://paper-desk.local");
      const pathname = url.pathname;
      if (request.method === "GET" && pathname === "/v1/health") {
        const [reachable, body] = await Promise.all([
          Promise.resolve().then(() => gatewayReachable()).then((value) => value === true).catch(() => false),
          exclusive(() => {
            const state = ledger.load();
            return {
              status: "ok",
              gatewayReachable: false,
              gatewayHost,
              gatewayPort,
              account: "DUR970597",
              halt: activeHalt(ledger.haltBody()),
              brakes: brakeUsage(state, Date.now(), { blockOnInitDay: process.env.PAPER_DESK_BLOCK_ON_INIT_DAY === "true" }),
            };
          }),
        ]);
        body.gatewayReachable = reachable;
        send(response, 200, body);
        return;
      }

      if (request.method === "POST" && pathname === "/v1/halt") {
        const raw = await readBody(request);
        let reason = "halt";
        if (raw.trim()) {
          let parsed;
          try {
            parsed = JSON.parse(raw);
          } catch {
            send(response, 400, { status: "rejected", reason: "halt JSON is invalid" });
            return;
          }
          if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
            send(response, 400, { status: "rejected", reason: "halt JSON is invalid" });
            return;
          }
          if (parsed.reason !== undefined && typeof parsed.reason !== "string") {
            send(response, 400, { status: "rejected", reason: "halt reason is invalid" });
            return;
          }
          if (parsed.reason) reason = parsed.reason;
        }
        ledger.setHalt(reason);
        const halt = activeHalt(ledger.haltBody());
        send(response, 200, { status: "halted", ...halt });
        return;
      }

      const intentMatch = pathname.match(/^\/v1\/intents\/([A-Za-z0-9][A-Za-z0-9._:-]{7,63})$/);
      if (request.method === "GET" && (intentMatch || pathname === "/v1/intents")) {
        let intentId;
        try {
          intentId = validateKey(intentMatch ? intentMatch[1] : url.searchParams.get("intentId"), "intentId");
        } catch (error) {
          logError(error);
          send(response, 400, { status: "rejected", ...publicFailure(error) });
          return;
        }
        const body = await exclusive(() => {
          const state = ledger.load();
          const record = state.intents.get(intentId);
          if (!record) return { missing: true, intentId };
          if (!record.result || record.status === "claimed") {
            return {
              status: "uncertain",
              intentId,
              desk: record.desk,
              action: record.action,
              reason: "intent was claimed before a durable result; no automatic replay is allowed",
            };
          }
          return { ...storedResult(record), ledgerStatus: record.status };
        });
        if (body.missing) send(response, 404, { status: "not_found", intentId });
        else send(response, httpStatus(body), body);
        return;
      }

      if (request.method === "POST" && pathname === "/v1/intents") {
        const raw = await readBody(request);
        let parsed;
        try {
          parsed = JSON.parse(raw);
        } catch {
          send(response, 400, { status: "rejected", reason: "intent JSON is invalid" });
          return;
        }
        let intent;
        try {
          intent = parseIntent(parsed);
        } catch (error) {
          if (typeof parsed?.action === "string" && parsed.action.toLowerCase() === "modify-stop" && PUBLIC_ERRORS.has(error.publicCode)) { error.publicReason = error.message; error.publicCode = "modify_stop_refused"; }
          logError(error);
          send(response, 400, { status: "rejected", ...publicFailure(error) });
          return;
        }
        const outcome = await exclusive(async () => {
          const state = ledger.load();
          const claimed = claimRecord(state, intent);
          if (claimed.replay) return claimed.replay;
          ledger.save(state);
          ledger.audit({
            event: "intent_claimed",
            intentId: intent.intentId,
            action: intent.action,
            desk: intent.desk,
            hash: claimed.hash,
          });
          const halt = activeHalt(ledger.haltBody());
          if (intent.action === "place" && halt.active) {
            const result = {
              status: "rejected",
              intentId: intent.intentId,
              desk: intent.desk,
              action: "place",
              observedAt: new Date().toISOString(),
              reason: "HALT is active: new orders are refused",
            };
            finish(state, intent, "rejected", result);
            ledger.save(state);
            ledger.audit({ event: "intent_finished", intentId: intent.intentId, status: "rejected", result });
            return result;
          }
          const runner = execute || (await import("./executor.mjs")).executeIntent;
          try {
            assertSideEffect(intent, { getHalt: () => activeHalt(ledger.haltBody()) });
            const result = await runner(intent, state, { halt, getHalt: () => activeHalt(ledger.haltBody()), saveState: ledger.save });
            const status = result?.status === "ok" ? "done" : (result?.status || "rejected");
            finish(state, intent, status, result);
            ledger.save(state);
            ledger.audit({ event: "intent_finished", intentId: intent.intentId, status, result });
            return result;
          } catch (error) {
            logError(error);
            const status = error?.code === "uncertain" ? "uncertain" : "rejected";
            const result = {
              status,
              intentId: intent.intentId,
              desk: intent.desk,
              action: intent.action,
              observedAt: new Date().toISOString(),
              ...publicFailure(error),
            };
            finish(state, intent, status, result);
            ledger.save(state);
            ledger.audit({ event: "intent_finished", intentId: intent.intentId, status, result });
            return result;
          }
        });
        send(response, httpStatus(outcome), outcome);
        return;
      }

      send(response, 404, { status: "not_found", reason: "unknown route" });
    } catch (error) {
      logError(error);
      const status = Number.isInteger(error?.statusCode) ? error.statusCode : 500;
      send(response, status, { status: "rejected", ...publicFailure(error), ...(error.publicCode === "intent_conflict" ? { intentId: error.intentId } : {}) });
    }
  }

  const server = createHttpServer((request, response) => {
    handle(request, response).catch((error) => {
      logError(error);
      if (!response.headersSent) send(response, 500, { status: "rejected", ...publicFailure(error) });
      else response.end();
    });
  });
  server.requestTimeout = 60_000;
  server.headersTimeout = 20_000;
  server.timeout = 0;

  return {
    allowlist,
    gatewayPort,
    listenHost: listen.host,
    listenPort: listen.port,
    ledger,
    server,
    handle,
    listen() {
      return new Promise((resolve, reject) => {
        const onError = (error) => {
          server.off("listening", onListening);
          reject(error);
        };
        const onListening = () => {
          server.off("error", onError);
          resolve(server.address());
        };
        server.once("error", onError);
        server.once("listening", onListening);
        server.listen(listen.port, listen.host);
      });
    },
    close() {
      if (typeof server.closeIdleConnections === "function") server.closeIdleConnections();
      return new Promise((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
    },
  };
}

async function main() {
  const gatewayPort = Number(process.env.IB_DESK_GATEWAY_PORT || PAPER_PORT);
  const started = createServer({
    testMode: false,
    gatewayPort,
    gatewayHost: process.env.IB_DESK_GATEWAY_HOST || LISTEN_HOST,
    listenHost: process.env.PAPER_DESK_BIND || LISTEN_HOST,
    listenPort: Number(process.env.PAPER_DESK_PORT || LISTEN_PORT),
    allowlist: process.env.PAPER_DESK_ALLOW ? JSON.parse(process.env.PAPER_DESK_ALLOW) : DEFAULT_PEERS,
    stateDir: process.env.PAPER_DESK_STATE_DIR || "/state",
  });
  // Fail closed before accept if the IB runtime cannot be loaded.
  const runtime = await import("./executor.mjs");
  runtime.assertRuntime();
  const address = await started.listen();
  console.error(`paper-desk-executor listening ${address.address}:${address.port}`);
  const shutdown = () => {
    started.close().finally(() => process.exit(0));
  };
  process.once("SIGTERM", shutdown);
  process.once("SIGINT", shutdown);
}

const entry = process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
if (entry) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
