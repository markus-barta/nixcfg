import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const clients = fileURLToPath(new URL("./clients/", import.meta.url));
const id = (digit) => `1791619200000-${digit.repeat(32)}`;
const row = (digit = "a", body = "Hello Amy") => ({ id: id(digit), from: "ops", to: "amy", ticket: "OPS-290", createdAt: "2026-10-10T08:00:00.000Z", body });
const frame = (message) => `id: ${message.id}\nevent: message\ndata: ${JSON.stringify(message)}\n\n`;
function fixture() {
  const root = realpathSync(mkdtempSync(path.join(tmpdir(), "ops290-client-")));
  const bin = path.join(root, "bin");
  mkdirSync(bin);
  const stream = path.join(root, "stream");
  const argumentsPath = path.join(root, "curl-args");
  writeFileSync(path.join(bin, "curl"), '#!/bin/sh\nprintf "%s\\n" "$@" >> "$MAILBOX_CURL_ARGS"\ncat "$MAILBOX_FIXTURE"\nexit "${MAILBOX_CURL_EXIT:-0}"\n', { mode: 0o700 });
  return { root, bin, stream, argumentsPath,
    env: { ...process.env, HOME: root, PATH: `${bin}:${process.env.PATH}`, MAILBOX_FIXTURE: stream, MAILBOX_CURL_ARGS: argumentsPath, AMY_MAILBOX_DIR: path.join(root, "amy"), MBX_ROOT: path.join(root, ".local", "share", "agent-mailbox") },
  };
}
function amy(ctx, overrides = {}) {
  return spawnSync("sh", [path.join(clients, "amy-watch.sh"), "--once"], { env: { ...ctx.env, ...overrides }, encoding: "utf8", timeout: 5000 });
}

async function watchOps(t, ctx, { args = [], onOutput = () => {}, stopOnError = true } = {}) {
  mkdirSync(path.join(ctx.env.HOME, ".local", "share", "agent-mailbox", "to-ops"), { recursive: true });
  const child = spawn(process.execPath, [...args, path.join(clients, "mbx-watch.mjs"), "http://fixture.invalid", "0.05"],
    { env: ctx.env, stdio: ["ignore", "pipe", "pipe"] });
  t.after(() => child.kill("SIGTERM"));
  let output = ""; let errors = "";
  const timer = setTimeout(() => child.kill("SIGTERM"), 5000);
  child.stdout.on("data", (data) => { output += data; onOutput(output, child); });
  child.stderr.on("data", (data) => { errors += data; if (stopOnError) child.kill("SIGTERM"); });
  await new Promise((resolve) => child.once("close", resolve));
  clearTimeout(timer);
  return { output, errors };
}

function replayLoader(ctx, { raceReceipts = false } = {}) {
  const loader = path.join(ctx.root, "replay-loader.mjs");
  const barrier = path.join(ctx.root, "receipt-barrier");
  if (raceReceipts) mkdirSync(barrier);
  writeFileSync(loader, `import cp from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { syncBuiltinESMExports } from "node:module";
import { EventEmitter } from "node:events";
import { Readable } from "node:stream";
import { readFileSync } from "node:fs";
cp.spawn = () => {
  const child = new EventEmitter();
  child.stdout = Readable.from([readFileSync(process.env.MAILBOX_FIXTURE)]);
  child.kill = () => {};
  child.stdout.once("end", () => child.emit("close", 7));
  return child;
};
${raceReceipts ? `// Hold both watchers at receipt creation so this exercises a real race.
const write = fs.writeFileSync;
let arrived = false;
fs.writeFileSync = (filename, ...args) => {
  if (!arrived && /^[0-9]{13}-[a-f0-9]{32}$/.test(path.basename(filename))) {
    arrived = true;
    write(path.join(${JSON.stringify(barrier)}, String(process.pid)), "ready");
    const deadline = Date.now() + 3000;
    while (fs.readdirSync(${JSON.stringify(barrier)}).length < 2) {
      if (Date.now() > deadline) throw new Error("receipt race barrier timed out");
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
    }
  }
  return write(filename, ...args);
};` : ""}
syncBuiltinESMExports();
`);
  return loader;
}

test("OPS refuses default paths escaping home, including a shared path prefix", () => {
  for (const sharedPrefix of [false, true]) {
    const ctx = fixture();
    const outside = sharedPrefix ? `${ctx.root}-outside` : realpathSync(mkdtempSync(path.join(tmpdir(), "ops290-outside-home-")));
    mkdirSync(outside, { recursive: true });
    symlinkSync(outside, path.join(ctx.root, ".local"));
    const root = path.join(outside, "share", "agent-mailbox");
    const result = spawnSync(process.execPath, [path.join(clients, "mbx-watch.mjs"), "http://fixture.invalid"],
      { env: ctx.env, encoding: "utf8", timeout: 5000 });
    assert.equal(result.status, 2, result.stderr);
    assert.match(result.stderr, /bad watch root/);
    assert.equal(existsSync(path.join(root, "watch-ops")), false);
    assert.equal(existsSync(ctx.argumentsPath), false);
  }
});

test("OPS refuses symlink roots and missing descendants that resolve outside home", () => {
  const outside = realpathSync(mkdtempSync(path.join(tmpdir(), "ops290-outside-")));
  for (const missingDescendants of [false, true]) {
    const ctx = fixture();
    const link = missingDescendants ? path.join(ctx.root, ".local") : ctx.env.MBX_ROOT;
    mkdirSync(path.dirname(link), { recursive: true });
    symlinkSync(outside, link);
    const result = spawnSync(process.execPath, [path.join(clients, "mbx-watch.mjs"), "http://fixture.invalid"],
      { env: ctx.env, encoding: "utf8", timeout: 5000 });
    assert.equal(result.status, 2, result.stderr);
    assert.match(result.stderr, /bad watch root/);
  }
  assert.deepEqual(readdirSync(outside), []);
});

test("OPS ignores MBX_ROOT and uses the fixed mailbox under HOME", async (t) => {
  const ctx = fixture();
  const root = ctx.env.MBX_ROOT;
  ctx.env.MBX_ROOT = `${ctx.root}-outside/mailbox`;
  writeFileSync(ctx.stream, frame({ ...row(), from: "amy", to: "ops" }));
  const result = await watchOps(t, ctx, { args: ["--import", replayLoader(ctx)] });
  assert.ok(result.output.includes(`MBX NEW for ops: ${id("a")}`), result.errors);
  assert.equal(readFileSync(path.join(root, "watch-ops", "cursor"), "utf8"), `${id("a")}\n`);
  assert.equal(existsSync(ctx.env.MBX_ROOT), false);
});

test("OPS still validates endpoint and interval before creating watch state", () => {
  const ctx = fixture();
  for (const args of [[], [ctx.env.MBX_ROOT, "http://fixture.invalid"], ["file:///tmp/events"],
    ["http://fixture.invalid", "0"], ["http://fixture.invalid", "-1"], ["http://fixture.invalid", "bad"], ["http://fixture.invalid", "Infinity"]]) {
    const result = spawnSync(process.execPath, [path.join(clients, "mbx-watch.mjs"), ...args],
      { env: ctx.env, encoding: "utf8", timeout: 5000 });
    assert.equal(result.status, 2, result.stderr);
    assert.match(result.stderr, /bad watch endpoint or interval/);
    assert.equal(existsSync(path.join(ctx.env.MBX_ROOT, "watch-ops")), false);
    assert.equal(existsSync(ctx.argumentsPath), false);
  }
});

test("OPS rejects traversal-shaped event ids without receipts or cursor advancement", async (t) => {
  for (const bad of ["../../escape", `${id("a")}/../escape`, `${id("a")}\n`]) {
    const ctx = fixture();
    const message = { ...row(), id: bad, from: "amy", to: "ops" };
    // A literal newline in the SSE id field would terminate the frame before
    // its data. Keep that field valid to exercise the JSON id's trailing newline.
    writeFileSync(ctx.stream, bad.endsWith("\n")
      ? `id: ${id("a")}\nevent: message\ndata: ${JSON.stringify(message)}\n\n`
      : frame(message));
    const result = await watchOps(t, ctx, { args: ["--import", replayLoader(ctx)] });
    assert.match(result.errors, /event delivery failed/);
    assert.equal(result.output.includes("MBX NEW for ops:"), false);
    assert.deepEqual(readdirSync(path.join(ctx.env.MBX_ROOT, "watch-ops")), []);
  }
});

test("OPS ignores traversal-shaped and unsafe local filenames while accepting ordinary names", async (t) => {
  const ctx = fixture();
  const inbox = path.join(ctx.env.MBX_ROOT, "to-ops");
  mkdirSync(inbox, { recursive: true });
  const contents = "From: codex\nTicket: OPS-290\n\nlocal filename test\n";
  const rejected = ["..escape.txt", "nested..name.txt", "unsafe name.txt", "unsafe.txt\n"];
  for (const name of [...rejected, "safe_name-01.txt"]) writeFileSync(path.join(inbox, name), contents);
  writeFileSync(ctx.stream, "");
  const result = await watchOps(t, ctx, { args: ["--import", replayLoader(ctx)] });
  const announcements = result.output.split("\n").filter((line) => line.startsWith("MBX NEW for ops:"));
  assert.equal(announcements.length, 1, result.output);
  assert.match(announcements[0], /safe_name-01\.txt/);
  for (const name of rejected) assert.equal(readFileSync(path.join(inbox, name), "utf8"), contents);
});

for (const source of ["push", "local"]) {
  test(`OPS concurrent ${source} receipt creation announces a shared message once`, async (t) => {
    const ctx = fixture();
    const message = { ...row(), from: "amy", to: "ops" };
    const inbox = path.join(ctx.env.MBX_ROOT, "to-ops");
    mkdirSync(inbox, { recursive: true });
    if (source === "local") writeFileSync(path.join(inbox, "pulled.txt"), `From: amy\nTicket: OPS-290\nVia: hsb0 mailbox ${message.id}\n\n${message.body}\n`);
    writeFileSync(ctx.stream, source === "push" ? frame(message) : "");
    const args = ["--import", replayLoader(ctx, { raceReceipts: true })];
    const results = await Promise.all([watchOps(t, ctx, { args }), watchOps(t, ctx, { args })]);
    const announcements = results.flatMap(({ output }) => output.split("\n")).filter((line) => line.startsWith("MBX NEW for ops:"));
    assert.equal(announcements.length, 1, JSON.stringify(results));
    for (const { errors } of results) assert.doesNotMatch(errors, /event delivery failed|local inbox scan failed/);
    assert.equal(readdirSync(path.join(ctx.root, "receipt-barrier")).length, 2);
    const receipt = path.join(ctx.env.MBX_ROOT, "watch-ops", id("a"));
    assert.equal(readFileSync(receipt, "utf8"), "seen\n");
    assert.equal(statSync(receipt).mode & 0o777, 0o600);
  });
}

test("OPS sets aside an invalid saved cursor and starts replay without it", async (t) => {
  const ctx = fixture();
  const state = path.join(ctx.env.MBX_ROOT, "watch-ops");
  mkdirSync(state, { recursive: true });
  const invalid = "../../escape\n";
  writeFileSync(path.join(state, "cursor"), invalid, { mode: 0o600 });
  writeFileSync(ctx.stream, frame({ ...row(), from: "amy", to: "ops" }));
  const result = await watchOps(t, ctx, { stopOnError: false, onOutput(output, child) {
    if (output.includes(`MBX NEW for ops: ${id("a")}`)) child.kill("SIGTERM");
  } });
  assert.match(result.errors, /invalid saved cursor/);
  assert.ok(result.output.includes(`MBX NEW for ops: ${id("a")}`), result.errors);
  assert.equal(readFileSync(path.join(state, "cursor.invalid"), "utf8"), invalid);
  assert.equal(readFileSync(path.join(state, "cursor"), "utf8"), `${id("a")}\n`);
  assert.doesNotMatch(readFileSync(ctx.argumentsPath, "utf8"), /Last-Event-ID/);
});

test("OPS exits cleanly with status 2 when an invalid cursor cannot be renamed", () => {
  const ctx = fixture();
  const state = path.join(ctx.env.MBX_ROOT, "watch-ops");
  mkdirSync(path.join(state, "cursor.invalid"), { recursive: true });
  writeFileSync(path.join(state, "cursor.invalid", "keep"), "existing data");
  const invalid = "../../escape\n";
  writeFileSync(path.join(state, "cursor"), invalid, { mode: 0o600 });
  const result = spawnSync(process.execPath, [path.join(clients, "mbx-watch.mjs"), "http://fixture.invalid"],
    { env: ctx.env, encoding: "utf8", timeout: 5000 });
  assert.equal(result.status, 2, result.stderr);
  assert.equal(result.stderr, "mbx: cannot set aside invalid saved cursor\n");
  assert.equal(result.stdout, "");
  assert.equal(readFileSync(path.join(state, "cursor"), "utf8"), invalid);
  assert.equal(readFileSync(path.join(state, "cursor.invalid", "keep"), "utf8"), "existing data");
  assert.equal(existsSync(ctx.argumentsPath), false);
});

test("Amy decoder preserves a work-directory containing literal backslashes", () => {
  const ctx = fixture();
  ctx.env.AMY_MAILBOX_DIR = path.join(ctx.root, "literal\\npath");
  writeFileSync(ctx.stream, frame(row()));
  const result = amy(ctx);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(readFileSync(path.join(ctx.env.AMY_MAILBOX_DIR, "inbox", `${id("a")}.json`))), row());
});

test("Amy hook timeout retains receipts and cursor for retry; zero disables wrapper", () => {
  const ctx = fixture();
  const hook = path.join(ctx.bin, "slow-hook");
  writeFileSync(hook, '#!/bin/sh\nprintf started > "$HOOK_STARTED"\nexec sleep 10\n', { mode: 0o700 });
  writeFileSync(ctx.stream, frame(row()));
  const started = path.join(ctx.root, "hook-started");
  const result = amy(ctx, { AMY_MAILBOX_HOOK: hook, AMY_MAILBOX_HOOK_TIMEOUT: "1", HOOK_STARTED: started });
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /hook failed/);
  assert.equal(existsSync(started), true, result.stderr);
  assert.equal(existsSync(path.join(ctx.env.AMY_MAILBOX_DIR, "cursor")), false);
  assert.deepEqual(readdirSync(path.join(ctx.env.AMY_MAILBOX_DIR, "processed")), []);
  writeFileSync(hook, "#!/bin/sh\ncat >/dev/null\n", { mode: 0o700 });
  assert.equal(amy(ctx, { AMY_MAILBOX_HOOK: hook, AMY_MAILBOX_HOOK_TIMEOUT: "0" }).status, 0);
  assert.equal(amy(ctx, { AMY_MAILBOX_HOOK_TIMEOUT: "bad" }).status, 2);
});

test("Amy prunes only old receipt IDs and keeps recent receipts and inbox data", () => {
  const ctx = fixture();
  const state = ctx.env.AMY_MAILBOX_DIR;
  mkdirSync(path.join(state, "processed"), { recursive: true });
  mkdirSync(path.join(state, "inbox"));
  const old = new Date(Date.now() - 31 * 86400000);
  for (const file of [path.join(state, "processed", id("b")), path.join(state, "processed", "unrelated"), path.join(state, "inbox", `${id("b")}.json`)]) {
    writeFileSync(file, "keep inbox/unrelated only"); utimesSync(file, old, old);
  }
  writeFileSync(path.join(state, "processed", id("c")), "recent");
  writeFileSync(ctx.stream, frame(row()));
  assert.equal(amy(ctx).status, 0);
  assert.equal(existsSync(path.join(state, "processed", id("b"))), false);
  assert.equal(existsSync(path.join(state, "processed", id("c"))), true);
  assert.equal(existsSync(path.join(state, "processed", "unrelated")), true);
  assert.equal(existsSync(path.join(state, "inbox", `${id("b")}.json`)), true);
});

test("Amy systemd service accepts clean signal exits", () => {
  assert.match(readFileSync(path.join(clients, "amy-mailbox.service"), "utf8"), /^SuccessExitStatus=130 143$/m);
});

test("mbx list strips CRLF header carriage returns while keeping the file exact", () => {
  const ctx = fixture();
  const inbox = path.join(ctx.env.MBX_ROOT, "to-codex");
  mkdirSync(inbox, { recursive: true });
  const bytes = Buffer.from("From: ops\r\nTicket: OPS-290\r\n\r\nhello\r\n");
  const file = path.join(inbox, "crlf.txt");
  writeFileSync(file, bytes);
  const result = spawnSync("bash", [path.join(clients, "mbx"), "list", "codex"], { env: ctx.env, encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /from=ops ticket=OPS-290 \|/);
  assert.deepEqual(readFileSync(file), bytes);
});

test("OPS prunes only receipts older than 30 days", async (t) => {
  const ctx = fixture();
  const state = path.join(ctx.env.MBX_ROOT, "watch-ops");
  mkdirSync(state, { recursive: true });
  const old = new Date(Date.now() - 31 * 86400000);
  for (const name of [id("b"), "unrelated"]) { const file = path.join(state, name); writeFileSync(file, "old"); utimesSync(file, old, old); }
  writeFileSync(path.join(state, id("c")), "recent");
  writeFileSync(ctx.stream, frame({ ...row(), from: "amy", to: "ops" }));
  ctx.env.MAILBOX_CURL_EXIT = "7";
  const result = await watchOps(t, ctx);
  assert.ok(result.output.includes(`MBX NEW for ops: ${id("a")}`));
  assert.equal(existsSync(path.join(state, id("b"))), false);
  assert.equal(existsSync(path.join(state, id("c"))), true);
  assert.equal(existsSync(path.join(state, "unrelated")), true);
});

test("mbx list pulled files do not repeat messages already announced by OPS push", async (t) => {
  const ctx = fixture();
  const message = { ...row(), from: "amy", to: "ops", body: "already pushed" };
  writeFileSync(ctx.stream, frame(message));
  let listed = false;
  const result = await watchOps(t, ctx, { stopOnError: false, onOutput(output, child) {
    if (!listed && output.includes("already pushed")) {
      listed = true;
      writeFileSync(ctx.stream, JSON.stringify({ messages: [message] }));
      const list = spawnSync("bash", [path.join(clients, "mbx"), "list", "ops"], { env: ctx.env, encoding: "utf8" });
      assert.equal(list.status, 0, list.stderr);
      assert.ok(list.stdout.includes("already pushed"));
      setTimeout(() => child.kill("SIGTERM"), 250);
    }
  } });
  assert.equal(listed, true);
  assert.equal(result.output.split("\n").filter((line) => line.includes("already pushed")).length, 1);
  assert.equal(readdirSync(path.join(ctx.env.MBX_ROOT, "to-ops")).length, 1);
});

test("OPS extracts a large replay chunk before applying the incomplete-frame bound", async (t) => {
  const ctx = fixture();
  const messages = Array.from({ length: 16 }, (_, i) => ({ ...row(i.toString(16), "x".repeat(12000)), from: "amy", to: "ops" }));
  writeFileSync(ctx.stream, messages.map(frame).join(""));
  const result = await watchOps(t, ctx, { args: ["--import", replayLoader(ctx)] });
  assert.equal(result.output.split("\n").filter((line) => line.startsWith("MBX NEW for ops:")).length, 16, result.errors);
  assert.equal(readdirSync(path.join(ctx.env.MBX_ROOT, "watch-ops")).filter((name) => /^[0-9]{13}-[a-f0-9]{32}$/.test(name)).length, 16);
});

for (const complete of [false, true]) {
  test(`OPS still rejects an oversized ${complete ? "complete" : "incomplete"} frame without advancing cursor`, async (t) => {
    const ctx = fixture();
    const message = { ...row("a", "x".repeat(140000)), from: "amy", to: "ops" };
    const event = frame(message);
    writeFileSync(ctx.stream, complete ? event : event.slice(0, -2));
    const result = await watchOps(t, ctx, { args: ["--import", replayLoader(ctx)] });
    assert.equal(result.output.includes("MBX NEW for ops:"), false);
    assert.match(result.errors, /falling back to local poll/);
    assert.equal(existsSync(path.join(ctx.env.MBX_ROOT, "watch-ops", "cursor")), false);
  });
}

test("Amy writes private inbox, survives restart, and deduplicates unread replay without ack", () => {
  const ctx = fixture();
  writeFileSync(ctx.stream, frame(row()));
  let result = amy(ctx);
  assert.equal(result.status, 0, result.stderr);
  const state = ctx.env.AMY_MAILBOX_DIR;
  const saved = path.join(state, "inbox", `${id("a")}.json`);
  assert.deepEqual(readFileSync(saved), Buffer.from(`${JSON.stringify(row())}\n`));
  assert.deepEqual(JSON.parse(readFileSync(saved)), row());
  assert.equal(statSync(state).mode & 0o777, 0o700);
  for (const file of [saved, path.join(state, "cursor"), path.join(state, "processed", id("a"))]) assert.equal(statSync(file).mode & 0o777, 0o600);
  writeFileSync(ctx.stream, frame(row()) + frame(row("b", "new after restart")));
  result = amy(ctx);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(readdirSync(path.join(state, "inbox")).sort(), [`${id("a")}.json`, `${id("b")}.json`]);
  assert.equal(readFileSync(path.join(state, "cursor"), "utf8"), `${id("b")}\n`);
  const args = readFileSync(ctx.argumentsPath, "utf8");
  assert.ok(args.includes(`Last-Event-ID: ${id("a")}`));
  assert.equal(args.includes("/ack"), false);
  assert.equal(args.includes("/v1/messages"), false);
  writeFileSync(ctx.stream, frame(row("b")));
  assert.equal(amy(ctx).status, 1);
  assert.equal(readdirSync(state).some((file) => file.startsWith(".watch.")), false);
});

test("Amy inbox preserves UTF-8 JSON bytes and decoded multiline body exactly", () => {
  const ctx = fixture();
  const body = "Grüße aus Österreich\nHello Amy!\t😀\n\n";
  // Include whitespace and escaped Unicode to catch parse/reserialise changes.
  const json = JSON.stringify(row("a", body)).replace('{"id"', '{ "id"').replace("Grüße", "Gr\\u00fcße");
  writeFileSync(ctx.stream, `id: ${id("a")}\nevent: message\ndata: ${json}\n\n`);
  const result = amy(ctx);
  assert.equal(result.status, 0, result.stderr);
  const saved = readFileSync(path.join(ctx.env.AMY_MAILBOX_DIR, "inbox", `${id("a")}.json`));
  assert.deepEqual(saved, Buffer.from(`${json}\n`));
  assert.equal(JSON.parse(saved).body, body);
});

test("Amy hook receives exact decoded bytes and arguments; message text never executes", () => {
  const ctx = fixture();
  const body = `quotes " slash \\ newline\n\tCR\r\b\f control \u0001 DEL\u007f café 漢字 😀\n$(touch ${path.join(ctx.root, "executed")})\n\n`;
  const hook = path.join(ctx.bin, "hook");
  writeFileSync(hook, '#!/bin/sh\nprintf "%s\\n" "$1" "$2" > "$HOOK_ARGS"\ncat > "$HOOK_BODY"\n', { mode: 0o700 });
  const hookArgs = path.join(ctx.root, "hook-args");
  const hookBody = path.join(ctx.root, "hook-body");
  writeFileSync(ctx.stream, frame(row("a", body)));
  const result = amy(ctx, { AMY_MAILBOX_HOOK: hook, HOOK_ARGS: hookArgs, HOOK_BODY: hookBody });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(hookBody, "utf8"), body);
  assert.equal(readFileSync(hookArgs, "utf8"), `${id("a")}\nops\n`);
  assert.equal(existsSync(path.join(ctx.root, "executed")), false);
  assert.deepEqual(readdirSync(path.join(ctx.env.AMY_MAILBOX_DIR, "inbox")), []);
});

test("failed Amy hook and invalid/mismatched events retain cursor and retry", () => {
  const ctx = fixture();
  writeFileSync(ctx.stream, frame(row()));
  const failedHook = path.join(ctx.bin, "fail-hook");
  writeFileSync(failedHook, "#!/bin/sh\nexit 7\n", { mode: 0o700 });
  assert.equal(amy(ctx, { AMY_MAILBOX_HOOK: failedHook }).status, 1);
  assert.equal(existsSync(path.join(ctx.env.AMY_MAILBOX_DIR, "cursor")), false);
  assert.deepEqual(readdirSync(path.join(ctx.env.AMY_MAILBOX_DIR, "processed")), []);
  assert.equal(amy(ctx).status, 0);
  for (const message of [{ ...row("b"), to: "ops" }, { ...row("b"), from: "amy" }, { ...row("b"), id: "../../escape" }]) {
    writeFileSync(ctx.stream, frame(message));
    assert.equal(amy(ctx).status, 1);
    assert.equal(readFileSync(path.join(ctx.env.AMY_MAILBOX_DIR, "cursor"), "utf8"), `${id("a")}\n`);
  }
  writeFileSync(ctx.stream, frame(row("b")).replace(`id: ${id("b")}`, `id: ${id("c")}`));
  assert.equal(amy(ctx).status, 1);
});

test("POSIX awk decoder handles unicode escapes, surrogate pairs and rejects ambiguous JSON", () => {
  const ctx = fixture();
  const messagePath = path.join(ctx.root, "message.json");
  const run = (json) => {
    writeFileSync(messagePath, json);
    return spawnSync("awk", ["-f", path.join(clients, "message.awk"), messagePath], { env: { ...process.env, LC_ALL: "C", AMY_MAILBOX_WORK: ctx.root }, encoding: "utf8" });
  };
  const json = JSON.stringify(row("a", "replace"));
  assert.equal(run(json.replace('"replace"', '"\\u00e9\\ud83d\\ude00\\ud800\\u0001"')).status, 0);
  assert.equal(readFileSync(path.join(ctx.root, "body"), "utf8"), "é😀�\u0001");
  for (const bad of [json + "trailing", json.replace(/}$/, ',"body":"duplicate"}'), json.replace('"replace"', '"\\u0000"'), json.replace('"replace"', '"\\q"'), json.replace('"replace"', "42")]) assert.equal(run(bad).status, 1);
});

test("existing local mbx send/list/read/keep behavior remains available", () => {
  const ctx = fixture();
  ctx.env.MBX_ROOT = path.join(ctx.root, "custom-mailbox");
  const run = (...args) => spawnSync("bash", [path.join(clients, "mbx"), ...args], { env: ctx.env, encoding: "utf8" });
  assert.equal(run("send", "codex", "-f", "ops", "-t", "OPS-290", "-m", "local data").status, 0);
  assert.match(run("list", "codex").stdout, /from=ops ticket=OPS-290 \| local data/);
  assert.match(run("read", "codex", "--keep").stdout, /read 1 message\(s\) for codex \(kept\)/);
  assert.match(run("read", "codex").stdout, /archived to done/);
  assert.match(run("list", "codex").stdout, /unread for codex: 0/);
  assert.equal(readdirSync(path.join(ctx.env.MBX_ROOT, "done", "codex")).length, 1);
});

test("mbx read/list/wait sanitise terminal data without changing kept or archived bytes", () => {
  const ctx = fixture();
  const inbox = path.join(ctx.env.MBX_ROOT, "to-codex");
  mkdirSync(inbox, { recursive: true });
  const controls = Array.from({ length: 32 }, (_, i) => i).filter((i) => ![9, 10].includes(i))
    .concat(127, Array.from({ length: 32 }, (_, i) => 128 + i),
      Array.from({ length: 5 }, (_, i) => 0x202a + i), Array.from({ length: 4 }, (_, i) => 0x2066 + i),
      [0x061c, 0x200b, 0x200e, 0x200f, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0xfeff, 0xe0000, 0xe007f]);
  const body = `${String.fromCodePoint(...controls)}\nGrüße\tHello 😀\n\n`;
  const bytes = Buffer.concat([Buffer.from(`From: ops\nTicket: OPS-290\n\n${body}`), Buffer.from([0xff])]);
  const file = path.join(inbox, "unsafe.txt");
  writeFileSync(file, bytes);
  const run = (...args) => spawnSync("bash", [path.join(clients, "mbx"), ...args], { env: ctx.env, encoding: "utf8", timeout: 5000 });
  const read = run("read", "codex", "--keep");
  assert.equal(read.status, 0, read.stderr);
  assert.ok(read.stdout.includes(`${"�".repeat(controls.length)}\nGrüße\tHello 😀\n\n�`));
  assert.deepEqual(readFileSync(file), bytes);
  const list = run("list", "codex");
  assert.equal(list.status, 0, list.stderr);
  assert.ok(list.stdout.includes(`${"�".repeat(controls.length)} Grüße Hello 😀`), JSON.stringify(list.stdout));
  assert.deepEqual(readFileSync(file), bytes);
  const waited = run("wait", "codex", "0");
  assert.equal(waited.status, 0, waited.stderr);
  for (const result of [read, list, waited]) assert.doesNotMatch(result.stdout, /[\x00-\x08\x0b-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/u);
  assert.deepEqual(readFileSync(path.join(ctx.env.MBX_ROOT, "done", "codex", "unsafe.txt")), bytes);
});

for (const recipient of ["codex", "ops"]) {
  test(`mbx local ${recipient} watch visibly replaces terminal and bidi controls`, async (t) => {
    const ctx = fixture();
    ctx.env.MBX_ROOT = path.join(ctx.root, "custom-mailbox");
    const inbox = path.join(ctx.env.MBX_ROOT, `to-${recipient}`);
    mkdirSync(inbox, { recursive: true });
    const bytes = Buffer.from("From: ops\nTicket: OPS-290\n\nHi\x1b[31m\r\x7f\u0085\u202e\u2066 Grüße 😀\n");
    const file = path.join(inbox, "unsafe.txt");
    writeFileSync(file, bytes);
    const child = spawn("bash", [path.join(clients, "mbx"), "watch", recipient, "0.05"], { env: ctx.env, stdio: ["ignore", "pipe", "pipe"] });
    t.after(() => child.kill("SIGTERM"));
    let output = ""; let errors = "";
    const exit = new Promise((resolve) => child.once("close", resolve));
    const timeout = setTimeout(() => child.kill("SIGTERM"), 5000);
    child.stdout.on("data", (data) => { output += data; if (output.includes("MBX NEW")) child.kill("SIGTERM"); });
    child.stderr.on("data", (data) => { errors += data; });
    await exit;
    clearTimeout(timeout);
    assert.ok(output.includes("Hi�[31m����� Grüße 😀"), output);
    assert.doesNotMatch(output, /[\x00-\x08\x0b-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/u);
    assert.deepEqual(readFileSync(file), bytes);
    assert.equal(existsSync(ctx.argumentsPath), false);
    assert.equal(existsSync(path.join(ctx.root, ".local", "share", "agent-mailbox")), false);
    if (recipient === "ops") assert.match(errors, /mbx: non-default MBX_ROOT; falling back to local poll/);
    else assert.equal(errors, "");
  });
}

test("Amy continuous watcher reconnects with its saved cursor and skips replayed hook delivery", async (t) => {
  const ctx = fixture();
  writeFileSync(ctx.stream, frame(row()));
  const child = spawn("sh", [path.join(clients, "amy-watch.sh")], { env: ctx.env, stdio: ["ignore", "pipe", "pipe"] });
  t.after(() => child.kill("SIGTERM"));
  let errors = "";
  child.stderr.on("data", (data) => { errors += data; });
  const exit = new Promise((resolve) => child.once("close", resolve));
  const timeout = setTimeout(() => child.kill("SIGTERM"), 5000);
  const check = setInterval(() => {
    if (existsSync(ctx.argumentsPath) && readFileSync(ctx.argumentsPath, "utf8").includes(`Last-Event-ID: ${id("a")}`)) child.kill("SIGTERM");
  }, 25);
  await exit;
  clearTimeout(timeout); clearInterval(check);
  assert.equal(errors, "");
  assert.ok(readFileSync(ctx.argumentsPath, "utf8").includes(`Last-Event-ID: ${id("a")}`));
  assert.deepEqual(readdirSync(path.join(ctx.env.AMY_MAILBOX_DIR, "processed")), [id("a")]);
  assert.match(readFileSync(ctx.argumentsPath, "utf8"), /--max-time\n3660\n/);
});

test("OPS push prints once, keeps local watch and reports unreachable fallback", async (t) => {
  const ctx = fixture();
  const message = { ...row("a", `new\n\x1b\r\x7f\u0085\u202e\u2066\u061c\u200b\u200e\u200f\u2060\u2061\u2062\u2063\u2064\ufeff\u{e0000}\u{e007f} 👩‍💻${"é".repeat(150)}`), from: "amy", to: "ops" };
  writeFileSync(ctx.stream, frame(message) + frame(message));
  const inbox = path.join(ctx.env.MBX_ROOT, "to-ops");
  mkdirSync(inbox, { recursive: true });
  writeFileSync(path.join(inbox, "local.txt"), "From: codex\nTicket: OPS-290\n\nlocal hello\u202e\u2069\n");
  const defaultEnv = { ...ctx.env, MAILBOX_CURL_EXIT: "7" };
  delete defaultEnv.MBX_ROOT;
  const processChild = spawn("bash", [path.join(clients, "mbx"), "watch", "ops", "0.05"], { env: defaultEnv, stdio: ["ignore", "pipe", "pipe"] });
  t.after(() => processChild.kill("SIGTERM"));
  let output = ""; let errors = "";
  const exit = new Promise((resolve) => processChild.once("close", resolve));
  const timer = setTimeout(() => processChild.kill("SIGTERM"), 5000);
  processChild.stdout.on("data", (data) => { output += data; });
  processChild.stderr.on("data", (data) => {
    errors += data;
    if (errors.includes("falling back to local poll")) processChild.kill("SIGTERM");
  });
  await exit;
  clearTimeout(timer);
  assert.ok(errors.includes("falling back to local poll"), errors);
  assert.ok(output.includes("mbx watch armed on to-ops (every 0.05s)"));
  const lines = output.trim().split("\n");
  assert.equal(lines.filter((line) => line.startsWith(`MBX NEW for ops: ${id("a")}`)).length, 1);
  assert.ok(lines.some((line) => line.includes("from=codex ticket=OPS-290 | local hello")));
  const pushed = lines.find((line) => line.startsWith(`MBX NEW for ops: ${id("a")}`));
  assert.equal(Array.from(pushed.split(" | ")[2]).length, 140);
  assert.equal(pushed.includes("\x1b"), false);
  assert.ok(pushed.includes("new ������"));
  assert.ok(output.includes("local hello��"));
  assert.doesNotMatch(output, /[\x00-\x08\x0b-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/u);
  assert.equal(readFileSync(path.join(ctx.env.MBX_ROOT, "watch-ops", "cursor"), "utf8"), `${id("a")}\n`);
  assert.equal(existsSync(path.join(inbox, "local.txt")), true);
  writeFileSync(ctx.stream, frame(message) + frame({ ...message, id: id("b"), body: "after restart" }));
  const restarted = spawn("bash", [path.join(clients, "mbx"), "watch", "ops", "0.05"], { env: { ...ctx.env, MAILBOX_CURL_EXIT: "7" }, stdio: ["ignore", "pipe", "pipe"] });
  t.after(() => restarted.kill("SIGTERM"));
  let replayOutput = "";
  restarted.stdout.on("data", (data) => { replayOutput += data; });
  restarted.stderr.on("data", (data) => { if (String(data).includes("falling back")) restarted.kill("SIGTERM"); });
  const restartTimeout = setTimeout(() => restarted.kill("SIGTERM"), 5000);
  await new Promise((resolve) => restarted.once("close", resolve));
  clearTimeout(restartTimeout);
  assert.equal(replayOutput.includes(id("a")), false);
  assert.ok(replayOutput.includes(`${id("b")} | from=amy ticket=OPS-290 | after restart`));
  assert.ok(readFileSync(ctx.argumentsPath, "utf8").includes(`Last-Event-ID: ${id("a")}`));
  assert.match(readFileSync(ctx.argumentsPath, "utf8"), /--max-time\n3660\n/);
});
