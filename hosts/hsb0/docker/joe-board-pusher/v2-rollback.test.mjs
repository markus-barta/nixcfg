import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";
import { StageStore, prepareLock } from "./v2-stage-worker.mjs";
import { FRAME_FORMAT } from "./v2-stage-handoff.mjs";
import { startCycle } from "./v1-cycle.mjs";
import { createCycleStore } from "./v1-cycle-store.mjs";
import { copyObservation } from "./v2-stage-handoff.mjs";
import { deskOwnershipPolicyContract } from "./desk-ledger.mjs";
import { createExecutorAttributionMemory } from "./executor-attribution-memory.mjs";
import { readExecutorAttribution } from "./executor-attribution.mjs";

const fixture = new URL("./fixtures/r15/", import.meta.url);
const revision = "0c4e2946fc5ea220c72b57709db00710ebd3ba8c";
const sha = bytes => createHash("sha256").update(bytes).digest("hex");
const json = name => JSON.parse(fs.readFileSync(name));
const instant = "2026-10-20T11:00:00.000Z";
const at = seconds => new Date(Date.parse(instant) + seconds * 1000).toISOString();

function verifyR15() {
  const provenance = json(new URL("provenance.json", fixture));
  assert.equal(provenance.revision, revision);
  assert.equal(provenance.sourceDirectory, "hosts/hsb0/docker/joe-board-pusher");
  const files = fs.readdirSync(fixture, { recursive: true })
    .filter(name => fs.lstatSync(new URL(name, fixture)).isFile() && name !== "provenance.json").sort();
  assert.deepEqual(files, Object.keys(provenance.files).sort());
  for (const name of files) {
    const bytes = fs.readFileSync(new URL(name, fixture));
    assert.deepEqual({ bytes: bytes.length, sha256: sha(bytes) }, provenance.files[name], name);
  }
}

test("rollback fixture preserves the exact r15 worker and complete import/contract closure", async () => {
  verifyR15();
  const { verify } = await import("./fixtures/r15/verify-contracts.mjs");
  assert.equal(verify(), true);
});

test("actual r16 opens r16d pairs in place and continues above the saved high-water", async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ops404-r16d-rollback-"));
  t.after(() => spawnSync("trash", [root]));
  const runtime = path.join(root, "r16"), v2 = path.join(root, "v2");
  const tree = "hosts/hsb0/docker/joe-board-pusher";
  const r16Revision = "0a20ef6da3b6d3a26fd8c7e7a0719ede0c595558";
  const files = execFileSync("git", ["ls-tree", "--full-tree", "-r", "--name-only", `${r16Revision}:${tree}`], { encoding: "utf8" }).trim().split("\n");
  for (const name of files.filter(name => (/^[^/]+\.mjs$/.test(name) && !name.endsWith(".test.mjs"))
    || name === "contracts.lock.json" || name.startsWith("contracts/"))) {
    const destination = path.join(runtime, name);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.writeFileSync(destination, execFileSync("git", ["show", `${r16Revision}:${tree}/${name}`]));
  }
  const { StageStore: R16Store } = await import(pathToFileURL(path.join(runtime, "v2-stage-worker.mjs")));
  fs.mkdirSync(v2, { mode: 0o700 });
  const options = { root: v2, uid: process.getuid(), gid: process.getgid() };
  prepareLock(v2, options.uid, options.gid);
  const r16d = new StageStore(options); r16d.enroll(); await r16d.open();
  const observation = {
    format: FRAME_FORMAT, bookTs: instant,
    equity: { value: "100.00", currency: "EUR" }, cash: { value: "10.00", currency: "EUR" },
    sourceObservedAt: { equity: instant, cash: instant, positions: at(120) },
    apiReplyCheckedAt: at(120), positions: [],
  };
  assert.equal(r16d.stage(observation, () => at(150)).status, 200);
  const before = new Map(["sequence-state.json", "current.json", "receipts.jsonl", "pair-1/snapshot.json", "pair-1/receipt.json"]
    .map(name => [name, fs.readFileSync(path.join(v2, name))]));
  const lockInode = fs.statSync(path.join(v2, ".allocator.lock")).ino;
  const rollback = await new R16Store(options).open();
  assert.deepEqual(rollback.retainedSeqs(), [1]);
  assert.equal(rollback.previous.value.positions.observedAt, at(120));
  for (const [name, bytes] of before) assert.deepEqual(fs.readFileSync(path.join(v2, name)), bytes, name);
  assert.equal(fs.statSync(path.join(v2, ".allocator.lock")).ino, lockInode);
  assert.deepEqual(rollback.stage({ ...observation, apiReplyCheckedAt: at(151) }, () => at(151)), { status: 200, reason: null, seq: 2 });
  assert.deepEqual((await new StageStore(options).open()).retainedSeqs(), [1, 2]);
});

test("actual r15 rejects r16 pairs; move-aside preserves evidence and resumes above high-water within one IB cycle", async t => {
  verifyR15();
  const { StageStore: R15Store } = await import("./fixtures/r15/v2-stage-worker.mjs");
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ops404-rollback-"));
  t.after(() => spawnSync("trash", [root]));
  const v2 = path.join(root, "v2");
  const cycles = path.join(root, "v1-cycles");
  const backup = path.join(root, "rollback-r16-20261020T110100Z");
  fs.mkdirSync(v2, { mode: 0o700 });
  const options = { root: v2, uid: process.getuid(), gid: process.getgid() };
  prepareLock(v2, options.uid, options.gid);
  const r16 = new StageStore(options);
  r16.enroll();
  await r16.open();
  const writer = createCycleStore({ root: cycles });
  for (const seconds of [30, 60]) {
    const generatedAt = at(seconds);
    const body = JSON.stringify({ schema: "inspr.joe.household.v1", generatedAt: instant, masked: true });
    const observation = {
      format: FRAME_FORMAT, bookTs: instant,
      equity: { value: "100.00", currency: "EUR" }, cash: { value: "10.00", currency: "EUR" },
      apiReplyCheckedAt: generatedAt, positions: [],
      v1Cycle: startCycle(body)(200, generatedAt),
    };
    const reservation = r16.reserve(observation, generatedAt);
    assert.equal(reservation.status, 200);
    assert.equal(await writer.write(reservation.seq, body, observation.v1Cycle.v1Sha256), true);
    assert.equal(r16.stage(observation, () => generatedAt, reservation, true).status, 200);
  }
  assert.deepEqual(r16.retainedSeqs(), [1, 2]);
  const statePath = path.join(v2, "sequence-state.json");
  const logPath = path.join(v2, "receipts.jsonl");
  const beforeState = fs.readFileSync(statePath);
  const beforeLog = fs.readFileSync(logPath);
  const beforeLock = fs.statSync(path.join(v2, ".allocator.lock")).ino;
  const bodies = fs.readdirSync(cycles).map(name => [name, fs.readFileSync(path.join(cycles, name))]);
  const pairs = new Map(r16.retainedSeqs().map(seq => {
    const name = `pair-${seq}`;
    const snapshot = fs.readFileSync(path.join(v2, name, "snapshot.json"));
    const receipt = fs.readFileSync(path.join(v2, name, "receipt.json"));
    const value = JSON.parse(snapshot);
    assert.equal(value.brokerAccount.observedAt, instant);
    assert.equal(value.positions.observedAt, instant);
    assert.notEqual(value.generatedAt, instant);
    assert.equal(new R15Store(options).validProjection(value), false);
    return [name, { snapshot, receipt }];
  }));
  const pointer = fs.readFileSync(path.join(v2, "current.json"));

  // No move-aside: r15 fails before it can publish or alter the allocator/log.
  await assert.rejects(new R15Store(options).open(), /stage_storage_invalid/);
  assert.deepEqual(fs.readFileSync(statePath), beforeState);
  assert.deepEqual(fs.readFileSync(logPath), beforeLog);
  assert.deepEqual(fs.readFileSync(path.join(v2, "current.json")), pointer);

  // RUNBOOK step 2: the backup is a sibling, never unknown residue inside v2.
  fs.mkdirSync(backup, { mode: 0o700 });
  fs.cpSync(cycles, path.join(backup, "v1-cycles"), { recursive: true });
  fs.renameSync(path.join(v2, "current.json"), path.join(backup, "current.json"));
  // Moving only the pointer is insufficient: retained pairs are also validated.
  await assert.rejects(new R15Store(options).open(), /stage_storage_invalid/);
  for (const name of pairs.keys()) fs.renameSync(path.join(v2, name), path.join(backup, name));
  assert.deepEqual(fs.readdirSync(v2).sort(), [".allocator.lock", "receipts.jsonl", "sequence-state.json"]);
  assert.deepEqual(fs.readFileSync(statePath), beforeState);
  assert.deepEqual(fs.readFileSync(logPath), beforeLog);
  assert.equal(fs.statSync(path.join(v2, ".allocator.lock")).ino, beforeLock);
  for (const [name, bytes] of bodies) assert.deepEqual(fs.readFileSync(path.join(cycles, name)), bytes);

  const r15 = await new R15Store(options).open();
  assert.deepEqual(r15.retainedSeqs(), []);
  assert.equal(r15.current, null);
  assert.equal(r15.previous, null);
  assert.equal(r15.state.lastReservedSeq, 2);
  assert.equal(r15.state.lastGeneratedAt, at(60));
  assert.deepEqual(fs.readFileSync(statePath), beforeState);
  assert.deepEqual(fs.readFileSync(logPath), beforeLog);
  for (const bookTs of [instant, at(59)]) {
    assert.deepEqual(r15.stage(bookTs, () => at(60)), { status: 422, reason: "source_time_invalid" });
    assert.deepEqual(fs.readFileSync(statePath), beforeState);
    assert.deepEqual(fs.readFileSync(logPath), beforeLog);
  }

  // A healthy next IB update is 180 s after the old book, 120 s after rollback.
  const nextBook = at(180);
  assert.ok(Date.parse(nextBook) - Date.parse(r15.state.lastGeneratedAt) <= 180_000);
  assert.deepEqual(r15.stage(nextBook, () => nextBook), { status: 200, reason: null, seq: 3 });
  assert.equal(json(statePath).lastReservedSeq, 3);
  assert.equal(json(path.join(v2, "current.json")).pair, "pair-3");
  const next = json(path.join(v2, "pair-3/snapshot.json"));
  assert.equal(next.generatedAt, nextBook);
  assert.equal(next.brokerAccount.observedAt, nextBook);
  assert.equal(next.positions.observedAt, nextBook);
  assert.ok(fs.readFileSync(logPath).subarray(0, beforeLog.length).equals(beforeLog));
  assert.deepEqual(jsonLines(logPath).map(row => row.seq), [1, 2, 3]);
  assert.deepEqual((await new R15Store(options).open()).retainedSeqs(), [3]);

  // Normal pusher reconnect pruning must not erase archived v1 provenance.
  await writer.prune(r15.retainedSeqs());
  assert.deepEqual(fs.readFileSync(path.join(backup, "current.json")), pointer);
  for (const [name, bytes] of bodies) assert.deepEqual(fs.readFileSync(path.join(backup, "v1-cycles", name)), bytes);
  for (const [name, bytes] of pairs) {
    assert.deepEqual(fs.readFileSync(path.join(backup, name, "snapshot.json")), bytes.snapshot);
    assert.deepEqual(fs.readFileSync(path.join(backup, name, "receipt.json")), bytes.receipt);
  }
  assert.equal(fs.statSync(backup).mode & 0o777, 0o700);
});

function jsonLines(name) {
  return fs.readFileSync(name, "utf8").trim().split("\n").map(line => JSON.parse(line));
}

for (const revision of [9, 10, 11]) test(`pre-OPS-557 rev ${revision} rejects new basis pairs; documented move-aside resumes above high-water`, async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ops557-rollback-"));
  t.after(() => spawnSync("trash", [root]));
  const runtime = path.join(root, "pre-ops557");
  const base = "84ae0f6219eb36784376c8d49fde7b797d9a2005"; // JOED-149, #1224.
  const tree = "hosts/hsb0/docker/joe-board-pusher";
  // Import the actual old worker with its complete runtime/contract closure.
  // No copied or approximated validation logic can mask a rollback regression.
  const files = execFileSync("git", ["ls-tree", "--full-tree", "-r", "--name-only", `${base}:${tree}`], { encoding: "utf8" }).trim().split("\n");
  for (const name of files.filter(name => (/^[^/]+\.mjs$/.test(name) && !name.endsWith(".test.mjs"))
    || name === "contracts.lock.json" || name.startsWith("contracts/"))) {
    const destination = path.join(runtime, name);
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.writeFileSync(destination, execFileSync("git", ["show", `${base}:${tree}/${name}`]));
  }
  const { StageStore: OldStore, validObservation: oldValidObservation } = await import(pathToFileURL(path.join(runtime, "v2-stage-worker.mjs")));
  const { createV2Publisher: oldPublisher, createPostStateStore: oldPostState } = await import(pathToFileURL(path.join(runtime, "v2-publisher.mjs")));
  let memoryPath, memoryBytes;
  if (revision === 11) await t.test("r21 rejects the whole j3 memory; preserving it permits roll-forward attribution", async () => {
    const { createExecutorAttributionMemory: oldMemory } = await import(pathToFileURL(path.join(runtime, "executor-attribution-memory.mjs")));
    const { readExecutorAttribution: oldAttribution } = await import(pathToFileURL(path.join(runtime, "executor-attribution.mjs")));
    const account = "DUROLLBACK";
    const memory = createExecutorAttributionMemory({ account });
    const executions = ["j3", "joe"].map((subDesk, index) => {
      const execution = { acctNumber: account, execId: `rollback.memory.${index}.01`, clientId: 705,
        orderId: 900 + index, side: "BOT", shares: 1, price: 1, time: instant };
      memory.record({ clientId: execution.clientId, execId: execution.execId, orderId: execution.orderId,
        desk: subDesk === "j3" ? "j" : "joe", subDesk, source: "intent", provenAt: instant });
      return { contract: { conId: 557, symbol: "MEMORY", secType: "STK", currency: "USD" }, execution };
    });
    const state = memory.snapshot();
    const legacyCompatible = structuredClone(state);
    delete legacyCompatible.entries[JSON.stringify([account, 705, executions[0].execution.execId])];
    assert.doesNotThrow(() => oldMemory({ account, state: legacyCompatible }), "Joe proof alone is compatible");
    assert.throws(() => oldMemory({ account, state }), /memory unavailable/, "one j3 entry rejects even the Joe proof");
    memoryPath = path.join(root, "executor-attribution-memory.json");
    memoryBytes = Buffer.from(JSON.stringify(state));
    fs.writeFileSync(memoryPath, memoryBytes, { mode: 0o600 });
    const ledgerPath = path.join(root, "executor-ledger.json");
    fs.writeFileSync(ledgerPath, JSON.stringify({ schema: "barta.paper-desk-executor-state.v1", account, executions,
      intents: Object.fromEntries(["j3", "joe"].map((desk, index) => [desk, { action: "place", desk,
        result: { bracket: { clientId: 705, parentOrderId: 900 + index } } }])) }));
    const options = { account, file: ledgerPath, memoryFile: memoryPath, remember: true, onEvent() {} };
    const rollbackAttribution = oldAttribution(options);
    for (const { execution } of executions) assert.throws(() => rollbackAttribution.attribute(execution), /ledger_unavailable/);
    assert.deepEqual(fs.readFileSync(memoryPath), memoryBytes, "rollback must preserve the incompatible proof file");
    const forward = readExecutorAttribution(options);
    assert.deepEqual(executions.map(({ execution }) => {
      const { desk, subDesk } = forward.attribute(execution);
      return { desk, subDesk };
    }), [{ desk: "j", subDesk: "j3" }, { desk: "joe", subDesk: "joe" }]);
    assert.deepEqual(fs.readFileSync(memoryPath), memoryBytes, "roll-forward reuses both exact proofs unchanged");
  });
  const v2 = path.join(root, "v2"), cycles = path.join(root, "v1-cycles"), backup = path.join(root, "rollback-ops557");
  fs.mkdirSync(v2, { mode: 0o700 });
  const options = { root: v2, uid: process.getuid(), gid: process.getgid(), revision, env: {} };
  prepareLock(v2, options.uid, options.gid);
  const store = new StageStore(options); store.enroll(); await store.open();
  const writer = createCycleStore({ root: cycles });
  const basis = `desk-policy-${deskOwnershipPolicyContract().policyHash.slice(0, 12)}`;
  let newObservation;
  for (const seconds of [30, 60]) {
    const generatedAt = at(seconds);
    const body = JSON.stringify({ schema: "inspr.joe.household.v1", generatedAt, masked: true });
    const observation = copyObservation({
      book: { ts: generatedAt, apiReplyCheckedAt: generatedAt, gateway: true, summary: {}, positions: [], portfolio: [] },
      ...(seconds === 60 ? { historyBasis: basis } : {}),
      v1Cycle: startCycle(body)(200, generatedAt),
    }, revision);
    if (seconds === 30) assert.equal(oldValidObservation(observation), true, "old handoff without a basis is accepted");
    const reservation = store.reserve(observation, generatedAt);
    assert.equal(reservation.status, 200);
    assert.equal(await writer.write(reservation.seq, body, observation.v1Cycle.v1Sha256), true);
    assert.equal(store.stage(observation, () => generatedAt, reservation, true).status, 200);
    if (seconds === 60) newObservation = observation;
  }
  assert.equal(oldValidObservation(newObservation), false, "mixed old/new handoffs are rejected too");
  const pairs = new Map(store.retainedSeqs().map(seq => [`pair-${seq}`, new Map(["snapshot.json", "receipt.json"]
    .map(name => [name, fs.readFileSync(path.join(v2, `pair-${seq}`, name))]))]));
  const v1 = new Map(fs.readdirSync(cycles).map(name => [name, fs.readFileSync(path.join(cycles, name))]));
  const before = new Map(["current.json", "sequence-state.json", "receipts.jsonl"]
    .map(name => [name, fs.readFileSync(path.join(v2, name))]));
  const lockInode = fs.statSync(path.join(v2, ".allocator.lock")).ino;
  const postPath = path.join(root, "v2-post-state.json");
  const postState = oldPostState({ file: postPath });
  postState.save({ format: "ops408.v2-post-state.v1",
    lastPosted: { seq: 1, sha256: sha(pairs.get("pair-1").get("snapshot.json")) },
    pending: { seq: 2, sha256: sha(pairs.get("pair-2").get("snapshot.json")) }, outcomes: [] });
  const beforePost = fs.readFileSync(postPath);
  const rollback = new OldStore(options);
  await assert.rejects(rollback.open(), /stage_storage_invalid/);
  assert.equal(rollback.validProjection(JSON.parse(pairs.get("pair-1").get("snapshot.json"))), true);
  assert.equal(rollback.validProjection(JSON.parse(pairs.get("pair-2").get("snapshot.json"))), false);
  assert.throws(() => rollback.readCommittedPair(), /stage_storage_invalid/);
  let sends = 0;
  const publish = reader => oldPublisher({ reader, now: () => at(180),
    stateStore: postState,
    emit() {}, send: async () => { sends++; return { ok: true, status: 200,
      text: async () => JSON.stringify({ receivedAt: at(180) }) }; },
  }).push({ url: "http://fixture.invalid/joe/inbox", token: "synthetic-rollback" });
  assert.equal(await publish(rollback), null);
  assert.equal(sends, 0, "old publisher cannot read or send the new pair");
  assert.deepEqual(fs.readFileSync(postPath), beforePost);
  for (const [name, bytes] of before) assert.deepEqual(fs.readFileSync(path.join(v2, name)), bytes);

  // README order: stop both processes, archive v1 evidence, move pointer and
  // every pair outside v2; leave the allocator, lock and append-only log intact.
  fs.mkdirSync(backup, { mode: 0o700 });
  fs.cpSync(cycles, path.join(backup, "v1-cycles"), { recursive: true });
  fs.copyFileSync(postPath, path.join(backup, "v2-post-state.json"));
  fs.renameSync(path.join(v2, "current.json"), path.join(backup, "current.json"));
  await assert.rejects(new OldStore(options).open(), /stage_storage_invalid/,
    "moving the pointer alone leaves incompatible retained pairs");
  for (const name of pairs.keys()) fs.renameSync(path.join(v2, name), path.join(backup, name));
  assert.deepEqual(fs.readdirSync(v2).sort(), [".allocator.lock", "receipts.jsonl", "sequence-state.json"]);
  for (const name of ["sequence-state.json", "receipts.jsonl"]) assert.deepEqual(fs.readFileSync(path.join(v2, name)), before.get(name));
  assert.equal(fs.statSync(path.join(v2, ".allocator.lock")).ino, lockInode);
  const old = await new OldStore(options).open();
  assert.deepEqual(old.retainedSeqs(), []);
  assert.equal(old.readCommittedPair(), null);
  assert.equal(old.state.lastReservedSeq, 2);
  assert.equal(old.state.lastGeneratedAt, at(60));
  assert.deepEqual(fs.readFileSync(postPath), beforePost, "rollback preserves the durable cursor and uncertain POST");
  const next = copyObservation({ book: { ts: at(180), apiReplyCheckedAt: at(180), gateway: true, summary: {}, positions: [], portfolio: [] } }, revision);
  assert.deepEqual(old.stage(next, () => at(180)), { status: 200, reason: null, seq: 3 });
  assert.equal((await publish(old)).status, 200);
  assert.equal(sends, 1);
  assert.deepEqual(postState.load().lastPosted, { seq: 3, sha256: sha(old.readCommittedPair().bytes) });
  assert.equal(postState.load().pending, null);
  assert.equal(fs.statSync(path.join(v2, ".allocator.lock")).ino, lockInode);
  assert.deepEqual(jsonLines(path.join(v2, "receipts.jsonl")).map(row => row.seq), [1, 2, 3]);
  assert.ok(fs.readFileSync(path.join(v2, "receipts.jsonl")).subarray(0, before.get("receipts.jsonl").length).equals(before.get("receipts.jsonl")));
  assert.deepEqual((await new OldStore(options).open()).retainedSeqs(), [3]);
  await writer.prune(old.retainedSeqs());
  assert.deepEqual(fs.readFileSync(path.join(backup, "current.json")), before.get("current.json"));
  for (const [name, files] of pairs) for (const [file, bytes] of files) assert.deepEqual(fs.readFileSync(path.join(backup, name, file)), bytes);
  for (const [name, bytes] of v1) assert.deepEqual(fs.readFileSync(path.join(backup, "v1-cycles", name)), bytes);
  assert.deepEqual(fs.readFileSync(path.join(backup, "v2-post-state.json")), beforePost);
  if (memoryPath) assert.deepEqual(fs.readFileSync(memoryPath), memoryBytes, "stager recovery leaves attribution memory intact");
});
