// OPS-290: observe push and local files without acknowledging either inbox.
import { spawn } from "node:child_process";
import { chmodSync, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
const ID_PATTERN = /^[0-9]{13}-[a-f0-9]{32}$/;

const [endpoint, interval = "3"] = process.argv.slice(2);
if (!/^https?:\/\//.test(endpoint) || !Number.isFinite(Number(interval)) || Number(interval) <= 0) {
  console.error("mbx: bad watch endpoint or interval"); process.exit(2);
}
// Resolve existing ancestors too: a not-yet-created root must not escape home
// through a symlink in its parent path.
function canonicalPath(resolved) {
  try { return realpathSync(resolved); }
  catch (error) {
    if (error.code !== "ENOENT" || path.dirname(resolved) === resolved) throw error;
    return path.join(canonicalPath(path.dirname(resolved)), path.basename(resolved));
  }
}
let root;
try {
  const home = canonicalPath(path.resolve(homedir()));
  root = canonicalPath(path.join(homedir(), ".local", "share", "agent-mailbox"));
  if (!root.startsWith(home + path.sep)) throw new Error("root outside home");
} catch {
  console.error("mbx: bad watch root (must be inside home)"); process.exit(2);
}
const state = path.join(root, "watch-ops");
const inbox = path.join(root, "to-ops");
mkdirSync(state, { recursive: true, mode: 0o700 });
chmodSync(state, 0o700);
const cursorPath = path.join(state, "cursor");
let cursor = "";
try { cursor = readFileSync(cursorPath, "utf8").trim(); }
catch (error) { if (error.code !== "ENOENT") throw error; }
// The exit decision is a control-flow flag, not file data (CodeQL js/user-controlled-bypass).
let setAsideFailed = false;
if (cursor) {
  try { cursor = safeName(cursor); }
  catch {
    try { renameSync(cursorPath, path.join(state, "cursor.invalid")); }
    catch { setAsideFailed = true; }
    if (!setAsideFailed) console.error("mbx: invalid saved cursor");
    cursor = "";
  }
}
if (setAsideFailed) { console.error("mbx: cannot set aside invalid saved cursor"); process.exit(2); }
const seenLocal = new Set();
let stopped = false;
let child;
let retryTimer;
let backoff = 1;
const RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
function safeName(id) {
  if (typeof id !== "string" || id.length !== 46 || !ID_PATTERN.test(id) || path.basename(id) !== id) throw new Error("invalid message id");
  return id;
}
function receiptPath(id) {
  const receipt = path.join(state, safeName(id));
  if (path.dirname(receipt) !== state) throw new Error("invalid receipt path");
  return receipt;
}
function claimReceipt(id) {
  try { writeFileSync(receiptPath(id), "seen\n", { flag: "wx", mode: 0o600 }); return true; }
  catch (error) { if (error.code === "EEXIST") return false; throw error; }
}
function pruneReceipts() {
  const cutoff = Date.now() - RETENTION_MS;
  for (const name of readdirSync(state)) {
    try { safeName(name); } catch { continue; }
    const receipt = receiptPath(name);
    const stat = lstatSync(receipt);
    if (stat.isFile() && stat.mtimeMs < cutoff) unlinkSync(receipt);
  }
}
pruneReceipts();
const pruneTimer = setInterval(pruneReceipts, 60 * 60 * 1000);

function preview(body) {
  // Peer text must not inject terminal escape sequences or extra output lines.
  return Array.from(body.replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f\u061c\u200b\u200e\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff\u{e0000}-\u{e007f}]/gu, "�")
    .replace(/[\t\n\u2028\u2029]/g, " ")).slice(0, 140).join("");
}
function scanLocal() {
  try {
    for (const filename of readdirSync(inbox).sort()) {
      if (!/^[A-Za-z0-9._-]+\.txt$/.test(filename) || !filename.endsWith(".txt") || filename.includes("..") || path.basename(filename) !== filename) continue;
      const localPath = path.join(inbox, filename);
      if (path.dirname(localPath) !== inbox) continue;
      if (seenLocal.has(filename)) continue;
      let contents;
      try { contents = readFileSync(localPath, "utf8"); } catch { continue; }
      const header = (key) => contents.match(new RegExp(`^${key}: (.*)$`, "m"))?.[1]?.replace(/\r/g, "") ?? "";
      const remoteId = /^hsb0 mailbox ([0-9]{13}-[a-f0-9]{32})$/.exec(header("Via"))?.[1];
      if (remoteId && !claimReceipt(remoteId)) { seenLocal.add(filename); continue; }
      const body = contents.split(/\r?\n\r?\n/).slice(1).join("\n\n");
      console.log(`MBX NEW for ops: ${preview(filename)} | from=${preview(header("From"))} ticket=${preview(header("Ticket"))} | ${preview(body)}`);
      seenLocal.add(filename);
    }
  } catch { console.error("mbx: local inbox scan failed"); }
}
console.log(`mbx watch armed on to-ops (every ${interval}s)`);
scanLocal();
const localTimer = setInterval(scanLocal, Number(interval) * 1000);

function consume(frame) {
  const lines = frame.split("\n");
  if (!lines.includes("event: message")) return;
  const id = lines.find((line) => line.startsWith("id: "))?.slice(4);
  const data = lines.filter((line) => line.startsWith("data: ")).map((line) => line.slice(6)).join("\n");
  const message = JSON.parse(data);
  safeName(id);
  if (message.id !== id || message.to !== "ops" || message.from !== "amy" || typeof message.body !== "string") throw new Error("invalid event");
  const announcement = `MBX NEW for ops: ${id} | from=${message.from} ticket=${preview(message.ticket ?? "none")} | ${preview(message.body)}`;
  if (!claimReceipt(id)) return;
  console.log(announcement);
  writeFileSync(`${cursorPath}.new`, `${id}\n`, { mode: 0o600 });
  renameSync(`${cursorPath}.new`, cursorPath);
  cursor = id;
}

function connect() {
  if (stopped) return;
  const args = ["--silent", "--show-error", "--fail", "--no-buffer", "--connect-timeout", "5", "--max-time", "3660"];
  if (cursor) args.push("-H", `Last-Event-ID: ${cursor}`);
  args.push(`${endpoint}/v1/events`);
  child = spawn("curl", args, { stdio: ["ignore", "pipe", "ignore"] });
  let pending = "";
  let healthy = false;
  let failed = false;
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    pending += chunk;
    let end;
    while ((end = pending.indexOf("\n\n")) !== -1) {
      if (Buffer.byteLength(pending.slice(0, end)) > 128 * 1024) { failed = true; child.kill(); return; }
      const frame = pending.slice(0, end).replace(/\r/g, "");
      pending = pending.slice(end + 2);
      try { consume(frame); healthy = true; backoff = 1; }
      catch { failed = true; console.error("mbx: event delivery failed; retaining cursor"); child.kill(); break; }
    }
    // Bound the remaining incomplete frame after extracting complete events.
    if (Buffer.byteLength(pending) > 128 * 1024) { failed = true; child.kill(); }
  });
  child.on("error", () => { failed = true; });
  child.once("close", (code) => {
    if (stopped) return;
    if (!healthy || code || failed) console.error(`mbx: hsb0 push unavailable; falling back to local poll, retry in ${backoff}s`);
    scanLocal();
    retryTimer = setTimeout(connect, backoff * 1000);
    backoff = Math.min(30, backoff * 2);
  });
}
connect();
function stop() {
  stopped = true;
  clearInterval(localTimer);
  clearInterval(pruneTimer);
  clearTimeout(retryTimer);
  child?.kill();
}
process.once("SIGINT", stop);
process.once("SIGTERM", stop);
