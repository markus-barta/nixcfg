import {
  chmodSync, closeSync, constants, fstatSync, fsyncSync, futimesSync, lstatSync,
  mkdirSync, openSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync,
} from "node:fs";
import { randomBytes } from "node:crypto";
import path from "node:path";
import { failure, ID_PATTERN, parseMessage, validIdentity } from "./security.mjs";

export const UNREAD_LIMIT = 500;
export const POST_LIMIT = 120;
export const HOUR_MS = 60 * 60 * 1000;
export const RETENTION_MS = 30 * 24 * HOUR_MS;

export function confinedPath(directory, name, isMessageId = false) {
  if (isMessageId && (typeof name !== "string" || !ID_PATTERN.test(name))) throw failure(404, "message not found");
  const resolved = path.resolve(directory, isMessageId ? `${name}.json` : name);
  // Include the separator so sibling directories with a shared prefix fail.
  // The filesystem root already ends in a separator.
  const prefix = directory.endsWith(path.sep) ? directory : directory + path.sep;
  if (!resolved.startsWith(prefix)) throw new Error("mailbox path is invalid");
  return resolved;
}

function privateDirectory(directory) {
  const parent = path.dirname(directory);
  mkdirSync(confinedPath(parent, directory), { recursive: true, mode: 0o700 });
  if (!lstatSync(confinedPath(parent, directory)).isDirectory()) throw new Error("mailbox directory is not a real directory");
  chmodSync(confinedPath(parent, directory), 0o700);
}

function syncDirectory(directory) {
  const fd = openSync(confinedPath(path.dirname(directory), directory), constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
  try { fsyncSync(fd); } finally { closeSync(fd); }
}

function writeAtomic(directory, name, value, isMessageId = false) {
  const temporary = `${confinedPath(directory, name, isMessageId)}.${randomBytes(16).toString("hex")}.new`;
  const fd = openSync(confinedPath(directory, temporary), constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  try {
    try {
      writeFileSync(fd, `${JSON.stringify(value)}\n`);
      fsyncSync(fd);
    } finally { closeSync(fd); }
    renameSync(confinedPath(directory, temporary), confinedPath(directory, name, isMessageId));
    syncDirectory(directory);
  } finally {
    try { unlinkSync(confinedPath(directory, temporary)); } catch (error) { if (error.code !== "ENOENT") throw error; }
  }
}

function readJSON(directory, name, maxBytes, isMessageId = false) {
  const fd = openSync(confinedPath(directory, name, isMessageId), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size > maxBytes) throw new Error("mailbox state file is invalid");
    return JSON.parse(readFileSync(fd, "utf8"));
  } finally { closeSync(fd); }
}

export function openMailbox(stateDir, identities, now = Date.now) {
  if (typeof stateDir !== "string" || !path.isAbsolute(stateDir) || stateDir.includes("\0")) throw new Error("stateDir must be an absolute path");
  if (identities.length < 2 || identities.some((identity) => !validIdentity(identity))) throw new Error("mailbox identities are invalid");
  const root = path.resolve(stateDir);
  privateDirectory(root);
  const parents = new Map();
  const directories = new Map();
  for (const kind of ["inbox", "archive"]) {
    const parent = confinedPath(root, kind);
    parents.set(kind, parent);
    privateDirectory(parent);
    const byIdentity = new Map();
    for (const identity of identities) {
      const dir = confinedPath(parent, identity);
      byIdentity.set(identity, dir);
      privateDirectory(dir);
    }
    directories.set(kind, byIdentity);
  }
  const rateFile = "rate-limits.json";
  let rates = new Map(identities.map((identity) => [identity, []]));
  try {
    const stored = readJSON(root, rateFile, 128 * 1024);
    if (!stored || typeof stored !== "object" || Array.isArray(stored)) throw new Error("mailbox rate state is invalid");
    for (const identity of identities) {
      const times = Object.hasOwn(stored, identity) ? stored[identity] : [];
      if (!Array.isArray(times) || times.length > POST_LIMIT || times.some((time) => !Number.isSafeInteger(time) || time < 0)) throw new Error("mailbox rate state is invalid");
      rates.set(identity, times);
    }
  } catch (error) { if (error.code !== "ENOENT") throw error; }

  function directory(kind, identity) {
    const result = directories.get(kind)?.get(identity);
    if (!result) throw new Error("mailbox path is invalid");
    // Refuse symlinks even if a state directory was replaced after startup.
    for (const dir of [root, parents.get(kind), result]) {
      if (!lstatSync(confinedPath(path.dirname(dir), dir)).isDirectory()) throw new Error("mailbox directory is not a real directory");
    }
    return result;
  }

  function files(kind, identity) {
    const dir = directory(kind, identity);
    return readdirSync(confinedPath(path.dirname(dir), dir)).filter((name) => name.endsWith(".json") && ID_PATTERN.test(name.slice(0, -5)));
  }

  function readMessage(identity, id) {
    const row = readJSON(directory("inbox", identity), id, 128 * 1024, true);
    if (!row || row.id !== id || row.to !== identity || !identities.includes(row.from) || !Number.isFinite(Date.parse(row.createdAt))) throw new Error("stored mailbox message is invalid");
    const parsed = parseMessage({ to: row.to, body: row.body, ...(row.ticket === null ? {} : { ticket: row.ticket }) }, row.from, identities);
    return { id, from: row.from, ...parsed, createdAt: row.createdAt };
  }

  function admitPost(sender) {
    if (!rates.has(sender)) throw failure(403, "source is not allowed");
    const epoch = now();
    const times = rates.get(sender).filter((time) => time > epoch - HOUR_MS);
    if (times.length >= POST_LIMIT) throw failure(429, "sender hourly POST limit reached");
    const next = new Map(rates);
    next.set(sender, [...times, epoch]);
    // An I/O failure consumes the attempt in memory too. In particular, a
    // failed directory fsync after rename must not reopen admission slots.
    rates = next;
    writeAtomic(root, rateFile, Object.fromEntries(next));
  }

  function unread(identity) { return files("inbox", identity).length; }

  function send(sender, message) {
    // Keep the capacity check and publication synchronous: concurrent HTTP
    // bodies cannot interleave an admission and its committed message file.
    const parsed = parseMessage({ to: message.to, body: message.body, ...(message.ticket === null ? {} : { ticket: message.ticket }) }, sender, identities);
    if (!identities.includes(sender)) throw failure(403, "source is not allowed");
    if (unread(parsed.to) >= UNREAD_LIMIT) throw failure(429, "recipient unread limit reached");
    const epoch = now();
    const id = `${String(epoch).padStart(13, "0")}-${randomBytes(16).toString("hex")}`;
    const createdAt = new Date(epoch).toISOString();
    const row = { id, from: sender, to: parsed.to, ticket: parsed.ticket, createdAt, body: parsed.body };
    writeAtomic(directory("inbox", row.to), id, row, true);
    return { id, createdAt };
  }

  function messages(identity) {
    return files("inbox", identity).map((name) => readMessage(identity, name.slice(0, -5)))
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id)).slice(0, 50);
  }

  function ack(recipient, id) {
    // Validate the ID before the identity lookup, preserving invalid-ID errors.
    confinedPath(root, id, true);
    const inbox = directory("inbox", recipient);
    try { readMessage(recipient, id); }
    catch (error) {
      if (error.code !== "ENOENT") throw error;
      if (identities.some((identity) => identity !== recipient && files("inbox", identity).includes(`${id}.json`))) throw failure(403, "only the recipient may acknowledge");
      throw failure(404, "message not found");
    }
    const fd = openSync(confinedPath(inbox, id, true), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      // Retention begins at acknowledgment; an old unread message is retained
      // for a full thirty days after it is moved to the archive.
      futimesSync(fd, now() / 1000, now() / 1000);
      fsyncSync(fd);
    } finally { closeSync(fd); }
    const archive = directory("archive", recipient);
    renameSync(confinedPath(inbox, id, true), confinedPath(archive, id, true));
    syncDirectory(directory("inbox", recipient));
    syncDirectory(directory("archive", recipient));
  }

  function prune() {
    const cutoff = now() - RETENTION_MS;
    for (const identity of identities) {
      const dir = directory("archive", identity);
      let changed = false;
      for (const name of files("archive", identity)) {
        const id = name.slice(0, -5);
        const stat = lstatSync(confinedPath(dir, id, true));
        if (!stat.isFile()) throw new Error("mailbox archive entry is not a regular file");
        if (stat.mtimeMs < cutoff) { unlinkSync(confinedPath(dir, id, true)); changed = true; }
      }
      if (changed) syncDirectory(dir);
    }
  }

  prune();
  return { root, send, messages, unread, ack, admitPost, prune };
}
