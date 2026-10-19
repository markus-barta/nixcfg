import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, mkdirSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import path from "node:path";
import { EventEmitter } from "node:events";
import { Readable } from "node:stream";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import "./paper-desk-account-fixture.mjs"; // OPS-317: the executor requires a configured (synthetic) paper account at import
import { createServer as executor } from "../modules/paper-desk-executor/server.mjs";
import { createServer as mailbox } from "../modules/agent-mailbox/server.mjs";
import { readPeers } from "../modules/tailnet-peers/peers.mjs";

const temporaryRoot = fileURLToPath(new URL("./.tmp/", import.meta.url));
mkdirSync(temporaryRoot, { recursive: true });

function fixture(t) {
  const directory = mkdtempSync(path.join(temporaryRoot, "ops384-reader-"));
  t.after(() => rmSync(directory, { recursive: true }));
  const file = path.join(directory, "peers.json");
  const write = (peers) => {
    writeFileSync(file + ".new", JSON.stringify({ schema: 1, peers }), { mode: 0o600 });
    renameSync(file + ".new", file);
  };
  return { directory, file, write };
}

async function request(app, peer, url = "/v1/health", method = "GET") {
  const input = Readable.from([]);
  Object.assign(input, { method, url, headers: {}, socket: { remoteAddress: peer } });
  let status, body;
  await app.handle(input, {
    writeHead(code) { status = code; },
    end(raw) { body = JSON.parse(raw); },
  });
  return { status, body };
}

for (const [name, create] of [["executor", executor], ["mailbox", mailbox]]) {
  test(`${name}: valid, missing, invalid and atomically changed snapshots are observed`, async (t) => {
    const f = fixture(t);
    mkdirSync(path.join(f.directory, "state"));
    const app = create({
      peersFile: f.file,
      stateDir: path.join(f.directory, "state"),
      gatewayReachable: () => true,
      log: () => {},
    });
    t.after(() => app.close().catch((error) => { if (error.code !== "ERR_SERVER_NOT_RUNNING") throw error; }));
    assert.equal((await request(app, "100.64.0.14")).status, 200);
    assert.equal((await request(app, "100.64.0.23")).status, 403);
    f.write({ "100.64.0.23": "amy" });
    const valid = await request(app, "::ffff:100.64.0.23");
    assert.equal(valid.status, 200);
    if (name === "mailbox") assert.equal(valid.body.identity, "amy");
    if (name === "executor") {
      assert.equal((await request(app, "100.64.0.23", "/v1/admin/attribution", "POST")).status, 403);
    }
    f.write({ "100.64.0.25": "amy" });
    assert.equal((await request(app, "100.64.0.23")).status, 403);
    assert.equal((await request(app, "100.64.0.25")).status, 200);
    for (const invalid of [
      "{broken", "null", "[]", '{"schema":2,"peers":{"100.64.0.25":"amy"}}',
      '{"schema":1,"peers":{"100.64.0.14":"amy"}}',
      '{"schema":1,"peers":{"100.64.0.25":"constructor"}}',
      '{"schema":1,"peers":{"100.64.0.25":"unknown"}}',
      ...(name === "mailbox" ? ['{"schema":1,"peers":{"100.64.0.25":"ops"}}'] : []),
      '{"schema":1,"peers":{"192.0.2.1":"amy"}}',
      '{"schema":1,"peers":[]}', " ".repeat(16385),
    ]) {
      writeFileSync(f.file, invalid);
      assert.equal((await request(app, "100.64.0.25")).status, 403, invalid.slice(0, 80));
      assert.equal((await request(app, "100.64.0.14")).status, 200);
    }
  });
}

test("snapshot reader never admits a dynamic admin source or unsafe file", (t) => {
  const f = fixture(t);
  f.write({ "100.64.0.25": "amy" });
  assert.deepEqual([...readPeers(f.file, { "100.64.0.14": "ops" }, ["amy"], ["100.64.0.25"])],
    [["100.64.0.14", "ops"]]);
  writeFileSync(f.file + ".new", '{"schema":1,"peers":{"100.64.0.25":"amy"}}', { mode: 0o666 });
  renameSync(f.file + ".new", f.file);
  chmodSync(f.file, 0o666);
  assert.deepEqual([...readPeers(f.file, { "100.64.0.14": "ops" }, ["amy"])], [["100.64.0.14", "ops"]]);
});

test("snapshot paths reject traversal, symlinks, arbitrary paths and production overrides", (t) => {
  const f = fixture(t);
  f.write({ "100.64.0.25": "amy" });
  const link = path.join(f.directory, "link.json");
  symlinkSync(f.file, link);
  const directoryLink = path.join(f.directory, "directory-link");
  symlinkSync(f.directory, directoryLink);
  const escape = path.join(f.directory, "escape.json");
  symlinkSync(fileURLToPath(new URL("./fixtures/tailnet-peers/joined.json", import.meta.url)), escape);
  const staticPeers = { "100.64.0.14": "ops" };
  for (const file of [link, escape, path.join(directoryLink, "peers.json"),
    `${f.directory}/../${path.basename(f.directory)}/peers.json`,
    path.relative(process.cwd(), f.file), "/etc/passwd", "/run/tailnet-peers-evil/peers.json",
    "/tailnet-peers/peers.json", undefined, "", 42]) {
    assert.deepEqual([...readPeers(file, staticPeers, ["amy"])], Object.entries(staticPeers), String(file));
  }
  assert.equal(readPeers(f.file, staticPeers, ["amy"]).get("100.64.0.25"), "amy");
  // A normal process (without node --test) cannot opt into a fixture via env.
  const child = spawnSync(process.execPath, ["--input-type=module", "-e", `
    import assert from "node:assert/strict";
    import { readPeers, SNAPSHOT_PATH } from ${JSON.stringify(new URL("../modules/tailnet-peers/peers.mjs", import.meta.url).href)};
    assert.equal(SNAPSHOT_PATH, "/run/tailnet-peers/peers.json");
    assert.deepEqual([...readPeers(process.env.PAPER_DESK_PEERS_FILE, ${JSON.stringify(staticPeers)}, ["amy"])], ${JSON.stringify(Object.entries(staticPeers))});
  `], { env: { PAPER_DESK_PEERS_FILE: f.file }, encoding: "utf8" });
  assert.equal(child.status, 0, child.stderr);
});

test("mailbox revokes active SSE and long polls within 15 seconds of snapshot removal", async (t) => {
  t.mock.timers.enable({ apis: ["setInterval", "setTimeout"] });
  const f = fixture(t);
  f.write({ "100.64.0.23": "amy" });
  const app = mailbox({ peersFile: f.file, stateDir: path.join(f.directory, "state"), log: () => {} });
  t.after(() => app.close());
  const streams = [];
  for (const url of ["/v1/events", "/v1/messages?wait=60"]) {
    const input = Readable.from([]);
    Object.assign(input, { method: "GET", url, headers: {}, socket: { remoteAddress: "100.64.0.23" } });
    const output = new EventEmitter();
    Object.assign(output, {
      writeHead() {}, flushHeaders() {}, write() { return true; },
      end() { this.ended = true; }, destroy() { this.destroyed = true; },
    });
    await app.handle(input, output);
    assert.equal(output.ended, undefined);
    streams.push(output);
  }
  f.write({});
  t.mock.timers.tick(15000);
  for (const output of streams) {
    assert.equal(output.ended, true);
    assert.equal(output.destroyed, true);
  }
});
