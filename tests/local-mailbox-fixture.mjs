import { EventEmitter } from "node:events";
import { Readable } from "node:stream";

// Exercise the actual listener callback without binding a host network port.
export async function mailboxRequest(app, { local = true, method = "POST", url = "/v1/messages", body,
  peer = "100.64.0.14", headers = {}, chunks } = {}) {
  const raw = body === undefined ? "" : JSON.stringify(body);
  const request = Readable.from(chunks ?? (raw ? [Buffer.from(raw)] : []));
  Object.assign(request, { method, url, socket: { remoteAddress: peer },
    headers: { "content-type": "application/json", "x-ticket": "JOED-43", ...headers } });
  return new Promise(resolve => {
    const response = {
      writeHead(status, responseHeaders) { this.status = status; this.headers = responseHeaders; },
      end(payload) { resolve({ status: this.status, headers: this.headers, body: JSON.parse(payload) }); },
    };
    (local ? app.localServer : app.server).emit("request", request, response);
  });
}

export function mailboxHttpRequest(app, { loseReply = () => false } = {}) {
  return (options, onResponse) => {
    const request = new EventEmitter();
    request.destroy = () => {};
    request.end = payload => {
      mailboxRequest(app, { body: JSON.parse(payload), headers: Object.fromEntries(Object.entries(options.headers).map(([key, value]) => [key.toLowerCase(), value])) }).then(result => {
        if (loseReply()) { request.emit("error", new Error("synthetic lost reply")); return; }
        const response = new EventEmitter();
        response.statusCode = result.status;
        response.resume = () => queueMicrotask(() => response.emit("end"));
        onResponse(response);
      }).catch(error => request.emit("error", error));
    };
    return request;
  };
}
