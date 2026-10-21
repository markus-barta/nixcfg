import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { Readable } from "node:stream";
import { StageStore, prepareLock } from "./v2-stage-worker.mjs";
import { createV2Publisher, createPostStateStore } from "./v2-publisher.mjs";

const checkout = process.env.JOEDESK_CHECKOUT;
test("real d36b5295 board accepts committed v2 bytes fresh; identical replay is benign; v1 is rejected without replacing retained state", {
  skip: checkout ? false : "JOEDESK_CHECKOUT unset; real JoeDesk checkout is not available in CI",
}, async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ops408-board-"));
  fs.chmodSync(root, 0o700);
  t.after(() => spawnSync("trash", [root]));
  const dataDir = path.join(root, "board"), v2 = path.join(root, "v2");
  fs.mkdirSync(dataDir, { mode: 0o700 }); fs.mkdirSync(v2, { mode: 0o700 });
  const at = "2026-10-20T20:00:00.000Z";
  const opts = { root: v2, uid: process.getuid(), gid: process.getgid() };
  prepareLock(v2, opts.uid, opts.gid);
  const reader = new StageStore(opts); reader.enroll(); await reader.open();
  assert.equal(reader.stage({ bookTs: at, apiReplyCheckedAt: at }, () => at).status, 200);
  const { createJoeServer } = await import(pathToFileURL(path.join(checkout, "server.mjs")));
  const token = "ops408-synthetic-contract-token";
  const server = createJoeServer({ dataDir, clock: () => at, inboxToken: token });
  const inProcess = process.env.JOEDESK_CONTRACT_TRANSPORT === "in-process";
  if (!inProcess) {
    await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
    t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  } else t.diagnostic("in-process real HTTP handler; socket transport not exercised (sandbox denies loopback listen)");
  const url = inProcess ? "http://fixture.invalid/joe/inbox" : `http://127.0.0.1:${server.address().port}/joe/inbox`;
  const send = inProcess ? (_url, options) => new Promise(resolve => {
    const req = Readable.from([Buffer.from(options.body)]);
    Object.assign(req, { method: options.method, url: "/joe/inbox",
      headers: Object.fromEntries(Object.entries(options.headers).map(([key, value]) => [key.toLowerCase(), value])) });
    const res = { writeHead(status) { this.statusCode = status; },
      end(body) { resolve(new Response(body, { status: this.statusCode })); } };
    server.emit("request", req, res);
  }) : fetch;
  const receipts = [];
  const publisher = file => createV2Publisher({ reader, stateStore: createPostStateStore({ file }), now: () => at, send, emit: event => receipts.push(event) });
  const accepted = await publisher(path.join(root, "post-state.json")).push({ url, token });
  assert.equal(accepted.status, 200); assert.equal(accepted.outcome, "accepted");
  assert.equal(accepted.receivedAt, at);
  assert.equal(server.readModel.panels(at).halt.state, "fresh");
  const state = fs.readFileSync(path.join(dataDir, "data-state.json"));
  const pair = reader.readCommittedPair();
  const feed = server.readModel.feeds().data;
  const { receivedAt, ...ingress } = feed.value;
  assert.deepEqual(ingress, JSON.parse(pair.bytes)); assert.equal(receivedAt, at);
  // This is also the migrate-v2 case: the board already holds seq N, and a
  // newly activated pusher without a cursor sends that exact retained pair.
  const seeded = publisher(path.join(root, "fresh-post-state.json"));
  const replay = await seeded.push({ url, token });
  assert.equal(replay.status, 422); assert.equal(replay.outcome, "sequence_replayed");
  assert.equal(await seeded.push({ url, token }), null);
  assert.equal(server.readModel.panels(at).halt.state, "fresh");
  assert.deepEqual(fs.readFileSync(path.join(dataDir, "data-state.json")), state);
  const v1 = await send(url, { method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: '{"schema":"inspr.joe.household.v1"}' });
  assert.equal(v1.status, 422); assert.equal((await v1.json()).reason, "schema_unsupported");
  assert.deepEqual(fs.readFileSync(path.join(dataDir, "data-state.json")), state);
  assert.doesNotMatch(JSON.stringify(receipts), /brokerAccount|synthetic-contract-token|"schema"/);
});
