import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";

export const V1_CYCLES = "/var/lib/joe-board-pusher/v1-cycles";
const seqOk = seq => Number.isSafeInteger(seq) && seq > 0;
const fail = () => { throw new Error("v1_cycle_store_invalid"); };

// Only the pusher imports this module. The isolated stager never sees the body.
export function createCycleStore({ root = V1_CYCLES, io = fs.promises, uid = process.getuid(), gid = process.getgid(),
  emit = event => console.warn(JSON.stringify(event)) } = {}) {
  let chain = Promise.resolve();
  let writing = false;
  let prunePending;
  let prunePromise;
  const event = reason => { try { emit({ event: "v1_cycle_unbound", reason }); } catch {} };
  async function directory() {
    try { await io.mkdir(root, { mode: 0o700 }); } catch (error) { if (error.code !== "EEXIST") throw error; }
    const stat = await io.lstat(root);
    if (!stat.isDirectory() || stat.isSymbolicLink() || (stat.mode & 0o7777) !== 0o700 || stat.uid !== uid || stat.gid !== gid) fail();
  }
  const enqueue = task => { const next = chain.then(task); chain = next.catch(() => {}); return next; };
  return {
    write(seq, body, digest) {
      // A stuck filesystem must not accumulate request bodies in pusher RAM.
      if (writing) { event("store_busy"); return Promise.resolve(false); }
      writing = true;
      return enqueue(async () => {
        let handle;
        try {
          if (!seqOk(seq) || typeof body !== "string" || Buffer.byteLength(body) > 262144
            || createHash("sha256").update(body).digest("hex") !== digest) fail();
          await directory();
          handle = await io.open(path.join(root, `${seq}.json`), fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
          const stat = await handle.stat();
          if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== uid || stat.gid !== gid || (stat.mode & 0o7777) !== 0o600) fail();
          await handle.writeFile(body);
          await handle.sync();
          await handle.close(); handle = undefined;
          const dir = await io.open(root, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
          try { await dir.sync(); } finally { await dir.close(); }
          return true;
        } catch {
          event("store_write_failed");
          return false;
        } finally { try { await handle?.close(); } catch {} }
      }).finally(() => { writing = false; });
    },
    prune: function prune(seqs) {
      // Keep only the latest control set while a write/prune is outstanding.
      if (!Array.isArray(seqs) || seqs.length > 1024 || seqs.some(seq => !seqOk(seq)) || new Set(seqs).size !== seqs.length) {
        event("store_prune_failed"); return Promise.resolve(false);
      }
      prunePending = [...seqs];
      if (prunePromise) return prunePromise;
      prunePromise = enqueue(async () => {
        let result = true;
        while (prunePending !== undefined) {
          const seqs = prunePending; prunePending = undefined;
          try {
            await directory();
            const names = await io.readdir(root);
            if (names.length > 2048) fail();
            // Validate the entire set before removing recognized residue.
            for (const name of names) {
              if (!/^[1-9]\d{0,15}\.json$/.test(name) || !seqOk(Number(name.slice(0, -5)))) fail();
              const stat = await io.lstat(path.join(root, name));
              if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.uid !== uid || stat.gid !== gid || (stat.mode & 0o7777) !== 0o600) fail();
            }
            const keep = new Set(seqs.map(seq => `${seq}.json`));
            for (const name of names) if (!keep.has(name)) await io.unlink(path.join(root, name));
            const dir = await io.open(root, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
            try { await dir.sync(); } finally { await dir.close(); }
          } catch { event("store_prune_failed"); result = false; }
        }
        return result;
      }).finally(() => {
        prunePromise = undefined;
        // A control arriving as the previous task settles still needs a turn.
        if (prunePending !== undefined) return prune(prunePending);
      });
      return prunePromise;
    },
  };
}
