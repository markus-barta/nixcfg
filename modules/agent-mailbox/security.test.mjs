import assert from "node:assert/strict";
import test from "node:test";
import { assertListen, assertPeers, DEFAULT_PEERS, isTailnetIPv4, normalizePeer, parseMessage } from "./security.mjs";

test("caller addresses normalize IPv4-mapped IPv6 without admitting other addresses", () => {
  const peers = assertPeers(DEFAULT_PEERS);
  assert.equal(peers.get(normalizePeer("::ffff:100.64.0.10")), "amy");
  assert.equal(peers.get(normalizePeer("100.64.0.14")), "ops");
  for (const address of [undefined, "127.0.0.1", "100.64.0.9", "100.64.0.10.evil", "::1", "constructor", " 100.64.0.10"]) assert.equal(peers.get(normalizePeer(address)), undefined);
  for (const address of ["100.64.0.0", "100.127.255.255"]) assert.equal(isTailnetIPv4(address), true);
  for (const address of ["100.63.255.255", "100.128.0.0", "100.64.256.1", "100.64.00.10", "::ffff:100.64.0.10"]) assert.equal(isTailnetIPv4(address), false);
});

test("production binds only hsb0 with valid port and path-safe configured peer identities", () => {
  assert.deepEqual(assertListen("100.64.0.6", 8471), { host: "100.64.0.6", port: 8471 });
  for (const host of ["0.0.0.0", "::", "192.168.1.99", "127.0.0.1", "100.64.0.7"]) assert.throws(() => assertListen(host, 8471));
  for (const port of [0, -1, 65536, 1.1, "8471", NaN]) assert.throws(() => assertListen("100.64.0.6", port));
  for (const peers of [[], null, {}, { "100.64.0.10": "amy" }, { "127.0.0.1": "amy", "100.64.0.14": "ops" }]) assert.throws(() => assertPeers(peers));
  for (const identity of ["../ops", "/ops", "", "amy\0", "constructor", "prototype", "__proto__", "OPS"]) assert.throws(() => assertPeers({ ...DEFAULT_PEERS, "100.64.0.10": identity }));
});

test("message schema admits only recipient, optional bounded ticket, and bounded text", () => {
  const identities = ["amy", "ops"];
  const parse = (value) => parseMessage(value, "amy", identities);
  assert.deepEqual(parse({ to: "ops", body: "hello" }), { to: "ops", ticket: null, body: "hello" });
  for (const ticket of ["OP-1", "OPS-272", "A123456789012345-123456"]) assert.equal(parse({ to: "ops", body: "hi", ticket }).ticket, ticket);
  assert.equal(parse({ to: "ops", body: "x".repeat(16384) }).body.length, 16384);
  for (const value of [null, [], "hello", {}, { to: "amy", body: "hi" }, { to: "unknown", body: "hi" }, { to: "../ops", body: "hi" }]) assert.throws(() => parse(value), { statusCode: 400 });
  for (const ticket of [null, 272, "ops-272", "O-1", "OPS-", "OPS-1234567", "OPS-1\n", "ABCDEFGHIJKLMNOPQ-1"]) assert.throws(() => parse({ to: "ops", body: "hi", ticket }), { statusCode: 400 });
  for (const body of [null, {}, 1, "", "x\0y", "x".repeat(16385)]) assert.throws(() => parse({ to: "ops", body }), { statusCode: 400 });
  for (const key of ["from", "identity", "id", "createdAt", "path", "__proto__", "constructor"]) {
    const value = JSON.parse(`{"to":"ops","body":"hello","${key}":"ops"}`);
    assert.throws(() => parse(value), { statusCode: 400 });
  }
});
