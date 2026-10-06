import path from "node:path";

export const PAPER_PORT = 4002;
export const LIVE_PORT = 4001;
export const LISTEN_HOST = "100.64.0.6";
export const LISTEN_PORT = 8470;
export const DEFAULT_PEERS = Object.freeze(["100.64.0.9", "100.64.0.14"]);

export function confinedPath(root, candidate, label = "path") {
  if (typeof candidate !== "string" || candidate.length === 0 || candidate.includes("\0")) {
    throw new Error(`${label} is invalid`);
  }
  const resolvedRoot = path.resolve(root);
  const resolvedPath = path.resolve(candidate);
  const relative = path.relative(resolvedRoot, resolvedPath);
  if (!resolvedPath.startsWith(`${resolvedRoot}${path.sep}`)
      || relative === "" || relative === ".." || relative.startsWith(`..${path.sep}`)
      || path.isAbsolute(relative)) {
    throw new Error(`${label} must be beneath ${resolvedRoot}`);
  }
  return resolvedPath;
}

export function assertPaperPort(port) {
  const value = Number(port);
  if (value === LIVE_PORT) throw new Error("live port 4001 is refused");
  if (value !== PAPER_PORT) throw new Error("executor refuses any non-paper port");
  return PAPER_PORT;
}

export function assertGatewayHost(host) {
  if (host !== LISTEN_HOST) throw new Error("executor refuses an undeclared Gateway host");
  return LISTEN_HOST;
}

export function normalizePeer(address) {
  const raw = String(address || "").trim().toLowerCase();
  if (raw.startsWith("::ffff:")) return raw.slice("::ffff:".length);
  return raw;
}

function ipv4Parts(value) {
  const parts = String(value).split(".");
  if (parts.length !== 4) return null;
  const numbers = parts.map((part) => (/^\d{1,3}$/.test(part) ? Number(part) : NaN));
  if (numbers.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return null;
  return numbers;
}

export function isTailnetIPv4(value) {
  const parts = ipv4Parts(value);
  // Tailscale CGNAT is 100.64.0.0/10.
  return Boolean(parts && parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127);
}

export function assertPeerAllowlist(candidates, { testMode = false } = {}) {
  if (!Array.isArray(candidates) || candidates.length === 0 || candidates.length > 32) {
    throw new Error("peer allowlist is empty");
  }
  const peers = [];
  for (const candidate of candidates) {
    const peer = normalizePeer(candidate);
    const loopbackOk = testMode && peer === "127.0.0.1";
    if (!loopbackOk && !isTailnetIPv4(peer)) throw new Error("peer allowlist entry is not a tailnet address");
    if (!peers.includes(peer)) peers.push(peer);
  }
  return Object.freeze(peers);
}

export function peerAllowed(address, allowlist) {
  return allowlist.includes(normalizePeer(address));
}

export function assertListen(host, port, { testMode = false } = {}) {
  const normalized = normalizePeer(host);
  const listenPort = Number(port);
  if (!Number.isInteger(listenPort) || listenPort < 0 || listenPort > 65535) {
    throw new Error("listen port is invalid");
  }
  if (testMode) {
    if (normalized !== "127.0.0.1") throw new Error("test listener must stay on loopback");
    return { host: "127.0.0.1", port: listenPort };
  }
  if (normalized !== LISTEN_HOST) throw new Error("executor listens only on the hsb0 tailnet address");
  if (listenPort !== LISTEN_PORT) throw new Error("executor listens only on port 8470");
  return { host: LISTEN_HOST, port: LISTEN_PORT };
}
