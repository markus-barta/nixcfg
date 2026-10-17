import { constants, openSync, closeSync, fstatSync, readSync, writeSync, fsyncSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';

export const hash = value => createHash('sha256').update(typeof value === 'string' ? value : JSON.stringify(value)).digest('hex');

// Single writer per journal (executor capture / producer service respectively).
// A damaged or torn tail is evidence: refuse to overwrite, truncate or rebuild.
function* rows(fd, { strictTail = true, offset = 0, previous: initialHash = '0'.repeat(64), count = 0 } = {}) {
  const size = fstatSync(fd).size, chunk = Buffer.alloc(65536);
  let position = offset, pending = Buffer.alloc(0), previous = initialHash, n = count;
  while (position < size) {
    const count = readSync(fd, chunk, 0, Math.min(chunk.length, size - position), position);
    if (!count) throw new Error('journal_short_read');
    position += count;
    pending = Buffer.concat([pending, chunk.subarray(0, count)]);
    let end;
    while ((end = pending.indexOf(10)) !== -1) {
      const row = JSON.parse(pending.subarray(0, end).toString('utf8'));
      pending = pending.subarray(end + 1);
      if (row.n !== ++n || row.previous !== previous || row.hash !== hash({ n: row.n, previous: row.previous, entry: row.entry })) throw new Error('journal_corrupt');
      previous = row.hash;
      yield { ...row, end: position - pending.length };
    }
    if (pending.length > 32 * 1024 * 1024) throw new Error('journal_entry_too_large');
  }
  if (strictTail && pending.length) throw new Error('journal_torn_tail');
}

export function openJournal(filename, { retain = () => true, onEntry = () => {} } = {}) {
  mkdirSync(path.dirname(filename), { recursive: true, mode: 0o700 });
  const fd = openSync(filename, constants.O_RDWR | constants.O_APPEND | constants.O_CREAT | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o600);
  try {
    if (!fstatSync(fd).isFile()) throw new Error('journal_not_regular');
    const entries = [];
    let previous = '0'.repeat(64), n = 0;
    for (const row of rows(fd)) {
      n = row.n; previous = row.hash;
      if (retain(row.entry)) entries.push(row.entry);
      onEntry(row.entry);
    }
    // Make initial creation durable, including the directory entry.
    fsyncSync(fd);
    const directory = openSync(path.dirname(filename), constants.O_RDONLY);
    try { fsyncSync(directory); } finally { closeSync(directory); }
    let failed = false;
    return {
      entries,
      append(entry) {
        if (failed) throw new Error('journal_failed');
        const row = { n: n + 1, previous, entry };
        row.hash = hash(row);
        const bytes = Buffer.from(`${JSON.stringify(row)}\n`);
        try {
          let written = 0;
          while (written < bytes.length) written += writeSync(fd, bytes, written, bytes.length - written);
          fsyncSync(fd);
        } catch (error) { failed = true; throw error; }
        n = row.n; previous = row.hash;
        if (retain(entry)) entries.push(structuredClone(entry));
      },
      close: () => closeSync(fd),
    };
  } catch (error) { closeSync(fd); throw error; }
}

// Reader never opens the executor journal for write or creates a missing input.
export function readJournal(filename) {
  const fd = openSync(filename, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    if (!fstatSync(fd).isFile()) throw new Error('journal_not_regular');
    // Ignore a writer's in-flight final line; it becomes visible next poll.
    return [...rows(fd, { strictTail: false })].map(row => row.entry);
  } finally { closeSync(fd); }
}


// A poll reads only the newly appended suffix. Startup verifies the full chain
// once; later polls recheck the last committed line as a bounded anchor.
export function createJournalReader(filename) {
  let offset = 0, count = 0, previous = '0'.repeat(64), identity, anchor, failed = false;
  return onRow => {
    if (failed) throw new Error('capture_history_rewritten');
    const fd = openSync(filename, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const info = fstatSync(fd), nextIdentity = `${info.dev}:${info.ino}`;
      if (!info.isFile()) throw new Error('journal_not_regular');
      if (identity && (identity !== nextIdentity || info.size < offset)) throw new Error('capture_history_regressed');
      if (anchor) {
        const bytes = Buffer.alloc(anchor.bytes.length);
        if (readSync(fd, bytes, 0, bytes.length, anchor.offset) !== bytes.length || !bytes.equals(anchor.bytes)) throw new Error('capture_history_rewritten');
      }
      identity = nextIdentity;
      for (const row of rows(fd, { strictTail: false, offset, count, previous })) {
        onRow(row.entry, row.n);
        const bytes = Buffer.alloc(row.end - offset);
        if (readSync(fd, bytes, 0, bytes.length, offset) !== bytes.length) throw new Error('journal_short_read');
        anchor = { offset, bytes };
        offset = row.end; count = row.n; previous = row.hash;
      }
      return count;
    } catch (error) { failed = true; throw error; } finally { closeSync(fd); }
  };
}
