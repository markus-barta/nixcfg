import net from "node:net";
import { copyDeskActivity } from "./desk-activity.mjs";
import { exactKeys, validCycle, frame } from "./v1-cycle.mjs";
import { contractRevision, copyExactValues } from "./v2-exact-values.mjs";

export const FRAME_FORMAT = "ops392.switch-set-observation.v2";
export const MAX_FRAME_BYTES = 16 * 1024;
const MAX_CONTROL_BYTES = 32 * 1024;

// Copy only existing scalar evidence, after v1 settles. Never inspect a ledger.
// A symbol/side shared by desks or broker contracts cannot prove a single owner.
export function copyObservation({ book, family, deskEquities, dayPnl, executions, executorAttribution, v1Cycle } = {}, revision = 9) {
  if (v1Cycle !== undefined && !validCycle(v1Cycle)) return null;
  if (!book || typeof book.ts !== "string" || book.ts.length > 64) return null;
  if (book.apiReplyCheckedAt != null && (typeof book.apiReplyCheckedAt !== "string" || book.apiReplyCheckedAt.length > 24)) return null;
  const rows = book.positions || [];
  if (!Array.isArray(rows) || rows.length > 256) return null;
  const owners = new Map();
  const counts = new Map();
  const key = row => `${row.symbol}|${row.side}|${row.currency || ""}`;
  const addOwners = (desk, positions) => {
    if (!Array.isArray(positions) || positions.length > 256) return false;
    for (const row of positions) {
      const side = row.side === "Long" ? "long" : row.side === "Short" ? "short" : null;
      if (!side) continue;
      const id = key({ symbol: row.symbol, currency: row.currency, side });
      if (!owners.has(id)) owners.set(id, desk);
      else if (owners.get(id) !== desk) owners.set(id, null);
    }
    return true;
  };
  if (deskEquities?.ok) {
    for (const desk of ["j", "joe", "joel"]) {
      if (!addOwners(desk, deskEquities.desks?.[desk]?.positions)) return null;
    }
  } else if (revision === 10 && deskEquities?.phaseBDesks) {
    for (const desk of ["j", "joe", "joel"]) {
      const value = deskEquities.phaseBDesks[desk];
      if (value?.reconciled && !addOwners(desk, value.positions)) return null;
    }
  } else {
    const positions = family?.ok ? family.positions : family?.partialAccounting?.positions;
    if (positions && !addOwners("j", positions)) return null;
  }
  const positions = [];
  for (const row of rows) {
    if (typeof row.symbol !== "string" || row.symbol.length > 16 || typeof row.pos !== "number" || !Number.isFinite(row.pos)) return null;
    if (row.pos === 0) continue;
    const side = row.pos > 0 ? "long" : "short";
    const id = key({ symbol: row.symbol, side, currency: row.currency });
    counts.set(id, (counts.get(id) || 0) + 1);
    positions.push({ symbol: row.symbol, side, desk: owners.get(id) || null,
      scope: ["SXR8", "TSLA"].includes(row.symbol) ? "keep" : "stage0" });
  }
  // No contract identity is sent. Ambiguous same-symbol broker rows stay unmapped.
  for (let i = 0, j = 0; i < rows.length; i++) {
    const row = rows[i];
    if (row.pos === 0) continue;
    const out = positions[j++];
    if (out.scope === "keep" || counts.get(key({ symbol: row.symbol, currency: row.currency, side: out.side })) > 1) out.desk = null;
  }
  const raw = tag => {
    const item = book.summary?.[tag];
    if (!item) return null;
    if (typeof item.value !== "string" || item.value.length > 32 || typeof item.currency !== "string" || item.currency.length > 3) return null;
    return { value: item.value, currency: item.currency };
  };
  return { format: FRAME_FORMAT, bookTs: book.ts, equity: raw("NetLiquidation"), cash: raw("TotalCashValue"),
    sourceObservedAt: {
      equity: book.summaryObservedAt === undefined ? book.ts : book.summaryObservedAt?.NetLiquidation ?? null,
      cash: book.summaryObservedAt === undefined ? book.ts : book.summaryObservedAt?.TotalCashValue ?? null,
      positions: book.positionsCoverage?.observedAt === undefined ? book.ts : book.positionsCoverage.observedAt,
    },
    apiReplyCheckedAt: book.apiReplyCheckedAt ?? null, positions,
    deskActivity: copyDeskActivity({ book, family, deskEquities, executions, executorAttribution }),
    ...(revision === 10 ? { exactValues: copyExactValues({ book, deskEquities, dayPnl }) } : {}),
    ...(v1Cycle === undefined ? {} : { v1Cycle: { ...v1Cycle } }) };
}

// No direct filesystem, contract, timer or broker work. The injected body
// writer starts only on the later sequence assignment, after v1 settlement.
export function createStageHandoff({
  socketPath,
  makeSocket = () => new net.Socket(),
  defer = setImmediate,
  cycleStore,
  revision = contractRevision(),
} = {}) {
  if (socketPath !== "/run/joe-household-v2/stage.sock") return { offer: () => false, stop() {} };
  let socket;
  let credit = false;
  let stopped = false;
  let pending;
  function connect() {
    if (stopped) return;
    let next;
    try { next = makeSocket(); } catch { return; }
    socket = next;
    credit = false;
    pending = undefined;
    let incoming = Buffer.alloc(0);
    next.on("error", () => { credit = false; next.destroy(); });
    next.on("close", () => {
      if (socket !== next) return;
      credit = false;
      pending = undefined;
      socket = undefined;
      if (!stopped) defer(connect).unref?.();
    });
    const invalid = () => { credit = false; pending = undefined; next.destroy(); };
    next.on("data", bytes => {
      if (socket !== next) return;
      if (incoming.length + bytes.length > MAX_CONTROL_BYTES + 5) { invalid(); return; }
      incoming = Buffer.concat([incoming, bytes]);
      while (incoming.length) {
        if (incoming[0] !== 0 && incoming[0] !== 0x01) { invalid(); return; }
        if (incoming[0] === 0x01) {
          if (credit || pending) { invalid(); return; }
          credit = true; incoming = incoming.subarray(1); continue;
        }
        if (incoming.length < 4) return;
        const length = incoming.readUInt32BE();
        if (length < 1 || length > MAX_CONTROL_BYTES) { invalid(); return; }
        if (incoming.length < length + 4) return;
        let control;
        try { control = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(incoming.subarray(4, length + 4))); }
        catch { invalid(); return; }
        incoming = incoming.subarray(length + 4);
        if (exactKeys(control, "event,retainedSeqs") && control.event === "v1_retained"
          && Array.isArray(control.retainedSeqs) && control.retainedSeqs.length <= 1024
          && new Set(control.retainedSeqs).size === control.retainedSeqs.length
          && control.retainedSeqs.every(seq => Number.isSafeInteger(seq) && seq > 0)) {
          pending = undefined;
          // Serialize behind any in-flight body write, including late writes.
          try { Promise.resolve(cycleStore?.prune(control.retainedSeqs)).catch(() => {}); } catch {}
        } else if (exactKeys(control, "event,seq,observationId") && control.event === "v1_store"
          && pending && !pending.assigned && control.observationId === pending.cycle.observationId
          && Number.isSafeInteger(control.seq) && control.seq > 0) {
          const job = pending; job.assigned = true;
          Promise.resolve().then(() => cycleStore?.write(control.seq, job.body, job.cycle.v1Sha256))
            .catch(() => false).then(stored => {
              if (socket !== next || pending !== job || next.destroyed) return;
              try { next.write(frame({ seq: control.seq, observationId: control.observationId, stored: stored === true })); }
              catch { invalid(); }
            });
        } else { invalid(); return; }
      }
    });
    next.unref?.();
    try { next.connect("/run/joe-household-v2/stage.sock"); } catch { next.destroy(); }
  }
  connect();
  return {
    offer(source) {
      const current = socket;
      if (!credit || !current?.writable || current.destroyed || current.connecting || current.writableLength > 0) return false;
      try {
        const observation = copyObservation(source, revision);
        if (!observation) return false;
        const bytes = Buffer.from(JSON.stringify(observation));
        if (bytes.length > MAX_FRAME_BYTES) return false;
        const frame = Buffer.allocUnsafe(4 + bytes.length);
        frame.writeUInt32BE(bytes.length);
        bytes.copy(frame, 4);
        // A false return still owns the one outstanding frame. Never retry.
        credit = false;
        if (observation.v1Cycle) pending = { body: source.v1Body, cycle: observation.v1Cycle, assigned: false };
        return current.write(frame);
      } catch {
        current.destroy();
        return false;
      }
    },
    stop() { stopped = true; credit = false; socket?.destroy(); },
  };
}
