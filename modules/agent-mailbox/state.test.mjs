import assert from "node:assert/strict";
import fs from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { HOUR_MS, openMailbox, POST_LIMIT, RETENTION_MS, UNREAD_LIMIT } from "./state.mjs";

const identities = ["amy", "ops"];
const newRoot = () => fs.mkdtempSync(path.join(tmpdir(), "ops272-state-"));
const message = { to: "ops", ticket: "OPS-272", body: "message text" };

test("messages and rate state publish via fsynced temporary files and rename with private modes", (t) => {
  const root = newRoot();
  const mailbox = openMailbox(root, identities);
  const realRename = fs.renameSync;
  const publications = [];
  t.mock.method(fs, "renameSync", (source, target) => {
    assert.match(source, /\.[a-f0-9]{32}\.new$/);
    const candidate = JSON.parse(fs.readFileSync(source, "utf8"));
    assert.equal(fs.statSync(source).mode & 0o777, 0o600);
    assert.equal(fs.existsSync(target), false);
    publications.push(candidate);
    realRename(source, target);
  });
  syncBuiltinESMExports();
  try {
    mailbox.admitPost("amy");
    const sent = mailbox.send("amy", message);
    assert.match(sent.id, /^[0-9]{13}-[a-f0-9]{32}$/);
    assert.equal(publications.length, 2);
    const file = path.join(root, "inbox", "ops", `${sent.id}.json`);
    assert.deepEqual(JSON.parse(fs.readFileSync(file, "utf8")), { ...sent, from: "amy", ...message });
    for (const candidate of [file, path.join(root, "rate-limits.json")]) assert.equal(fs.statSync(candidate).mode & 0o777, 0o600);
    for (const directory of [root, path.join(root, "inbox"), path.join(root, "inbox", "ops"), path.join(root, "archive", "amy")]) assert.equal(fs.statSync(directory).mode & 0o777, 0o700);
    assert.deepEqual(fs.readdirSync(path.join(root, "inbox", "ops")), [`${sent.id}.json`]);
  } finally { t.mock.restoreAll(); syncBuiltinESMExports(); }
});

test("failed atomic writes publish no partial message and remove their own temporary file", (t) => {
  const root = newRoot();
  const mailbox = openMailbox(root, identities);
  t.mock.method(fs, "writeFileSync", () => { throw new Error("simulated write failure"); });
  syncBuiltinESMExports();
  try {
    assert.throws(() => mailbox.send("amy", message), /simulated write failure/);
    assert.deepEqual(fs.readdirSync(path.join(root, "inbox", "ops")), []);
  } finally { t.mock.restoreAll(); syncBuiltinESMExports(); }
});

test("unread caps survive reopening and acknowledgement releases recipient capacity", () => {
  const root = newRoot();
  let clock = Date.now();
  const mailbox = openMailbox(root, identities, () => clock++);
  const ids = Array.from({ length: UNREAD_LIMIT }, () => mailbox.send("amy", message).id);
  assert.equal(mailbox.unread("ops"), 500);
  assert.equal(mailbox.messages("ops").length, 50);
  assert.deepEqual(mailbox.messages("ops").map((row) => row.id), ids.slice(0, 50));
  assert.throws(() => mailbox.send("amy", message), { statusCode: 429 });
  const reopened = openMailbox(root, identities, () => clock++);
  assert.equal(reopened.unread("ops"), 500);
  assert.throws(() => reopened.send("amy", message), { statusCode: 429 });
  assert.throws(() => reopened.ack("amy", ids[0]), { statusCode: 403 });
  reopened.ack("ops", ids[0]);
  assert.equal(reopened.unread("ops"), 499);
  assert.equal(fs.statSync(path.join(root, "archive", "ops", `${ids[0]}.json`)).mode & 0o777, 0o600);
  reopened.send("amy", message);
  assert.equal(reopened.unread("ops"), 500);
  assert.throws(() => reopened.ack("ops", ids[0]), { statusCode: 404 });
});

test("rolling POST caps are per identity, persistent, and expire exactly one hour later", () => {
  const root = newRoot();
  let clock = Date.now();
  const mailbox = openMailbox(root, identities, () => clock);
  for (let index = 0; index < POST_LIMIT; index++) mailbox.admitPost("amy");
  assert.throws(() => mailbox.admitPost("amy"), { statusCode: 429 });
  mailbox.admitPost("ops");
  const restarted = openMailbox(root, identities, () => clock);
  assert.throws(() => restarted.admitPost("amy"), { statusCode: 429 });
  clock += HOUR_MS - 1;
  assert.throws(() => restarted.admitPost("amy"), { statusCode: 429 });
  clock += 1;
  restarted.admitPost("amy");
  assert.equal(JSON.parse(fs.readFileSync(path.join(root, "rate-limits.json"), "utf8")).amy.length, 1);
});

test("a failed rate-state fsync does not reopen a sender admission slot", (t) => {
  const root = newRoot();
  const mailbox = openMailbox(root, identities);
  for (let index = 0; index < POST_LIMIT - 1; index++) mailbox.admitPost("amy");
  const realFsync = fs.fsyncSync;
  t.mock.method(fs, "fsyncSync", (fd) => {
    if (fs.fstatSync(fd).isDirectory()) throw new Error("simulated directory sync failure");
    realFsync(fd);
  });
  syncBuiltinESMExports();
  try {
    assert.throws(() => mailbox.admitPost("amy"), /simulated directory sync failure/);
    assert.throws(() => mailbox.admitPost("amy"), { statusCode: 429 });
  } finally { t.mock.restoreAll(); syncBuiltinESMExports(); }
  assert.throws(() => openMailbox(root, identities).admitPost("amy"), { statusCode: 429 });
});

test("retention starts at ack, prunes at startup, and never removes unread messages", () => {
  const root = newRoot();
  let clock = Date.now();
  const mailbox = openMailbox(root, identities, () => clock);
  const old = mailbox.send("amy", message);
  const unread = mailbox.send("amy", message);
  clock += RETENTION_MS + 1000;
  mailbox.ack("ops", old.id);
  const archive = path.join(root, "archive", "ops", `${old.id}.json`);
  assert.ok(Math.abs(fs.statSync(archive).mtimeMs - clock) < 1);
  mailbox.prune();
  assert.equal(fs.existsSync(archive), true);
  clock += RETENTION_MS - 1000;
  openMailbox(root, identities, () => clock);
  assert.equal(fs.existsSync(archive), true);
  clock += 2000;
  openMailbox(root, identities, () => clock);
  assert.equal(fs.existsSync(archive), false);
  assert.deepEqual(mailbox.messages("ops").map((row) => row.id), [unread.id]);
});

test("paths reject traversal, symlink directories and message files without touching targets", () => {
  const root = newRoot();
  const mailbox = openMailbox(root, identities);
  const victim = path.join(root, "keep.txt");
  fs.writeFileSync(victim, "preserve this");
  for (const id of ["../keep.txt", "../../etc/passwd", "../archive/ops", "/etc/passwd", "x\0.json"]) assert.throws(() => mailbox.ack("ops", id), { statusCode: 404 });
  assert.throws(() => mailbox.messages("../ops"));
  assert.throws(() => mailbox.send("amy", { ...message, to: "../ops" }), { statusCode: 400 });
  const id = `${Date.now()}-${"a".repeat(32)}`;
  fs.symlinkSync(victim, path.join(root, "inbox", "ops", `${id}.json`));
  assert.throws(() => mailbox.messages("ops"), /ELOOP/);
  assert.throws(() => mailbox.ack("ops", id), /ELOOP/);
  const linkedRoot = newRoot();
  fs.symlinkSync(root, path.join(linkedRoot, "inbox"));
  assert.throws(() => openMailbox(linkedRoot, identities), /real directory/);
  const linkedRate = newRoot();
  fs.symlinkSync(victim, path.join(linkedRate, "rate-limits.json"));
  assert.throws(() => openMailbox(linkedRate, identities), /ELOOP/);
  assert.equal(fs.readFileSync(victim, "utf8"), "preserve this");
});
