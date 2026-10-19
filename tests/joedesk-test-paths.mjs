// Shared source boundary for the actual-pinned-source T101/T102 gates.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

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
  const root = fs.realpathSync(value);
  assert.notEqual(root, path.parse(root).root, "source directory required");
  const fd = fs.openSync(
    root,
    fs.constants.O_RDONLY | fs.constants.O_DIRECTORY,
  );
  try {
    assert.ok(fs.fstatSync(fd).isDirectory(), "source directory required");
  } finally {
    fs.closeSync(fd);
  }
  return root;
}
export function sourcePath(root, name) {
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
  const allowed = path.join(root, "sources.json");
  assert.ok(allowed.startsWith(temp + path.sep));
  const fd = fs.openSync(
    allowed,
    fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW,
  );
  try {
    assert.ok(fs.fstatSync(fd).isFile(), "regular source map required");
    return JSON.parse(fs.readFileSync(fd));
  } finally {
    fs.closeSync(fd);
  }
}
