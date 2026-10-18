import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { closeSync, existsSync, fstatSync, mkdirSync, mkdtempSync, openSync, readFileSync, readdirSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { Worker } from "node:worker_threads";
import { admitIntent, MAX_RECON_EVIDENCE_BYTES, MAX_STATE_BYTES, openLedger, pruneState, RECON_RETENTION_MS, RETENTION_MS } from "./state.mjs";
import { digest, newYorkDay, parseIntent } from "./policy.mjs";

test("read-only sampler load never initializes, migrates, archives or invokes capture", () => {
  const root = mkdtempSync(path.join(tmpdir(), "joed20-readonly-"));
  const ledger = openLedger(root, { beforePrune: () => assert.fail("read-only load invoked capture") });
  ledger.load({ readOnly: true });
  assert.deepEqual(readdirSync(root), []);
  const initialized = openLedger(root);
  initialized.load();
  const legacy = JSON.parse(readFileSync(initialized.statePath, "utf8"));
  delete legacy.reconStorageVersion;
  writeFileSync(initialized.statePath, JSON.stringify(legacy));
  const before = readFileSync(initialized.statePath, "utf8"), files = readdirSync(root);
  assert.equal(ledger.load({ initialize: false, readOnly: true }).reconStorageVersion, undefined);
  assert.equal(readFileSync(initialized.statePath, "utf8"), before);
  assert.deepEqual(readdirSync(root), files);
});

test("retention preserves recent idempotency and unresolved evidence while pruning expired terminal claims", () => {
  const now = Date.now();
  const recent = new Date(now - RETENTION_MS + 1000).toISOString();
  const old = new Date(now - RETENTION_MS - 1000).toISOString();
  const state = { intents: {
    "recent-id": { status: "done", finishedAt: recent },
    "expired-id": { status: "done", finishedAt: old },
    uncertain: { status: "uncertain", claimedAt: old },
    "crash-id": { status: "claimed", claimedAt: old },
  }, placements: [{ status: "uncertain", reservedAt: old }, { status: "submitted", reservedAt: old }], executions: [{ execution: "retained ownership" }] };
  pruneState(state, now);
  assert.deepEqual([...state.intents.keys()], ["recent-id", "uncertain", "crash-id"]);
  assert.equal(state.placements.length, 1); assert.equal(state.executions.length, 1);
});

test("bounded admission refuses overload without discarding existing claims", () => {
  const state = { intents: Object.fromEntries(Array.from({ length: 5000 }, (_, index) => [`test-${String(index).padStart(4, "0")}`, { status: "uncertain" }])), placements: [], executions: [] };
  assert.throws(() => admitIntent(state), /capacity/);
  assert.equal(state.intents.size, 5000);
});

test("byte capacity counts Map evidence and refuses oversized saves without replacing the ledger", () => {
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "ops266-capacity-")));
  const state = ledger.load();
  const original = readFileSync(ledger.statePath, "utf8");
  const evidence = { status: "uncertain", payload: "x".repeat(16 * 1024 * 1024) };
  state.intents.set("large-evidence", evidence);
  assert.throws(() => admitIntent(state), /capacity/);
  assert.throws(() => ledger.save(state), /size limit/);
  assert.equal(state.intents.get("large-evidence"), evidence);
  assert.equal(readFileSync(ledger.statePath, "utf8"), original);
});

test("ledger dictionaries round-trip as Maps and reject reserved or malformed keys", () => {
  const root = mkdtempSync(path.join(tmpdir(), "ops266-keys-"));
  const ledger = openLedger(root);
  const state = ledger.load();
  state.intents.set("valid-id", { status: "uncertain" });
  state.firstOrders.set("j", new Map([["AAPL", "2026-10-01"]]));
  ledger.save(state);
  const loaded = ledger.load();
  for (const map of [loaded.intents, loaded.firstOrders, loaded.firstOrders.get("j")]) assert.ok(map instanceof Map);
  assert.deepEqual(loaded.intents.get("valid-id"), { status: "uncertain" });
  assert.equal(loaded.firstOrders.get("j").get("AAPL"), "2026-10-01");
  const disk = readFileSync(ledger.statePath, "utf8");
  assert.deepEqual(JSON.parse(disk).intents, { "valid-id": { status: "uncertain" } });
  assert.deepEqual(JSON.parse(disk).firstOrders, { j: { AAPL: "2026-10-01" } });
  for (const key of ["__proto__", "constructor", "prototype", "short", "bad/path"]) {
    const poisoned = JSON.parse(disk);
    Object.defineProperty(poisoned.intents, key, { value: { status: "uncertain" }, enumerable: true });
    writeFileSync(ledger.statePath, JSON.stringify(poisoned));
    assert.throws(() => ledger.load(), /intentId is invalid/);
    assert.throws(() => ledger.save(poisoned), /intentId is invalid/);
  }
  for (const key of ["__proto__", "constructor", "prototype", "other-desk"]) {
    const poisoned = JSON.parse(disk);
    Object.defineProperty(poisoned.firstOrders, key, { value: {}, enumerable: true });
    writeFileSync(ledger.statePath, JSON.stringify(poisoned));
    assert.throws(() => ledger.load(), /desk is invalid/);
    assert.throws(() => ledger.save(poisoned), /desk is invalid/);
  }
  for (const key of ["__proto__", "constructor", "prototype", "bad/symbol"]) {
    const poisoned = JSON.parse(disk);
    Object.defineProperty(poisoned.firstOrders.j, key, { value: "2026-10-01", enumerable: true });
    writeFileSync(ledger.statePath, JSON.stringify(poisoned));
    assert.throws(() => ledger.load(), /symbol is invalid/);
    assert.throws(() => ledger.save(poisoned), /symbol is invalid/);
  }
  state.intents.set("__proto__", { status: "uncertain" });
  assert.throws(() => ledger.save(state), /intentId is invalid/);
  state.intents.delete("__proto__");
  state.firstOrders.get("j").set("constructor", "2026-10-01");
  assert.throws(() => ledger.save(state), /symbol is invalid/);
});

test("ledger and audit reads refuse symlinks; atomic writes ignore predictable temporary links", () => {
  const root = mkdtempSync(path.join(tmpdir(), "ops266-files-"));
  const ledger = openLedger(root);
  const state = ledger.load();
  const victim = path.join(root, "unrelated.txt");
  writeFileSync(victim, "preserve me");
  symlinkSync(victim, `${ledger.statePath}.new`);
  ledger.save(state);
  assert.equal(readFileSync(victim, "utf8"), "preserve me");
  symlinkSync(victim, ledger.haltPath);
  assert.throws(() => ledger.haltBody(), /ELOOP/);
  ledger.setHalt("operator stop");
  assert.match(ledger.haltBody(), /operator stop/);
  assert.equal(readFileSync(victim, "utf8"), "preserve me");
  for (const file of ["ledger.json", "audit.jsonl"]) {
    const otherRoot = mkdtempSync(path.join(tmpdir(), "ops266-links-"));
    symlinkSync(victim, path.join(otherRoot, file));
    const other = openLedger(otherRoot);
    assert.throws(() => file === "ledger.json" ? other.load() : other.audit({ event: "test" }), /ELOOP/);
    assert.equal(readFileSync(victim, "utf8"), "preserve me");
  }
});

test("concurrent ledger initialization publishes one complete ledger without overwriting the winner", async () => {
  const root = mkdtempSync(path.join(tmpdir(), "ops266-init-"));
  const initializations = Array.from({ length: 6 }, () => new Promise((resolve, reject) => {
    const worker = new Worker(`
      const { parentPort, workerData } = require("node:worker_threads");
      import(workerData.module).then(({ openLedger }) => {
        parentPort.postMessage(openLedger(workerData.root).load().initializedAt);
      });
    `, { eval: true, workerData: { root, module: new URL("./state.mjs", import.meta.url).href } });
    worker.once("message", resolve);
    worker.once("error", reject);
    worker.once("exit", (code) => { if (code !== 0) reject(new Error(`ledger worker exited ${code}`)); });
  }));
  const timestamps = await Promise.all(initializations);
  assert.equal(new Set(timestamps).size, 1);
  assert.equal(openLedger(root).load().initializedAt, timestamps[0]);
  const events = readFileSync(openLedger(root).auditPath, "utf8").trim().split("\n").map((row) => JSON.parse(row));
  assert.equal(events.filter((row) => row.event === "ledger_initialized").length, 1);
});

test("first-order coverage dates survive pruning old filled placements", () => {
  const now = Date.now();
  const first = new Date(now - RETENTION_MS - 86400000).toISOString();
  const state = { intents: {}, placements: [
    { desk: "j", symbol: "AAPL", status: "filled", reservedAt: first },
    { desk: "j", symbol: "AAPL", status: "submitted", reservedAt: new Date(now).toISOString() },
  ], executions: [] };
  pruneState(state, now);
  assert.equal(state.placements.length, 1);
  assert.equal(state.firstOrders.get("j").get("AAPL"), newYorkDay(Date.parse(first)));
  pruneState(state, now + RETENTION_MS + 1);
  assert.deepEqual(state.placements, []);
  assert.equal(state.firstOrders.get("j").get("AAPL"), newYorkDay(Date.parse(first)));
});

test("audit rotation remains bounded and HALT and ledger persist independently", () => {
  const root = mkdtempSync(path.join(tmpdir(), "ops266-ledger-"));
  const ledger = openLedger(root);
  const state = ledger.load();
  ledger.setHalt("operator stop");
  state.intents.set("durable-id", { status: "uncertain", claimedAt: new Date().toISOString() });
  ledger.save(state);
  for (let index = 0; index < 40; index++) ledger.audit({ event: "large", payload: "x".repeat(64000) });
  assert.ok(statSync(ledger.auditPath).size <= 1024 * 1024);
  assert.ok(statSync(`${ledger.auditPath}.1`).size <= 1024 * 1024);
  assert.equal(openLedger(root).load().intents.get("durable-id").status, "uncertain");
  assert.match(openLedger(root).haltBody(), /operator stop/);
});

test("unresolved stop modifications retain their bracket beyond normal placement retention and round-trip", () => {
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "ops266-stop-history-")));
  const state = ledger.load();
  const old = new Date(Date.now() - RETENTION_MS - 1000).toISOString();
  state.placements = ["reserved", "uncertain", "submitted"].map((status) => ({ desk: "j", symbol: "AAPL", reservedAt: old, status: "submitted", stopHistory: [{ at: old, from: 95, to: 100, intentId: `j-stop-${status}`, status }] }));
  ledger.save(state);
  assert.deepEqual(ledger.load().placements.map((row) => row.stopHistory[0].status), ["reserved", "uncertain"]);
});

function reconRow(intentId, payload = "evidence", at = new Date().toISOString()) {
  return { action: "recon", desk: "j", hash: `hash-${intentId}`, status: "done", claimedAt: at, finishedAt: at, result: {
    status: "ok", intentId, desk: "j", action: "recon", observedAt: at,
    account: "DU0000000", gateway: true, ownershipComplete: true,
    ownershipHistory: { status: "complete" },
    positions: [], openOrders: [], executions: [{ payload }], pnlPerDesk: { j: { realized: 10 } },
  } };
}

function evidenceRows(ledger, file = ledger.reconEvidencePath) {
  return readFileSync(file, "utf8").trim().split("\n").map((line) => JSON.parse(line));
}

test("thousands of recon snapshots persist far below the byte limit with matching canonical evidence", () => {
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "ops331-many-")));
  const state = ledger.load();
  for (let index = 0; index < 4000; index++) {
    const id = `recon-${String(index).padStart(4, "0")}`;
    state.intents.set(id, reconRow(id, "x".repeat(2500)));
  }
  ledger.save(state);
  assert.ok(statSync(ledger.statePath).size < MAX_STATE_BYTES / 5);
  assert.equal(ledger.load().intents.size, 4000);
  assert.doesNotThrow(() => admitIntent(state, "place"));
  const rows = evidenceRows(ledger);
  for (const row of rows) {
    const receipt = state.intents.get(row.intentId).result;
    assert.equal(row.resultSha256, digest(row.result));
    assert.equal(row.resultSha256, receipt.resultSha256);
    assert.equal(receipt.executions, undefined);
    assert.equal(receipt.snapshot, "omitted");
    assert.deepEqual(receipt.omittedCounts, { positions: 0, openOrders: 0, executions: 1, pnlPerDesk: 1 });
    assert.equal(row.desk, "j"); assert.equal(row.observedAt, row.result.observedAt);
  }
  const row = rows[0], reversed = Object.fromEntries(Object.entries(row.result).reverse());
  assert.equal(digest(reversed), row.resultSha256, "object key order does not change the digest");
  for (const file of [ledger.reconEvidencePath, `${ledger.reconEvidencePath}.1`]) {
    assert.ok(statSync(file).size <= MAX_RECON_EVIDENCE_BYTES);
    assert.equal(statSync(file).mode & 0o777, 0o600);
  }
});

test("recon count exhaustion cannot exhaust the state-changing claim budget", () => {
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "ops331-count-")));
  const state = ledger.load();
  for (let index = 0; index < 5000; index++) state.intents.set(`recon-${index.toString().padStart(4, "0")}`, { action: "recon", status: "claimed", claimedAt: new Date().toISOString() });
  assert.throws(() => admitIntent(state, "recon"), /capacity/);
  for (const action of ["place", "flatten", "cancel", "modify-stop"]) assert.doesNotThrow(() => admitIntent(state, action));
});

test("48-hour recon retention preserves the replay window and leaves full state-changing results for 14 days", () => {
  const now = Date.now(), recent = new Date(now - RECON_RETENTION_MS + 1).toISOString();
  const old = new Date(now - RECON_RETENTION_MS - 1).toISOString();
  const state = { intents: new Map([
    ["recon-recent", reconRow("recon-recent", "recent", recent)],
    ...["done", "claimed", "uncertain"].map((status) => [`recon-${status}`, { ...reconRow(`recon-${status}`, "old", old), status }]),
    ...["place", "flatten", "cancel", "modify-stop"].map((action) => [`mutation-${action}`, { ...reconRow(`mutation-${action}`, "full mutation evidence", old), action }]),
    ["mutation-uncertain", { action: "place", status: "uncertain", claimedAt: new Date(now - RETENTION_MS - 1).toISOString(), result: { evidence: "unresolved" } }],
  ]), placements: [], executions: [] };
  const results = [...state.intents].filter(([id]) => id.startsWith("mutation-")).map(([id, row]) => [id, row.result]);
  pruneState(state, now);
  assert.equal(state.intents.has("recon-recent"), true);
  for (const status of ["done", "claimed", "uncertain"]) assert.equal(state.intents.has(`recon-${status}`), false);
  for (const [id, result] of results) assert.deepEqual(state.intents.get(id).result, result);
  pruneState(state, Date.parse(old) + RETENTION_MS);
  for (const [id] of results) assert.equal(state.intents.has(id), true);
  pruneState(state, Date.parse(old) + RETENTION_MS + 1);
  assert.deepEqual([...state.intents.keys()], ["mutation-uncertain"]);

  const custom = { intents: { "custom-recon": reconRow("custom-recon", "custom", old) }, placements: [], executions: [] };
  pruneState(custom, now, { reconRetentionMs: 72 * 60 * 60_000 });
  assert.equal(custom.intents.size, 1);
  for (const value of [0, -1, 15 * 60_000, 16 * 60_000 - 1, RETENTION_MS + 1, NaN, Infinity]) assert.throws(() => openLedger("/unused", { reconRetentionMs: value }), /recon retention/);
  assert.doesNotThrow(() => openLedger("/unused", { reconRetentionMs: 16 * 60_000 }));
});

test("recon retention environment accepts finite fractional hours and rejects invalid or out-of-range values clearly", (t) => {
  const previous = process.env.PAPER_DESK_RECON_RETENTION_HOURS;
  t.after(() => {
    if (previous === undefined) delete process.env.PAPER_DESK_RECON_RETENTION_HOURS;
    else process.env.PAPER_DESK_RECON_RETENTION_HOURS = previous;
  });
  delete process.env.PAPER_DESK_RECON_RETENTION_HOURS;
  assert.equal(openLedger("/unused").reconRetentionMs, RECON_RETENTION_MS);
  for (const hours of [16 / 60, 0.33333333, 1.123456789, 48, 336]) {
    process.env.PAPER_DESK_RECON_RETENTION_HOURS = String(hours);
    assert.equal(openLedger("/unused").reconRetentionMs, Math.round(hours * 3_600_000));
  }
  for (const hours of ["", " ", "invalid", "NaN", "Infinity", "-Infinity", "0", "-1", "0.25", String(16 / 60 - 0.00000001), "336.0000001", "1e100"]) {
    process.env.PAPER_DESK_RECON_RETENTION_HOURS = hours;
    assert.throws(() => openLedger("/unused"), /PAPER_DESK_RECON_RETENTION_HOURS.*16.*336/);
  }
});

test("the 16-minute floor retains recon receipts throughout validity plus future clock skew", () => {
  const now = Date.now(), id = "recon-clock-skew";
  const intent = { schema: "barta.paper-desk-intent.v2", intentId: id, desk: "j", action: "recon", createdAt: new Date(now + 60_000).toISOString(), expiresAt: new Date(now + 16 * 60_000).toISOString() };
  assert.doesNotThrow(() => parseIntent(intent, now));
  const state = { intents: { [id]: reconRow(id, "skew", new Date(now).toISOString()) }, placements: [], executions: [] };
  const replayAt = now + 16 * 60_000 - 1;
  assert.doesNotThrow(() => parseIntent(intent, replayAt));
  pruneState(state, replayAt, { reconRetentionMs: 16 * 60_000 });
  assert.equal(state.intents.has(id), true);
  pruneState(state, now + 16 * 60_000 + 1, { reconRetentionMs: 16 * 60_000 });
  assert.equal(state.intents.has(id), false);
});

test("OPS-331 incident regression: a ledger above admission headroom migrates and immediately admits new intents", (t) => {
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "ops331-incident-")));
  ledger.load();
  const legacy = JSON.parse(readFileSync(ledger.statePath, "utf8"));
  delete legacy.reconStorageVersion;
  for (let index = 0; index < 269; index++) {
    const id = `recon-${index.toString().padStart(4, "0")}`;
    legacy.intents[id] = reconRow(id, "x".repeat(60200));
  }
  legacy.executions = [{ evidence: "x".repeat(201000) }];
  legacy.foreignAlerts = [{ at: new Date().toISOString(), evidence: "x".repeat(148000) }];
  // Even already-expired non-recon evidence must survive the migration itself.
  legacy.intents["mutation-old-place"] = { ...reconRow("mutation-old-place", "full", new Date(Date.now() - RETENTION_MS - 1).toISOString()), action: "place" };
  for (const action of ["place", "flatten", "cancel", "modify-stop"]) {
    for (const status of ["claimed", "uncertain", "done", "rejected"]) {
      const id = `mutation-${action}-${status}`;
      legacy.intents[id] = { action, desk: "j", status, hash: `hash-${id}`, claimedAt: new Date(Date.now() - RETENTION_MS - 1).toISOString(), brokerPlan: { orderRef: "j|261001|retained", orderIds: [100, 101], contract: { symbol: "AAPL", conId: 265598 } }, result: { status, executions: [{ execId: "retained-fill", quantity: 2 }], details: { evidence: "non-recon unchanged" } } };
    }
  }
  legacy.placements = [{ desk: "j", symbol: "AAPL", status: "filled", reservedAt: new Date().toISOString(), orderIds: [1, 2], stopHistory: [{ status: "uncertain" }] }];
  legacy.firstOrders = { j: { AAPL: "2026-10-01" } };
  legacy.attributionJournal = [{ evidence: "assignment retained" }];
  legacy.ownershipSnapshot = { account: "DU0000000", positions: [{ symbol: "AAPL", position: 2 }], ownershipComplete: true };
  legacy.ownershipComplete = true;
  const body = `${JSON.stringify(legacy)}\n`;
  assert.ok(Buffer.byteLength(body) > MAX_STATE_BYTES - 262144);
  assert.ok(Buffer.byteLength(body) < MAX_STATE_BYTES);
  assert.throws(() => admitIntent(structuredClone(legacy), "place"), /capacity/, "reproduce the old refusal before migration");
  writeFileSync(ledger.statePath, body);

  const migrated = ledger.load();
  assert.doesNotThrow(() => admitIntent(structuredClone(migrated), "place"), "migration must unblock the old admission refusal immediately");
  assert.equal(readFileSync(ledger.backupPath, "utf8"), body);
  assert.equal(statSync(ledger.backupPath).mode & 0o777, 0o600);
  assert.equal(migrated.intents.get("mutation-old-place").result.executions[0].payload, "full");
  const disk = JSON.parse(readFileSync(ledger.statePath, "utf8"));
  for (const [id, row] of Object.entries(legacy.intents).filter(([, row]) => row.action !== "recon")) {
    assert.deepEqual(migrated.intents.get(id), row);
    assert.deepEqual(disk.intents[id], row, `migration preserves the complete non-recon row ${id}`);
  }
  for (const key of ["executions", "placements", "firstOrders", "foreignAlerts", "attributionJournal", "ownershipSnapshot", "ownershipComplete"]) assert.deepEqual(disk[key], legacy[key]);
  assert.ok(ledger.usage().ledgerBytes < 1024 * 1024);
  t.diagnostic(`incident fixture: ${Buffer.byteLength(body)} bytes before, ${ledger.usage().ledgerBytes} bytes after migration`);
  for (const action of ["place", "flatten", "recon", "cancel", "modify-stop"]) assert.doesNotThrow(() => admitIntent(structuredClone(migrated), action));
  for (const row of Object.values(disk.intents).filter((row) => row.action === "recon")) assert.equal(row.result.resultCompacted, true);
  // Read contents and mtime through one descriptor (no check-then-use race).
  const snapshotOf = (file) => { const fd = openSync(file, "r"); try { return [readFileSync(fd, "utf8"), fstatSync(fd).mtimeMs]; } finally { closeSync(fd); } };
  const before = [ledger.statePath, ledger.backupPath, ledger.reconEvidencePath, `${ledger.reconEvidencePath}.1`].map((file) => [file, ...snapshotOf(file)]);
  openLedger(ledger.root).load();
  for (const [file, contents, mtime] of before) { const [now, nowMtime] = snapshotOf(file); assert.equal(now, contents); assert.equal(nowMtime, mtime); }
  // A retry/old writer can introduce another legacy row after migration.
  disk.intents["recon-extra"] = reconRow("recon-extra");
  writeFileSync(ledger.statePath, JSON.stringify(disk));
  ledger.load();
  assert.equal(readFileSync(ledger.backupPath, "utf8"), body, "the original backup is never overwritten");
  assert.equal(evidenceRows(ledger).at(-1).intentId, "recon-extra");
});

test("recon evidence rotation retains two complete 0600 generations and repeated saves append nothing", () => {
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "ops331-rotation-")));
  const state = ledger.load();
  for (let index = 0; index < 4; index++) {
    const id = `recon-rotate-${index}`;
    state.intents.set(id, reconRow(id, "x".repeat(4 * 1024 * 1024)));
    ledger.save(state);
  }
  assert.deepEqual(evidenceRows(ledger).map((row) => row.intentId), ["recon-rotate-3"]);
  assert.deepEqual(evidenceRows(ledger, `${ledger.reconEvidencePath}.1`).map((row) => row.intentId), ["recon-rotate-2"]);
  const files = readdirSync(ledger.root).filter((file) => file.startsWith("recon-evidence"));
  assert.deepEqual(files.sort(), ["recon-evidence.jsonl", "recon-evidence.jsonl.1"]);
  const before = files.map((file) => [file, statSync(path.join(ledger.root, file)).mtimeMs]);
  ledger.save(state);
  for (const [file, mtime] of before) {
    assert.equal(statSync(path.join(ledger.root, file)).mtimeMs, mtime);
    assert.equal(statSync(path.join(ledger.root, file)).mode & 0o777, 0o600);
    assert.ok(statSync(path.join(ledger.root, file)).size <= MAX_RECON_EVIDENCE_BYTES);
  }
});

test("migration fails closed on unusable backup paths without replacing the original ledger", () => {
  for (const blocked of ["directory", "symlink"]) {
    const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "ops331-failure-")));
    ledger.load();
    const value = JSON.parse(readFileSync(ledger.statePath, "utf8"));
    delete value.reconStorageVersion;
    value.intents["recon-failure"] = reconRow("recon-failure");
    const body = JSON.stringify(value);
    writeFileSync(ledger.statePath, body);
    if (blocked === "directory") mkdirSync(ledger.backupPath);
    else symlinkSync(ledger.statePath, ledger.backupPath);
    assert.throws(() => ledger.load(), blocked === "directory" ? /not a regular file/ : /ELOOP/);
    assert.equal(readFileSync(ledger.statePath, "utf8"), body);
  }
});

test("migration still compacts and admits mutations when its evidence archive is unwritable after backup", (t) => {
  const logged = [];
  t.mock.method(console, "error", (line) => logged.push(JSON.parse(line)));
  for (const blocked of ["directory", "symlink"]) {
    const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "ops331-archive-failure-")));
    ledger.load();
    const value = JSON.parse(readFileSync(ledger.statePath, "utf8"));
    delete value.reconStorageVersion;
    for (const id of ["recon-failure-one", "recon-failure-two"]) value.intents[id] = reconRow(id);
    value.intents["place-retained"] = { action: "place", status: "uncertain", brokerPlan: { orderIds: [1, 2] }, result: { evidence: "preserve" } };
    const body = JSON.stringify(value);
    writeFileSync(ledger.statePath, body);
    const victim = path.join(ledger.root, "unrelated.txt");
    writeFileSync(victim, "preserve me");
    if (blocked === "directory") mkdirSync(ledger.reconEvidencePath);
    else symlinkSync(victim, ledger.reconEvidencePath);
    const migrated = ledger.load();
    assert.equal(readFileSync(ledger.backupPath, "utf8"), body);
    for (const id of ["recon-failure-one", "recon-failure-two"]) {
      assert.equal(migrated.intents.get(id).result.snapshot, "omitted");
      assert.equal(migrated.intents.get(id).result.resultSha256, digest(value.intents[id].result));
    }
    assert.deepEqual(migrated.intents.get("place-retained"), value.intents["place-retained"]);
    assert.equal(ledger.load().reconStorageVersion, 1);
    for (const action of ["place", "flatten"]) assert.doesNotThrow(() => admitIntent(structuredClone(migrated), action));
    assert.equal(readFileSync(victim, "utf8"), "preserve me");
  }
  assert.equal(logged.length, 2);
  for (const event of logged) {
    assert.equal(event.event, "recon_migration_archive_failed");
    assert.equal(event.migrationBackupAvailable, true);
    assert.equal(event.backup, "ledger.pre-ops331.json");
  }
});

test("future or unknown recon storage versions fail closed without archiving, backup or downgrade", () => {
  for (const version of [2, 3, "1", null, 0]) {
    const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "ops331-version-")));
    ledger.load();
    const value = JSON.parse(readFileSync(ledger.statePath, "utf8"));
    value.reconStorageVersion = version;
    value.intents["recon-future"] = reconRow("recon-future");
    const body = JSON.stringify(value);
    writeFileSync(ledger.statePath, body);
    assert.throws(() => ledger.load(), /unsupported reconStorageVersion.*refusing to migrate or downgrade/);
    assert.equal(readFileSync(ledger.statePath, "utf8"), body);
    assert.equal(existsSync(ledger.backupPath), false);
    assert.equal(existsSync(ledger.reconEvidencePath), false);
  }
});

test("a crash after publishing recon evidence and before writing the migrated ledger is safely retried", () => {
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "ops331-crash-")));
  ledger.load();
  const value = JSON.parse(readFileSync(ledger.statePath, "utf8"));
  delete value.reconStorageVersion;
  value.intents["recon-crash"] = reconRow("recon-crash");
  value.intents["place-uncertain"] = { action: "place", status: "uncertain", brokerPlan: { orderIds: [21, 22] }, result: { status: "uncertain" } };
  const body = JSON.stringify(value);
  writeFileSync(ledger.statePath, body);
  const script = `
    import fs from "node:fs";
    import { syncBuiltinESMExports } from "node:module";
    const open = fs.openSync;
    fs.openSync = (file, flags, ...rest) => {
      if (String(file).startsWith(process.argv[1] + ".") && String(file).endsWith(".new") && (flags & fs.constants.O_WRONLY)) process.exit(86);
      return open(file, flags, ...rest);
    };
    syncBuiltinESMExports();
    const { openLedger } = await import(process.argv[2]);
    openLedger(process.argv[3]).load();
  `;
  assert.throws(() => execFileSync(process.execPath, ["--input-type=module", "-e", script, ledger.statePath, new URL("./state.mjs", import.meta.url).href, ledger.root], { stdio: "pipe" }), (error) => error.status === 86);
  assert.equal(readFileSync(ledger.statePath, "utf8"), body);
  assert.equal(readFileSync(ledger.backupPath, "utf8"), body);
  assert.deepEqual(evidenceRows(ledger).map((row) => row.result), [value.intents["recon-crash"].result]);
  const migrated = ledger.load();
  assert.equal(migrated.intents.get("recon-crash").result.snapshot, "omitted");
  assert.deepEqual(migrated.intents.get("place-uncertain"), value.intents["place-uncertain"]);
  const rows = evidenceRows(ledger);
  assert.equal(rows.length, 2, "the retry duplicates evidence instead of losing it");
  for (const row of rows) assert.equal(row.resultSha256, migrated.intents.get(row.intentId).result.resultSha256);
  assert.equal(readFileSync(ledger.backupPath, "utf8"), body);
});

test("recon evidence rejects symlinks and oversized individual results before compacting", () => {
  for (const blocked of ["link", "size"]) {
    const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "ops331-evidence-boundary-")));
    const state = ledger.load(), before = readFileSync(ledger.statePath, "utf8");
    const id = "recon-boundary", row = reconRow(id, "x".repeat(blocked === "size" ? MAX_RECON_EVIDENCE_BYTES : 1));
    state.intents.set(id, row);
    const victim = path.join(ledger.root, "unrelated.txt");
    writeFileSync(victim, "preserve me");
    if (blocked === "link") symlinkSync(victim, ledger.reconEvidencePath);
    assert.throws(() => ledger.save(state), blocked === "link" ? /ELOOP/ : /evidence row exceeds size limit/);
    assert.equal(readFileSync(ledger.statePath, "utf8"), before);
    assert.equal(state.intents.get(id), row);
    assert.equal(readFileSync(victim, "utf8"), "preserve me");
    assert.equal(existsSync(ledger.backupPath), false, "new ledgers do not create migration backups");
  }
});

test("headroom reports disk bytes and emits one warning per 75-percent crossing", (t) => {
  const warn = t.mock.method(console, "warn", () => {});
  const ledger = openLedger(mkdtempSync(path.join(tmpdir(), "ops331-headroom-")));
  const state = ledger.load();
  state.intents.set("mutation-large", { action: "place", status: "uncertain", result: { evidence: "x".repeat(12 * 1024 * 1024) } });
  ledger.save(state);
  const usage = ledger.usage();
  assert.equal(usage.ledgerBytes, statSync(ledger.statePath).size);
  assert.equal(usage.ledgerPercent, usage.ledgerBytes / MAX_STATE_BYTES * 100);
  assert.equal(usage.ledgerMaxBytes, MAX_STATE_BYTES);
  assert.ok(usage.ledgerPercent >= 75);
  ledger.load(); ledger.usage(); ledger.save(state);
  assert.equal(warn.mock.callCount(), 1);
  assert.equal(JSON.parse(warn.mock.calls[0].arguments[0]).event, "ledger_headroom_warning");
  state.intents.delete("mutation-large"); ledger.save(state);
  state.intents.set("mutation-large", { action: "place", status: "uncertain", result: { evidence: "x".repeat(12 * 1024 * 1024) } });
  ledger.save(state);
  assert.equal(warn.mock.callCount(), 2);
});

test('save invokes capture exactly once before compaction and retention', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'joed20-once-'));
  let calls = 0;
  const ledger = openLedger(root, { beforePrune: state => {
    calls++;
    assert.equal(state.intents.get('expired-recon').result.resultCompacted, undefined);
  } });
  const state = ledger.load();
  for (let i = 0; i < 2; i++) {
    state.intents.set('expired-recon', { action: 'recon', status: 'done', finishedAt: '2020-01-01T00:00:00Z', result: { status: 'ok', executions: [] } });
    ledger.save(state);
    assert.equal(calls, i + 1);
    assert.equal(state.intents.has('expired-recon'), false);
  }
});
