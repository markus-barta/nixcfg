import { createServer as createHttpServer } from "node:http";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { TextDecoder } from "node:util";
import {
  assertListen, assertPeers, BODY_LIMIT, DEFAULT_PEERS, failure, ID_PATTERN,
  LISTEN_HOST, LISTEN_PORT, normalizePeer, parseMessage, POLICY,
} from "./security.mjs";
import { HOUR_MS, openMailbox, UNREAD_LIMIT } from "./state.mjs";

export const STREAM_LIMIT = 4;
export const HEARTBEAT_MS = 15000;
export const STREAM_LIFETIME_MS = HOUR_MS;

function send(response, status, body) {
  const payload = JSON.stringify(body);
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload),
    "Cache-Control": "no-store",
    "Connection": "close",
    "X-Mailbox-Policy": POLICY,
  });
  response.end(payload);
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let bytes = 0;
    const timer = setTimeout(() => finish(failure(408, "request body timed out")), 10000);
    timer.unref();
    function finish(error) {
      clearTimeout(timer);
      request.off("data", onData);
      request.off("end", onEnd);
      request.off("error", onError);
      request.off("aborted", onAborted);
      if (error) { request.pause(); reject(error); }
      else {
        try { resolve(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks))); }
        catch { reject(failure(400, "body must be valid UTF-8")); }
      }
    }
    function onData(chunk) {
      bytes += chunk.length;
      if (bytes > BODY_LIMIT) finish(failure(413, "request body is too large"));
      else chunks.push(chunk);
    }
    function onEnd() { finish(); }
    function onError() { finish(failure(400, "request body could not be read")); }
    function onAborted() { finish(failure(400, "request body was aborted")); }
    request.on("data", onData);
    request.once("end", onEnd);
    request.once("error", onError);
    request.once("aborted", onAborted);
  });
}

function jsonBody(raw) {
  try { return JSON.parse(raw); }
  catch { throw failure(400, "body must be valid JSON"); }
}

export function createServer(options = {}) {
  const listen = assertListen(options.listenHost ?? LISTEN_HOST, options.listenPort ?? LISTEN_PORT);
  const peers = assertPeers(options.peers ?? DEFAULT_PEERS);
  const identities = [...new Set(peers.values())];
  const mailbox = openMailbox(options.stateDir ?? "/var/lib/agent-mailbox", identities, options.now ?? Date.now);
  const log = options.log ?? ((line) => console.log(line));
  // Count SSE and long polls together: neither can exhaust the peer's slots.
  const connections = new Map(identities.map((identity) => [identity, new Set()]));

  function reserve(identity, response) {
    const active = connections.get(identity);
    if (active.size >= STREAM_LIMIT) throw failure(429, "recipient connection limit reached");
    const timers = [];
    const cleanups = [];
    let unsubscribe = () => {};
    let closed = false;
    const finish = () => {
      if (closed) return;
      closed = true;
      unsubscribe();
      for (const timer of timers) clearTimeout(timer);
      for (const cleanup of cleanups) cleanup();
      active.delete(finish);
      response.off("close", finish);
      response.off("error", finish);
      response.end();
    };
    active.add(finish);
    response.once("close", finish);
    response.once("error", finish);
    return {
      finish,
      subscribe(listener) { unsubscribe = mailbox.subscribe(identity, listener); },
      timer(timer) { timers.push(timer); timer.unref(); },
      cleanup(callback) { cleanups.push(callback); },
    };
  }

  function streamEvents(identity, response) {
    // Read/validate before headers. Registration and replay are synchronous,
    // so a committed send cannot fall between the snapshot and subscription.
    const replay = mailbox.messages(identity, UNREAD_LIMIT);
    const connection = reserve(identity, response);
    response.writeHead(200, {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-store",
      "Connection": "keep-alive",
      "X-Accel-Buffering": "no",
      "X-Mailbox-Policy": POLICY,
    });
    response.flushHeaders?.();
    let queue = replay;
    let blocked = false;
    let closed = false;
    let drainTimer;
    const onDrain = () => { clearTimeout(drainTimer); blocked = false; pump(); };
    connection.cleanup(() => {
      closed = true;
      queue = [];
      clearTimeout(drainTimer);
      response.off("drain", onDrain);
      // Shutdown/lifetime rotation must not wait forever for queued socket
      // bytes. The recipient can replay these still-unread messages.
      if (blocked) response.destroy?.();
    });
    const write = (payload) => {
      try {
        // false means the chunk was accepted into Node's bounded socket
        // buffer. Pause until drain; destroying immediately could discard it.
        if (!response.write(payload)) {
          blocked = true;
          response.once("drain", onDrain);
          drainTimer = setTimeout(() => { response.destroy?.(); connection.finish(); }, HEARTBEAT_MS);
          drainTimer.unref();
          return false;
        }
        return true;
      } catch { connection.finish(); return false; }
    };
    function pump() {
      while (!closed && !blocked && queue.length) {
        const message = queue.shift();
        if (!write(`id: ${message.id}\nevent: message\ndata: ${JSON.stringify(message)}\n\n`)) return;
      }
    }
    connection.subscribe((message) => {
      // A recipient may acknowledge while live traffic arrives; cap even
      // that case instead of letting a stalled subscriber accumulate forever.
      if (queue.length >= UNREAD_LIMIT) { response.destroy?.(); connection.finish(); return; }
      queue.push(message);
      pump();
    });
    connection.timer(setInterval(() => { if (!blocked && !closed) write(": heartbeat\n\n"); }, HEARTBEAT_MS));
    // Empty streams and healthy streams both periodically release their slot.
    connection.timer(setTimeout(connection.finish, STREAM_LIFETIME_MS));
    pump();
  }

  function longPoll(identity, response, seconds) {
    const connection = reserve(identity, response);
    const deliver = () => {
      try { send(response, 200, { messages: mailbox.messages(identity) }); }
      catch { send(response, 500, { error: "mailbox operation failed" }); }
      finally { connection.finish(); }
    };
    connection.subscribe(deliver);
    connection.timer(setTimeout(deliver, seconds * 1000));
  }

  async function handle(request, response) {
    const identity = peers.get(normalizePeer(request.socket?.remoteAddress)) ?? null;
    const method = request.method;
    // Log only canonical routes, excluding arbitrary paths and query strings
    // that could contain message text. JSON encoding keeps each event one line.
    let logPath = "[unknown]";
    let status = 500;
    function reply(code, body) { status = code; send(response, code, body); }
    try {
      // Match raw paths. URL normalization and percent-decoding never turn
      // caller-controlled traversal into a valid message ID or storage path.
      const route = request.url?.split("?", 1)[0] ?? "";
      const ackMatch = /^\/v1\/messages\/([0-9]{13}-[a-f0-9]{32})\/ack$/.exec(route);
      if (["/v1/health", "/v1/messages", "/v1/events"].includes(route) || ackMatch) logPath = route;
      if (!identity) { reply(403, { error: "source is not allowed" }); return; }
      if (method === "POST") mailbox.admitPost(identity);
      if (request.headers?.expect) throw failure(417, "Expect is not supported");
      if (Number(request.headers?.["content-length"]) > BODY_LIMIT) throw failure(413, "request body is too large");
      if (method === "GET" && ["/v1/health", "/v1/messages", "/v1/events"].includes(route)) {
        if (await readBody(request)) throw failure(400, "GET body must be empty");
        const query = new URLSearchParams(request.url?.split("?").slice(1).join("?") ?? "");
        if (route === "/v1/events") {
          const cursor = query.get("since") ?? request.headers?.["last-event-id"];
          if (cursor !== undefined && cursor !== null && !ID_PATTERN.test(cursor)) throw failure(400, "event cursor is invalid");
          // Always replay ALL unread, including IDs at/before the cursor. IDs
          // are random within each millisecond and clocks can move backwards.
          // The explicit ack is the only authority for removing unread data.
          streamEvents(identity, response);
          status = 200;
          return;
        }
        if (route === "/v1/health") reply(200, { ok: true, identity, unread: mailbox.unread(identity) });
        else {
          const wait = query.get("wait");
          if (wait !== null && (!/^(?:[0-9]|[1-5][0-9]|60)$/.test(wait))) throw failure(400, "wait must be an integer from 0 to 60");
          const messages = mailbox.messages(identity);
          if (messages.length || !Number(wait)) reply(200, { messages });
          else { longPoll(identity, response, Number(wait)); status = 200; }
        }
        return;
      }
      if (method === "POST" && (route === "/v1/messages" || ackMatch)) {
        if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(request.headers?.["content-type"] ?? "")) throw failure(415, "Content-Type must be application/json");
        const raw = await readBody(request);
        if (route === "/v1/messages") {
          const message = parseMessage(jsonBody(raw), identity, identities);
          reply(201, mailbox.send(identity, message));
        } else {
          const value = raw.length ? jsonBody(raw) : {};
          if (!value || typeof value !== "object" || Array.isArray(value) || Object.keys(value).length) throw failure(400, "ack body must be empty or an empty object");
          if (!ID_PATTERN.test(ackMatch[1])) throw failure(404, "message not found");
          mailbox.ack(identity, ackMatch[1]);
          reply(200, { ok: true });
        }
        return;
      }
      reply(404, { error: "unknown route" });
    } catch (error) {
      const code = [400, 403, 404, 408, 413, 415, 417, 429].includes(error.statusCode) ? error.statusCode : 500;
      reply(code, { error: code === 500 ? "mailbox operation failed" : error.message });
    } finally {
      log(JSON.stringify({ method, path: logPath, identity, status }));
    }
  }

  const dispatch = (request, response) => {
    handle(request, response).catch(() => {
      if (!response.headersSent) send(response, 500, { error: "mailbox operation failed" });
      else response.end();
    });
  };
  const server = createHttpServer(dispatch);
  // Avoid Node's automatic 100/417 replies without the policy header, and
  // authorize the socket before handling clients waiting on an Expect reply.
  server.on("checkContinue", dispatch);
  server.on("checkExpectation", dispatch);
  server.requestTimeout = 30000;
  server.headersTimeout = 10000;
  server.on("clientError", (error, socket) => {
    const status = error.code === "ERR_HTTP_REQUEST_TIMEOUT" ? 408 : 400;
    if (!socket.writable) return;
    const body = JSON.stringify({ error: "invalid HTTP request" });
    socket.end(`HTTP/1.1 ${status} ${status === 408 ? "Request Timeout" : "Bad Request"}\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\nX-Mailbox-Policy: ${POLICY}\r\n\r\n${body}`);
    log(JSON.stringify({ method: "UNKNOWN", path: "[invalid]", identity: peers.get(normalizePeer(socket.remoteAddress)) ?? null, status }));
  });
  // The same synchronous store operations serialize pruning with sends/acks.
  const pruneTimer = setInterval(() => {
    try { mailbox.prune(); } catch { console.error("agent-mailbox archive prune failed"); }
  }, HOUR_MS);
  pruneTimer.unref();
  server.once("close", () => clearInterval(pruneTimer));

  return {
    server, handle, mailbox, listenHost: listen.host, listenPort: listen.port,
    listen() {
      return new Promise((resolve, reject) => {
        const onError = (error) => { server.off("listening", onListening); reject(error); };
        const onListening = () => { server.off("error", onError); resolve(server.address()); };
        server.once("error", onError);
        server.once("listening", onListening);
        server.listen(listen.port, listen.host);
      });
    },
    close() {
      clearInterval(pruneTimer);
      for (const active of connections.values()) for (const finish of active) finish();
      server.closeIdleConnections();
      return new Promise((resolve, reject) => server.close((error) => error && error.code !== "ERR_SERVER_NOT_RUNNING" ? reject(error) : resolve()));
    },
  };
}

async function main() {
  const app = createServer({
    listenHost: process.env.AGENT_MAILBOX_BIND ?? LISTEN_HOST,
    listenPort: Number(process.env.AGENT_MAILBOX_PORT ?? LISTEN_PORT),
    peers: process.env.AGENT_MAILBOX_PEERS ? JSON.parse(process.env.AGENT_MAILBOX_PEERS) : DEFAULT_PEERS,
    stateDir: process.env.AGENT_MAILBOX_STATE_DIR ?? "/var/lib/agent-mailbox",
  });
  await app.listen();
  const shutdown = () => { app.close().finally(() => process.exit(0)); };
  process.once("SIGTERM", shutdown);
  process.once("SIGINT", shutdown);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(() => { console.error("agent-mailbox startup failed"); process.exitCode = 1; });
}
