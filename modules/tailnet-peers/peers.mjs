// OPS-384: a host-owned snapshot; read per request so replacement/revocation is immediate.
import { closeSync, constants, fstatSync, openSync, readFileSync, realpathSync } from "node:fs";
import { isIP } from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const SNAPSHOT_PATH = "/run/tailnet-peers/peers.json";
const TEST_ROOT = fileURLToPath(new URL("../../tests/.tmp/", import.meta.url));

function snapshotPath(file) {
  // Production always opens the literal host-owned path, never an arbitrary env path.
  if (file === SNAPSHOT_PATH) return SNAPSHOT_PATH;
  if (!process.env.NODE_TEST_CONTEXT || typeof file !== "string" || !path.isAbsolute(file)
      || path.resolve(file) !== file) return undefined;
  const root = path.resolve(TEST_ROOT) + path.sep;
  if (!file.startsWith(root)) return undefined;
  const resolved = realpathSync(file);
  // Reject symlinks as well as escapes; the test root is tied to the source location.
  return resolved === file && resolved.startsWith(root) ? resolved : undefined;
}

export function readPeers(file, staticPeers, identities, excluded = []) {
  const fallback = new Map(Object.entries(staticPeers));
  let fd;
  try {
    const source = snapshotPath(file);
    if (!source) return fallback;
    fd = openSync(source, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size > 16384 || (stat.mode & 0o022)) return fallback;
    const value = JSON.parse(readFileSync(fd, "utf8"));
    if (!value || value.schema !== 1 || Object.keys(value).sort().join(",") !== "peers,schema"
        || !value.peers || typeof value.peers !== "object" || Array.isArray(value.peers)
        || Object.keys(value.peers).length > 32) return fallback;
    const dynamic = Object.entries(value.peers);
    for (const [ip, identity] of dynamic) {
      const octets = ip.split(".").map(Number);
      if (isIP(ip) !== 4 || octets[0] !== 100 || octets[1] < 64 || octets[1] > 127
          || fallback.has(ip) || excluded.includes(ip) || !identities.includes(identity)) return fallback;
    }
    return new Map([...fallback, ...dynamic]);
  } catch {
    return fallback;
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}
