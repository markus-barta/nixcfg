import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import test from "node:test";
import { StageStore, prepareLock, buildCandidate } from "./v2-stage-worker.mjs";
import { createV2Publisher, createPostStateStore, OUTCOME_LIMIT } from "./v2-publisher.mjs";
import { startCycle } from "./v1-cycle.mjs";
import { copyObservation } from "./v2-stage-handoff.mjs";
import { createCycleStore } from "./v1-cycle-store.mjs";
import { runPusher } from "./fixtures/pusher-harness.mjs";

const at = "2026-10-20T20:00:00.000Z";
const sha = bytes => createHash("sha256").update(bytes).digest("hex");
const read = name => JSON.parse(fs.readFileSync(name));
const revision = "67e15fad20c946975e9ce9012ee3d103af0fd18d";
const tree = "hosts/hsb0/docker/joe-board-pusher";
function temp(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ops408-r17-"));
  fs.chmodSync(root, 0o700);
  t.after(() => spawnSync("trash", [root]));
  return root;
}
async function fixture(t, options = {}) {
  const root = temp(t), v2 = path.join(root, "v2"), file = path.join(root, "v2-post-state.json");
  fs.mkdirSync(v2, { mode: 0o700 });
  const identity = { uid: process.getuid(), gid: process.getgid() };
  prepareLock(v2, identity.uid, identity.gid);
  const store = new StageStore({ root: v2, ...identity }); store.enroll(); await store.open();
  const stateStore = createPostStateStore({ file });
  const sent = [], events = [];
  const send = options.send ?? (async (_url, request) => {
    sent.push(request);
    return { ok: true, status: 200, text: async () => JSON.stringify({ receivedAt: at }) };
  });
  const publisher = () => createV2Publisher({ reader: new StageStore({ root: v2, ...identity }), stateStore,
    send, now: () => at, emit: event => events.push(event) });
  const push = instance => instance.push({ url: "http://fixture.invalid/joe/inbox", token: "synthetic-contract-token" });
  return { root, v2, file, store, stateStore, sent, events, publisher, push };
}
function exportBaseline(root) {
  const names = execFileSync("git", ["ls-tree", "-r", "--full-tree", "--name-only", `${revision}:${tree}`], { encoding: "utf8" }).trim().split("\n");
  for (const name of names.filter(n => (/^[^/]+\.mjs$/.test(n) && !n.endsWith(".test.mjs")) || n === "contracts.lock.json" || n.startsWith("contracts/"))) {
    const file = path.join(root, name); fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, execFileSync("git", ["show", `${revision}:${tree}/${name}`]));
  }
  return pathToFileURL(path.join(root, "pusher.mjs"));
}

const gatewaySnapshot = (gateway = { apiSessionReady: true, checkedAt: at }) => {
  const snapshot = buildCandidate(7, at, { apiReplyCheckedAt: at });
  snapshot.safety.gateway = gateway;
  // Synthetic private values must never enter the emitted line.
  snapshot.source.label = "synthetic-private-source";
  snapshot.brokerAccount.equity = { amount: "1234567.89", currency: "EUR" };
  return JSON.stringify(snapshot);
};
const checkedAtAge = age => new Date(Date.parse(at) - age).toISOString();
for (const [name, body, health] of [
  ["fresh check", gatewaySnapshot(), { gateway: true }],
  ["59999 ms check", gatewaySnapshot({ apiSessionReady: true, checkedAt: checkedAtAge(59999) }), { gateway: true }],
  ["60000 ms check", gatewaySnapshot({ apiSessionReady: true, checkedAt: checkedAtAge(60000) }), { gateway: false, lastError: "gateway_unconfirmed" }],
  ["older check", gatewaySnapshot({ apiSessionReady: true, checkedAt: checkedAtAge(60001) }), { gateway: false, lastError: "gateway_unconfirmed" }],
  ["explicitly unready check", gatewaySnapshot({ apiSessionReady: false, checkedAt: at, reason: "clock_regressed" }), { gateway: false, lastError: "clock_regressed" }],
  ["unready check without reason", gatewaySnapshot({ apiSessionReady: false, checkedAt: at }), { gateway: false, lastError: "gateway_unconfirmed" }],
  ["legacy check without readiness flag", gatewaySnapshot({ checkedAt: at }), { gateway: true }],
  ["future check", gatewaySnapshot({ apiSessionReady: true, checkedAt: checkedAtAge(-1) }), { gateway: false, lastError: "gateway_unconfirmed" }],
  ["invalid check time", gatewaySnapshot({ apiSessionReady: true, checkedAt: "unparseable" }), { gateway: false, lastError: "gateway_unconfirmed" }],
  ["missing check time", gatewaySnapshot({ apiSessionReady: true }), { gateway: false, lastError: "gateway_unconfirmed" }],
  ["invalid generation time", JSON.stringify({ generatedAt: "unparseable", safety: { gateway: { checkedAt: at } } }), { gateway: false, lastError: "gateway_unconfirmed" }],
  ["absent gateway", JSON.stringify({ generatedAt: at, safety: {} }), { gateway: false, lastError: "gateway_unknown" }],
  ["absent safety", '{"generatedAt":"' + at + '"}', { gateway: false, lastError: "gateway_unknown" }],
  ["null gateway", gatewaySnapshot(null), { gateway: false, lastError: "gateway_unknown" }],
  ["non-object gateway", gatewaySnapshot("synthetic-private-gateway"), { gateway: false, lastError: "gateway_unknown" }],
  ["array gateway", gatewaySnapshot([]), { gateway: false, lastError: "gateway_unknown" }],
  ["unparseable body", '{"safety":', { gateway: false, lastError: "gateway_unknown" }],
  ["null body", "null", { gateway: false, lastError: "gateway_unknown" }],
  ["body at size bound", gatewaySnapshot().padEnd(262144), { gateway: true }],
  ["oversized body", gatewaySnapshot().padEnd(262145), { gateway: false, lastError: "gateway_unknown" }],
  ...["synthetic-private-reason 1234567.89", "UPPERCASE", "code_123", "clock_regressed\n", "", "a".repeat(65), 42, { value: "synthetic-private-reason" }].map(reason => [
    `unsafe reason ${typeof reason === "string" ? JSON.stringify(reason.slice(0, 24)) : typeof reason}`,
    gatewaySnapshot({ apiSessionReady: false, checkedAt: at, reason }), { gateway: false, lastError: "gateway_unconfirmed" },
  ]),
]) test(`v2_post gateway contract: ${name}; receipt and outcome state unchanged`, async () => {
  const bytes = Buffer.from(body), events = [], saves = [];
  // Deliberately different metadata and wall clock prove health uses only the body.
  const generatedAt = checkedAtAge(-3600000), recordedAt = checkedAtAge(-7200000);
  let state = { format: "ops408.v2-post-state.v1", lastPosted: null, pending: null, outcomes: [] };
  const initial = structuredClone(state), fingerprint = { seq: 7, sha256: sha(bytes) };
  const publisher = createV2Publisher({
    reader: { contracts: async () => {}, readCommittedPair: () => ({ bytes, seq: 7, generatedAt }) },
    stateStore: { load: () => structuredClone(state), save: value => { state = structuredClone(value); saves.push(state); } },
    send: async (_url, request) => {
      assert.strictEqual(request.body, bytes);
      return { ok: true, status: 200, text: async () => JSON.stringify({ receivedAt: at, value: "synthetic-private-reply" }) };
    },
    now: () => recordedAt, emit: event => events.push(event),
  });
  const receipt = { status: 200, seq: 7, generatedAt, receivedAt: at, recordedAt, bodySha256: sha(bytes), outcome: "accepted" };
  assert.deepEqual(await publisher.push({ url: "http://fixture.invalid/joe/inbox", token: "synthetic-contract-token" }), receipt);
  assert.deepEqual(events, [{ event: "v2_post", ...receipt, ...health }]);
  assert.deepEqual(saves, [
    { ...initial, pending: fingerprint },
    { ...initial, lastPosted: fingerprint, outcomes: [receipt] },
  ]);
  assert.equal(JSON.stringify(state), JSON.stringify({ ...initial, lastPosted: fingerprint, outcomes: [receipt] }));
  assert.doesNotMatch(JSON.stringify(events), /synthetic-private|synthetic-contract-token|1234567\.89|brokerAccount|checkedAt|apiSessionReady|"body"/);
  assert.equal(await publisher.push({ url: "http://fixture.invalid/joe/inbox", token: "synthetic-contract-token" }), null);
  assert.equal(events.length, 1);
});

test("v2_post_skipped retains its value-free shape without generatedAt or gateway", async () => {
  const events = [];
  const publisher = createV2Publisher({ reader: { contracts: async () => {}, readCommittedPair() { throw new Error("synthetic-private-fault"); } },
    emit: event => events.push(event) });
  assert.equal(await publisher.push({ url: "http://fixture.invalid/joe/inbox", token: "synthetic-contract-token" }), null);
  assert.deepEqual(events, [{ event: "v2_post_skipped", reason: "committed_pair_or_post_state_unavailable" }]);
});

test("only current.json commits a pair: exact bytes, newest sequence, no new commit, restart cursor and no writes under v2", async t => {
  const f = await fixture(t), publisher = f.publisher();
  assert.equal(await f.push(publisher), null); assert.equal(f.sent.length, 0);
  for (let i = 0; i < 2; i++) assert.equal(f.store.stage(at, () => at).status, 200);
  const before = fs.readdirSync(f.v2, { recursive: true }).filter(n => fs.statSync(path.join(f.v2, n)).isFile())
    .map(n => [n, fs.readFileSync(path.join(f.v2, n))]);
  const bytes = fs.readFileSync(path.join(f.v2, "pair-2/snapshot.json"));
  const result = await f.push(publisher);
  assert.equal(result.seq, 2); assert.equal(result.status, 200); assert.equal(result.bodySha256, sha(bytes));
  assert.deepEqual(f.sent[0].body, bytes);
  assert.deepEqual(f.sent[0].headers, { Authorization: "Bearer synthetic-contract-token", "Content-Type": "application/json", "User-Agent": "joe-board-pusher/1.0" });
  assert.equal(await f.push(publisher), null); assert.equal(await f.push(f.publisher()), null);
  assert.equal(f.sent.length, 1);
  for (const [name, value] of before) assert.deepEqual(fs.readFileSync(path.join(f.v2, name)), value, name);
  assert.equal(f.store.stage(at, () => at).status, 200);
  assert.equal((await f.push(f.publisher())).seq, 3); assert.equal(f.sent.length, 2);
  assert.equal(read(f.file).lastPosted.seq, 3);
  assert.equal(fs.statSync(f.file).mode & 0o777, 0o600);
  assert.equal(JSON.stringify(f.events).includes('"schema"'), false);
  // Regressing a pointer cannot regress publication.
  fs.writeFileSync(path.join(f.v2, "current.json"), JSON.stringify({ format: "ops392.v2-stage-current.v1", pair: "pair-1" }));
  assert.equal(await f.push(f.publisher()), null); assert.equal(f.sent.length, 2);
});

for (const fault of ["pair_rename", "pair_dir_fsync", "snapshot_write", "receipt_fsync"]) test(`crash at ${fault} never publishes the uncommitted pair or reservation`, async t => {
  const f = await fixture(t);
  f.store.boundary = label => { if (label === fault) throw new Error("synthetic"); };
  assert.throws(() => f.store.stage(at, () => at));
  const opened = [];
  const io = new Proxy(fs, { get(target, key) {
    if (key !== "openSync") return target[key];
    return (file, ...args) => { opened.push(String(file)); return target.openSync(file, ...args); };
  } });
  const reader = new StageStore({ root: f.v2, uid: process.getuid(), gid: process.getgid(), io });
  await reader.contracts();
  assert.equal(reader.readCommittedPair(), null);
  assert.equal(await f.push(f.publisher()), null); assert.equal(f.sent.length, 0);
  assert.equal(opened.some(n => /(?:sequence-state|next-|pair-|receipt)/.test(n)), false);
});

test("uncertain acceptance retries identical bytes after restart; sequence_replayed is terminal", async t => {
  let calls = 0; const bodies = [];
  const f = await fixture(t, { send: async (_url, request) => {
    bodies.push(Buffer.from(request.body));
    if (++calls === 1) throw new Error("synthetic response loss");
    return { ok: false, status: 422, text: async () => '{"reason":"sequence_replayed"}' };
  } });
  f.store.stage(at, () => at);
  assert.equal((await f.push(f.publisher())).status, "post_failed");
  assert.equal(read(f.file).pending.seq, 1); assert.equal(read(f.file).lastPosted, null);
  assert.equal((await f.push(f.publisher())).outcome, "sequence_replayed");
  assert.deepEqual(bodies[0], bodies[1]); assert.equal(await f.push(f.publisher()), null);
  assert.equal(calls, 2); assert.equal(read(f.file).lastPosted.seq, 1);
});

for (const fault of ["missing", "corrupt", "symlink", "hash", "cursor"]) test(`v2 fails closed for ${fault}, never substitutes v1`, async t => {
  const f = await fixture(t); f.store.stage(at, () => at);
  const marker = path.join(f.v2, "current.json");
  if (fault === "missing") fs.renameSync(marker, path.join(f.root, "archived-current.json"));
  if (fault === "corrupt") fs.writeFileSync(marker, "broken");
  if (fault === "symlink") { fs.renameSync(marker, path.join(f.root, "archived-current.json")); fs.symlinkSync(path.join(f.root, "archived-current.json"), marker); }
  if (fault === "hash") fs.appendFileSync(path.join(f.v2, "pair-1/snapshot.json"), " ");
  if (fault === "cursor") fs.writeFileSync(f.file, '{"lastPosted":0}', { mode: 0o600 });
  assert.equal(await f.push(f.publisher()), null); assert.equal(f.sent.length, 0);
});

test("single in-flight publisher; bounded value-free outcomes survive failure/restart", async t => {
  let release;
  const f = await fixture(t, { send: () => new Promise(resolve => { release = resolve; }) });
  f.store.stage(at, () => at); const pub = f.publisher(); const pending = f.push(pub);
  // contracts() imports settle before the first transport call.
  while (!release) await new Promise(resolve => setImmediate(resolve));
  assert.equal(await f.push(pub), null);
  release({ ok: false, status: 503, text: async () => '{"secret":"synthetic-private-reply"}' });
  await pending;
  const failed = createV2Publisher({ reader: f.store, stateStore: f.stateStore, now: () => at, emit() {},
    send: async () => ({ ok: false, status: 503, text: async () => "synthetic-private-reply" }) });
  for (let i = 0; i < OUTCOME_LIMIT + 3; i++) await f.push(failed);
  const state = read(f.file);
  assert.equal(state.outcomes.length, OUTCOME_LIMIT); assert.equal(state.pending.seq, 1); assert.equal(state.lastPosted, null);
  const stored = fs.readFileSync(f.file);
  assert.ok(stored.length <= 65536);
  assert.doesNotMatch(stored.toString("utf8"), /synthetic-private|synthetic-contract-token|brokerAccount/);
});

test("chmod read-only simulation rejects write-open of the v2 directory and pair body", async t => {
  const f = await fixture(t); f.store.stage(at, () => at);
  const file = path.join(f.v2, "pair-1/snapshot.json");
  fs.chmodSync(file, 0o400); fs.chmodSync(f.v2, 0o500);
  try {
    assert.throws(() => fs.openSync(file, "w"), error => ["EACCES", "EPERM", "EROFS"].includes(error.code));
    assert.throws(() => fs.openSync(path.join(f.v2, "unexpected"), "w"), error => ["EACCES", "EPERM", "EROFS"].includes(error.code));
    assert.ok(fs.readFileSync(file).length > 0);
  } finally { fs.chmodSync(f.v2, 0o700); fs.chmodSync(file, 0o600); }
});

test("v1 POST, logs and stored cycle bytes match exact 67e15fad for absent and unrecognized switch values", async t => {
  const root = temp(t), baseline = exportBaseline(root), candidate = new URL("./pusher.mjs", import.meta.url);
  for (const variant of ["normal", "retained", "outage"]) {
    const before = await runPusher(baseline, { variant });
    for (const pushSchema of [undefined, "v1", "inspr.joe.household.v1", "inspr.joe.household.v2 ", ""]) {
      const after = await runPusher(candidate, { variant, pushSchema });
      assert.deepEqual(after.requests, before.requests); assert.deepEqual(after.logs, before.logs);
      assert.equal(after.v1Body, before.v1Body); assert.equal(after.v2Calls, 0);
      const normalize = cycle => JSON.stringify({ ...cycle, observationId: "ops392.v1-cycle.00000000-0000-4000-8000-000000000000" });
      assert.equal(normalize(after.cycle), normalize(before.cycle));
      const a = path.join(root, `${variant}-${pushSchema === undefined ? "absent" : Buffer.from(pushSchema).toString("hex")}-cycles`);
      const writer = createCycleStore({ root: a, emit() {} });
      assert.equal(await writer.write(1, after.v1Body, after.cycle.v1Sha256), true);
      assert.deepEqual(fs.readFileSync(path.join(a, "1.json")), before.requests[0].body);
    }
  }
});

test("v2 mode computes and stores v1 evidence as not_posted_v2_active, with no v1 POST", async t => {
  const run = await runPusher(new URL("./pusher.mjs", import.meta.url), { pushSchema: "inspr.joe.household.v2" });
  assert.equal(run.requests.length, 0); assert.equal(run.v2Calls, 1);
  assert.equal(run.cycle.v1Status, "not_posted_v2_active");
  const f = await fixture(t), writer = createCycleStore({ root: path.join(f.root, "v1-cycles") });
  const observation = copyObservation({ book: { ts: at, summary: {}, positions: [] }, v1Cycle: run.cycle });
  const reservation = f.store.reserve(observation, at);
  assert.equal(await writer.write(reservation.seq, run.v1Body, run.cycle.v1Sha256), true);
  assert.equal(f.store.stage(observation, () => at, reservation, true).status, 200);
  const receipt = read(path.join(f.v2, "pair-1/receipt.json"));
  assert.equal(receipt.v1PostStatus, "not_posted_v2_active"); assert.equal(receipt.v1Status, "not_posted_v2_active");
  assert.equal(fs.readFileSync(path.join(f.root, "v1-cycles/1.json"), "utf8"), run.v1Body);
  assert.equal((await new StageStore({ root: f.v2, uid: process.getuid(), gid: process.getgid() }).open()).previous.value.seq, 1);
});

test("r17 rollback: r16d ignores sibling cursor; activated receipts need move-aside, allocator resumes above N", async t => {
  const f = await fixture(t), baseline = path.join(f.root, "baseline"); fs.mkdirSync(baseline); exportBaseline(baseline);
  const { StageStore: OldStore } = await import(pathToFileURL(path.join(baseline, "v2-stage-worker.mjs")));
  const opts = { root: f.v2, uid: process.getuid(), gid: process.getgid() };
  f.store.stage(at, () => at); await f.push(f.publisher());
  assert.equal((await new OldStore(opts).open()).previous.value.seq, 1);
  const observation = { bookTs: at, v1Cycle: startCycle('{}')("not_posted_v2_active", at) };
  f.store.stage(observation, () => at);
  await assert.rejects(new OldStore(opts).open(), /stage_storage_invalid/);
  const before = fs.readFileSync(path.join(f.v2, "sequence-state.json"));
  const lock = fs.statSync(path.join(f.v2, ".allocator.lock")).ino;
  const archive = path.join(f.root, "rollback-archive"); fs.mkdirSync(archive, { mode: 0o700 });
  for (const name of ["pair-1", "pair-2", "current.json", "receipts.jsonl"]) fs.renameSync(path.join(f.v2, name), path.join(archive, name));
  const old = await new OldStore(opts).open();
  assert.deepEqual(fs.readFileSync(path.join(f.v2, "sequence-state.json")), before);
  assert.equal(fs.statSync(path.join(f.v2, ".allocator.lock")).ino, lock);
  assert.equal(old.stage(at, () => at).seq, 3);
  assert.equal(read(f.file).lastPosted.seq, 1);
});

for (const fault of ["writeFileSync", "file_fsync", "renameSync", "directory_fsync"]) test(`posting cursor ${fault} failure before send fails closed and restart recovers its own temporary file`, async t => {
  const f = await fixture(t); f.store.stage(at, () => at);
  const io = new Proxy(fs, { get(target, key) {
    if (key === fault) return () => { throw new Error("synthetic persistence fault"); };
    if (key === "fsyncSync") return fd => {
      if ((fault === "file_fsync" && !fs.fstatSync(fd).isDirectory())
        || (fault === "directory_fsync" && fs.fstatSync(fd).isDirectory())) throw new Error("synthetic fsync fault");
      return fs.fsyncSync(fd);
    };
    return target[key];
  } });
  const broken = createV2Publisher({ reader: f.store, stateStore: createPostStateStore({ file: f.file, io }),
    send: async () => { assert.fail("persistence failure must precede transport"); }, emit() {} });
  assert.equal(await f.push(broken), null);
  assert.equal((await f.push(f.publisher())).status, 200);
  assert.equal(read(f.file).lastPosted.seq, 1);
});

test("accepted POST with failed cursor settlement still logs its outcome and retries identical bytes safely", async t => {
  const f = await fixture(t); f.store.stage(at, () => at);
  let renames = 0, sends = 0; const events = [], hashes = [];
  const io = new Proxy(fs, { get(target, key) {
    if (key !== "renameSync") return target[key];
    return (...args) => { if (++renames === 2) throw new Error("synthetic uncertain settlement"); return target.renameSync(...args); };
  } });
  const send = async (_url, request) => {
    hashes.push(sha(request.body));
    return ++sends === 1 ? { status: 200, ok: true, text: async () => '{}' }
      : { status: 422, ok: false, text: async () => '{"reason":"sequence_replayed"}' };
  };
  const make = stateStore => createV2Publisher({ reader: f.store, stateStore, send, now: () => at, emit: event => events.push(event) });
  assert.equal(await f.push(make(createPostStateStore({ file: f.file, io }))), null);
  assert.equal(events.find(event => event.event === "v2_post").status, 200);
  assert.equal(read(f.file).pending.seq, 1); assert.equal(read(f.file).lastPosted, null);
  const restarted = make(f.stateStore);
  assert.equal((await f.push(restarted)).outcome, "sequence_replayed");
  assert.equal(await f.push(restarted), null); assert.equal(sends, 2); assert.equal(hashes[0], hashes[1]);
  assert.equal(read(f.file).lastPosted.seq, 1);
});

for (const fault of ["pending_hash", "mode", "symlink", "oversized", "temp_mode"]) test(`unsafe ${fault} posting state cannot trigger a v2 POST`, async t => {
  const f = await fixture(t); f.store.stage(at, () => at);
  const state = f.stateStore.load();
  if (fault === "pending_hash") state.pending = { seq: 1, sha256: "0".repeat(64) };
  f.stateStore.save(state);
  if (fault === "mode") fs.chmodSync(f.file, 0o644);
  if (fault === "symlink") { const archived = path.join(f.root, "archived-post-state"); fs.renameSync(f.file, archived); fs.symlinkSync(archived, f.file); }
  if (fault === "oversized") fs.writeFileSync(f.file, " ".repeat(65537));
  if (fault === "temp_mode") { fs.writeFileSync(`${f.file}.tmp`, ""); fs.chmodSync(`${f.file}.tmp`, 0o644); }
  assert.equal(await f.push(f.publisher()), null); assert.equal(f.sent.length, 0);
});
