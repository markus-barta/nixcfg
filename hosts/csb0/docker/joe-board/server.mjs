#!/usr/bin/env node
/**
 * Joe household board service (csb0).
 * Serves static /joe/ UI + schema + latest snapshot.
 * Accepts POST /joe/inbox with Bearer token (machine push; no browser OAuth).
 * Paper projection only — never talks to IB, never places orders.
 */
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { timingSafeEqual } from "node:crypto";
import { fileURLToPath } from "node:url";
import { validateHouseholdSnapshot } from "./validate.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PUBLIC = path.join(__dirname, "public");
// Fixed container paths (not taken from request or free-form env paths).
const DATA_DIR = "/var/lib/joe-board";
const DATA_FILE = path.join(DATA_DIR, "data.json");
const TOKEN_FILE = "/run/secrets/joe-board-push-token";
const BIND_HOST = "0.0.0.0";
const BIND_PORT = 8080;
const MAX_BODY = 262144;

const STATIC_FILES = Object.freeze({
  "/joe": "index.html",
  "/joe/": "index.html",
  "/joe/index.html": "index.html",
  "/joe/data.schema.json": "data.schema.json",
});

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
};

function readToken() {
  try {
    return fs.readFileSync(TOKEN_FILE, "utf8").trim();
  } catch (err) {
    // Local/dev fallback only when secret file absent.
    const fallback = process.env.JOE_INBOX_TOKEN;
    if (typeof fallback === "string" && fallback.length >= 16) return fallback.trim();
    console.error("token read failed", err && err.code ? err.code : err);
    return "";
  }
}

function safeEqualStr(a, b) {
  const aa = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (aa.length !== bb.length) {
    timingSafeEqual(aa, Buffer.alloc(aa.length));
    return false;
  }
  return timingSafeEqual(aa, bb);
}

function ensureDataDir() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
}

function atomicWriteJson(file, obj) {
  ensureDataDir();
  const text = JSON.stringify(obj, null, 2) + "\n";
  const tmp = `${file}.next`;
  fs.writeFileSync(tmp, text, { mode: 0o644 });
  fs.renameSync(tmp, file);
}

function send(res, status, body, headers = {}) {
  const payload = typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body);
  res.writeHead(status, {
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    ...headers,
    "Content-Length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function sendJson(res, status, obj) {
  send(res, status, `${JSON.stringify(obj)}\n`, { "Content-Type": "application/json; charset=utf-8" });
}

function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(Object.assign(new Error("body too large"), { code: "TOO_LARGE" }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function bearerToken(req) {
  const h = String(req.headers.authorization || "");
  const prefix = "Bearer ";
  if (h.length < prefix.length || h.slice(0, prefix.length).toLowerCase() !== "bearer ") {
    return "";
  }
  // Skip "Bearer" + single space without regex (avoids ReDoS findings).
  return h.slice(prefix.length).trim();
}

async function handleInbox(req, res) {
  if (req.method !== "POST") {
    sendJson(res, 405, { ok: false, error: "method not allowed" });
    return;
  }
  const expected = readToken();
  if (!expected) {
    sendJson(res, 503, { ok: false, error: "inbox token not configured" });
    return;
  }
  const got = bearerToken(req);
  if (!got || !safeEqualStr(got, expected)) {
    sendJson(res, 401, { ok: false, error: "unauthorized" });
    return;
  }
  let raw;
  try {
    raw = await readBody(req, MAX_BODY);
  } catch (err) {
    if (err.code === "TOO_LARGE") {
      sendJson(res, 413, { ok: false, error: "body too large" });
      return;
    }
    sendJson(res, 400, { ok: false, error: "bad body" });
    return;
  }
  let parsed;
  try {
    parsed = JSON.parse(raw.toString("utf8"));
  } catch {
    sendJson(res, 400, { ok: false, error: "invalid json" });
    return;
  }
  const { ok, errors } = validateHouseholdSnapshot(parsed);
  if (!ok) {
    sendJson(res, 422, { ok: false, error: "schema validation failed", errors: errors.slice(0, 20) });
    return;
  }
  try {
    atomicWriteJson(DATA_FILE, parsed);
  } catch (err) {
    console.error("atomic write failed", err);
    sendJson(res, 500, { ok: false, error: "store failed" });
    return;
  }
  sendJson(res, 200, {
    ok: true,
    storedAt: new Date().toISOString(),
    generatedAt: parsed.generatedAt,
    equity: parsed.totals?.equity ?? null,
  });
}

function handleStatic(req, res, urlPath) {
  if (urlPath === "/joe/data.json") {
    let body;
    try {
      body = fs.readFileSync(DATA_FILE);
    } catch (err) {
      if (err && err.code === "ENOENT") {
        sendJson(res, 404, { ok: false, error: "NO DATA" });
        return;
      }
      throw err;
    }
    send(res, 200, body, { "Content-Type": "application/json; charset=utf-8" });
    return;
  }

  const name = STATIC_FILES[urlPath];
  if (!name) {
    sendJson(res, 404, { ok: false, error: "not found" });
    return;
  }
  const file = path.join(PUBLIC, name);
  const body = fs.readFileSync(file);
  const ext = path.extname(file).toLowerCase();
  send(res, 200, body, { "Content-Type": MIME[ext] || "application/octet-stream" });
}

const server = http.createServer(async (req, res) => {
  try {
    const host = req.headers.host || "localhost";
    const u = new URL(req.url || "/", `http://${host}`);
    const urlPath = u.pathname;

    if (urlPath === "/healthz" || urlPath === "/readyz") {
      let hasData = false;
      try {
        fs.accessSync(DATA_FILE, fs.constants.R_OK);
        hasData = true;
      } catch {
        hasData = false;
      }
      sendJson(res, 200, { ok: true, service: "joe-board", hasData });
      return;
    }

    if (urlPath === "/joe/inbox") {
      await handleInbox(req, res);
      return;
    }

    if (urlPath === "/joe" || urlPath.startsWith("/joe/")) {
      if (req.method !== "GET" && req.method !== "HEAD") {
        sendJson(res, 405, { ok: false, error: "method not allowed" });
        return;
      }
      handleStatic(req, res, urlPath);
      return;
    }

    sendJson(res, 404, { ok: false, error: "not found" });
  } catch (err) {
    console.error("request error", err);
    sendJson(res, 500, { ok: false, error: "internal" });
  }
});

ensureDataDir();
server.listen(BIND_PORT, BIND_HOST, () => {
  console.log(`joe-board listening on ${BIND_HOST}:${BIND_PORT} data=${DATA_DIR}`);
});
