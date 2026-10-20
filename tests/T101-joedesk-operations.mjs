import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawnSync } from "node:child_process";
import childProcess from "node:child_process";
import { syncBuiltinESMExports } from "node:module";
import { createHash } from "node:crypto";
import vm from "node:vm";
import { fleetActorSource } from "./joedesk-pinned-functions.mjs";
import {
  sourceRoot,
  sourcePath,
  readSource,
  readSourceMap,
} from "./joedesk-test-paths.mjs";
import {
  requireSafeHost,
  swapDirectories,
  runSwap,
  normalizeStore,
  requireBoardStopped,
} from "../scripts/joedesk-data-swap.mjs";

const source = process.env.JOEDESK_TEST_SOURCE
  ? sourceRoot(process.env.JOEDESK_TEST_SOURCE)
  : undefined;
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
function operatorRecordIO(dir) {
  return {
    ...fs,
    openSync(file, ...args) {
      assert.equal(path.dirname(file), "/var/lib/joedesk-rollback");
      return fs.openSync(path.join(dir, path.basename(file)), ...args);
    },
    lstatSync(file) {
      assert.equal(file, "/var/lib/joedesk-rollback");
      return fs.lstatSync(dir);
    },
  };
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
      JSON.parse(readSource(source, "fixtures/valid.json"))["fleet-config"],
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
    [sourcePath(source, "scripts/prepare-data.mjs"), ...args],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 0, "actual prepare-data CLI must pass");
}

test("source readers require fixed parents and reject symlink escapes", () => {
  const dir = root();
  put(dir, "package.json", { name: "synthetic-source" });
  assert.equal(sourceRoot(dir), dir);
  assert.equal(
    JSON.parse(readSource(dir, "package.json")).name,
    "synthetic-source",
  );
  for (const outside of ["/", "/etc", path.dirname(dir)])
    assert.throws(() => sourceRoot(outside), /source outside fixed parents/);
  fs.symlinkSync("/etc", path.join(dir, "escape"));
  assert.throws(
    () => sourceRoot(path.join(dir, "escape")),
    /source outside fixed parents/,
  );
  fs.symlinkSync("/etc/hosts", path.join(dir, "server.mjs"));
  assert.throws(
    () => readSource(dir, "server.mjs"),
    /source file outside root/,
  );
  assert.throws(
    () => readSource(dir, "../package.json"),
    /fixed source filename/,
  );
});

test("source maps accept the CI temp layout and reject foreign layouts", () => {
  const dir = fs.mkdtempSync(
    path.join(fs.realpathSync(os.tmpdir()), "ops354-ci-"),
  );
  put(dir, "sources.json", { synthetic: "/nix/store/synthetic-source" });
  assert.deepEqual(readSourceMap(path.join(dir, "sources.json")), {
    synthetic: "/nix/store/synthetic-source",
  });
  put(dir, "other.json", {});
  assert.throws(() => readSourceMap(path.join(dir, "other.json")));
  const foreign = root();
  put(foreign, "sources.json", {});
  assert.throws(() => readSourceMap(path.join(foreign, "sources.json")));
});

test("legacy curl keeps cookie paths in stdin and restricts request destinations", async (t) => {
  const { publicRead } = await import("../scripts/joedesk-legacy-smoke.mjs");
  const calls = [];
  const mock = t.mock.method(childProcess, "execFileSync", (...args) => {
    calls.push(args);
    return Buffer.from("synthetic-response\n200");
  });
  syncBuiltinESMExports();
  try {
    const cookie = "/private/synthetic cookie jar";
    for (const base of [
      "https://cs0.barta.cm/joe/",
      "http://127.0.0.1/joe/",
      "http://127.0.0.1:1/joe/",
      "http://127.0.0.1:80/joe/",
      "http://127.0.0.1:65535/joe/",
    ]) {
      assert.equal(publicRead(base, "data.json", cookie).status, 200);
      const [command, args, options] = calls.at(-1);
      assert.equal(command, "curl");
      assert.ok(!args.includes(cookie));
      assert.deepEqual(args.slice(-3, -1), ["--config", "-"]);
      assert.equal(options.input, 'cookie = "' + cookie + '"\n');
      assert.equal(options.stdio[0], "pipe");
      assert.equal(new URL(args.at(-1)).pathname, "/joe/data.json");
    }
    publicRead("https://cs0.barta.cm/joe/", "data.json");
    assert.equal(calls.at(-1)[2].input, undefined);
    assert.ok(!calls.at(-1)[1].includes("--config"));
    const count = calls.length;
    for (const base of [
      "http://127.0.0.1:0/joe/",
      "http://127.0.0.1:65536/joe/",
      "https://example.invalid/joe/",
      "http://127.0.0.1:1234/other/",
    ])
      assert.throws(
        () => publicRead(base, "data.json", cookie),
        /legacy_base_invalid/,
      );
    for (const unsafe of ['bad"path', "bad\\path", "bad\rpath", "bad\npath"])
      assert.throws(
        () => publicRead("https://cs0.barta.cm/joe/", "data.json", unsafe),
        /private_cookie_jar_required/,
      );
    assert.throws(
      () => publicRead("https://cs0.barta.cm/joe/", "../data.json", cookie),
      /legacy_route_invalid/,
    );
    assert.equal(calls.length, count, "invalid input must fail before curl");
  } finally {
    mock.mock.restore();
    syncBuiltinESMExports();
  }
});

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
  {
    skip:
      !source &&
      "exact v2 source unavailable; real prepare-data CLI not exercised",
  },
  () => {
    const dir = root(),
      store = path.join(dir, "joe-board"),
      backup = path.join(dir, "backup"),
      staged = path.join(dir, "v2"),
      snapshot = path.join(dir, "snapshot.json");
    seed(store);
    const before = bytes(store);
    const samples = JSON.parse(readSource(source, "fixtures/valid.json")),
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

test("rehearsal roots share fixed source parents and reject escapes before work", async () => {
  const { labParents, validateLabRoot } = await import(
    "../scripts/joedesk-lab-paths.mjs"
  );
  const { createLabRoot } = await import("../scripts/rehearse-joedesk.mjs");
  const parents = labParents();
  assert.equal(validateLabRoot(), parents[0]);
  const defaultParent = path.join(os.homedir(), ".cache", "joedesk-rehearsal");
  if (fs.existsSync(defaultParent))
    assert.equal(parents[0], fs.realpathSync(defaultParent));
  for (const parent of [os.tmpdir(), "/private/tmp"].filter(fs.existsSync)) {
    const dir = createLabRoot(parent);
    const candidate = path.join(dir, "v2-source");
    fs.mkdirSync(candidate, { mode: 0o700 });
    assert.equal(sourceRoot(candidate), candidate);
    const nested = path.join(dir, "not-created", "nested");
    assert.equal(validateLabRoot(nested), nested);
    assert.equal(fs.existsSync(path.dirname(nested)), false);
    fs.symlinkSync("/etc", path.join(dir, "escape"));
    assert.throws(
      () => createLabRoot(path.join(dir, "escape", "uncreated")),
      /lab_root_outside_allowed_parents/,
    );
  }
  const outside = "/etc/ops354-uncreated-lab";
  assert.equal(fs.existsSync(outside), false);
  for (const invalid of [outside, parents[0] + "-lookalike", "/etc"]) {
    assert.throws(
      () => createLabRoot(invalid),
      /lab_root_outside_allowed_parents/,
    );
    const result = spawnSync(
      process.execPath,
      [
        new URL("../scripts/rehearse-joedesk.mjs", import.meta.url).pathname,
        "--source",
        "/nonexistent-ops354-source",
        "--lab-root",
        invalid,
        "--dry-run",
      ],
      { encoding: "utf8" },
    );
    assert.equal(result.status, 1);
    assert.match(result.stderr, /lab_root_outside_allowed_parents/);
  }
  assert.equal(fs.existsSync(outside), false);
});

test("extracted labels retain exact rule, priority and strip-before-auth order", async () => {
  const { labelsToDynamic, requireWorkstation } = await import(
    "../scripts/rehearse-joedesk.mjs"
  );
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
      "X-Auth-Request-Preferred-Username": "",
      "X-Auth-Request-Groups": "",
      "X-Forwarded-User": "",
      "X-Forwarded-Email": "",
      "X-Forwarded-Preferred-Username": "",
    },
  );
  assert.deepEqual(
    config.middlewares["hostdash-auth-csb0"].forwardAuth.authResponseHeaders,
    ["X-Auth-Request-User", "X-Auth-Request-Email"],
  );
});
test("rollback plan binds exact set, images, generations and cross-host commands without SSH", async (t) => {
  const { rollbackPlan, setDigest, readOperatorRecord } = await import(
    "../scripts/rollback-joedesk.mjs"
  );
  const release = JSON.parse(
    fs.readFileSync(
      new URL("../hosts/csb0/joedesk-release.json", import.meta.url),
    ),
  );
  const record = {
    previous_set_sha256: setDigest(release.sets.previous),
    rollback_nixcfg_rev: "a".repeat(40),
    pre_cutover_hsb0_nixcfg_rev: "e".repeat(40),
    pre_cutover_pusher_source_tree: "f".repeat(40),
    pre_cutover_executor_source_tree: "1".repeat(40),
    pre_cutover_pusher_image: "fixture:recorded",
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
  const dir = root(),
    recordFile = path.join(dir, "record.json"),
    recordPath = "/var/lib/joedesk-rollback/record.json",
    io = operatorRecordIO(dir);
  put(dir, "record.json", record);
  assert.deepEqual(readOperatorRecord(recordPath, io), record);
  fs.chmodSync(recordFile, 0o644);
  assert.throws(
    () => readOperatorRecord(recordPath, io),
    /private_operator_record_required/,
  );
  fs.chmodSync(recordFile, 0o600);
  fs.symlinkSync(recordFile, path.join(dir, "linked-record.json"));
  assert.throws(
    () =>
      readOperatorRecord("/var/lib/joedesk-rollback/linked-record.json", io),
    /private_operator_record_required/,
  );
  const open = fs.openSync;
  let replaced = false;
  const mock = t.mock.method(fs, "openSync", (file, ...args) => {
    const fd = open(file, ...args);
    if (file === recordFile && !replaced) {
      replaced = true;
      fs.renameSync(file, path.join(dir, "retained-record.json"));
      put(dir, "record.json", { replacement: true });
    }
    return fd;
  });
  try {
    assert.deepEqual(readOperatorRecord(recordPath, io), record);
    assert.equal(
      replaced,
      true,
      "record replacement must exercise the descriptor read",
    );
  } finally {
    mock.mock.restore();
  }
  const plan = rollbackPlan(record, release);
  assert.match(
    plan.crossStop.join("\n"),
    /stop joe-board-pusher joe-household-v2-stage/,
  );
  assert.match(plan.crossSwitch.join("\n"), /just switch/);
  assert.ok(
    plan.crossStop.findIndex((s) => s.includes("git fetch")) <
      plan.crossStop.findIndex((s) => s.includes("systemctl stop")),
  );
  assert.ok(
    plan.crossStop.findIndex((s) => s.includes("verifyRollbackTarget")) <
      plan.crossStop.findIndex((s) => s.includes("systemctl stop")),
  );
  assert.ok(
    plan.crossSwitch.includes(
      "git merge --ff-only '" + record.rollback_nixcfg_rev + "'",
    ),
  );
  assert.ok(!plan.crossSwitch.some((s) => s.includes("git pull")));
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
  await t.test("unsafe cookie jars fail during rollback preflight", () => {
    for (const character of ['"', "\\", "\r", "\n"])
      assert.throws(
        () =>
          rollbackPlan(
            { ...record, cookie_jar: "/private/cookie" + character + "jar" },
            release,
          ),
        /private_cookie_jar_required/,
      );
    for (const cookie_jar of [undefined, "", "relative"])
      assert.throws(
        () => rollbackPlan({ ...record, cookie_jar }, release),
        /private_cookie_jar_required/,
      );
    for (const cookie_jar of [
      "/private/cookie jar",
      "/private/#jar",
      "/private/-jar",
    ])
      assert.ok(rollbackPlan({ ...record, cookie_jar }, release));
  });
});

test("operator records accept the default and private filenames in the fixed root", async () => {
  const { readOperatorRecord } = await import(
    "../scripts/rollback-joedesk.mjs"
  );
  const dir = root(),
    io = operatorRecordIO(dir),
    record = { synthetic: true };
  put(dir, "record.json", record);
  put(dir, "Review_2026-10.19.json", record);
  assert.deepEqual(readOperatorRecord(undefined, io), record);
  assert.deepEqual(
    readOperatorRecord("/var/lib/joedesk-rollback/Review_2026-10.19.json", io),
    record,
  );
  fs.chmodSync(path.join(dir, "record.json"), 0o644);
  assert.throws(
    () => readOperatorRecord(undefined, io),
    /private_operator_record_required/,
    "the default must still reach the descriptor permission checks",
  );
});

test("operator record paths reject traversal, subdirectories and other names before opening", async () => {
  const { readOperatorRecord } = await import(
    "../scripts/rollback-joedesk.mjs"
  );
  const io = {
    openSync() {
      assert.fail("invalid paths must be rejected before open");
    },
  };
  for (const file of [
    "../x.json",
    "/var/lib/joedesk-rollback/../x.json",
    "/var/lib/joedesk-rollback/nested/../x.json",
    "/var/lib/joedesk-rollback/nested/x.json",
    "/private/x.json",
    "/var/lib/joedesk-rollback-other/x.json",
    "/var/lib/joedesk-rollback/record.txt",
    "/var/lib/joedesk-rollback/.json",
    "/var/lib/joedesk-rollback/bad name.json",
    "/var/lib/joedesk-rollback/record.json\n",
  ])
    assert.throws(
      () => readOperatorRecord(file, io),
      /private_operator_record_required/,
      file,
    );
});

test("operator records reject symlinked, exposed or foreign-owned parent directories", async () => {
  const { readOperatorRecord } = await import(
    "../scripts/rollback-joedesk.mjs"
  );
  const dir = root(),
    io = operatorRecordIO(dir),
    record = { synthetic: true };
  put(dir, "record.json", record);
  io.readFileSync = () => assert.fail("unsafe parent must fail before reading");
  for (const mode of [0o740, 0o704, 0o750, 0o705]) {
    fs.chmodSync(dir, mode);
    assert.throws(
      () => readOperatorRecord(undefined, io),
      /private_operator_record_required/,
    );
  }
  fs.chmodSync(dir, 0o700);
  const link = path.join(root(), "linked-parent");
  fs.symlinkSync(dir, link);
  const linkedIO = operatorRecordIO(link);
  linkedIO.readFileSync = io.readFileSync;
  assert.throws(
    () => readOperatorRecord(undefined, linkedIO),
    /private_operator_record_required/,
  );
  const parent = fs.lstatSync(dir);
  io.lstatSync = () => ({
    isDirectory: () => true,
    mode: parent.mode,
    uid: Math.max(uid, 0) + 1,
  });
  assert.throws(
    () => readOperatorRecord(undefined, io),
    /private_operator_record_required/,
  );
});

test("Docker context precedence cannot send a workstation lab to a remote engine", async () => {
  const { resolveLocalDockerSocket } = await import(
    "../scripts/joedesk-docker.mjs"
  );
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

test("engine name and bind visibility are checked before a lab can use Docker", async () => {
  const { requireLabDocker } = await import("../scripts/joedesk-docker.mjs");
  for (const engine of ["csb0", "CSB9.example.invalid", "hsb0", "agm1"]) {
    const calls = [];
    assert.throws(
      () =>
        requireLabDocker(
          root(),
          (args) => {
            calls.push(args);
            return engine;
          },
          () => "/fixture.sock",
        ),
      /fleet_docker/,
    );
    assert.deepEqual(calls, [["info", "--format", "{{.Name}}"]]);
  }
  for (const outcome of ["visible", "empty", "failed"]) {
    const dir = root(),
      calls = [];
    const command = (args) => {
      calls.push(args);
      if (args[0] === "info") return "colima";
      if (outcome === "failed") throw Error("synthetic stderr must not escape");
      return outcome === "visible"
        ? fs.readFileSync(path.join(dir, "docker-visibility-marker"), "utf8")
        : "";
    };
    if (outcome === "visible")
      requireLabDocker(dir, command, () => "/fixture.sock");
    else
      assert.throws(
        () => requireLabDocker(dir, command, () => "/fixture.sock"),
        /^Error: lab_root_not_visible_to_docker$/,
      );
    assert.ok(calls[1].includes(dir + ":/lab:ro"));
    assert.ok(calls[1].includes("none"));
  }
});

test("lab edge publishes loopback on bridge, connects internally and reads YAML", async () => {
  const { createLabRoot, startLabEdge } = await import(
    "../scripts/rehearse-joedesk.mjs"
  );
  const base = root(),
    dir = createLabRoot(base),
    calls = [];
  assert.equal(path.dirname(dir), base);
  assert.equal(fs.statSync(dir).mode & 0o777, 0o700);
  startLabEdge(
    { root: dir, edge: "lab-edge", network: "lab-internal" },
    (args) => calls.push(args),
  );
  assert.equal(calls[0][calls[0].indexOf("--network") + 1], "bridge");
  assert.equal(calls[0][calls[0].indexOf("-p") + 1], "127.0.0.1::8080");
  assert.ok(
    calls[0].includes(path.join(dir, "dynamic.yml") + ":/dynamic.yml:ro"),
  );
  assert.ok(calls[0].includes("--providers.file.filename=/dynamic.yml"));
  assert.ok(
    calls[0].includes("--entrypoints.web.http.aliasHeadersStrategy=delete"),
  );
  assert.deepEqual(calls[1], [
    "network",
    "connect",
    "lab-internal",
    "lab-edge",
  ]);
});

test("Docker failures reveal only first subcommand and numeric status", async () => {
  const { docker } = await import("../scripts/joedesk-docker.mjs");
  for (const subcommand of ["port", "exec", "network"]) {
    assert.throws(
      () =>
        docker([subcommand, "synthetic-private-argument"], {}, () => {
          throw Object.assign(new Error("synthetic-private-stderr"), {
            status: 17,
            stderr: "synthetic-private-stderr",
          });
        }),
      { message: `local_docker_command_failed_${subcommand}_exit_17` },
    );
  }
  assert.throws(
    () =>
      docker(["unsafe argument"], {}, () => {
        throw Error("not found");
      }),
    { message: "local_docker_command_failed_unknown_exit_unavailable" },
  );
});

test("lab never bind-mounts the host store: every data operation shares one Linux volume", async () => {
  const { labData, prepareLabData } = await import(
    "../scripts/rehearse-joedesk.mjs"
  );
  const { expectedBackup } = await import(
    "../scripts/joedesk-legacy-smoke.mjs"
  );
  const volume = "ops354-12345678-1234-1234-1234-123456789abc-data";
  const calls = [],
    payload = Buffer.from('{"synthetic":"unaltered backup bytes"}\n');
  const digest = createHash("sha256").update(payload).digest("hex");
  const manifest = Buffer.from(
    JSON.stringify({
      schema: "joedesk.data-backup.v1",
      boardSchema: "v1",
      files: ["data.json", "history.json"].map((name) => ({
        name,
        size: payload.length,
        sha256: digest,
      })),
    }),
  );
  const data = labData(
    {
      root: "/host-inputs",
      candidate: "/host-source",
      volume,
      image: "candidate-image",
    },
    (args) => {
      calls.push(args);
      if (args[0] === "volume") return "";
      if (args.at(-1) === "/lab/v1-backup/backup-manifest.json")
        return manifest.toString("base64");
      if (args.at(-1).startsWith("/lab/v1-backup/"))
        return payload.toString("base64");
      return "ok";
    },
  );
  try {
    data.create();
    prepareLabData(data, "2026-10-16T00:00:00Z");
    data.swap("rollback");
    assert.equal(data.ownership(), "ok");
    assert.deepEqual(expectedBackup("/lab/v1-backup", data.readBackupFile), {
      "data.json": digest,
      "history.json": digest,
    });
    assert.deepEqual(data.readBackupFile("/lab/v1-backup/data.json"), payload);
    assert.throws(
      () => data.readBackupFile("/host-inputs/joe-board/data.json"),
      /backup_path/,
    );
  } finally {
    data.cleanup();
  }
  const mounts = (args) =>
    args.flatMap((arg, i) => (arg === "-v" ? [args[i + 1]] : []));
  assert.deepEqual(mounts(data.boardMount), [volume + ":/var/lib"]);
  const helpers = calls.filter((args) => args[0] === "run");
  assert.ok(helpers.length >= 9);
  for (const args of helpers) {
    assert.deepEqual(mounts(args), [
      volume + ":/lab",
      "/host-inputs/fixtures:/fixtures:ro",
      "/host-source:/source:ro",
      new URL("../scripts", import.meta.url).pathname + ":/ops:ro",
    ]);
    assert.equal(args[args.indexOf("--user") + 1], "0:0");
    assert.equal(args[args.indexOf("--network") + 1], "none");
  }
  assert.ok(helpers.some((args) => args.includes("/fixtures/snapshot.json")));
  for (const direction of ["forward", "rollback"]) {
    const args = helpers.find((args) => args.includes(direction));
    assert.ok(args.includes("/ops/joedesk-data-swap.mjs"));
    assert.equal(args[args.indexOf("--store") + 1], "/lab/joe-board");
    assert.equal(args[args.indexOf("--lab-root") + 1], "/lab");
    assert.equal(args[args.indexOf("--gid") + 1], "1000");
    assert.ok(args.includes("--writers-stopped"));
  }
  assert.deepEqual(calls.at(-1), ["volume", "rm", volume]);
  const count = calls.length;
  data.cleanup();
  assert.equal(
    calls.length,
    count,
    "cleanup removes only the volume created by this run, once",
  );
});

test("lab refuses foreign or pre-existing volumes and never cleans them up", async () => {
  const { labData } = await import("../scripts/rehearse-joedesk.mjs");
  for (const volume of [
    "production-data",
    "ops354-data",
    "ops354-../foreign-data",
  ])
    assert.throws(() => labData({ volume }), /lab_volume_name_required/);
  const volume = "ops354-12345678-1234-1234-1234-123456789abc-data",
    calls = [];
  const data = labData({ volume }, (args) => {
    calls.push(args);
    return volume;
  });
  try {
    assert.throws(() => data.create(), /lab_volume_exists/);
  } finally {
    data.cleanup();
  }
  assert.deepEqual(calls, [["volume", "ls", "--format", "{{.Name}}"]]);
});

test("every board state except exited refuses the production swap", () => {
  for (const state of [
    "running",
    "restarting",
    "paused",
    "created",
    "removing",
    "dead",
    "unknown",
    "exited\npaused",
  ])
    assert.throws(() => requireBoardStopped(state), /board_must_be_stopped/);
  for (const state of ["", "exited", "exited\nexited\n"])
    requireBoardStopped(state);
});

test("ownership normalization cannot follow a symlink swapped in before open", (t) => {
  const dir = root(),
    staged = path.join(dir, "stage"),
    outside = path.join(dir, "outside");
  seed(staged);
  put(dir, "outside", "unchanged");
  const beforeFd = fs.openSync(
    outside,
    fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW,
  );
  const before = fs.fstatSync(beforeFd),
    open = fs.openSync;
  let raced = false;
  t.mock.method(fs, "openSync", (file, ...args) => {
    if (!raced && file === path.join(staged, "data.json")) {
      raced = true;
      fs.renameSync(file, file + ".retained");
      fs.symlinkSync(outside, file);
    }
    return open(file, ...args);
  });
  assert.throws(() => normalizeStore(staged, uid, gid), /regular_unlinked/);
  assert.equal(raced, true);
  try {
    const after = fs.fstatSync(beforeFd);
    assert.equal(after.ino, before.ino);
    assert.equal(after.dev, before.dev);
    assert.equal(after.mode, before.mode);
    assert.equal(fs.readFileSync(beforeFd, "utf8"), "unchanged");
  } finally {
    fs.closeSync(beforeFd);
  }
});

test("operators cannot request the internal flock bypass", () => {
  const result = spawnSync(
    process.execPath,
    [
      new URL("../scripts/joedesk-data-swap.mjs", import.meta.url).pathname,
      "rollback",
      "--lock-held",
    ],
    { encoding: "utf8" },
  );
  assert.equal(result.status, 1);
  assert.match(result.stderr, /joedesk_swap_failed: usage/);
});

test(
  "legacy check uses only files really shipped by db621bf COPY instructions",
  {
    skip:
      !source &&
      !process.env.JOEDESK_LEGACY_SOURCE &&
      "immutable legacy source unavailable; Dockerfile closure not exercised",
  },
  async () => {
    const { checkLegacyFiles } = await import(
      "../scripts/joedesk-legacy-smoke.mjs"
    );
    const legacy = process.env.JOEDESK_LEGACY_SOURCE
        ? sourceRoot(process.env.JOEDESK_LEGACY_SOURCE)
        : undefined,
      rev = "db621bf7f00a4c609b0930ef7d5020f3c8935ee9";
    const git = (...args) => {
      const result = spawnSync("git", ["-C", source, ...args], {
        encoding: "utf8",
      });
      assert.equal(result.status, 0, "immutable db621bf Git objects required");
      return result.stdout;
    };
    const read = (file) =>
      legacy
        ? readSource(legacy, file)
        : Buffer.from(git("show", rev + ":" + file));
    const files = legacy
      ? fs
          .readdirSync(legacy, { recursive: true, withFileTypes: true })
          .filter((entry) => entry.isFile())
          .map((entry) =>
            path.relative(legacy, path.join(entry.parentPath, entry.name)),
          )
      : git("ls-tree", "-r", "--name-only", rev).trim().split("\n");
    const copySources = [
      ...read("Dockerfile")
        .toString()
        .matchAll(/^COPY (.+)\s+\S+$/gm),
    ].flatMap((match) => match[1].split(/\s+/));
    const shipped = new Set(
      files.filter((file) =>
        copySources.some((src) => file === src || file.startsWith(src + "/")),
      ),
    );
    assert.ok(shipped.has("package.json"));
    assert.ok(
      !shipped.has("release.json"),
      "db621bf intentionally does not ship release.json",
    );
    const digest = (b) => createHash("sha256").update(b).digest("hex"),
      payload = Buffer.from("synthetic v1 bytes");
    const accessed = [];
    const readContainer = (file) => {
      accessed.push(file);
      if (file === "/var/lib/joe-board/data.json") return payload;
      assert.ok(
        file.startsWith("/app/") && shipped.has(file.slice(5)),
        "check attempted a file absent from the real image COPY closure",
      );
      return read(file.slice(5));
    };
    const probe = async (route) => {
      assert.ok(["/healthz", "/readyz"].includes(route));
      return {
        status: 200,
        json: async () => ({ ok: true, service: "joe-board", hasData: true }),
      };
    };
    assert.equal(
      await checkLegacyFiles(readContainer, probe, digest, {
        "data.json": digest(payload),
      }),
      digest(read("public/joe/joe-version.js")),
    );
    assert.ok(!accessed.some((file) => file.endsWith("release.json")));
    await assert.rejects(
      () =>
        checkLegacyFiles(readContainer, probe, digest, {
          "data.json": digest("corrupt"),
        }),
      /restored_bytes/,
    );
    await assert.rejects(
      () =>
        checkLegacyFiles(
          (file) =>
            file === "/app/package.json"
              ? JSON.stringify({
                  name: "joedesk",
                  version: "wrong",
                  type: "module",
                })
              : readContainer(file),
          probe,
          digest,
          {},
        ),
      /package_mismatch/,
    );
  },
);

test(
  "actual v2 identity reader never aliases punctuation into an authenticated user",
  {
    skip:
      !source &&
      "exact v2 source unavailable; actual identity reader not exercised",
  },
  async () => {
    const { spoofHeaders } = await import("../scripts/rehearse-joedesk.mjs");
    const server = readSource(source, "server.mjs", "utf8");
    const constant = server.match(/^const FLEET_ACTOR = .+;$/m)?.[0];
    const functionSource = server.match(
      /function fleetActor\(req\) \{[\s\S]*?\n\}/,
    )?.[0];
    assert.ok(
      constant && functionSource,
      "actual pinned identity reader required",
    );
    assert.equal(
      constant + "; (" + functionSource + ")",
      fleetActorSource,
      "actual pinned identity reader differs from reviewed fixture",
    );
    const actor = vm.runInNewContext(fleetActorSource, {}, { timeout: 1000 });
    for (const name of Object.keys(spoofHeaders)) {
      if (name.toLowerCase() === "x-auth-request-user") continue;
      assert.equal(
        actor({ headers: { [name.toLowerCase()]: "synthetic-spoof" } }),
        "",
        "alias must not supply identity",
      );
      assert.equal(
        actor({
          headers: {
            [name.toLowerCase()]: "synthetic-spoof",
            "x-auth-request-user": "lab-authenticated",
          },
        }),
        "lab-authenticated",
      );
    }
  },
);

function runtimeRepo() {
  const dir = root();
  let head;
  const git = (...args) => {
    // Real Git tree snapshots need no test commits, signing changes or hooks.
    const resolved = args.map((arg) =>
      arg === "HEAD"
        ? head
        : arg.startsWith("HEAD:")
          ? head + arg.slice(4)
          : arg,
    );
    const result = spawnSync("git", ["-C", dir, ...resolved], {
      encoding: "utf8",
    });
    if (result.status !== 0) throw new Error("fixture_git_failed");
    return result.stdout.trim();
  };
  git("init", "-q");
  const snapshot = () => {
    git("add", "pusher", "executor");
    head = git("write-tree");
    return head;
  };
  for (const name of ["pusher", "executor"]) {
    fs.mkdirSync(path.join(dir, name));
    put(path.join(dir, name), "runtime.mjs", "export const fixture = true;\n");
  }
  put(path.join(dir, "executor"), "default.nix", "{}\n");
  const rev = snapshot();
  const previous = Object.fromEntries(
    ["pusher", "executor"].map((name) => [
      name,
      {
        nixcfg_rev: rev,
        source_path: name,
        source_tree: git("rev-parse", rev + ":" + name),
      },
    ]),
  );
  return { dir, git, snapshot, previous };
}

test("rollback runtime gates catch added files and changed bytes at HEAD", async () => {
  const { verifyPreviousRuntimeSource } = await import(
    "../scripts/rollback-joedesk.mjs"
  );
  for (const [name, file] of [
    ["pusher", "added.py"],
    ["executor", "added.mjs"],
    ["pusher", "runtime.mjs"],
    ["executor", "runtime.mjs"],
  ]) {
    const fixture = runtimeRepo();
    verifyPreviousRuntimeSource(fixture.previous, "HEAD", fixture.git);
    put(path.join(fixture.dir, name), file, "changed\n");
    fixture.snapshot();
    assert.throws(
      () => verifyPreviousRuntimeSource(fixture.previous, "HEAD", fixture.git),
      /runtime_source_mismatch/,
    );
  }
  const fixture = runtimeRepo();
  put(
    path.join(fixture.dir, "executor"),
    "default.nix",
    "{ fixture = true; }\n",
  );
  fixture.snapshot();
  verifyPreviousRuntimeSource(fixture.previous, "HEAD", fixture.git);
});

test("rollback resolves the exact fetched fast-forward target before stopping writers", async () => {
  const { verifyRollbackTarget, setDigest } = await import(
    "../scripts/rollback-joedesk.mjs"
  );
  const fixture = runtimeRepo();
  const previous = { ...fixture.previous, board: { rev: "b".repeat(40) } };
  for (const name of ["pusher", "executor"])
    previous[name].image = "fixture:recorded";
  const record = {
    rollback_nixcfg_rev: "a".repeat(40),
    previous_set_sha256: setDigest(previous),
    pre_cutover_hsb0_nixcfg_rev: fixture.previous.pusher.nixcfg_rev,
    pre_cutover_pusher_source_tree: fixture.previous.pusher.source_tree,
    pre_cutover_executor_source_tree: fixture.previous.executor.source_tree,
    pre_cutover_pusher_image: "fixture:recorded",
  };
  // Variant B: historical previous has different runtime bytes. The record
  // names the runtime actually running immediately before phase1.
  put(
    path.join(fixture.dir, "pusher"),
    "runtime.mjs",
    "export const r16d = true;\n",
  );
  put(
    path.join(fixture.dir, "executor"),
    "runtime.mjs",
    "export const r16d = true;\n",
  );
  record.pre_cutover_hsb0_nixcfg_rev = fixture.snapshot();
  record.pre_cutover_pusher_source_tree = fixture.git(
    "rev-parse",
    "HEAD:pusher",
  );
  record.pre_cutover_executor_source_tree = fixture.git(
    "rev-parse",
    "HEAD:executor",
  );
  const calls = [];
  const runGit = (...args) => {
    calls.push(args);
    if (args[0] === "rev-parse" && args[1].endsWith("^{commit}"))
      return record.rollback_nixcfg_rev;
    if (args[0] === "merge-base") return "";
    if (args[0] === "show" && /configuration.nix|default.nix/.test(args[1]))
      return "joeSet = joeRelease.sets.${joeRelease.active};";
    if (args[0] === "show")
      return JSON.stringify(
        args[1].endsWith("flake.lock")
          ? { nodes: { joedesk: { locked: { rev: previous.board.rev } } } }
          : { active: "previous", sets: { previous } },
      );
    const mapped = args.map((arg) =>
      arg
        .replace("hosts/hsb0/docker/joe-board-pusher", "pusher")
        .replace("modules/paper-desk-executor", "executor"),
    );
    return fixture.git(
      ...mapped.map((arg) =>
        arg === record.rollback_nixcfg_rev
          ? "HEAD"
          : arg.startsWith(record.rollback_nixcfg_rev + ":")
            ? arg.replace(record.rollback_nixcfg_rev, "HEAD")
            : arg,
      ),
    );
  };
  verifyRollbackTarget(record, previous, runGit);
  assert.deepEqual(calls.slice(0, 3), [
    ["rev-parse", record.rollback_nixcfg_rev + "^{commit}"],
    ["merge-base", "--is-ancestor", "HEAD", record.rollback_nixcfg_rev],
    ["merge-base", "--is-ancestor", record.rollback_nixcfg_rev, "FETCH_HEAD"],
  ]);
  assert.throws(
    () =>
      verifyRollbackTarget(record, previous, (...args) => {
        if (args[0] === "merge-base") throw Error("diverged");
        return runGit(...args);
      }),
    /not_fetched_fast_forward/,
  );
  assert.throws(
    () =>
      verifyRollbackTarget(record, previous, (...args) =>
        args[0] === "show" && args[1].endsWith("joedesk-release.json")
          ? JSON.stringify({ active: "current", sets: { current: previous } })
          : runGit(...args),
      ),
    /previous_pins_not_selected/,
  );
});

test("recorded pre-cutover B runtime accepted; mismatched trees and implicit A refused", async () => {
  const { verifyRecordedRuntimeSource } = await import(
    "../scripts/rollback-joedesk.mjs"
  );
  const f = runtimeRepo();
  const record = {
    pre_cutover_hsb0_nixcfg_rev: f.previous.pusher.nixcfg_rev,
    pre_cutover_pusher_source_tree: f.previous.pusher.source_tree,
    pre_cutover_executor_source_tree: f.previous.executor.source_tree,
  };
  const git = (...args) =>
    f.git(
      ...args.map((arg) =>
        arg
          .replace("hosts/hsb0/docker/joe-board-pusher", "pusher")
          .replace("modules/paper-desk-executor", "executor"),
      ),
    );
  verifyRecordedRuntimeSource(record, "HEAD", git);
  for (const key of [
    "pre_cutover_pusher_source_tree",
    "pre_cutover_executor_source_tree",
  ]) {
    assert.throws(
      () =>
        verifyRecordedRuntimeSource(
          { ...record, [key]: "0".repeat(40) },
          "HEAD",
          git,
        ),
      /recorded_runtime_source_mismatch/,
    );
    const absent = { ...record };
    delete absent[key];
    assert.throws(
      () => verifyRecordedRuntimeSource(absent, "HEAD", git),
      /recorded_pre_cutover_runtime_required/,
    );
  }
  put(path.join(f.dir, "pusher"), "runtime.mjs", "different runtime\n");
  f.snapshot();
  assert.throws(
    () => verifyRecordedRuntimeSource(record, "HEAD", git),
    /previous_runtime_source_mismatch/,
  );
});
