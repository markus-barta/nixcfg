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
