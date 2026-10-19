import net from "node:net";

export const FRAME_FORMAT = "ops392.switch-set-observation.v2";
export const MAX_FRAME_BYTES = 16 * 1024;

// Copy only existing scalar evidence, after v1 settles. Never inspect a ledger.
// A symbol/side shared by desks or broker contracts cannot prove a single owner.
export function copyObservation({ book, family, deskEquities } = {}) {
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
    apiReplyCheckedAt: book.apiReplyCheckedAt ?? null, positions };
}

// This module deliberately has no filesystem, contract, timer or broker work.
export function createStageHandoff({
  socketPath,
  makeSocket = () => new net.Socket(),
  defer = setImmediate,
} = {}) {
  if (socketPath !== "/run/joe-household-v2/stage.sock") return { offer: () => false, stop() {} };
  let socket;
  let credit = false;
  let stopped = false;
  function connect() {
    if (stopped) return;
    let next;
    try { next = makeSocket(); } catch { return; }
    socket = next;
    credit = false;
    next.on("error", () => { credit = false; next.destroy(); });
    next.on("close", () => {
      if (socket !== next) return;
      credit = false;
      socket = undefined;
      if (!stopped) defer(connect).unref?.();
    });
    next.on("data", bytes => {
      if (socket !== next) return;
      if (credit || bytes.length !== 1 || bytes[0] !== 0x01) {
        credit = false;
        next.destroy();
      } else credit = true;
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
        const observation = copyObservation(source);
        if (!observation) return false;
        const bytes = Buffer.from(JSON.stringify(observation));
        if (bytes.length > MAX_FRAME_BYTES) return false;
        const frame = Buffer.allocUnsafe(4 + bytes.length);
        frame.writeUInt32BE(bytes.length);
        bytes.copy(frame, 4);
        // A false return still owns the one outstanding frame. Never retry.
        credit = false;
        return current.write(frame);
      } catch {
        current.destroy();
        return false;
      }
    },
    stop() { stopped = true; credit = false; socket?.destroy(); },
  };
}
