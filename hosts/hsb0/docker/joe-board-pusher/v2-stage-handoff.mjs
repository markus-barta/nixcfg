import net from "node:net";

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
    offer(bookTs) {
      const current = socket;
      if (!credit || !current?.writable || current.destroyed || current.connecting || current.writableLength > 0) return false;
      if (typeof bookTs !== "string" || bookTs.length > 64) return false;
      credit = false;
      try {
        const bytes = Buffer.from(JSON.stringify({ format: "ops392.phase-a-observation.v1", bookTs }));
        if (bytes.length > 4096) return false;
        const frame = Buffer.allocUnsafe(4 + bytes.length);
        frame.writeUInt32BE(bytes.length);
        bytes.copy(frame, 4);
        // A false return still owns the one outstanding frame. Never retry.
        return current.write(frame);
      } catch {
        current.destroy();
        return false;
      }
    },
    stop() { stopped = true; credit = false; socket?.destroy(); },
  };
}
