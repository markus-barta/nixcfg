#!/usr/bin/env node
// OPS-354 / ADR §8: execute the actual P1/P3 host functions at immutable pins.
import assert from "node:assert/strict";
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import vm from "node:vm";
const args = process.argv.slice(2);
assert.equal(args.length, 2, "use --joedesk-source SOURCE");
assert.equal(args[0], "--joedesk-source");
const source = args[1];
const read = (file) =>
  JSON.parse(fs.readFileSync(new URL("../" + file, import.meta.url)));
const release = read("hosts/csb0/joedesk-release.json");
const lock = read("flake.lock");
assert.equal(
  release.sets[release.active].board.rev,
  lock.nodes.joedesk.locked.rev,
);
function show(rev, file) {
  assert.match(rev, /^[0-9a-f]{40}$/);
  return execFileSync("git", ["-C", source, "show", rev + ":" + file], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}
function checkGate(fn) {
  assert.equal(typeof fn, "function");
  for (const host of [
    "cs0.barta.cm",
    "CS0.BARTA.CM",
    "cs0",
    "localhost",
    "127.0.0.1",
    "[::1]",
  ])
    assert.equal(fn(host), true, "canonical host must be enabled");
  for (const host of [
    "example.invalid",
    "cs0.barta.com",
    "cs0.barta.cm.example.invalid",
    "evil-cs0.barta.cm",
    "",
    null,
  ])
    assert.equal(fn(host), false, "noncanonical host must show privacy stub");
}
for (const [name, set] of Object.entries(release.sets)) {
  if (set.board.data_schema === "v1") {
    const legacy = show(set.board.rev, "public/joe/joe.js");
    const functionSource = legacy.match(
      /function isCanonicalJoeHost\(hostname\) \{[\s\S]*?\n  \}/,
    )?.[0];
    assert.ok(functionSource, "actual legacy host function missing");
    checkGate(
      vm.runInNewContext("(" + functionSource + ")", {}, { timeout: 1000 }),
    );
    assert.match(
      legacy,
      /if \(!isCanonicalJoeHost\(location.hostname\)\)/,
      "legacy app must invoke the host gate",
    );
  } else {
    const moduleSource = show(set.board.rev, "public/joe/host.js");
    const { isCanonicalJoeHost } = await import(
      "data:text/javascript;base64," +
        Buffer.from(moduleSource).toString("base64")
    );
    checkGate(isCanonicalJoeHost);
    const app = show(set.board.rev, "public/joe/app.js");
    assert.match(
      app,
      /import \{ isCanonicalJoeHost \} from ['"]\.\/host.js['"]/,
    );
    assert.match(app, /if \(!isCanonicalJoeHost\(location.hostname\)\)/);
  }
}
console.log(
  "joedesk_production_host_gate=ok current_previous_and_candidate=actual-functions cs0=allowed",
);
