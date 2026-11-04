import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { CURRENT_DESK_OWNERSHIP_POLICY, deskOwnershipPolicyContract } from "./desk-ledger.mjs";
import { projectBook } from "./project.mjs";
import { copyObservation } from "./v2-stage-handoff.mjs";
import { buildCandidate, StageStore, prepareLock, validObservation } from "./v2-stage-worker.mjs";
import { createV2Publisher } from "./v2-publisher.mjs";
import { validateContract } from "./contracts/index.mjs";
import { checkSchema } from "./contracts/schema-validator.mjs";
import { runPusher, instant } from "./fixtures/pusher-harness.mjs";

const at = "2026-11-04T10:00:00.000Z";
const next = "2026-11-04T10:00:30.000Z";
const expected = "desk-policy-b5a60129aec4";
// Read-only comparison with local JoeDesk contracts/data.schema.json:364
// confirmed this pinned, vendored field has the board owner's r43 constraints.
const schema = JSON.parse(fs.readFileSync(new URL("./contracts/data.schema.json", import.meta.url)))
  .properties.desks.items.properties.historyBasis;
const desk = (snapshot, id) => snapshot.desks.find(row => row.id === id);
const book = (ts = at) => ({ ts, gateway: true, summary: {}, positions: [], portfolio: [] });
function checkBases(snapshot, basis = expected) {
  assert.equal(schema.pattern, "^[a-z][a-z0-9.-]*$");
  assert.equal(schema.maxLength, 96);
  for (const id of ["j", "joe"]) {
    assert.equal(desk(snapshot, id).historyBasis, basis);
    assert.match(desk(snapshot, id).historyBasis, /^desk-policy-[0-9a-f]{12}$/);
    assert.deepEqual(checkSchema(schema, desk(snapshot, id).historyBasis, {}), []);
  }
}

test("snapshot basis follows canonical ownership policy, independently of observations and evidence", () => {
  assert.equal(`desk-policy-${deskOwnershipPolicyContract().policyHash.slice(0, 12)}`, expected);
  const project = (policy, input = book(), opts = {}) => projectBook(input, {
    publisherAt: new Date(input.ts), deskOwnershipPolicy: policy, ...opts,
  });
  const first = project(CURRENT_DESK_OWNERSHIP_POLICY);
  checkBases(first);
  const reordered = structuredClone(CURRENT_DESK_OWNERSHIP_POLICY);
  reordered.assignments.reverse(); reordered.fillAttributionOverrides.reverse(); reordered.executorClientIds.reverse();
  const serialized = JSON.parse(JSON.stringify(reordered));
  checkBases(project(serialized));
  checkBases(project(serialized, { ...book(next), portfolio: [
    { symbol: "INTC", pos: 1, unrealizedPNL: 5, realizedPNL: 2 },
  ] }));
  checkBases(project(serialized, book(next), {
    familyRuntimeEnabled: true, family: { ok: false, reason: "synthetic unavailable" },
    deskEquities: { ok: false }, dayPnl: { ok: false },
  }));
  const prior = { ...CURRENT_DESK_OWNERSHIP_POLICY, fillAttributionOverrides: [] };
  const before = project(prior);
  checkBases(before, `desk-policy-${deskOwnershipPolicyContract(prior).policyHash.slice(0, 12)}`);
  assert.notEqual(desk(before, "j").historyBasis, expected);
  assert.deepEqual(desk(first, "joel"), desk(before, "joel"), "Joel's full existing v1 representation is unchanged");
  assert.equal(desk(first, "joel").historyBasis, "joel.stage0-keep-excluded.v1");
  for (const field of ["execId", "desk", "basis", "date"]) {
    const changed = structuredClone(CURRENT_DESK_OWNERSHIP_POLICY);
    changed.fillAttributionOverrides[0][field] = {
      execId: "synthetic-new-identity", desk: "joe", basis: "synthetic revised decision", date: "2026-11-05",
    }[field];
    const basis = `desk-policy-${deskOwnershipPolicyContract(changed).policyHash.slice(0, 12)}`;
    assert.notEqual(basis, expected);
    checkBases(project(changed), basis);
  }
});

for (const pushSchema of [undefined, "inspr.joe.household.v2"]) {
  test(`first pusher snapshot and handoff carry the basis across worker restarts (${pushSchema ?? "v1"})`, async () => {
    const options = { cycles: 1, pushSchema };
    for (let restart = 0; restart < 2; restart++) {
      const pushed = await runPusher(new URL("./pusher.mjs", import.meta.url), options);
      assert.equal(pushed.observations.length, 1, "inspect the first snapshot from each cold worker");
      checkBases(JSON.parse(pushed.v1Body));
      assert.equal(pushed.observation.historyBasis, expected);
      assert.equal(validObservation(pushed.observation), true);
      for (const revision of [9, 10]) {
        const snapshot = buildCandidate(1, instant, pushed.observation, instant, null, revision);
        checkBases(snapshot);
        assert.equal(Object.hasOwn(desk(snapshot, "joel"), "historyBasis"), false);
        assert.equal(validateContract("data", snapshot, { stage: "ingress" }).ok, true);
      }
      assert.equal(pushed.inputsUnchanged, true);
    }
  });
}

for (const revision of [9, 10]) test(`rev ${revision} commits and publishes the first new basis, preserving old pairs through restart`, async t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ops557-basis-"));
  fs.chmodSync(root, 0o700);
  t.after(() => spawnSync("trash", [root]));
  const options = { root, uid: process.getuid(), gid: process.getgid(), revision, env: {} };
  prepareLock(root, options.uid, options.gid);
  const store = new StageStore(options); store.enroll(); await store.open();
  const old = copyObservation({ book: book() }, revision);
  assert.equal(store.stage(old, () => at).status, 200);
  const oldBytes = fs.readFileSync(path.join(root, "pair-1/snapshot.json"));
  const observation = copyObservation({ book: book(next), historyBasis: expected }, revision);
  assert.equal(validObservation(observation), true);
  assert.equal(store.stage(observation, () => next).status, 200);
  const current = store.readCommittedPair();
  const snapshot = JSON.parse(current.bytes);
  checkBases(snapshot);
  assert.equal(Object.hasOwn(desk(snapshot, "joel"), "historyBasis"), false);
  assert.deepEqual(desk(snapshot, "joel"), desk(buildCandidate(2, next,
    copyObservation({ book: book(next) }, revision), next, null, revision), "joel"));
  assert.equal(store.validProjection(snapshot), true);
  assert.equal(validateContract("data", snapshot, { stage: "ingress" }).ok, true);
  const restarted = await new StageStore(options).open();
  assert.deepEqual(restarted.readCommittedPair().bytes, current.bytes);
  assert.deepEqual(fs.readFileSync(path.join(root, "pair-1/snapshot.json")), oldBytes);
  let sent;
  const publisher = createV2Publisher({ reader: restarted, now: () => next,
    stateStore: { load: () => ({ format: "ops408.v2-post-state.v1", lastPosted: null, pending: null, outcomes: [] }), save() {} }, emit() {},
    send: async (_url, request) => { sent = request.body;
      return { ok: true, status: 200, text: async () => JSON.stringify({ receivedAt: next }) }; },
  });
  assert.equal((await publisher.push({ url: "http://fixture.invalid/joe/inbox", token: "synthetic-basis-test" })).status, 200);
  assert.deepEqual(sent, current.bytes);
  checkBases(JSON.parse(sent));
  for (const change of [
    snap => { desk(snap, "j").historyBasis = expected.toUpperCase(); },
    snap => { delete desk(snap, "joe").historyBasis; },
    snap => { desk(snap, "joe").historyBasis = "desk-policy-000000000000"; },
    snap => { desk(snap, "joel").historyBasis = expected; },
  ]) {
    const invalid = structuredClone(snapshot); change(invalid);
    assert.equal(restarted.validProjection(invalid), false);
  }
  const uppercase = structuredClone(snapshot);
  desk(uppercase, "j").historyBasis = expected.toUpperCase();
  assert.equal(validateContract("data", uppercase, { stage: "ingress" }).ok, false,
    "uppercase would cause the board to reject the entire snapshot");
});

test("handoff rejects malformed policy bases before copying or staging", () => {
  const good = copyObservation({ book: book(), historyBasis: expected });
  for (const historyBasis of [null, 42, "", expected.toUpperCase(), "desk-policy-b5A60129aec4",
    "desk_policy-b5a60129aec4", `${expected}\n`, "a".repeat(97), "desk-policy-b5a60129aec"]) {
    assert.equal(copyObservation({ book: book(), historyBasis }), null);
    assert.equal(validObservation({ ...good, historyBasis }), false);
  }
  assert.equal(validObservation(copyObservation({ book: book() })), true, "old observation shape remains supported");
});
