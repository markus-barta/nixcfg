import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";
import { createDeskEquityCloseRecorder, createOutcomeStore, closeBoundary, closeMaxAgeMs, atomicWrite } from "./desk-equity-closes.mjs";
import { buildCandidate } from "./v2-stage-worker.mjs";
import { copyObservation } from "./v2-stage-handoff.mjs";

const before = "2026-11-13T22:59:45.000Z", after = "2026-11-13T23:00:05.000Z";
const desks = ["j", "joe", "joel"];
function source(at = before) {
  return { book: { ts: at, gateway: true, apiReplyCheckedAt: at, summary: {}, positions: [], portfolio: [],
    positionsCoverage: { status: "complete", observedAt: at } },
  deskEquities: { ok: true, desks: Object.fromEntries(desks.map(id => [id, { positions: [] }])),
    phaseBDesks: Object.fromEntries(desks.map((id, i) => [id, { reconciled: true, base: 5000, equity: 5001.25 + i,
      totalPnl: 1.25 + i, openPnl: 0, observedAt: at, oldestInputAt: at, fx: null, positions: [] }])) } };
}
function fixture(create = createDeskEquityCloseRecorder, options = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ops556-close-")), events = [];
  const settings = { firstDay: "2026-11-13", intervalSec: 30, revision: 11,
    statePath: path.join(dir, "state.json"), outcomePath: path.join(dir, "outcomes.jsonl"), diagnostic: e => events.push(e), ...options };
  return { dir, events, settings, recorder: create(settings), reopen: () => create(settings),
    rows: () => fs.existsSync(settings.outcomePath) ? fs.readFileSync(settings.outcomePath, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : [] };
}

test("closed day retains the same exact EUR equity as the live projection", () => {
  const f = fixture(), input = source(), original = structuredClone(input);
  assert.equal(f.recorder.observe(input, before), true);
  assert.deepEqual(input, original);
  assert.deepEqual(f.rows(), []);
  assert.equal(f.recorder.observe(source(after), after), true);
  const live = buildCandidate(1, before, copyObservation(input, 11), before, null, 11);
  assert.equal(f.rows().length, 3);
  for (const row of f.rows()) {
    assert.deepEqual(row.equityClose, live.desks.find(d => d.id === row.desk).money.equity);
    assert.equal(row.observedAt, before); assert.equal(row.maxAgeMs, 120_000); assert.equal(row.reason, null);
  }
});

test("last exact observation survives a later inexact observation without becoming a later valuation", () => {
  const f = fixture(); f.recorder.observe(source(), before);
  const later = "2026-11-13T22:59:55.000Z", input = source(later);
  input.deskEquities.phaseBDesks.j.equity = 1.123456789;
  f.recorder.observe(input, later); f.recorder.observe(source(after), after);
  assert.equal(f.rows()[0].observedAt, before); assert.equal(f.rows()[1].observedAt, later);
});

test("no broker observation produces null and no_observation, never a midnight valuation", () => {
  const f = fixture(); f.recorder.observe(null, before); f.recorder.observe(source(after), after);
  assert.equal(f.rows().length, 3);
  for (const row of f.rows()) { assert.equal(row.equityClose, null); assert.equal(row.reason, "no_observation"); }
});

function staleControl(create) {
  const f = fixture(create), at = "2026-11-13T22:57:59.999Z";
  f.recorder.observe(source(at), at); f.recorder.observe(source(after), after);
  assert.equal(f.rows()[0].equityClose, null); assert.equal(f.rows()[0].reason, "stale");
}
test("feed gap: last exact observation one millisecond beyond four cycles is stale", () => staleControl(createDeskEquityCloseRecorder));
test("age bound includes exactly four cycles and comes from actual configured cadence", () => {
  const f = fixture(), at = "2026-11-13T22:58:00.000Z";
  f.recorder.observe(source(at), at); f.recorder.observe(null, after);
  assert.notEqual(f.rows()[0].equityClose, null);
  assert.equal(closeMaxAgeMs(30), 120000); assert.equal(closeMaxAgeMs(45), 180000);
  assert.equal(closeMaxAgeMs(3600), 300000, "never exceed the live input-age limit");
  assert.throws(() => closeMaxAgeMs(0), /cadence/);
});
for (const seconds of [119, 121]) test(`${seconds} seconds before midnight is ${seconds < 120 ? 'exact' : 'stale'}`, () => {
  const f = fixture(), at = new Date(Date.parse(closeBoundary('2026-11-13')) - seconds * 1000).toISOString();
  f.recorder.observe(source(at), at); f.recorder.observe(null, after);
  assert.equal(f.rows()[0].reason, seconds < 120 ? null : 'stale');
});
for (const offset of [2000, 1]) test(`pre-midnight valuation ${offset} ms before boundary delivered at 00:00:02 closes its observation day`, () => {
  const f = fixture(), boundary = closeBoundary('2026-11-13');
  const observedAt = new Date(Date.parse(boundary) - offset).toISOString();
  const deliveredAt = new Date(Date.parse(boundary) + 2000).toISOString();
  f.recorder.observe(null, before);
  assert.equal(f.recorder.observe(source(observedAt), deliveredAt), true);
  for (const row of f.rows()) {
    assert.equal(row.vienna_day, '2026-11-13'); assert.equal(row.observedAt, observedAt);
    assert.notEqual(row.equityClose, null);
  }
  const state = JSON.parse(fs.readFileSync(f.settings.statePath));
  assert.ok(Object.values(state.desks).every(row => row.lastExact === null));
});

function exactControl(create) {
  const f = fixture(create), input = source(); input.deskEquities.phaseBDesks.j.equity = 1.123456789;
  f.recorder.observe(input, before); f.recorder.observe(null, after);
  assert.equal(f.rows()[0].equityClose, null); assert.equal(f.rows()[0].reason, "inexact");
  assert.notEqual(f.rows()[1].equityClose, null);
}
test("an inexact equity is null independently for that desk", () => exactControl(createDeskEquityCloseRecorder));
for (const problem of ["gateway", "reconciliation", "fx", "old-input", "future-input", "positions"]) {
  test(`live exactness gate: ${problem} cannot produce a close`, () => {
    const f = fixture(), input = source(), row = input.deskEquities.phaseBDesks.j;
    if (problem === "gateway") input.book.apiReplyCheckedAt = "2026-11-13T22:58:45.000Z";
    if (problem === "reconciliation") row.reconciled = false;
    if (problem === "fx") row.fx = false;
    if (problem === "old-input") row.oldestInputAt = "2026-11-13T22:54:44.999Z";
    if (problem === "future-input") { row.observedAt = after; row.oldestInputAt = after; }
    if (problem === "positions") delete input.book.positionsCoverage;
    f.recorder.observe(input, before); f.recorder.observe(null, after);
    assert.equal(f.rows()[0].equityClose, null); assert.equal(f.rows()[0].reason, "inexact");
  });
}

test("restart mid-day retains observations and appends no early outcome", () => {
  const f = fixture(), midday = "2026-11-13T12:00:00.000Z";
  f.recorder.observe(source(midday), midday);
  const restarted = f.reopen(); restarted.observe(source(), before);
  assert.deepEqual(f.rows(), []); restarted.observe(null, after);
  assert.equal(f.rows()[0].observedAt, before);
});
test("restart across midnight finalizes durable observations, not the new day's equity", () => {
  const f = fixture(); f.recorder.observe(source(), before);
  const restarted = f.reopen(); restarted.observe(source(after), after);
  assert.equal(f.rows()[0].observedAt, before);
  const bytes = fs.readFileSync(f.settings.outcomePath, "utf8");
  f.reopen().observe(source(after), after);
  assert.equal(fs.readFileSync(f.settings.outcomePath, "utf8"), bytes);
});
test("multi-day restart gap records null only after tracking began", () => {
  const f = fixture(); f.recorder.observe(source(), before);
  const later = "2026-11-16T12:00:00.000Z"; f.reopen().observe(source(later), later);
  assert.equal(f.rows().length, 9);
  assert.equal(f.rows().filter(r => r.reason === "restart_gap").length, 6);
  assert.ok(f.rows().every(r => r.vienna_day >= "2026-11-13"));
});
test("days missed by a running recorder are recorder_gap, not restart_gap", () => {
  const f = fixture(); f.recorder.observe(source(), before);
  const later = "2026-11-16T12:00:00.000Z"; f.recorder.observe(null, later);
  assert.equal(f.rows().filter(row => row.reason === "recorder_gap").length, 6);
  assert.equal(f.rows().filter(row => row.reason === "restart_gap").length, 0);
});
test("a storage failure while the recorder is running cannot become restart_gap on recovery", t => {
  const f = fixture(); f.recorder.observe(source(), before);
  const open = fs.openSync; let fail = true;
  t.mock.method(fs, "openSync", (filename, ...args) => {
    if (filename === f.settings.statePath && fail) throw new Error("synthetic_storage_failure");
    return open(filename, ...args);
  });
  assert.equal(f.recorder.observe(null, "2026-11-14T12:00:00.000Z"), false);
  fail = false;
  assert.equal(f.recorder.observe(null, "2026-11-16T12:00:00.000Z"), true);
  assert.equal(f.rows().filter(row => row.reason === "recorder_gap").length, 6);
  assert.equal(f.rows().filter(row => row.reason === "restart_gap").length, 0);
});
test("a broker observation under an old contract has its own durable reason", () => {
  const f = fixture(undefined, { revision: 9 }); f.recorder.observe(source(), before);
  f.reopen().observe(null, after);
  assert.ok(f.rows().every(row => row.reason === "contract_unsupported"));
});
test("crash after outcomes commit and before state advance replays idempotently", () => {
  const f = fixture(); f.recorder.observe(source(), before);
  const state = fs.readFileSync(f.settings.statePath); f.recorder.observe(null, after);
  const outcomes = fs.readFileSync(f.settings.outcomePath);
  fs.writeFileSync(f.settings.statePath, state);
  f.reopen().observe(null, after);
  assert.deepEqual(fs.readFileSync(f.settings.outcomePath), outcomes);
});
test("crash replay retains a late-delivered close absent from the old private state", () => {
  const f = fixture(), observedAt = "2026-11-13T22:59:58.000Z", deliveredAt = "2026-11-13T23:00:02.000Z";
  f.recorder.observe(null, before);
  const priorState = fs.readFileSync(f.settings.statePath);
  assert.equal(f.recorder.observe(source(observedAt), deliveredAt), true);
  const outcomes = fs.readFileSync(f.settings.outcomePath);
  fs.writeFileSync(f.settings.statePath, priorState);
  assert.equal(f.reopen().observe(source(after), after), true);
  assert.deepEqual(fs.readFileSync(f.settings.outcomePath), outcomes);
  assert.ok(f.rows().every(row => row.observedAt === observedAt));
});
test("crash replay keeps committed recorder_gap reasons across a real restart", () => {
  const f = fixture(); f.recorder.observe(source(), before);
  const priorState = fs.readFileSync(f.settings.statePath), later = "2026-11-16T12:00:00.000Z";
  assert.equal(f.recorder.observe(null, later), true);
  const outcomes = fs.readFileSync(f.settings.outcomePath);
  fs.writeFileSync(f.settings.statePath, priorState);
  assert.equal(f.reopen().observe(null, later), true);
  assert.deepEqual(fs.readFileSync(f.settings.outcomePath), outcomes);
  assert.equal(f.rows().filter(row => row.reason === "recorder_gap").length, 6);
});
test("replay settles an outcome rename whose directory fsync failed before state advanced", t => {
  const f = fixture(); f.recorder.observe(source(), before);
  const original = fs.fsyncSync, priorState = fs.readFileSync(f.settings.statePath);
  let failOnce = true, directories = 0;
  t.mock.method(fs, "fsyncSync", fd => {
    if (fs.fstatSync(fd).isDirectory()) {
      directories++;
      if (failOnce) { failOnce = false; throw new Error("synthetic_sync_failure"); }
    }
    return original(fd);
  });
  assert.equal(f.recorder.observe(null, after), false);
  assert.deepEqual(fs.readFileSync(f.settings.statePath), priorState);
  assert.equal(f.rows().length, 3);
  const bytes = fs.readFileSync(f.settings.outcomePath);
  directories = 0;
  assert.equal(f.reopen().observe(null, after), true);
  assert.equal(directories, 2, "sync retained outcomes, then the private state directory");
  assert.deepEqual(fs.readFileSync(f.settings.outcomePath), bytes);
});

function conflictControl(create) {
  const f = fixture(); f.recorder.observe(source(), before); f.recorder.observe(null, after);
  const bytes = fs.readFileSync(f.settings.outcomePath, "utf8"), row = f.rows()[0];
  const store = create(f.settings.outcomePath, e => f.events.push(e));
  assert.equal(store.append([row]), true);
  assert.equal(fs.readFileSync(f.settings.outcomePath, "utf8"), bytes);
  const conflict = { ...row, equityClose: { amount: "999", currency: "EUR" } };
  assert.equal(store.append([conflict]), false);
  assert.equal(fs.readFileSync(f.settings.outcomePath, "utf8"), bytes);
  assert.equal(f.events.at(-1).reason, "outcome_conflict");
  assert.equal(JSON.stringify(f.events).includes("999"), false);
}
test("duplicate is a no-op; conflicting second outcome is rejected and logged without values", () => conflictControl(createOutcomeStore));

function startControl(create) {
  const f = fixture(create, { firstDay: "2026-11-14" });
  f.recorder.observe(source(), before); f.recorder.observe(source(after), after);
  assert.deepEqual(f.rows(), []);
}
test("start guard prevents every outcome for earlier days", () => startControl(createDeskEquityCloseRecorder));
for (const firstDay of [undefined, "", "invalid", "2026-02-30"]) {
  test(`unset/invalid start guard records nothing (${String(firstDay)})`, () => {
    const f = fixture(undefined, { firstDay });
    f.recorder.observe(source(), before); f.recorder.observe(null, after);
    assert.deepEqual(fs.readdirSync(f.dir), []);
  });
}
test("fixed guard cannot move earlier on restart; fresh install never backfills", () => {
  const f = fixture(); f.recorder.observe(source(), before);
  assert.equal(createDeskEquityCloseRecorder({ ...f.settings, firstDay: "2026-11-12" }).observe(null, after), false);
  assert.equal(f.events.at(-1).reason, "start_guard_changed"); assert.deepEqual(f.rows(), []);
  const fresh = fixture(undefined, { firstDay: "2026-01-01" }); fresh.recorder.observe(source(after), after);
  assert.deepEqual(fresh.rows(), []);
});
for (const [day, begin, end, hours] of [
  ["2026-10-25", "2026-10-24T22:00:00.000Z", "2026-10-25T23:00:00.000Z", 25],
  ["2027-03-28", "2027-03-27T23:00:00.000Z", "2027-03-28T22:00:00.000Z", 23],
]) test(`Vienna DST ${day} uses the ${hours}-hour civil day and correct close boundary`, () => {
  const previous = new Date(Date.parse(`${day}T12:00:00Z`) - 86400_000).toISOString().slice(0, 10);
  assert.equal(closeBoundary(previous), begin);
  assert.equal(closeBoundary(day), end); assert.equal((Date.parse(end) - Date.parse(begin)) / 3600_000, hours);
  const f = fixture(undefined, { firstDay: day }), last = new Date(Date.parse(end) - 15000).toISOString();
  f.recorder.observe(source(begin), begin); f.recorder.observe(source(last), last);
  const restarted = f.reopen(); restarted.observe(source(end), end);
  assert.equal(f.rows().length, 3);
  for (const row of f.rows()) { assert.equal(row.vienna_day, day); assert.equal(row.observedAt, last); assert.notEqual(row.equityClose, null); }
});
test("clock rollback and corrupted durable state fail closed without overwriting outcomes", () => {
  const f = fixture(); f.recorder.observe(source(), before);
  assert.equal(f.recorder.observe(source("2026-11-13T12:00:00.000Z"), "2026-11-13T12:00:00.000Z"), false);
  fs.writeFileSync(f.settings.statePath, "{}");
  assert.equal(f.reopen().observe(null, after), false); assert.deepEqual(f.rows(), []);
});
test("atomic persistence fsyncs bytes before rename and directory afterwards", () => {
  const events = [], io = Object.fromEntries(["openSync", "writeFileSync", "fsyncSync", "closeSync", "renameSync"].map(method =>
    [method, (...args) => { events.push([method, ...args]); return method === "openSync" ? events.length : undefined; }]));
  atomicWrite("/synthetic/outcomes.jsonl", "synthetic\n", io);
  assert.deepEqual(events.map(e => e[0]), ["openSync", "writeFileSync", "fsyncSync", "closeSync", "renameSync", "openSync", "fsyncSync", "closeSync"]);
  assert.equal(events[0][2], "wx"); assert.equal(events[0][3], 0o600);
});
for (const failure of ['writeFileSync', 'fsyncSync', 'renameSync']) test(`atomic persistence removes its temp after ${failure} failure`, () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ops556-atomic-failure-')), filename = path.join(dir, 'outcomes.jsonl');
  fs.writeFileSync(filename, 'committed\n');
  const injected = new Error('injected_storage_failure'), io = { ...fs, [failure]: (...args) => {
    if (failure === 'writeFileSync') fs.writeFileSync(...args); // Leave partial bytes before failing.
    throw injected;
  } };
  for (let i = 0; i < 10; i++) {
    assert.throws(() => atomicWrite(filename, 'uncommitted\n', io), error => error === injected);
    assert.deepEqual(fs.readdirSync(dir), ['outcomes.jsonl']);
    assert.equal(fs.readFileSync(filename, 'utf8'), 'committed\n');
  }
});
test('atomic persistence preserves the original error when temp cleanup also fails', () => {
  const injected = new Error('injected_write_failure');
  const io = { openSync: () => 1, writeFileSync: () => { throw injected; }, closeSync: () => {},
    unlinkSync: () => { throw new Error('injected_cleanup_failure'); } };
  assert.throws(() => atomicWrite('/synthetic/state.json', '{}', io), error => error === injected);
});
test("read-only or failed storage never propagates into publication", () => {
  const f = fixture(undefined, { statePath: "/nonexistent-ops556/state.json" });
  assert.equal(f.recorder.observe(source(), before), false);
  assert.equal(f.events.at(-1).reason, "storage_or_observation_unavailable");
});
test("persistent recorder failures log at most once per reason per 15 minutes", t => {
  let clock = 0; t.mock.method(Date, "now", () => clock);
  const f = fixture(undefined, { statePath: "/nonexistent-ops556/state.json" });
  for (let i = 0; i < 30; i++) { f.recorder.observe(source(), before); clock += 30_000; }
  assert.equal(f.events.length, 1);
  f.recorder.observe(source(), before); assert.equal(f.events.length, 2);
});
test("startup cleans only this writer's stale UUID temp files", () => {
  const f = fixture(), suffix = '.12345678-1234-1234-1234-123456789abc.tmp';
  const stale = [f.settings.statePath + suffix, f.settings.outcomePath + suffix];
  for (const filename of stale) fs.writeFileSync(filename, 'partial synthetic bytes');
  const unrelated = path.join(f.dir, 'unrelated.tmp'); fs.writeFileSync(unrelated, 'retain');
  const symlink = f.settings.statePath + '.aaaaaaaa-1234-1234-1234-123456789abc.tmp';
  fs.symlinkSync(unrelated, symlink);
  assert.equal(f.recorder.observe(source(), before), true);
  assert.ok(stale.every(filename => !fs.existsSync(filename)));
  assert.equal(fs.readFileSync(unrelated, 'utf8'), 'retain'); assert.equal(fs.lstatSync(symlink).isSymbolicLink(), true);
});

test("mutation controls kill missing age/start/conflict/exactness guards", async () => {
  const original = fs.readFileSync(new URL("./desk-equity-closes.mjs", import.meta.url), "utf8");
  const mutations = [
    ["age", 'Date.parse(closeAt) - Date.parse(exact.observedAt) > maxAgeMs', 'false'],
    ["start", 'if (day < firstDay) continue;', 'if (false) continue;'],
    ["conflict", 'canonicalOutcome(previous) !== canonicalOutcome(row)', 'false'],
    ["exactness", 'const money = live?.desks.find(row => row.id === desk)?.money.equity;', 'const money = { amount: "5001.25", currency: "EUR" };'],
  ];
  // Mutants live in /tmp and import the real dependencies by absolute file URL.
  for (const [name, needle, replacement] of mutations) {
    assert.ok(original.includes(needle), name);
    let changed = original.replace(needle, replacement).replace(/from "(\.\/[^\"]+)"/g,
      (_, specifier) => `from "${new URL(specifier, import.meta.url).href}"`);
    // Remove the second age check too: the stale behavioral assertion must kill
    // this mutation, rather than merely the writer's schema validation.
    if (name === "age") changed = changed.replace('Date.parse(row.closeAt) - Date.parse(row.observedAt) <= row.maxAgeMs', 'true');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ops556-mutant-")), filename = path.join(dir, "mutant.mjs");
    fs.writeFileSync(filename, changed);
    const mutant = await import(pathToFileURL(filename));
    assert.throws(() => name === "age" ? staleControl(mutant.createDeskEquityCloseRecorder)
      : name === "start" ? startControl(mutant.createDeskEquityCloseRecorder)
        : name === "conflict" ? conflictControl(mutant.createOutcomeStore) : exactControl(mutant.createDeskEquityCloseRecorder),
    { name: "AssertionError" }, `${name} mutation survived`);
  }
});
