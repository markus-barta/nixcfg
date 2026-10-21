import fs from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";

export const EXECUTOR_ATTRIBUTION_MEMORY_PATH = "/var/lib/joe-board-pusher/executor-attribution-memory.json";
export const ATTRIBUTION_MEMORY_SCHEMA = "inspr.joe.executor-attribution-memory.v1";
export const MAX_MEMORY_ENTRIES = 100_000;
export const MAX_MEMORY_BYTES = 32 * 1024 * 1024;
export const EXECUTOR_DESK_ROLLUP = Object.freeze({ j: "j", j2: "j", j5: "j", joe: "joe", joel: "joel" });
const dictionary = value => value && typeof value === "object" && !Array.isArray(value);
const positiveId = value => Number.isSafeInteger(value) && value > 0;
const token = value => typeof value === "string" && value.length > 0 && value.length <= 256 && value.trim() === value;
const keyFor = (account, clientId, execId) => JSON.stringify([account, clientId, execId]);
const failure = () => new Error("executor attribution memory unavailable");
const sameProof = (a, b) => a.orderId === b.orderId && a.desk === b.desk && a.subDesk === b.subDesk;

function validEntry(entry) {
  if (!dictionary(entry) || Object.keys(entry).sort().join() !== "clientId,desk,execId,orderId,provenAt,source,subDesk" ||
      !positiveId(entry.clientId) || !token(entry.execId) || !positiveId(entry.orderId) ||
      !Object.hasOwn(EXECUTOR_DESK_ROLLUP, entry.subDesk) || EXECUTOR_DESK_ROLLUP[entry.subDesk] !== entry.desk ||
      !["intent", "seed"].includes(entry.source)) return false;
  try { return new Date(entry.provenAt).toISOString() === entry.provenAt; }
  catch { return false; }
}

function validate(state, account) {
  if (!token(account) || !dictionary(state) || Object.keys(state).sort().join() !== "account,conflicts,entries,schema" ||
      state.schema !== ATTRIBUTION_MEMORY_SCHEMA || state.account !== account || !dictionary(state.entries) ||
      !Array.isArray(state.conflicts)) throw failure();
  const keys = Object.keys(state.entries);
  if (keys.length > MAX_MEMORY_ENTRIES || state.conflicts.length > keys.length ||
      new Set(state.conflicts).size !== state.conflicts.length) throw failure();
  for (const [key, entry] of Object.entries(state.entries)) {
    if (!validEntry(entry) || key !== keyFor(account, entry.clientId, entry.execId)) throw failure();
  }
  if (state.conflicts.some(key => !Object.hasOwn(state.entries, key))) throw failure();
  if (Buffer.byteLength(JSON.stringify(state)) + 1 > MAX_MEMORY_BYTES) throw failure();
  return state;
}

const empty = account => ({ schema: ATTRIBUTION_MEMORY_SCHEMA, account, entries: {}, conflicts: [] });

// Same opened inode, bounded even if the file grows, and never a symlink/FIFO.
export function readBoundedJson(file, maxBytes, fsImpl = fs) {
  let handle;
  try {
    handle = fsImpl.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    const stat = fsImpl.fstatSync(handle);
    if (!stat.isFile() || stat.size <= 0 || stat.size > maxBytes) throw failure();
    const bytes = Buffer.alloc(stat.size + 1);
    let count = 0;
    while (count < bytes.length) {
      const read = fsImpl.readSync(handle, bytes, count, bytes.length - count, null);
      if (!read) break;
      count += read;
    }
    if (count !== stat.size) throw failure();
    return JSON.parse(bytes.subarray(0, count).toString("utf8"));
  } finally { if (handle !== undefined) fsImpl.closeSync(handle); }
}

function applyEntries(state, entries) {
  const statuses = [];
  let changed = false;
  const conflicts = new Set(state.conflicts);
  for (const entry of entries) {
    if (!validEntry(entry)) throw failure();
    const key = keyFor(state.account, entry.clientId, entry.execId);
    const prior = state.entries[key];
    if (prior) {
      if (conflicts.has(key) || !sameProof(prior, entry)) {
        if (!conflicts.has(key)) { conflicts.add(key); changed = true; }
        statuses.push("conflict");
      } else statuses.push("alreadyPresent");
    } else {
      state.entries[key] = { ...entry };
      statuses.push("added");
      changed = true;
    }
  }
  state.conflicts = [...conflicts];
  validate(state, state.account);
  return { statuses, changed };
}

// Ephemeral implementation also gives exact-match callers a deterministic test
// seam. No proof is created by lookup, an OPS-test exception, or a remembered hit.
export function createExecutorAttributionMemory({ account, state = empty(account) } = {}) {
  state = structuredClone(validate(state, account));
  let conflicts = new Set(state.conflicts);
  return {
    account,
    get: (clientId, execId) => {
      const entry = state.entries[keyFor(account, clientId, execId)];
      return entry ? { ...entry } : null;
    },
    isConflict: (clientId, execId) => conflicts.has(keyFor(account, clientId, execId)),
    recordMany(entries) {
      if (entries.every(entry => validEntry(entry) &&
          !conflicts.has(keyFor(account, entry.clientId, entry.execId)) &&
          state.entries[keyFor(account, entry.clientId, entry.execId)] &&
          sameProof(state.entries[keyFor(account, entry.clientId, entry.execId)], entry))) {
        return entries.map(() => "alreadyPresent");
      }
      const next = structuredClone(state);
      const { statuses } = applyEntries(next, entries);
      state = next;
      conflicts = new Set(state.conflicts);
      return statuses;
    },
    record(entry) { return this.recordMany([entry])[0]; },
    snapshot: () => structuredClone(state),
  };
}

export function createFileExecutorAttributionMemory({ account, file = EXECUTOR_ATTRIBUTION_MEMORY_PATH,
  readOnly = false, fsImpl = fs } = {}) {
  if (!path.isAbsolute(file)) throw failure();
  const load = () => {
    try { return validate(readBoundedJson(file, MAX_MEMORY_BYTES, fsImpl), account); }
    catch (error) { if (error.code === "ENOENT") return validate(empty(account), account); throw failure(); }
  };
  let memory = createExecutorAttributionMemory({ account, state: load() });
  let failed = false;
  const ready = () => { if (failed) throw failure(); };
  return {
    account,
    get(clientId, execId) { ready(); return memory.get(clientId, execId); },
    isConflict(clientId, execId) { ready(); return memory.isConflict(clientId, execId); },
    record(entry) { return this.recordMany([entry])[0]; },
    recordMany(entries) {
      ready();
      if (readOnly) {
        // Compare against the persisted proof without changing even private RAM.
        return entries.map(entry => {
          if (!validEntry(entry)) throw failure();
          const prior = memory.get(entry.clientId, entry.execId);
          return !prior ? "added" : memory.isConflict(entry.clientId, entry.execId) || !sameProof(prior, entry)
            ? "conflict" : "alreadyPresent";
        });
      }
      // The common repeat call needs neither a disk read nor a disk write.
      if (entries.every(entry => {
        if (!validEntry(entry)) return false;
        const prior = memory.get(entry.clientId, entry.execId);
        return prior && sameProof(prior, entry) && !memory.isConflict(entry.clientId, entry.execId);
      })) return entries.map(() => "alreadyPresent");
      const directory = path.dirname(file);
      const lock = `${file}.lock`;
      const temporary = path.join(directory, `.${path.basename(file)}.${process.pid}.${randomUUID()}.tmp`);
      let lockHandle, handle, temporaryOwned = false;
      try {
        // Serializes the running pusher and an operator seed. Contention fails
        // closed; no stale-lock stealing and no last-writer-wins lost proofs.
        lockHandle = fsImpl.openSync(lock, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
        const state = load();
        const { statuses, changed } = applyEntries(state, entries);
        if (changed) {
          const body = `${JSON.stringify(state)}\n`;
          handle = fsImpl.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
          temporaryOwned = true;
          fsImpl.fchmodSync(handle, 0o600);
          fsImpl.writeFileSync(handle, body, "utf8");
          fsImpl.fsyncSync(handle);
          fsImpl.closeSync(handle); handle = undefined;
          fsImpl.renameSync(temporary, file); temporaryOwned = false;
          const directoryHandle = fsImpl.openSync(directory, fs.constants.O_RDONLY);
          try { fsImpl.fsyncSync(directoryHandle); } finally { fsImpl.closeSync(directoryHandle); }
        }
        memory = createExecutorAttributionMemory({ account, state });
        return statuses;
      } catch { failed = true; throw failure(); }
      finally {
        if (handle !== undefined) fsImpl.closeSync(handle);
        if (temporaryOwned) fsImpl.unlinkSync(temporary);
        if (lockHandle !== undefined) {
          fsImpl.closeSync(lockHandle);
          fsImpl.unlinkSync(lock);
        }
      }
    },
  };
}
