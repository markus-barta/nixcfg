import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { StageStore } from "./v2-stage-worker.mjs";

export const POST_STATE = "/var/lib/joe-board-pusher/v2-post-state.json";
export const OUTCOME_LIMIT = 128;
const MAX_STATE_BYTES = 65536;
const FORMAT = "ops408.v2-post-state.v1";
const sha = bytes => createHash("sha256").update(bytes).digest("hex");
const seqOk = seq => Number.isSafeInteger(seq) && seq > 0;
const fingerprint = value => value && seqOk(value.seq) && /^[0-9a-f]{64}$/.test(value.sha256)
  && Object.keys(value).sort().join() === "seq,sha256";
const instant = value => typeof value === "string" && Number.isFinite(Date.parse(value)) && new Date(value).toISOString() === value;
const statusOk = value => Number.isInteger(value) && value >= 100 && value <= 599
  || ["post_failed", "reply_failed"].includes(value);
const fail = () => { throw new Error("v2_post_state_invalid"); };

// A single atomic bounded file binds the durable cursor, uncertain attempt and
// value-free receipts. No write ever targets the stager's read-only directory.
export function createPostStateStore({ file = POST_STATE, io = fs, uid = process.getuid(), gid = process.getgid() } = {}) {
  const root = path.dirname(file), temp = `${file}.tmp`;
  function check(stat, directory = false) {
    if (stat.isSymbolicLink() || stat.uid !== uid || stat.gid !== gid
      || (stat.mode & 0o7777) !== (directory ? 0o700 : 0o600)
      || (directory ? !stat.isDirectory() : !stat.isFile() || stat.nlink !== 1 || stat.size > MAX_STATE_BYTES)) fail();
  }
  function validate(state) {
    if (!state || Object.keys(state).sort().join() !== "format,lastPosted,outcomes,pending" || state.format !== FORMAT
      || !(state.lastPosted === null || fingerprint(state.lastPosted)) || !(state.pending === null || fingerprint(state.pending))
      || (state.pending && state.lastPosted && state.pending.seq <= state.lastPosted.seq)
      || !Array.isArray(state.outcomes) || state.outcomes.length > OUTCOME_LIMIT) fail();
    for (const row of state.outcomes) {
      if (!row || Object.keys(row).sort().join() !== "bodySha256,generatedAt,outcome,receivedAt,recordedAt,seq,status"
        || !seqOk(row.seq) || !/^[0-9a-f]{64}$/.test(row.bodySha256)
        || !instant(row.generatedAt) || !instant(row.recordedAt) || !(row.receivedAt === null || instant(row.receivedAt))
        || !statusOk(row.status) || !["accepted", "sequence_replayed", "failed"].includes(row.outcome)) fail();
    }
    return state;
  }
  return {
    load() {
      const dir = io.openSync(root, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_DIRECTORY);
      try { check(io.fstatSync(dir), true); } finally { io.closeSync(dir); }
      let fd;
      try {
        // No lstat-then-open (TOCTOU): O_NOFOLLOW refuses links; the opened fd is checked.
        fd = io.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
        check(io.fstatSync(fd));
        const bytes = Buffer.alloc(MAX_STATE_BYTES + 1);
        let length = 0, read;
        while (length < bytes.length && (read = io.readSync(fd, bytes, length, bytes.length - length, null))) length += read;
        if (length > MAX_STATE_BYTES) fail();
        return validate(JSON.parse(bytes.subarray(0, length)));
      } catch (error) {
        if (error.code === "ENOENT") return { format: FORMAT, lastPosted: null, pending: null, outcomes: [] };
        throw error;
      } finally { if (fd !== undefined) io.closeSync(fd); }
    },
    save(state) {
      validate(state);
      const bytes = Buffer.from(JSON.stringify(state));
      if (bytes.length > MAX_STATE_BYTES) fail();
      // One directory fd is validated and later fsynced: no lstat-then-open race on the root.
      const dir = io.openSync(root, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_DIRECTORY);
      try {
        check(io.fstatSync(dir), true);
        // A crashed pre-rename temporary file is ours; the opened fd is validated before replacing.
        let fd;
        try {
          fd = io.openSync(temp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_NOFOLLOW, 0o600);
          check(io.fstatSync(fd));
          io.ftruncateSync(fd, 0);
          io.writeFileSync(fd, bytes); io.fsyncSync(fd);
        } finally { if (fd !== undefined) io.closeSync(fd); }
        io.renameSync(temp, file);
        io.fsyncSync(dir);
      } finally { io.closeSync(dir); }
    },
  };
}

export function createV2Publisher({ reader = new StageStore(), stateStore = createPostStateStore(),
  send = (...args) => fetch(...args), now = () => new Date().toISOString(),
  emit = event => console.log(JSON.stringify(event)) } = {}) {
  let busy = false;
  let ready = false;
  return {
    async push({ url, token }) {
      if (busy || !token) return null;
      busy = true;
      try {
        if (!ready) { await reader.contracts(); ready = true; }
        const pair = reader.readCommittedPair();
        if (!pair) return null;
        const state = stateStore.load();
        if (state.lastPosted && pair.seq <= state.lastPosted.seq) return null;
        const attempt = { seq: pair.seq, sha256: sha(pair.bytes) };
        if (state.pending && (pair.seq < state.pending.seq
          || pair.seq === state.pending.seq && attempt.sha256 !== state.pending.sha256)) fail();
        // Persist the exact uncertain attempt before sending. Crash/reply loss
        // retries the immutable bytes; never allocate or regenerate a sequence.
        state.pending = attempt;
        stateStore.save(state);
        let status = "post_failed", receivedAt = null, outcome = "failed";
        try {
          const response = await send(url, {
            method: "POST",
            headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", "User-Agent": "joe-board-pusher/1.0" },
            body: pair.bytes,
          });
          status = "reply_failed";
          const text = await response.text();
          status = response.status;
          let reply;
          try { if (text.length <= 4096) reply = JSON.parse(text); } catch {}
          if (instant(reply?.receivedAt)) receivedAt = reply.receivedAt;
          if (response.ok) outcome = "accepted";
          // The board can already hold this exact committed pair after migrate-v2
          // or an uncertain successful POST. Never loop on that replay.
          else if (status === 422 && reply?.reason === "sequence_replayed") outcome = "sequence_replayed";
        } catch {} // Never expose response bodies, tokens or raw transport errors.
        const receipt = { status, seq: pair.seq, generatedAt: pair.generatedAt, receivedAt,
          recordedAt: now(), bodySha256: attempt.sha256, outcome };
        if (outcome !== "failed") { state.lastPosted = attempt; state.pending = null; }
        state.outcomes = [...state.outcomes, receipt].slice(-OUTCOME_LIMIT);
        try { stateStore.save(state); }
        finally { try { emit({ event: "v2_post", ...receipt }); } catch {} }
        return receipt;
      } catch {
        try { emit({ event: "v2_post_skipped", reason: "committed_pair_or_post_state_unavailable" }); } catch {}
        return null;
      } finally { busy = false; }
    },
  };
}
