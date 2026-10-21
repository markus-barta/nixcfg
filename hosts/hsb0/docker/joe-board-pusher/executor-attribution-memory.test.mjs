import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { createExecutorAttribution, readExecutorAttribution } from "./executor-attribution.mjs";
import { ATTRIBUTION_MEMORY_SCHEMA, MAX_MEMORY_BYTES, MAX_MEMORY_ENTRIES,
  createExecutorAttributionMemory, createFileExecutorAttributionMemory } from "./executor-attribution-memory.mjs";
import { seedAttributionMemory } from "./seed-attribution-memory.mjs";
import { executorUnclaimedDiagnostic } from "./diag-executor-unclaimed.mjs";
import { FAMILY_BASELINE_PERIOD_START, createFileFamilyStateStore } from "./family-state.mjs";
import { J_FAMILY_CLASSIFIER, normalizeEconomicExecution } from "./execution-history.mjs";
import { executionActivity } from "./desk-activity.mjs";
import { copyObservation } from "./v2-stage-handoff.mjs";
import { buildCandidate } from "./v2-stage-worker.mjs";

const account = "DUSYNTHETIC";
const instant = "2026-10-19T15:00:00.000Z";
const key = (execId = "SENTINELEXEC.01", clientId = 705) => JSON.stringify([account, clientId, execId]);
const entry = (overrides = {}) => ({ clientId: 705, execId: "SENTINELEXEC.01", orderId: 101,
  desk: "j", subDesk: "j5", provenAt: instant, source: "intent", ...overrides });
const row = (overrides = {}) => ({
  contract: { conId: 99123, symbol: "SENTINELSYMBOL", currency: "USD", secType: "STK", multiplier: 1 },
  execution: { acctNumber: account, clientId: 705, orderId: 101, execId: "SENTINELEXEC.01",
    time: "2026-10-19T14:00:00Z", side: "BOT", shares: 98765, price: 45678.125,
    orderRef: "SENTINELREF|joe", ...overrides },
});
const intent = (desk = "j5", orderId = 101, clientId = 705) => ({ action: "flatten", desk,
  result: { flattened: [{ clientId, orderId }] } });
const ledger = (intents = { SENTINELINTENT: intent() }, executions = [row()]) => ({
  schema: "barta.paper-desk-executor-state.v1", account, intents, executions,
});
const empty = () => ({ schema: ATTRIBUTION_MEMORY_SCHEMA, account, entries: {}, conflicts: [] });
const source = (memory, intents, executions, options = {}) => createExecutorAttribution({ account, memory,
  ledger: ledger(intents, executions), now: () => instant, onEvent() {}, ...options });

function fixture(t, rows = [row()]) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "joed62-memory-"));
  t.after(() => spawnSync("trash", [directory]));
  const familyFile = path.join(directory, "family-ledger.json");
  const executorFile = path.join(directory, "executor-ledger.json");
  const memoryFile = path.join(directory, "executor-attribution-memory.json");
  const snapshotFile = path.join(directory, "snapshot.json");
  const state = { schema: "inspr.joe.family-execution-ledger.v1", version: 1, account,
    periodStart: FAMILY_BASELINE_PERIOD_START, initializedAt: instant, classifier: J_FAMILY_CLASSIFIER,
    executions: rows, commissions: [], queryExecutionIdentities: rows.map(row => row.execution.execId).sort(),
    ledgerObservedAt: instant, coverageThrough: instant, coverageTradingDay: "2026-10-19", family: null };
  createFileFamilyStateStore(familyFile).save(state);
  fs.writeFileSync(executorFile, JSON.stringify(ledger(undefined, rows)));
  fs.writeFileSync(snapshotFile, JSON.stringify(ledger(undefined, rows)), { mode: 0o400 });
  return { directory, familyFile, executorFile, memoryFile, snapshotFile, state, rows, account,
    allowedRoots: [directory, path.join(directory, "temporary-recovery"), path.join(directory, "mounted-recovery")] };
}

test("exact intent proof persists privately; a new reader remembers after pruning without altering raw rows", t => {
  const input = fixture(t);
  const execution = input.rows[0].execution;
  const before = structuredClone(execution);
  const read = () => readExecutorAttribution({ account, file: input.executorFile, memoryFile: input.memoryFile,
    remember: true, onEvent() {} });
  assert.equal(read().attribute(execution).subDesk, "j5");
  const handle = fs.openSync(input.memoryFile, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  let saved;
  try {
    assert.equal(fs.fstatSync(handle).mode & 0o777, 0o600);
    saved = JSON.parse(fs.readFileSync(handle, "utf8"));
  } finally { fs.closeSync(handle); }
  assert.equal(saved.schema, ATTRIBUTION_MEMORY_SCHEMA);
  assert.equal(saved.account, account);
  assert.deepEqual(Object.keys(saved.entries), [key()]);
  const proof = saved.entries[key()];
  assert.deepEqual({ ...proof, provenAt: instant }, entry());
  assert.equal(new Date(proof.provenAt).toISOString(), proof.provenAt);
  fs.writeFileSync(input.executorFile, JSON.stringify(ledger({}, [])));
  assert.deepEqual(read().attribute(execution), { ...execution, desk: "j", subDesk: "j5", cause: "remembered" });
  assert.deepEqual(execution, before);
  const rememberedHandle = fs.openSync(input.memoryFile, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    assert.deepEqual(JSON.parse(fs.readFileSync(rememberedHandle, "utf8")), saved, "remembering never renews proof time/source");
  } finally { fs.closeSync(rememberedHandle); }
  assert.equal(fs.readdirSync(input.directory).some(name => name.endsWith(".lock") || name.endsWith(".tmp")), false);
});

test("memory joins exact account/client/exec/order identity and preserves every other cause", () => {
  const memory = createExecutorAttributionMemory({ account });
  const original = row().execution;
  source(memory).attribute(original);
  const pruned = source(memory, {}, []);
  for (const overrides of [{ orderId: 102 }, { execId: "OTHER.01" }, { clientId: 700 }]) {
    assert.throws(() => pruned.attribute({ ...original, ...overrides }), /intent_unmatched/);
  }
  assert.throws(() => pruned.attribute({ ...original, acctNumber: "DUOTHER" }), /identity_invalid/);
  assert.throws(() => pruned.attribute({ ...original, orderId: undefined }), /order_key_missing/);
  const economic = normalizeEconomicExecution(row()).execution;
  assert.equal(source(memory, {}, [row()]).attribute(economic).cause, "remembered", "exact executor execution can recover its order key");
  assert.throws(() => source(memory, {}, [row(), row({ orderId: 102 })]).attribute(original), /identity_ambiguous/);
  assert.throws(() => source(memory, { a: intent(), b: intent() }).attribute(original), /intent_ambiguous/);
  assert.throws(() => source(memory, { a: intent("invalid") }).attribute(original), /intent_desk_invalid/);
  assert.throws(() => createExecutorAttribution({ account, memory, ledger: null }).attribute(original), /ledger_unavailable/);
  const otherAccountMemory = createExecutorAttributionMemory({ account: "DUOTHER" });
  otherAccountMemory.record(entry());
  assert.throws(() => source(otherAccountMemory, {}, []).attribute(original), /ledger_unavailable/);
});

test("OPS tests create no proofs; remembered intent fills cannot become tests or balance their opposite leg", t => {
  const rows = [row({ orderRef: "ops-test", shares: 2 }),
    row({ execId: "OPPOSITE.01", orderId: 102, orderRef: "ops-test", shares: 2, side: "SLD" })];
  const input = fixture(t, rows);
  fs.writeFileSync(input.executorFile, JSON.stringify(ledger({}, rows)));
  const read = () => readExecutorAttribution({ account, file: input.executorFile, memoryFile: input.memoryFile,
    remember: true, executionRows: rows, onEvent() {} });
  for (const row of rows) assert.equal(read().attribute(row.execution).cause, "ops_test");
  assert.throws(() => fs.openSync(input.memoryFile, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW),
    { code: "ENOENT" }, "test exceptions cannot create attribution memory");
  createFileExecutorAttributionMemory({ account, file: input.memoryFile }).record(entry());
  const attribution = read();
  assert.equal(attribution.attribute(rows[0].execution).cause, "remembered");
  assert.throws(() => attribution.attribute(rows[1].execution), /ops_test_not_flat/);
});

test("conflicting desk/sub-desk/order proofs stay unclaimed and quarantined across pruning and restart", t => {
  const input = fixture(t);
  const store = () => createFileExecutorAttributionMemory({ account, file: input.memoryFile });
  source(store()).attribute(row().execution);
  const before = JSON.parse(fs.readFileSync(input.memoryFile, "utf8")).entries[key()];
  const events = [];
  assert.throws(() => source(store(), { changed: intent("joe") }, [], { onEvent: event => events.push(event) })
    .attribute(row().execution), /memory_conflict/);
  assert.deepEqual(events, [{ event: "executor_attribution_memory_conflict", cause: "memory_conflict" }]);
  assert.deepEqual(JSON.parse(fs.readFileSync(input.memoryFile, "utf8")).entries[key()], before);
  assert.throws(() => source(store(), {}, []).attribute(row().execution), /memory_conflict/);
  assert.throws(() => source(store()).attribute(row().execution), /memory_conflict/, "even a later agreeing intent cannot silently unquarantine");
  for (const change of [{ subDesk: "j2" }, { orderId: 102 }]) {
    const memory = createExecutorAttributionMemory({ account });
    memory.record(entry());
    assert.equal(memory.record(entry(change)), "conflict");
    assert.deepEqual(memory.get(705, entry().execId), entry());
  }
});

test("corrupt/schema/account/entry/link/size memory failures close exact and remembered attribution without resetting evidence", t => {
  const input = fixture(t);
  const read = () => readExecutorAttribution({ account, file: input.executorFile, memoryFile: input.memoryFile, remember: true, onEvent() {} });
  const invalid = ["SENTINELCORRUPT", JSON.stringify({}), JSON.stringify({ ...empty(), account: "DUOTHER" }),
    JSON.stringify({ ...empty(), entries: { [key()]: entry({ desk: "joe" }) } }),
    JSON.stringify({ ...empty(), entries: { [key()]: entry({ source: "orderRef" }) } }),
    JSON.stringify({ ...empty(), conflicts: [key()] })];
  for (const body of invalid) {
    fs.writeFileSync(input.memoryFile, body);
    assert.throws(() => read().attribute(row().execution), /ledger_unavailable/);
    assert.equal(fs.readFileSync(input.memoryFile, "utf8"), body);
  }
  fs.truncateSync(input.memoryFile, MAX_MEMORY_BYTES + 1);
  assert.throws(() => read().attribute(row().execution), /ledger_unavailable/);
  const link = path.join(input.directory, "memory-link.json");
  fs.symlinkSync(input.snapshotFile, link);
  assert.throws(() => readExecutorAttribution({ account, file: input.executorFile, memoryFile: link }).attribute(row().execution), /ledger_unavailable/);
  const fifo = path.join(input.directory, "fifo");
  assert.equal(spawnSync("mkfifo", [fifo]).status, 0);
  assert.throws(() => createFileExecutorAttributionMemory({ account, file: fifo }), /memory unavailable/);
});

test("persistence fsync failure preserves prior proof and prevents claims; writer contention never steals locks", t => {
  const input = fixture(t);
  const store = createFileExecutorAttributionMemory({ account, file: input.memoryFile });
  store.record(entry());
  const before = fs.readFileSync(input.memoryFile);
  const failing = createFileExecutorAttributionMemory({ account, file: input.memoryFile,
    fsImpl: { ...fs, fsyncSync() { throw new Error("SENTINELIO"); } } });
  assert.throws(() => source(failing, { next: intent("joe", 102) }, [])
    .attribute(row({ execId: "NEXT.01", orderId: 102 }).execution), /ledger_unavailable/);
  assert.deepEqual(fs.readFileSync(input.memoryFile), before);
  assert.throws(() => source(failing, {}, []).attribute(row().execution), /memory unavailable/);
  const lock = `${input.memoryFile}.lock`;
  fs.writeFileSync(lock, "SENTINELLOCK");
  const contender = createFileExecutorAttributionMemory({ account, file: input.memoryFile });
  assert.throws(() => contender.record(entry({ execId: "NEXT.01" })), /memory unavailable/);
  assert.equal(fs.readFileSync(lock, "utf8"), "SENTINELLOCK");
  assert.deepEqual(fs.readFileSync(input.memoryFile), before);
});

test("separate writer snapshots merge additions instead of losing existing proofs", t => {
  const input = fixture(t);
  const a = createFileExecutorAttributionMemory({ account, file: input.memoryFile });
  const b = createFileExecutorAttributionMemory({ account, file: input.memoryFile });
  a.record(entry());
  b.record(entry({ execId: "SECOND.01" }));
  assert.equal(Object.keys(JSON.parse(fs.readFileSync(input.memoryFile, "utf8")).entries).length, 2);
});

test("entry count and serialized byte bounds reject overflow without pruning prior proofs", () => {
  const state = empty();
  for (let i = 0; i < MAX_MEMORY_ENTRIES; i++) {
    const execId = `BOUND${i}.01`;
    state.entries[key(execId)] = entry({ execId });
  }
  const memory = createExecutorAttributionMemory({ account, state });
  assert.throws(() => memory.record(entry()), /memory unavailable/);
  assert.equal(memory.get(705, "BOUND0.01").desk, "j");
  state.entries[key()] = entry();
  assert.throws(() => createExecutorAttributionMemory({ account, state }), /memory unavailable/);
  const large = empty();
  for (let i = 0; i < 60_000; i++) {
    const execId = `${i}`.padEnd(256, "x");
    large.entries[key(execId)] = entry({ execId });
  }
  assert.ok(Buffer.byteLength(JSON.stringify(large)) > MAX_MEMORY_BYTES);
  assert.throws(() => createExecutorAttributionMemory({ account, state: large }), /memory unavailable/);
});

test("seed restores exact snapshot proofs idempotently and writes only memory, leaving both ledgers and snapshot untouched", t => {
  const rows = [row(), row({ execId: "UNMATCHED.01", orderId: 999 })];
  const input = fixture(t, rows);
  fs.writeFileSync(input.executorFile, JSON.stringify(ledger({}, [])));
  const files = [input.familyFile, input.executorFile, input.snapshotFile];
  const before = files.map(file => fs.readFileSync(file));
  const first = seedAttributionMemory({ ...input, now: () => instant });
  assert.deepEqual(first, { seeded: 1, alreadyPresent: 0, conflicts: 0, unmatched: 1 });
  const saved = fs.readFileSync(input.memoryFile);
  assert.deepEqual(JSON.parse(saved).entries[key()], entry({ source: "seed" }));
  assert.deepEqual(seedAttributionMemory(input), { seeded: 0, alreadyPresent: 1, conflicts: 0, unmatched: 1 });
  assert.deepEqual(fs.readFileSync(input.memoryFile), saved);
  assert.deepEqual(files.map(file => fs.readFileSync(file)), before);
  assert.deepEqual(fs.readdirSync(input.directory).sort(), [...files, input.memoryFile].map(file => path.basename(file)).sort());
  assert.equal(readExecutorAttribution({ account, file: input.executorFile, memoryFile: input.memoryFile }).attribute(row().execution).cause, "remembered");
});

test("seed reports conflicts and exact-match failures without accepting inferred, ambiguous or foreign proofs", t => {
  const input = fixture(t, [row(), row({ execId: "AMBIGUOUS.01", orderId: 102 }),
    row({ execId: "OPS.01", orderId: 103, orderRef: "ops-test" })]);
  const snapshot = ledger({ one: intent("joe"), a: intent("j", 102), b: intent("joe", 102) }, input.rows);
  // snapshot was created 0400; replacement preserves that operational input policy.
  fs.chmodSync(input.snapshotFile, 0o600);
  fs.writeFileSync(input.snapshotFile, JSON.stringify(snapshot));
  const memory = createFileExecutorAttributionMemory({ account, file: input.memoryFile });
  memory.record(entry());
  assert.deepEqual(seedAttributionMemory(input), { seeded: 0, alreadyPresent: 0, conflicts: 1, unmatched: 2 });
  assert.deepEqual(seedAttributionMemory(input), { seeded: 0, alreadyPresent: 0, conflicts: 1, unmatched: 2 });
  assert.deepEqual(JSON.parse(fs.readFileSync(input.memoryFile, "utf8")).entries[key()], entry());
  const saved = fs.readFileSync(input.memoryFile);
  for (const bad of [{ ...snapshot, account: "DUOTHER" }, { ...snapshot, schema: "wrong" }, { ...snapshot, intents: [] }]) {
    fs.writeFileSync(input.snapshotFile, JSON.stringify(bad));
    assert.throws(() => seedAttributionMemory(input), /snapshot unavailable/);
    assert.deepEqual(fs.readFileSync(input.memoryFile), saved);
  }
});

test("seed accepts all three fixed recovery roots and opens the checked resolved path", t => {
  const input = fixture(t);
  const open = fs.openSync;
  const opened = [];
  t.mock.method(fs, "openSync", (file, flags, ...args) => {
    if (file === "/dev/shm/recovery/snapshot.json" || file === "/tmp/recovery/snapshot.json" || file === "/recovery/snapshot.json") {
      opened.push(file);
      assert.ok(flags & fs.constants.O_NOFOLLOW);
      return open(input.snapshotFile, flags, ...args);
    }
    return open(file, flags, ...args);
  });
  for (const snapshotFile of ["/dev/shm/recovery/snapshot.json", "/tmp/recovery/snapshot.json", "/recovery/snapshot.json",
    "/dev/shm/recovery/nested/../snapshot.json", "/tmp/recovery/nested/../snapshot.json", "/recovery/nested/../snapshot.json"]) {
    assert.deepEqual(seedAttributionMemory({ ...input, snapshotFile, allowedRoots: undefined, now: () => instant }),
      { seeded: opened.length === 1 ? 1 : 0, alreadyPresent: opened.length === 1 ? 0 : 1, conflicts: 0, unmatched: 0 });
    assert.equal(opened.at(-1), path.resolve(snapshotFile));
  }
  assert.equal(opened.length, 6);
});

test("seed rejects root, sibling, traversal and relative paths before opening any file", t => {
  const open = t.mock.method(fs, "openSync", () => { throw new Error("unexpected open"); });
  for (const snapshotFile of [undefined, "", "/dev/shm/recovery", "/dev/shm/recovery/", "/tmp/recovery", "/tmp/recovery/", "/recovery", "/recovery/",
    "/dev/shm/recoveryX/snapshot.json", "/tmp/recoveryX/snapshot.json", "/recoveryX/snapshot.json",
    "/dev/shm/recovery/../etc/snapshot.json", "/tmp/recovery/../etc/snapshot.json",
    "/recovery/../etc/snapshot.json", "snapshot.json", "dev/shm/recovery/snapshot.json", "tmp/recovery/snapshot.json",
    path.relative(process.cwd(), "/tmp/recovery/snapshot.json")]) {
    assert.throws(() => seedAttributionMemory({ snapshotFile, account }), /seed snapshot unavailable/);
  }
  assert.equal(open.mock.calls.length, 0);
});

test("seed rejects relative paths resolving inside an allowed root and refuses snapshot symlinks", t => {
  const input = fixture(t);
  const relative = path.relative(process.cwd(), input.snapshotFile);
  assert.throws(() => seedAttributionMemory({ ...input, snapshotFile: relative }), /seed snapshot unavailable/);
  const link = path.join(input.directory, "snapshot-link.json");
  fs.symlinkSync(input.snapshotFile, link);
  assert.throws(() => seedAttributionMemory({ ...input, snapshotFile: link }), { code: "ELOOP" });
  assert.throws(() => fs.openSync(input.memoryFile, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW), { code: "ENOENT" });
});

test("seed CLI input failures are fixed value-free JSON with fixed recovery roots", t => {
  const input = fixture(t);
  const link = path.join(input.directory, "snapshot-link.json");
  fs.symlinkSync(input.snapshotFile, link);
  const root = path.dirname(fileURLToPath(import.meta.url));
  for (const args of [[], ["SENTINELMISSING"], ["/dev/shm/recovery"], ["/dev/shm/recovery/"], ["/tmp/recovery"], ["/tmp/recovery/"], ["/recovery"],
    ["/dev/shm/recoveryX/snapshot.json"], ["/tmp/recoveryX/snapshot.json"], ["/recoveryX/snapshot.json"],
    ["/dev/shm/recovery/../etc/snapshot.json"], ["/tmp/recovery/../etc/snapshot.json"],
    ["/recovery/../etc/snapshot.json"], ["dev/shm/recovery/snapshot.json"], ["tmp/recovery/snapshot.json"], [input.snapshotFile], [link],
    ["/tmp/recovery/snapshot.json", "/recovery/snapshot.json"]]) {
    const result = spawnSync(process.execPath, ["seed-attribution-memory.mjs", ...args], {
      cwd: root, encoding: "utf8", env: { ...process.env, IB_DESK_ACCOUNT: account },
    });
    assert.equal(result.status, 1);
    assert.equal(result.stderr, "");
    assert.equal(result.stdout, `${JSON.stringify({ ok: false, cause: "seed_inputs_unavailable" })}\n`);
  }
});

test("remembered and matched executions share the desk activity path and value-free diagnostic cause clocks", t => {
  const rows = [row(), row({ execId: "MATCHED.01", orderId: 102 }), row({ execId: "CONFLICT.01", orderId: 103 })];
  const input = fixture(t, rows);
  const memory = createFileExecutorAttributionMemory({ account, file: input.memoryFile });
  memory.record(entry());
  memory.record(entry({ execId: "CONFLICT.01", orderId: 103 }));
  memory.record(entry({ execId: "CONFLICT.01", orderId: 103, subDesk: "j2" }));
  fs.writeFileSync(input.executorFile, JSON.stringify(ledger({ exact: intent("joe", 102) }, [])));
  const before = [input.familyFile, input.executorFile, input.memoryFile].map(file => fs.readFileSync(file));
  const report = executorUnclaimedDiagnostic(input);
  assert.deepEqual(report.causes.remembered, { count: 1, first: "2026-10-19T14:00:00.000Z", last: "2026-10-19T14:00:00.000Z" });
  assert.deepEqual(report.causes.memory_conflict, report.causes.remembered);
  assert.equal(report.causes.matched.count, 1);
  for (const sentinel of ["SENTINEL", account, "98765", "45678", "clientId", "orderId", "subDesk", "orderRef"]) {
    assert.equal(JSON.stringify(report).includes(sentinel), false, sentinel);
  }
  assert.deepEqual([input.familyFile, input.executorFile, input.memoryFile].map(file => fs.readFileSync(file)), before);
  const attribution = readExecutorAttribution({ account, file: input.executorFile, memoryFile: input.memoryFile, onEvent() {} });
  const executions = executionActivity({ ...input.state, executions: rows.slice(0, 2) }, attribution);
  assert.equal(executions.cause, undefined);
  assert.deepEqual(executions.executorClients, [{ client: 705, matched: 2, unmatched: 0 }]);
  const candidate = buildCandidate(1, instant, copyObservation({
    book: { ts: instant, gateway: true, positions: [], positionsCoverage: { status: "complete" }, openOrders: [], ordersObservedAt: instant },
    deskEquities: { ok: true, oldestSourceObservedAt: instant, desks: Object.fromEntries(["j", "joe", "joel"].map(id => [id, { positions: [] }])) },
    executions, executorAttribution: attribution,
  }));
  assert.deepEqual(candidate.desks.map(desk => [desk.id, desk.state]), [["j", "working"], ["joe", "working"], ["joel", "sit-out"]]);
});
