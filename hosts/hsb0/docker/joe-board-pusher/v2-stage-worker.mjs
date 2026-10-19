import fs from "node:fs";
import path from "node:path";
import net from "node:net";
import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { verify } from "./verify-contracts.mjs";

export const STATE_DIR = "/var/lib/joe-board-pusher/v2";
export const SOCKET_PATH = "/run/joe-household-v2/stage.sock";
export const CONTRACT_SHA = "3eaf443cf06579ab93d4ed32c0752f8a6fd6978b6086ba50a97f74faa00b0b9d";
const sha = bytes => createHash("sha256").update(bytes).digest("hex");
const stateFormat = "ops392.v2-sequence-state.v1";
const pairFormat = "ops392.v2-stage-pair.v1";
const pointerFormat = "ops392.v2-stage-current.v1";
const fail = () => { throw new Error("stage_storage_invalid"); };
const exactKeys = (value, keys) => value && typeof value === "object" && !Array.isArray(value)
  && JSON.stringify(Object.keys(value).sort()) === JSON.stringify(keys.split(",").sort());
const positiveSeq = n => Number.isSafeInteger(n) && n > 0;

export function normalizeBookTs(value) {
  if (typeof value !== "string" || value.length > 64) return null;
  // The source publishes UTC ISO instants. Reject Date.parse's calendar rollover.
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?Z$/.exec(value);
  if (!match) return null;
  const normalized = `${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}.${(match[7] || "").padEnd(3, "0")}Z`;
  const date = new Date(normalized);
  return Number.isFinite(date.getTime()) && date.toISOString() === normalized ? normalized : null;
}
const canonical = value => typeof value === "string" && normalizeBookTs(value) === value;
const freeze = value => {
  if (value && typeof value === "object") { Object.values(value).forEach(freeze); Object.freeze(value); }
  return value;
};
const observationId = instant => JSON.stringify(["ops392.phase-a.v1", instant]);

export function buildCandidate(seq, generatedAt) {
  const money = () => ({
    equity: null, dayPnl: null, openPnl: null, totalPnl: null,
    reasons: { equity: "source_not_authoritative", dayPnl: "source_not_authoritative", openPnl: "source_not_authoritative", totalPnl: "source_not_authoritative" },
  });
  return {
    schema: "inspr.joe.household.v2", seq, generatedAt, mode: "PAPER", currency: "EUR",
    source: { kind: "live-ib-api", label: "hsb0 joe-board-pusher (paper Gateway projection)" },
    safety: { halt: false, haltReason: null },
    desks: [["j", "J"], ["joe", "Joe"], ["joel", "Joel"]].map(([id, label]) => ({
      id, label, state: "sit-out", action: "Valuation unavailable pending exact source validation.", money: money(),
    })),
    totals: money(),
  };
}

export function acceptStage(acceptSnapshot, candidate, previous, receivedAt, floor) {
  if (candidate.seq <= floor) return { status: 422, reason: "sequence_replayed" };
  return acceptSnapshot("data", candidate, previous, receivedAt);
}

// Synchronous durable operations run only inside the separately limited worker.
export class StageStore {
  constructor({ root = STATE_DIR, uid = 1000, gid = 1000, io = fs, boundary = () => {} } = {}) {
    Object.assign(this, { root, uid, gid, io, boundary });
    this.disabled = false;
  }
  check(name, kind, limit) {
    const target = name ? path.join(this.root, name) : this.root;
    const stat = this.io.lstatSync(target);
    if (stat.isSymbolicLink() || stat.uid !== this.uid || stat.gid !== this.gid
      || (stat.mode & 0o7777) !== (kind === "directory" ? 0o700 : 0o600)
      || (kind === "directory" ? !stat.isDirectory() : !stat.isFile() || stat.nlink !== 1)
      || (limit !== undefined && stat.size > limit)) fail();
    return target;
  }
  names(name = "", max = 8) {
    const dir = this.io.opendirSync(this.check(name, "directory"));
    const names = [];
    try {
      let entry;
      while ((entry = dir.readSync())) {
        names.push(entry.name);
        if (names.length > max) fail();
      }
    } finally { dir.closeSync(); }
    return names;
  }
  read(name, limit) {
    const target = this.check(name, "file", limit);
    const fd = this.io.openSync(target, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try {
      const opened = this.io.fstatSync(fd);
      if (!opened.isFile() || opened.nlink !== 1 || opened.uid !== this.uid || opened.gid !== this.gid || (opened.mode & 0o7777) !== 0o600 || opened.size > limit) fail();
      const buffer = Buffer.alloc(limit + 1);
      let used = 0;
      while (used < buffer.length) {
        const count = this.io.readSync(fd, buffer, used, buffer.length - used, null);
        if (!count) break;
        used += count;
      }
      if (used > limit) fail();
      return buffer.subarray(0, used);
    } finally { this.io.closeSync(fd); }
  }
  json(name, limit = 4096) { return JSON.parse(this.read(name, limit)); }
  syncDir(name, label) {
    const fd = this.io.openSync(this.check(name, "directory"), fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    try { this.io.fsyncSync(fd); this.boundary(label); } finally { this.io.closeSync(fd); }
  }
  write(name, bytes, label) {
    const fd = this.io.openSync(path.join(this.root, name), fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try {
      this.io.writeFileSync(fd, bytes);
      this.boundary(`${label}_write`);
      this.io.fsyncSync(fd);
      this.boundary(`${label}_fsync`);
    } finally { this.io.closeSync(fd); }
  }
  atomic(name, value, label) {
    const temp = `.${name === "sequence-state.json" ? "sequence-state" : "current"}.tmp`;
    const bytes = Buffer.from(JSON.stringify(value));
    if (bytes.length > 4096) fail();
    this.write(temp, bytes, label);
    this.io.renameSync(path.join(this.root, temp), path.join(this.root, name));
    this.boundary(`${label}_rename`);
    this.syncDir("", `${label}_dir_fsync`);
  }
  async contracts() {
    verify(); // Before any contract imports (including JSON imports).
    const { validateContract } = await import("./contracts/index.mjs");
    const { acceptSnapshot } = await import("./contracts/accept.mjs");
    Object.assign(this, { validateContract, acceptSnapshot });
  }
  enroll() {
    // The operator explicitly recorded an empty v2 history for this host.
    if (this.names().some(name => name !== ".allocator.lock")) fail();
    this.check(".allocator.lock", "file", 0);
    this.atomic("sequence-state.json", {
      format: stateFormat, floor: 0, lastReservedSeq: 0,
      lastObservationId: null, lastGeneratedAt: null, lastGatewayCheckedAt: null,
    }, "enroll");
  }
  validateState(state) {
    if (!exactKeys(state, "format,floor,lastReservedSeq,lastObservationId,lastGeneratedAt,lastGatewayCheckedAt")
      || state.format !== stateFormat || state.floor !== 0
      || !Number.isSafeInteger(state.lastReservedSeq) || state.lastReservedSeq < state.floor
      || state.lastGatewayCheckedAt !== null) fail();
    if (state.lastReservedSeq === 0) {
      if (state.lastObservationId !== null || state.lastGeneratedAt !== null) fail();
    } else if (!canonical(state.lastGeneratedAt) || state.lastObservationId !== observationId(state.lastGeneratedAt)) fail();
  }
  readPair(name) {
    if (!/^pair-[1-9]\d{0,15}$/.test(name)) fail();
    const names = this.names(name, 2).sort();
    if (JSON.stringify(names) !== JSON.stringify(["receipt.json", "snapshot.json"])) fail();
    const bytes = this.read(`${name}/snapshot.json`, 262144);
    const snapshot = JSON.parse(bytes);
    const receipt = this.json(`${name}/receipt.json`);
    if (!exactKeys(receipt, "format,stagedReceivedAt,seq,generatedAt,generatedAdvancedAt,snapshotSha256,contractSetSha256")
      || receipt.format !== pairFormat || !positiveSeq(snapshot.seq) || name !== `pair-${snapshot.seq}`
      || receipt.seq !== snapshot.seq || receipt.generatedAt !== snapshot.generatedAt
      || !canonical(receipt.stagedReceivedAt) || !canonical(receipt.generatedAdvancedAt)
      || receipt.generatedAdvancedAt > receipt.stagedReceivedAt
      || receipt.snapshotSha256 !== sha(bytes) || receipt.contractSetSha256 !== CONTRACT_SHA
      || !this.validateContract("data", snapshot, { stage: "ingress" }).ok
      || JSON.stringify(snapshot) !== JSON.stringify(buildCandidate(snapshot.seq, snapshot.generatedAt))
      || this.acceptSnapshot("data", snapshot, null, receipt.stagedReceivedAt).status !== 200) fail();
    return { value: { ...snapshot, receivedAt: receipt.stagedReceivedAt }, generatedAdvancedAt: receipt.generatedAdvancedAt };
  }
  checkResidue(name, state) {
    if (name === ".sequence-state.tmp" || name === ".current.tmp") { this.read(name, 4096); return; }
    const match = /^(?:pair-|\.next-)([1-9]\d{0,15})$/.exec(name);
    if (!match || !positiveSeq(Number(match[1])) || Number(match[1]) > state.lastReservedSeq) fail();
    if (name.startsWith("pair-")) {
      this.readPair(name);
    } else {
      for (const child of this.names(name, 2)) {
        if (!["snapshot.json", "receipt.json"].includes(child)) fail();
        this.read(`${name}/${child}`, child === "snapshot.json" ? 262144 : 4096);
      }
    }
  }
  retire(name) {
    // Only entries completely recognized and checked under the lifetime lock.
    if (name.startsWith("pair-") || name.startsWith(".next-")) {
      for (const child of this.names(name, 2)) this.io.unlinkSync(path.join(this.root, name, child));
      this.io.rmdirSync(path.join(this.root, name));
    } else this.io.unlinkSync(path.join(this.root, name));
  }
  async open() {
    await this.contracts();
    this.check(".allocator.lock", "file", 0);
    const state = this.json("sequence-state.json");
    this.validateState(state);
    const names = this.names();
    let current = null;
    let previous = null;
    if (names.includes("current.json")) {
      const pointer = this.json("current.json");
      if (!exactKeys(pointer, "format,pair") || pointer.format !== pointerFormat || typeof pointer.pair !== "string") fail();
      previous = this.readPair(pointer.pair);
      current = pointer.pair;
      if (previous.value.seq <= state.floor || previous.value.seq > state.lastReservedSeq
        || previous.value.generatedAt > state.lastGeneratedAt
        || (previous.value.seq === state.lastReservedSeq && previous.value.generatedAt !== state.lastGeneratedAt)) fail();
    }
    const residue = names.filter(name => ![".allocator.lock", "sequence-state.json", "current.json", current].includes(name));
    if (residue.filter(name => /^(pair-|\.next-)/.test(name)).length > 1) fail();
    // Validate everything before removing anything. Unknown items disable v2.
    for (const name of residue) this.checkResidue(name, state);
    for (const name of residue) this.retire(name);
    if (residue.length) this.syncDir("", "recovery_dir_fsync");
    Object.assign(this, { state, previous, current });
    return this;
  }
  stage(bookTs, now = () => new Date().toISOString()) {
    if (this.disabled) fail();
    const generatedAt = normalizeBookTs(bookTs);
    if (!generatedAt || (this.state.lastGeneratedAt && generatedAt < this.state.lastGeneratedAt)) return { status: 422, reason: "source_time_invalid" };
    if (this.state.lastReservedSeq === Number.MAX_SAFE_INTEGER) { this.disabled = true; fail(); }
    try {
      const state = { ...this.state, lastReservedSeq: this.state.lastReservedSeq + 1, lastObservationId: observationId(generatedAt), lastGeneratedAt: generatedAt };
      this.atomic("sequence-state.json", state, "reserve");
      this.state = state;
      const candidate = buildCandidate(state.lastReservedSeq, generatedAt);
      if (!this.validateContract("data", candidate, { stage: "ingress" }).ok) fail();
      const bytes = Buffer.from(JSON.stringify(candidate));
      if (bytes.length > 262144) fail();
      freeze(candidate);
      const stagedReceivedAt = now();
      if (!canonical(stagedReceivedAt)) fail();
      const accepted = acceptStage(this.acceptSnapshot, candidate, this.previous, stagedReceivedAt, state.floor);
      if (accepted.status !== 200) return { status: accepted.status, reason: accepted.reason };
      const receipt = {
        format: pairFormat, stagedReceivedAt, seq: candidate.seq, generatedAt,
        generatedAdvancedAt: accepted.generatedAdvancedAt, snapshotSha256: sha(bytes), contractSetSha256: CONTRACT_SHA,
      };
      const next = `.next-${candidate.seq}`;
      const pair = `pair-${candidate.seq}`;
      this.io.mkdirSync(path.join(this.root, next), { mode: 0o700 });
      this.boundary("pair_mkdir");
      this.write(`${next}/snapshot.json`, bytes, "snapshot");
      this.write(`${next}/receipt.json`, Buffer.from(JSON.stringify(receipt)), "receipt");
      this.syncDir(next, "pair_fsync");
      this.io.renameSync(path.join(this.root, next), path.join(this.root, pair));
      this.boundary("pair_rename");
      this.syncDir("", "pair_dir_fsync");
      this.atomic("current.json", { format: pointerFormat, pair }, "pointer");
      if (this.current) { this.retire(this.current); this.syncDir("", "retire_dir_fsync"); }
      this.current = pair;
      this.previous = accepted;
      return { status: 200, reason: null };
    } catch {
      this.disabled = true; // Even an uncertain rename/fsync must never reuse memory state.
      throw new Error("stage_storage_invalid");
    }
  }
}

export function prepareLock(root = STATE_DIR, uid = 1000, gid = 1000) {
  const store = new StageStore({ root, uid, gid });
  store.check("", "directory");
  const lock = path.join(root, ".allocator.lock");
  try {
    const fd = fs.openSync(lock, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    fs.closeSync(fd);
    store.syncDir("", "lock_dir_fsync");
  } catch (error) { if (error.code !== "EEXIST") throw error; }
  return store.check(".allocator.lock", "file", 0);
}

export function launchLocked({ root = STATE_DIR, args = [], uid = 1000, gid = 1000, spawnWorker = spawn } = {}) {
  const lock = prepareLock(root, uid, gid);
  return spawnWorker("flock", ["--no-fork", "--nonblock", lock, process.execPath, fileURLToPath(import.meta.url), "--lock-held", ...args], {
    stdio: ["ignore", "pipe", "pipe", "ipc"],
    env: { PATH: process.env.PATH, NODE_ENV: "production" },
  });
}

export async function serveWorker({ store, socketPath = SOCKET_PATH, notify = message => process.send?.(message), createServer = net.createServer, setTimer = setTimeout, clearTimer = clearTimeout } = {}) {
  // Only the lock-holding worker may retire a stale socket.
  const parent = fs.lstatSync(path.dirname(socketPath));
  if (!parent.isDirectory() || parent.isSymbolicLink() || (parent.mode & 0o7777) !== 0o700 || parent.uid !== store.uid || parent.gid !== store.gid) fail();
  try {
    const stale = fs.lstatSync(socketPath);
    if (!stale.isSocket() || stale.isSymbolicLink() || stale.uid !== store.uid || stale.gid !== store.gid || (stale.mode & 0o7777) !== 0o600) fail();
    fs.unlinkSync(socketPath);
  } catch (error) { if (error.code !== "ENOENT") throw error; }
  let active;
  const server = createServer(socket => {
    if (active) { socket.destroy(); return; }
    active = socket;
    let buffer = Buffer.alloc(4100);
    let used = 0;
    let length = null;
    let busy = false;
    let timer;
    const clear = () => { clearTimer(timer); timer = undefined; };
    socket.on("error", () => socket.destroy());
    socket.on("close", () => { clear(); if (active === socket) active = undefined; });
    socket.on("data", chunk => {
      if (busy || used + chunk.length > buffer.length) { socket.destroy(); return; }
      if (!timer) timer = setTimer(() => socket.destroy(), 5000);
      chunk.copy(buffer, used); used += chunk.length;
      if (length === null && used >= 4) {
        length = buffer.readUInt32BE();
        if (length < 1 || length > 4096) { socket.destroy(); return; }
      }
      if (length === null || used < length + 4) return;
      if (used !== length + 4) { socket.destroy(); return; }
      clear(); busy = true;
      notify({ event: "job_start" });
      let observation;
      try {
        const payload = buffer.subarray(4, used);
        const text = new TextDecoder("utf-8", { fatal: true }).decode(payload);
        observation = JSON.parse(text);
      } catch { socket.destroy(); notify({ event: "job_done", outcome: "skipped" }); return; }
      if (!exactKeys(observation, "format,bookTs") || observation.format !== "ops392.phase-a-observation.v1" || typeof observation.bookTs !== "string" || observation.bookTs.length > 64) {
        socket.destroy(); notify({ event: "job_done", outcome: "skipped" }); return;
      }
      try {
        const result = store.stage(observation.bookTs);
        notify({ event: "job_done", outcome: result.status === 200 ? "committed" : "skipped" });
      } catch {
        notify({ event: "disabled" });
        socket.destroy(); server.close();
        return;
      }
      buffer = Buffer.alloc(4100); used = 0; length = null; busy = false;
      if (!socket.destroyed) socket.write(Buffer.from([0x01]));
    });
    socket.write(Buffer.from([0x01]));
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  fs.chmodSync(socketPath, 0o600);
  server.on("error", () => { notify({ event: "disabled" }); active?.destroy(); server.close(); });
  notify({ event: "ready" });
  return server;
}

async function main() {
  process.umask(0o077);
  const args = process.argv.slice(2);
  if (args.some(arg => !["--enroll", "--lock-held"].includes(arg))) fail();
  if (!args.includes("--lock-held")) {
    const child = launchLocked({ args });
    child.stdout.resume(); child.stderr.resume();
    child.on("error", () => { console.log('{"event":"v2_stage_disabled","reason":"worker_unavailable"}'); process.exitCode = 1; });
    child.on("exit", code => { process.exitCode = code || 1; if (code === 0) process.exitCode = 0; });
    return;
  }
  const store = new StageStore();
  if (args.includes("--enroll")) {
    verify(); store.enroll();
    console.log('{"event":"v2_stage_enrolled"}');
  } else {
    await store.open();
    await serveWorker({ store });
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(() => {
    process.send?.({ event: "disabled" });
    console.log('{"event":"v2_stage_disabled","reason":"startup_invalid"}');
    process.exitCode = 1;
  });
}
