import { request as httpRequest } from "node:http";

export const DELIVERY_TIMEOUT_MS = 1000;

// An absolute timer bounds connection, headers and response together, including
// a peer that trickles bytes. Never expose response data or exception messages.
export function postLocalMessage(socketPath, body, key, { request = httpRequest, timeoutMs = DELIVERY_TIMEOUT_MS } = {}) {
  if (!socketPath || !Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 2000) return Promise.reject(new Error("mailbox_unavailable"));
  const payload = JSON.stringify({ to: "amy", ticket: "JOED-43", body });
  return new Promise((resolve, reject) => {
    let req, timer, settled = false;
    const finish = ok => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (ok) resolve();
      else { req?.destroy(); reject(new Error("mailbox_unavailable")); }
    };
    timer = setTimeout(() => finish(false), timeoutMs);
    try {
      req = request({ socketPath, path: "/v1/messages", method: "POST", agent: false,
        headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload),
          "X-Ticket": "JOED-43", ...(key ? { "Idempotency-Key": key } : {}) } }, response => {
        response.on("error", () => finish(false));
        response.on("aborted", () => finish(false));
        response.on("end", () => finish(response.statusCode === 201));
        response.resume();
      });
      req.on("error", () => finish(false));
      req.end(payload);
    } catch { finish(false); }
  });
}

