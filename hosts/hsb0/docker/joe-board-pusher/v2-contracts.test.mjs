import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFileSync, spawnSync } from "node:child_process";
import test from "node:test";
import { verify } from "./verify-contracts.mjs";
import { labCompose, requireWorkstation, requireLocalEndpoint, assertCadence } from "../../../../scripts/rehearse-household-v2-stage.mjs";

const root = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(root, "../../../..");
const run = (cmd, args, options = {}) => execFileSync(cmd, args, { encoding: "utf8", ...options });
function temp(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "ops392-contract-"));
  t.after(() => { spawnSync("trash", [directory]); });
  return directory;
}
const producerVerifier = run("git", ["show", "d88950476d3a38c464f27ae498c2de10e696f0a5:hosts/hsb0/docker/joe-board-pusher/verify-contracts.mjs"]);
async function verifiers(directory) {
  fs.copyFileSync(path.join(root, "verify-contracts.mjs"), path.join(directory, "verify-contracts.mjs"));
  fs.writeFileSync(path.join(directory, "producer-verifier.mjs"), producerVerifier);
  const local = await import(pathToFileURL(path.join(directory, "verify-contracts.mjs")));
  const producer = await import(pathToFileURL(path.join(directory, "producer-verifier.mjs")));
  return [() => local.verify(), () => producer.verifyContracts(directory)];
}
function copyClosure(directory) {
  fs.cpSync(path.join(root, "contracts"), path.join(directory, "contracts"), { recursive: true });
  fs.copyFileSync(path.join(root, "contracts.lock.json"), path.join(directory, "contracts.lock.json"));
}

test("independently pinned reviewed 17-file closure verifies, with producer verdict parity", async t => {
  assert.equal(verify(), true);
  const lock = JSON.parse(fs.readFileSync(path.join(root, "contracts.lock.json")));
  assert.equal(Object.keys(lock.files).length, 17);
  const directory = temp(t); copyClosure(directory);
  for (const check of await verifiers(directory)) assert.equal(check(), true);
  for (const name of Object.keys(lock.files)) {
    const reviewed = execFileSync("git", ["show", `d88950476d3a38c464f27ae498c2de10e696f0a5:hosts/hsb0/docker/joe-board-pusher/contracts/${name}`]);
    assert.ok(fs.readFileSync(path.join(root, "contracts", name)).equals(reviewed));
  }
  assert.ok(fs.readFileSync(path.join(root, "contracts.lock.json")).equals(execFileSync("git", ["show", "d88950476d3a38c464f27ae498c2de10e696f0a5:hosts/hsb0/docker/joe-board-pusher/contracts.lock.json"])));
});
for (const fault of ["changed", "extra", "symlink", "directory-symlink", "lock-drift", "set-drift", "size-drift", "hash-drift", "manifest-drift"]) test(`pusher and producer verifiers reject ${fault}`, async t => {
  const directory = temp(t); copyClosure(directory);
  if (fault === "changed") fs.appendFileSync(path.join(directory, "contracts/index.mjs"), "\n");
  if (fault === "extra") fs.writeFileSync(path.join(directory, "contracts/extra.json"), "{}");
  if (fault === "symlink") { fs.renameSync(path.join(directory, "contracts/index.mjs"), path.join(directory, "held.mjs")); fs.symlinkSync("../held.mjs", path.join(directory, "contracts/index.mjs")); }
  if (fault === "directory-symlink") { fs.renameSync(path.join(directory, "contracts"), path.join(directory, "held-contracts")); fs.symlinkSync("held-contracts", path.join(directory, "contracts")); }
  if (["set-drift", "size-drift", "hash-drift", "manifest-drift"].includes(fault)) {
    const lockFile = path.join(directory, "contracts.lock.json"); const lock = JSON.parse(fs.readFileSync(lockFile));
    if (fault === "set-drift") lock.contract_set_sha256 = "0".repeat(64);
    if (fault === "size-drift") lock.files["index.mjs"].bytes++;
    if (fault === "hash-drift") lock.files["index.mjs"].sha256 = "0".repeat(64);
    if (fault === "manifest-drift") lock.manifest_revision = 6;
    fs.writeFileSync(lockFile, JSON.stringify(lock));
  }
  if (fault === "lock-drift") { const lock = JSON.parse(fs.readFileSync(path.join(directory, "contracts.lock.json"))); lock.revision = "0".repeat(40); fs.writeFileSync(path.join(directory, "contracts.lock.json"), JSON.stringify(lock)); }
  for (const check of await verifiers(directory)) assert.throws(check);
});
for (const schema of fs.readdirSync(path.join(root, "contracts")).filter(n => n.endsWith(".json"))) test(`missing ${schema} fails both verifiers`, async t => {
  const directory = temp(t); copyClosure(directory);
  fs.renameSync(path.join(directory, "contracts", schema), path.join(directory, "held.json"));
  for (const check of await verifiers(directory)) assert.throws(check);
});

function hostEval(t, source, enabled, filtered = false) {
  const directory = temp(t);
  const host = path.join(directory, "configuration.nix");
  fs.writeFileSync(host, source.replace("joeHouseholdV2StageEnabled = true;", `joeHouseholdV2StageEnabled = ${enabled};`));
  fs.mkdirSync(path.join(directory, "docker/joe-board-pusher"), { recursive: true });
  fs.copyFileSync(path.join(repo, "hosts/hsb0/docker/compose-spec.nix"), path.join(directory, "docker/compose-spec.nix"));
  if (filtered) {
    fs.cpSync(root, path.join(directory, "docker/joe-board-pusher"), { recursive: true });
    fs.mkdirSync(path.join(directory, "docker/joe-board-pusher/fixtures"), { recursive: true });
    fs.writeFileSync(path.join(directory, "docker/joe-board-pusher/fixtures/contracts.lock.json"), "{}");
    fs.mkdirSync(path.join(directory, "docker/joe-board-pusher/nested/contracts"), { recursive: true });
    fs.writeFileSync(path.join(directory, "docker/joe-board-pusher/nested/contracts/data.schema.json"), "{}");
  }
  const expr = `let
    baseLib = import <nixpkgs/lib>;
    lib = baseLib // { cleanSourceWith = args: args // { __toString = _: "/fixture/context"; }; };
    host = import ${host} {
      inherit lib;
      pkgs.stdenv.hostPlatform.system = "x86_64-linux";
      inputs = {};
      config.nixcfg = { paperDeskExecutor.serviceSpec = { image = "fixture"; }; agentMailbox.enable = true; agentMailbox.serviceSpec = { image = "mailbox-fixture"; }; };
    };
    executorDefault = (import ${repo}/modules/paper-desk-executor/default.nix {
      lib = baseLib; config = {}; pkgs = {};
    }).options.nixcfg.paperDeskExecutor.image.default;
    executor = baseLib.evalModules { modules = [{
      options.image = baseLib.mkOption { type = baseLib.types.str; default = executorDefault; };
      config.image = host.nixcfg.paperDeskExecutor.image or (baseLib.mkIf false "unused");
    }]; };
    source = builtins.elemAt host.nixcfg.composeStack.extraRestartTriggers 1;
    walk = base: prefix: builtins.concatLists (baseLib.mapAttrsToList (name: type:
      let target = base + ("/" + name); relative = prefix + name;
      in if source.filter target type then
        if type == "directory" then walk target (relative + "/") else [ relative ]
      else []) (builtins.readDir base));
  in ${filtered ? "walk source.src \"\"" : '{ spec = host.nixcfg.composeStack.spec; exclusions = host.nixcfg.composeStack.autoUpdate.excludeFromPull; executorImage = executor.config.image; }'}`;
  return JSON.parse(run("nix-instantiate", ["--eval", "--strict", "--json", "--expr", expr]));
}

test("Nix flag-off preserves baseline pusher rendering; enabled overlay preserves env/volumes and isolates service", t => {
  const source = fs.readFileSync(path.join(repo, "hosts/hsb0/configuration.nix"), "utf8");
  const old = run("git", ["show", "27681452:hosts/hsb0/configuration.nix"], { cwd: repo });
  const baseline = hostEval(t, old, false);
  const disabled = hostEval(t, source, false);
  const baselinePusher = baseline.spec.services["joe-board-pusher"];
  assert.ok(Buffer.from(JSON.stringify(baselinePusher)).equals(Buffer.from(JSON.stringify(disabled.spec.services["joe-board-pusher"]))));
  assert.equal(Object.hasOwn(disabled.spec.services, "joe-household-v2-stage"), false);
  assert.equal(disabled.executorImage, disabled.spec.services["joe-board-pusher"].image);
  assert.deepEqual(disabled.exclusions, baseline.exclusions);
  const enabled = hostEval(t, source, true);
  const service = enabled.spec.services["joe-household-v2-stage"];
  const pusher = enabled.spec.services["joe-board-pusher"];
  assert.deepEqual(pusher.environment, [...baselinePusher.environment, "JOE_V2_STAGE_SOCKET=/run/joe-household-v2/stage.sock"]);
  assert.deepEqual(pusher.volumes, [...baselinePusher.volumes, "/run/joe-household-v2:/run/joe-household-v2:rw"]);
  assert.equal(service.image, pusher.image);
  assert.equal(enabled.executorImage, pusher.image);
  assert.equal(service.network_mode, "none"); assert.equal(service.mem_limit, "128m"); assert.equal(service.memswap_limit, "128m");
  assert.equal(service.cpus, 0.25); assert.equal(service.pids_limit, 32); assert.equal(service.user, "1000:1000");
  assert.equal(service.read_only, true); assert.deepEqual(service.cap_drop, ["ALL"]); assert.deepEqual(service.security_opt, ["no-new-privileges:true"]);
  assert.equal(service.restart, "unless-stopped"); assert.equal(service.pull_policy, "never");
  assert.deepEqual(service.command, ["node", "v2-stage-supervisor.mjs"]);
  assert.deepEqual(service.volumes, ["/var/lib/joe-board-pusher/v2:/var/lib/joe-board-pusher/v2:rw", "/run/joe-household-v2:/run/joe-household-v2:rw"]);
  for (const key of ["env_file", "environment", "depends_on", "ports", "privileged"]) assert.equal(Object.hasOwn(service, key), false);
  assert.equal(Object.hasOwn(pusher, "depends_on"), false);
  assert.ok(enabled.exclusions.includes("joe-household-v2-stage"));
  assert.equal(enabled.spec.services["agent-mailbox"].image, "mailbox-fixture");
  const lab = labCompose({ stage: service, pusher }, "ops392-lab-1234", "ops392-lab-1234:local", "/synthetic-lab");
  for (const key of ["restart", "network_mode", "mem_limit", "memswap_limit", "cpus", "pids_limit", "read_only", "cap_drop", "security_opt", "user"]) {
    assert.deepEqual(lab.services.stage[key], service[key]);
  }
  assert.equal(lab.services.pusher.network_mode, pusher.network_mode);
  assert.deepEqual(lab.services.pusher.environment, pusher.environment);
  assert.equal(Object.hasOwn(lab.services.pusher, "env_file"), false);
  assert.deepEqual(lab.services.stage.volumes.slice(0, 2), ["state:/var/lib/joe-board-pusher/v2:rw", "ipc:/run/joe-household-v2:rw"]);
  assert.ok(!JSON.stringify(lab).includes("/run/agenix"));
});

test("real Nix relative-path source filter preserves full verified closure and excludes test/fixture JSON", async t => {
  const source = fs.readFileSync(path.join(repo, "hosts/hsb0/configuration.nix"), "utf8");
  const files = hostEval(t, source, true, true);
  assert.ok(files.includes("contracts.lock.json"));
  assert.equal(files.filter(n => n.startsWith("contracts/")).length, 17);
  assert.ok(!files.some(n => n.endsWith(".test.mjs") || n.endsWith(".masked.json") || n.startsWith("fixtures/") || n.startsWith("nested/")));
  const directory = temp(t);
  for (const name of files) { fs.mkdirSync(path.dirname(path.join(directory, name)), { recursive: true }); fs.copyFileSync(path.join(root, name), path.join(directory, name)); }
  for (const check of await verifiers(directory)) assert.equal(check(), true);
});

test("Dockerfile verifies closure and probes flock while preserving base digests and npm install", () => {
  const docker = fs.readFileSync(path.join(root, "Dockerfile"), "utf8");
  const old = run("git", ["show", "27681452:hosts/hsb0/docker/joe-board-pusher/Dockerfile"], { cwd: repo });
  assert.deepEqual(docker.match(/^FROM .*$/gm), old.match(/^FROM .*$/gm));
  assert.match(docker, /^RUN npm ci --omit=dev$/m);
  assert.match(docker, /COPY contracts\/ \.\/contracts\//);
  assert.match(docker, /RUN node verify-contracts-entry\.mjs/);
  assert.match(docker, /flock --no-fork --nonblock/);
  assert.doesNotMatch(docker, /apk upgrade/);
  for (const name of ["package.json", "package-lock.json"]) assert.equal(fs.readFileSync(path.join(root, name), "utf8"), run("git", ["show", `27681452:hosts/hsb0/docker/joe-board-pusher/${name}`], { cwd: repo }));
});

test("fixed verifier build entry cannot be bypassed with argv", t => {
  const directory = temp(t); copyClosure(directory);
  for (const name of ["verify-contracts.mjs", "verify-contracts-entry.mjs"]) fs.copyFileSync(path.join(root, name), path.join(directory, name));
  const entry = path.join(directory, "verify-contracts-entry.mjs");
  assert.equal(spawnSync(process.execPath, [entry, "ignored"]).status, 0);
  fs.appendFileSync(path.join(directory, "contracts/index.mjs"), "\n");
  assert.notEqual(spawnSync(process.execPath, [entry, "ignored"]).status, 0);
  assert.doesNotMatch(fs.readFileSync(path.join(root, "verify-contracts.mjs"), "utf8"), /process\.argv/);
});

test("Linux rehearsal refuses fleet hosts and remote Docker; cadence assertions fail closed", () => {
  for (const name of ["hsb0", "HSB8.example.invalid", "csb1", "agm-production", ""]) assert.throws(() => requireWorkstation(name));
  for (const name of ["workstation", "colima", "ubuntu-runner"]) assert.doesNotThrow(() => requireWorkstation(name));
  for (const endpoint of ["ssh://host", "tcp://127.0.0.1:2375", "unix://relative", ""]) assert.throws(() => requireLocalEndpoint(endpoint));
  assert.equal(requireLocalEndpoint("unix:///synthetic/docker.sock"), "unix:///synthetic/docker.sock");
  const valid = { equal: true, posts: 3, gaps: [22000, 30000], failures: 0 };
  assert.doesNotThrow(() => assertCadence(valid, 30000));
  for (const delta of [{ equal: false }, { posts: 1 }, { failures: 1 }, { gaps: [22000, 60000] }]) assert.throws(() => assertCadence({ ...valid, ...delta }, 30000));
});
