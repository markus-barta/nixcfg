// Shared source boundary for the actual-pinned-source T101/T102 gates.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { labParents } from "../scripts/joedesk-lab-paths.mjs";

// CI's fetchTree archives, workstation sibling checkouts, and per-run labs.
const sourceParents = [
  "/nix/store",
  path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../.."),
  ...labParents(),
];

const sourceNames = new Map([
  ["fixtures/valid.json", "fixtures/valid.json"],
  ["scripts/prepare-data.mjs", "scripts/prepare-data.mjs"],
  ["server.mjs", "server.mjs"],
  ["Dockerfile", "Dockerfile"],
  ["package.json", "package.json"],
  ["public/joe/joe-version.js", "public/joe/joe-version.js"],
  ["public/joe/joe.js", "public/joe/joe.js"],
  ["public/joe/host.js", "public/joe/host.js"],
  ["public/joe/app.js", "public/joe/app.js"],
]);
export function sourceRoot(value) {
  const root = path.resolve(fs.realpathSync(value));
  const parent = sourceParents.find((p) => root.startsWith(p + path.sep));
  assert.ok(parent, "source outside fixed parents");
  if (!root.startsWith(parent + path.sep))
    throw new Error("source outside fixed parent");
  const relative = path.relative(parent, root);
  assert.ok(
    relative.split(path.sep).every((p) => p && p !== "." && p !== ".."),
  );
  const allowed = path.join(parent, relative);
  const fd = fs.openSync(
    allowed,
    fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW,
    0o600,
  );
  try {
    assert.ok(fs.fstatSync(fd).isDirectory(), "source directory required");
  } finally {
    fs.closeSync(fd);
  }
  return allowed;
}
export function sourcePath(root, name) {
  root = sourceRoot(root);
  const relative = sourceNames.get(name);
  assert.ok(relative, "fixed source filename required");
  const file = fs.realpathSync(path.join(root, relative));
  assert.ok(file.startsWith(root + path.sep), "source file outside root");
  return file;
}
export function readSource(root, name, encoding) {
  const fd = fs.openSync(
    sourcePath(root, name),
    fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW,
    0o600,
  );
  try {
    assert.ok(fs.fstatSync(fd).isFile(), "regular source file required");
    return fs.readFileSync(fd, encoding);
  } finally {
    fs.closeSync(fd);
  }
}
export function readSourceMap(value) {
  const temp = fs.realpathSync(os.tmpdir());
  const file = fs.realpathSync(value);
  const root = path.dirname(file);
  assert.equal(path.dirname(root), temp, "CI temporary map directory required");
  assert.match(path.basename(root), /^ops354-ci-[A-Za-z0-9_-]+$/);
  assert.equal(path.basename(file), "sources.json");
  const allowed = path.join(temp, path.basename(root), "sources.json");
  assert.ok(allowed.startsWith(temp + path.sep));
  const fd = fs.openSync(
    allowed,
    fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW,
    0o600,
  );
  try {
    assert.ok(fs.fstatSync(fd).isFile(), "regular source map required");
    return JSON.parse(fs.readFileSync(fd));
  } finally {
    fs.closeSync(fd);
  }
}
