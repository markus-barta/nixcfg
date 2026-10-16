#!/usr/bin/env node
// OPS-354: the single stopped-writer swap used by rollback and the lab.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

export function requireSafeHost({ labRoot, hostname = os.hostname(), store }) {
  const short = hostname.toLowerCase().split(".")[0];
  if (labRoot) {
    if (/^(csb|hsb|agm)/.test(short)) throw new Error("fleet_is_not_a_lab");
    const root = fs.realpathSync(labRoot);
    if (
      !path.resolve(store).startsWith(root + path.sep) ||
      root === "/" ||
      path.resolve(store) === "/var/lib/joe-board"
    )
      throw new Error("lab_store_outside_root");
  } else if (
    short !== "csb0" ||
    path.resolve(store) !== "/var/lib/joe-board" ||
    process.getuid() !== 0
  ) {
    throw new Error("production_swap_requires_root_on_csb0");
  }
}

function directory(dir) {
  const stat = fs.lstatSync(dir);
  if (
    !stat.isDirectory() ||
    stat.isSymbolicLink() ||
    fs.realpathSync(dir) !== path.resolve(dir)
  )
    throw new Error("real_directory_required");
  return stat;
}
function absent(file) {
  try {
    fs.lstatSync(file);
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }
  throw new Error("destination_exists");
}
function syncDir(dir) {
  const fd = fs.openSync(dir, "r");
  try {
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}
function prepare(source, args) {
  const cli = path.join(source, "scripts/prepare-data.mjs");
  const result = spawnSync(process.execPath, [cli, ...args], {
    encoding: "utf8",
  });
  if (result.status !== 0) throw new Error("data_preparation_failed");
}
export function normalizeStore(dir, uid, gid) {
  directory(dir);
  // Validate the entire flat store before changing any ownership or mode.
  const files = fs.readdirSync(dir).map((name) => path.join(dir, name));
  for (const file of files) {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1)
      throw new Error("store_must_contain_regular_unlinked_files");
  }
  fs.chownSync(dir, uid, gid);
  fs.chmodSync(dir, 0o700);
  for (const file of files) {
    fs.chownSync(file, uid, gid);
    fs.chmodSync(file, 0o600);
  }
  syncDir(dir);
}
export function swapDirectories(
  store,
  staged,
  { uid = 1000, gid = 1000, rename = fs.renameSync } = {},
) {
  const current = directory(store),
    next = directory(staged);
  if (
    path.dirname(store) !== path.dirname(staged) ||
    current.dev !== next.dev ||
    store === staged
  )
    throw new Error("swap_requires_same_filesystem_siblings");
  normalizeStore(staged, uid, gid);
  const retained = store + ".retained-" + randomUUID();
  absent(retained);
  // Persist recovery coordinates before either rename, including when the
  // filesystem later refuses a write. The record contains no payload bytes.
  const receipt = retained + ".receipt.json";
  fs.writeFileSync(
    receipt,
    JSON.stringify({ store, retained, staged, uid, gid }) + "\n",
    { flag: "wx", mode: 0o600 },
  );
  const receiptFd = fs.openSync(receipt, "r");
  try {
    fs.fsyncSync(receiptFd);
  } finally {
    fs.closeSync(receiptFd);
  }
  syncDir(path.dirname(store));
  rename(store, retained);
  try {
    absent(store);
    rename(staged, store);
  } catch (error) {
    try {
      absent(store);
      rename(retained, store);
      syncDir(path.dirname(store));
    } catch {
      throw new Error("swap_recovery_required");
    }
    throw new Error("swap_failed_original_restored", { cause: error });
  }
  syncDir(path.dirname(store));
  return { retained, receipt };
}
export function runSwap(options) {
  const store = path.resolve(options.store);
  requireSafeHost({ ...options, store });
  if (!options.writersStopped) throw new Error("stop_all_writers_first");
  if (!options.labRoot && options.gid !== 1000)
    throw new Error("configured_board_gid_required");
  directory(store);
  if (!options.labRoot) {
    const running = spawnSync(
      "docker",
      [
        "compose",
        "-p",
        "csb0",
        "-f",
        "/etc/compose/csb0/docker-compose.yml",
        "ps",
        "--status",
        "running",
        "-q",
        "joe-board",
      ],
      { encoding: "utf8" },
    );
    if (running.status !== 0 || running.stdout.trim())
      throw new Error("board_must_be_stopped");
  }
  let staged;
  if (options.direction === "rollback") {
    staged = store + ".restore-" + randomUUID();
    absent(staged);
    prepare(options.source, ["verify", "--offline", options.backup]);
    prepare(options.source, [
      "restore",
      "--offline",
      options.backup,
      staged,
      "v1",
    ]);
  } else if (options.direction === "forward") {
    staged = path.resolve(options.staged);
    const stageStat = directory(staged);
    if (
      path.dirname(store) !== path.dirname(staged) ||
      fs.statSync(store).dev !== stageStat.dev ||
      store === staged
    )
      throw new Error("swap_requires_same_filesystem_siblings");
    // Use JoeDesk's own schema/closure checks, retaining this verification
    // backup too. Never copy a backup manifest into the active store.
    const verification = staged + ".verified-" + randomUUID();
    prepare(options.source, [
      "backup",
      "--offline",
      staged,
      verification,
      "v2",
    ]);
    prepare(options.source, ["verify", "--offline", verification]);
  } else throw new Error("direction_required");
  const uid = options.labRoot ? (options.uid ?? 1000) : 1000;
  if (
    !Number.isSafeInteger(uid) ||
    uid < 0 ||
    !Number.isSafeInteger(options.gid) ||
    options.gid < 0
  )
    throw new Error("numeric_ownership_required");
  return swapDirectories(store, staged, { uid, gid: options.gid });
}
function main() {
  const [direction, ...args] = process.argv.slice(2);
  const options = { direction, store: "/var/lib/joe-board", gid: 1000 };
  for (let i = 0; i < args.length; i++) {
    const key = args[i];
    if (key === "--writers-stopped") options.writersStopped = true;
    else if (key === "--lock-held") options.lockHeld = true;
    else {
      const name = {
        "--source": "source",
        "--store": "store",
        "--staged": "staged",
        "--backup": "backup",
        "--gid": "gid",
        "--uid": "uid",
        "--lab-root": "labRoot",
      }[key];
      if (!name || !args[i + 1]) throw new Error("usage");
      options[name] = ["gid", "uid"].includes(name)
        ? Number(args[++i])
        : args[++i];
    }
  }
  requireSafeHost(options);
  if (!options.labRoot && !options.lockHeld) {
    // Hold the normal Compose lock only for the stopped-service data swap;
    // release it BEFORE just switch, whose compose unit acquires it itself.
    const child = spawnSync(
      "flock",
      [
        "--nonblock",
        "/run/lock/compose-csb0.lock",
        process.execPath,
        process.argv[1],
        ...process.argv.slice(2),
        "--lock-held",
      ],
      { stdio: "inherit" },
    );
    if (child.status !== 0) process.exitCode = 1;
    return;
  }
  runSwap(options);
  console.log(
    JSON.stringify({
      ok: true,
      direction,
      original: "retained",
      ownership: "normalized",
      modes: "0700/0600",
    }),
  );
}
if (
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
) {
  try {
    main();
  } catch (error) {
    console.error(
      "joedesk_swap_failed: " +
        (error.message.match(/^[a-z0-9_]+$/)
          ? error.message
          : "preflight_or_io_error"),
    );
    process.exitCode = 1;
  }
}
