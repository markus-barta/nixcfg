import assert from "node:assert/strict";
import path from "node:path";
import test from "node:test";

import {
  DEFAULT_PEERS,
  assertListen,
  assertPaperPort,
  assertPeerAllowlist,
  confinedPath,
  normalizePeer,
  peerAllowed,
} from "./security.mjs";

test("confined paths stay beneath their fixed root", () => {
  assert.equal(confinedPath("/state", "/state/ledger.json"), path.resolve("/state/ledger.json"));
  assert.equal(confinedPath("/state", "/state/nested/ledger.json"), path.resolve("/state/nested/ledger.json"));
  assert.throws(() => confinedPath("/state", "/state"), /must be beneath/);
  assert.throws(() => confinedPath("/state", "/state/../etc/passwd"), /must be beneath/);
  assert.throws(() => confinedPath("/state", "/state-backup/ledger.json"), /must be beneath/);
  assert.throws(() => confinedPath("/state", "ledger.json"), /must be beneath/);
});

test("paper port 4002 is required and live port 4001 is a hard error", () => {
  assert.equal(assertPaperPort(4002), 4002);
  assert.equal(assertPaperPort("4002"), 4002);
  assert.throws(() => assertPaperPort(4001), /live port 4001/);
  assert.throws(() => assertPaperPort(4003), /non-paper port/);
  assert.throws(() => assertPaperPort(0), /non-paper port/);
});

test("peer allowlist accepts only tailnet sources and the default desks", () => {
  assert.deepEqual(assertPeerAllowlist(DEFAULT_PEERS), ["100.64.0.9", "100.64.0.14"]);
  assert.equal(normalizePeer("::ffff:100.64.0.9"), "100.64.0.9");
  assert.equal(peerAllowed("::ffff:100.64.0.14", DEFAULT_PEERS), true);
  assert.equal(peerAllowed("100.64.0.8", DEFAULT_PEERS), false);
  assert.equal(peerAllowed("127.0.0.1", DEFAULT_PEERS), false);
  assert.throws(() => assertPeerAllowlist(["192.168.1.99"]), /not a tailnet address/);
  assert.throws(() => assertPeerAllowlist(["0.0.0.0"]), /not a tailnet address/);
  assert.throws(() => assertPeerAllowlist(["127.0.0.1"]), /not a tailnet address/);
  assert.throws(() => assertPeerAllowlist([]), /empty/);
  assert.deepEqual(assertPeerAllowlist(["127.0.0.1"], { testMode: true }), ["127.0.0.1"]);
});

test("production listen stays on the hsb0 tailnet address and port 8470", () => {
  assert.deepEqual(assertListen("100.64.0.6", 8470), { host: "100.64.0.6", port: 8470 });
  assert.throws(() => assertListen("0.0.0.0", 8470), /tailnet address/);
  assert.throws(() => assertListen("192.168.1.99", 8470), /tailnet address/);
  assert.throws(() => assertListen("127.0.0.1", 8470), /tailnet address/);
  assert.throws(() => assertListen("100.64.0.6", 4002), /port 8470/);
  assert.throws(() => assertListen("100.64.0.6", 4001), /port 8470/);
  assert.deepEqual(assertListen("127.0.0.1", 0, { testMode: true }), { host: "127.0.0.1", port: 0 });
  assert.throws(() => assertListen("0.0.0.0", 0, { testMode: true }), /loopback/);
});
