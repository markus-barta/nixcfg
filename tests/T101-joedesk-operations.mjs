import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawnSync } from "node:child_process";
import {
  requireSafeHost,
  swapDirectories,
  runSwap,
  normalizeStore,
} from "../scripts/joedesk-data-swap.mjs";

const source = process.env.JOEDESK_TEST_SOURCE;
const uid = process.getuid(),
  gid = process.getgid();
function root() {
  const dir = fs.mkdtempSync(
    path.join(fs.realpathSync(os.tmpdir()), "ops354-swap-"),
  );
  fs.chmodSync(dir, 0o700);
  return dir;
}
function put(dir, name, value) {
  fs.writeFileSync(
    path.join(dir, name),
    typeof value === "string" ? value : JSON.stringify(value),
    { mode: 0o600 },
  );
}
function seed(dir) {
  fs.mkdirSync(dir, { mode: 0o700 });
  put(
    dir,
    "data.json",
    '{"schema":"inspr.joe.household.v1", "sentinel":"synthetic legacy bytes"}\n',
  );
  put(dir, "history.json", {
    schema: "inspr.joe.household.history.v1",
    points: [],
  });
  if (source)
    put(
      dir,
      "fleet-config.json",
      JSON.parse(fs.readFileSync(path.join(source, "fixtures/valid.json")))[
        "fleet-config"
      ],
    );
  put(dir, "fleet-config-actions.json", {
    schema: "inspr.joe.fleet-config.actions.v1",
    entries: [],
  });
}
function bytes(dir) {
  return Object.fromEntries(
    fs
      .readdirSync(dir)
      .sort()
      .map((n) => [n, fs.readFileSync(path.join(dir, n)).toString("hex")]),
  );
}
function prepare(...args) {
  const result = spawnSync(
    process.execPath,
    [path.join(source, "scripts/prepare-data.mjs"), ...args],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, "actual prepare-data CLI must pass");
}

test("host guards reject every fleet lab prefix and require exact production host/store", () => {
  const dir = root(),
    store = path.join(dir, "joe-board");
  for (const hostname of [
    "csb0",
    "csb9.example.invalid",
    "hsb0",
    "hsb100",
    "agm0",
    "CSB1",
  ])
    assert.throws(
      () => requireSafeHost({ labRoot: dir, hostname, store }),
      /fleet/,
    );
  requireSafeHost({ labRoot: dir, hostname: "workstation", store });
  assert.throws(
    () =>
      requireSafeHost({
        labRoot: dir,
        hostname: "workstation",
        store: "/var/lib/joe-board",
      }),
    /outside/,
  );
  assert.throws(
    () => requireSafeHost({ hostname: "workstation", store }),
    /requires/,
  );
});
test("second rename failure restores original directory and preserves staged bytes", () => {
  const dir = root(),
    store = path.join(dir, "joe-board"),
    staged = path.join(dir, "stage");
  seed(store);
  seed(staged);
  const before = bytes(store),
    stagedBefore = bytes(staged);
  let calls = 0;
  assert.throws(
    () =>
      swapDirectories(store, staged, {
        uid,
        gid,
        rename(a, b) {
          if (++calls === 2) throw new Error("fixture");
          fs.renameSync(a, b);
        },
      }),
    /original_restored/,
  );
  assert.deepEqual(bytes(store), before);
  assert.deepEqual(bytes(staged), stagedBefore);
  assert.equal(calls, 3);
});
test("swap refuses a non-sibling before renaming", () => {
  const dir = root(),
    store = path.join(dir, "joe-board");
  seed(store);
  const other = root();
  seed(path.join(other, "stage"));
  assert.throws(
    () => swapDirectories(store, path.join(other, "stage"), { uid, gid }),
    /siblings/,
  );
  assert.ok(fs.existsSync(store));
});
test("symlinks and hardlinks fail before ownership changes", () => {
  for (const kind of ["symlink", "hardlink"]) {
    const dir = root(),
      staged = path.join(dir, "stage");
    seed(staged);
    const target = path.join(dir, "outside");
    put(dir, "outside", "fixture");
    if (kind === "symlink") fs.symlinkSync(target, path.join(staged, "linked"));
    else fs.linkSync(target, path.join(staged, "linked"));
    assert.throws(() => normalizeStore(staged, uid, gid), /regular_unlinked/);
    assert.equal(fs.readFileSync(target, "utf8"), "fixture");
  }
});
test("explicit stopped-writer attestation is mandatory", () => {
  const dir = root(),
    store = path.join(dir, "joe-board");
  seed(store);
  assert.throws(
    () => runSwap({ direction: "rollback", store, labRoot: dir, gid, uid }),
    /stop_all_writers/,
  );
});
test(
  "real offline CLI: backup, staged v2 forward, exact v1 rollback and private modes",
  { skip: !source },
  () => {
    const dir = root(),
      store = path.join(dir, "joe-board"),
      backup = path.join(dir, "backup"),
      staged = path.join(dir, "v2"),
      snapshot = path.join(dir, "snapshot.json");
    seed(store);
    const before = bytes(store);
    const samples = JSON.parse(
        fs.readFileSync(path.join(source, "fixtures/valid.json")),
      ),
      data = structuredClone(samples.data),
      receipt = data.receivedAt;
    delete data.receivedAt;
    put(dir, "snapshot.json", data);
    prepare("backup", "--offline", store, backup, "v1");
    prepare("verify", "--offline", backup);
    prepare("migrate-v2", "--offline", backup, staged, snapshot, receipt);
    const forward = runSwap({
      direction: "forward",
      store,
      staged,
      source,
      labRoot: dir,
      uid,
      gid,
      writersStopped: true,
    });
    assert.deepEqual(bytes(forward.retained), before);
    assert.ok(fs.existsSync(path.join(store, "data-state.json")));
    assert.ok(!fs.existsSync(path.join(store, "data.json")));
    const rollback = runSwap({
      direction: "rollback",
      store,
      backup,
      source,
      labRoot: dir,
      uid,
      gid,
      writersStopped: true,
    });
    assert.deepEqual(bytes(store), before);
    assert.ok(fs.existsSync(path.join(rollback.retained, "data-state.json")));
    assert.equal(fs.statSync(store).uid, uid);
    assert.equal(fs.statSync(store).gid, gid);
    assert.equal(fs.statSync(store).mode & 0o777, 0o700);
    for (const name of fs.readdirSync(store)) {
      const stat = fs.statSync(path.join(store, name));
      assert.equal(stat.mode & 0o777, 0o600);
      assert.equal(stat.uid, uid);
      assert.equal(stat.gid, gid);
    }
    put(backup, "data.json", "corrupt");
    const retainedBefore = bytes(store);
    assert.throws(
      () =>
        runSwap({
          direction: "rollback",
          store,
          backup,
          source,
          labRoot: dir,
          uid,
          gid,
          writersStopped: true,
        }),
      /preparation_failed/,
    );
    assert.deepEqual(bytes(store), retainedBefore);
  },
);

test("extracted labels retain exact rule, priority and strip-before-auth order", async () => {
  const { labelsToDynamic, requireWorkstation } =
    await import("../scripts/rehearse-joedesk.mjs");
  for (const host of ["csb0", "hsb0.example.invalid", "agm1"])
    assert.throws(() => requireWorkstation(host), /fleet/);
  requireWorkstation("workstation");
  const spec = JSON.parse(
    spawnSync(
      "nix",
      [
        "eval",
        "--json",
        "--file",
        new URL("../hosts/csb0/docker/compose-spec.nix", import.meta.url)
          .pathname,
      ],
      { encoding: "utf8" },
    ).stdout,
  );
  const labels = spec.services["joe-board"].labels;
  const authLabels = spec.services.hostdash.labels.filter((l) =>
    l.startsWith("traefik.http.middlewares.hostdash-auth-csb0."),
  );
  const config = labelsToDynamic(
    labels,
    authLabels,
    "lab-board",
    "lab-auth",
  ).http;
  assert.equal(
    config.routers["joe-health-csb0"].rule,
    "Host(`127.0.0.1`) && Path(`/joe/healthz`) && (Method(`GET`) || Method(`HEAD`))",
  );
  assert.equal(config.routers["joe-health-csb0"].priority, 400);
  assert.deepEqual(config.routers["joe-csb0"].middlewares, [
    "joe-identity-strip-csb0@file",
    "hostdash-auth-csb0@file",
  ]);
  assert.deepEqual(
    config.middlewares["joe-identity-strip-csb0"].headers.customRequestHeaders,
    {
      "X-Auth-Request-User": "",
      "X-Auth-Request-Email": "",
      "X-Forwarded-User": "",
    },
  );
  assert.deepEqual(
    config.middlewares["hostdash-auth-csb0"].forwardAuth.authResponseHeaders,
    ["X-Auth-Request-User", "X-Auth-Request-Email"],
  );
});
test("rollback plan binds exact set, images, generations and cross-host commands without SSH", async () => {
  const { rollbackPlan, setDigest } =
    await import("../scripts/rollback-joedesk.mjs");
  const release = JSON.parse(
    fs.readFileSync(
      new URL("../hosts/csb0/joedesk-release.json", import.meta.url),
    ),
  );
  const record = {
    previous_set_sha256: setDigest(release.sets.previous),
    rollback_nixcfg_rev: "a".repeat(40),
    board_image_id: "sha256:" + "b".repeat(64),
    pusher_image_id: "sha256:" + "c".repeat(64),
    backup_manifest_sha256: "d".repeat(64),
    csb0_generation: 1,
    hsb0_generation: 2,
    v1_backup: "/private/backup",
    prepare_source: "/nix/store/fixture",
    cookie_jar: "/private/cookies",
    hsb0_checkout: "/srv/nixcfg",
  };
  const plan = rollbackPlan(record, release);
  assert.match(
    plan.crossStop.join("\n"),
    /stop joe-board-pusher paper-desk-executor/,
  );
  assert.match(plan.crossSwitch.join("\n"), /just switch/);
  assert.ok(
    !/ssh|override-input|compose override/.test(
      [...plan.crossStop, ...plan.crossSwitch].join("\n"),
    ),
  );
  for (const patch of [
    { previous_set_sha256: "0".repeat(64) },
    { board_image_id: "latest" },
    { rollback_nixcfg_rev: "main" },
    { csb0_generation: null },
    { v1_backup: "relative" },
  ])
    assert.throws(() => rollbackPlan({ ...record, ...patch }, release));
});

test("Docker context precedence cannot send a workstation lab to a remote engine", async () => {
  const { resolveLocalDockerSocket } =
    await import("../scripts/joedesk-docker.mjs");
  assert.throws(
    () =>
      resolveLocalDockerSocket({
        context: "remote",
        host: "unix:///fixture.sock",
        inspect: () => "ssh://remote.invalid",
      }),
    /local_unix/,
  );
  assert.throws(
    () =>
      resolveLocalDockerSocket({
        host: "tcp://remote.invalid:2375",
        inspect: () => "unix:///fixture.sock",
      }),
    /local_unix/,
  );
  assert.equal(
    resolveLocalDockerSocket({
      context: "local",
      host: "ssh://remote.invalid",
      inspect: () => "unix:///fixture.sock",
    }),
    "/fixture.sock",
  );
});
