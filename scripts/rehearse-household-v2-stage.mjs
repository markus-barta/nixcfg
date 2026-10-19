#!/usr/bin/env node
// OPS-392: destructive faults confined to uniquely named workstation containers.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { setTimeout as pause } from "node:timers/promises";

const repo = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
export function requireWorkstation(hostname) {
  if (!hostname || /^(csb|hsb|agm)/i.test(hostname.split(".")[0])) throw new Error("fleet_is_not_a_lab");
}
export function requireLocalEndpoint(endpoint) {
  if (!endpoint?.startsWith("unix:///")) throw new Error("local_unix_docker_required");
  return endpoint;
}
function run(command, args, options = {}) {
  try {
    return execFileSync(command, args, { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"], maxBuffer: 16 * 1024 * 1024, timeout: 600_000, ...options }).trim();
  } catch { throw new Error(`lab_command_failed_${command.replace(/[^a-z-]/gi, "")}`); }
}
export function readSettings() {
  // Evaluate the actual cleanSourceWith and service overlay; no NixOS build.
  const expression = `let
    lib = import <nixpkgs/lib>;
    host = import ${JSON.stringify(repo + "/hosts/hsb0/configuration.nix")} {
      inherit lib; inputs = {}; pkgs.stdenv.hostPlatform.system = "x86_64-linux";
      config.nixcfg = { paperDeskExecutor.serviceSpec = {}; agentMailbox.enable = false; };
    };
  in { context = toString (builtins.elemAt host.nixcfg.composeStack.extraRestartTriggers 1);
    stage = host.nixcfg.composeStack.spec.services.joe-household-v2-stage;
    pusher = host.nixcfg.composeStack.spec.services.joe-board-pusher;
  }`;
  return JSON.parse(run("nix-instantiate", ["--eval", "--strict", "--json", "--expr", expression]));
}
export function labCompose(settings, prefix, image, root) {
  assert.match(prefix, /^ops392-lab-[a-f0-9-]+$/);
  const stage = structuredClone(settings.stage), pusher = structuredClone(settings.pusher);
  // Only lab identities, synthetic entry points and volume sources change.
  for (const service of [stage, pusher]) {
    delete service.build; delete service.env_file;
    service.image = image; service.pull_policy = "never";
    service.labels = { "ops392.lab": prefix };
  }
  const ipc = "ipc:/run/joe-household-v2:rw";
  stage.container_name = prefix + "-stage";
  stage.command = ["node", "/lab/container.mjs", "stage"];
  stage.volumes = ["state:/var/lib/joe-board-pusher/v2:rw", ipc, `${root}/harness:/lab:ro`];
  pusher.container_name = prefix + "-pusher";
  pusher.command = ["node", "/lab/container.mjs", "pusher"];
  pusher.volumes = [ipc, `${root}/harness:/lab:ro`];
  // The synthetic token and broker are supplied only by module doubles.
  return { services: { pusher, stage }, volumes: { state: {}, ipc: {} } };
}
async function until(check, timeout = 75_000) {
  const end = performance.now() + timeout;
  while (performance.now() < end) {
    try { const value = check(); if (value) return value; } catch { /* container restarting */ }
    await pause(500);
  }
  throw new Error("lab_assertion_timed_out");
}
export function assertCadence(stats, intervalMs) {
  assert.equal(stats.equal, true, "v1_bytes_changed");
  assert.ok(stats.posts >= 2, "v1_posts_missing");
  assert.equal(stats.failures, 0, "unexpected_pusher_failure");
  // First timer is 8s; the first repeating timer is 30s, then exactly 30s.
  const expected = [intervalMs - 8000, ...stats.gaps.slice(1).map(() => intervalMs)];
  stats.gaps.forEach((gap, index) => assert.ok(Math.abs(gap - expected[index]) < 2000, "v1_interval_changed"));
}

async function main() {
  requireWorkstation(os.hostname());
  if (process.argv.length !== 2) throw new Error("no_arguments_supported");
  const endpoint = requireLocalEndpoint(process.env.DOCKER_CONTEXT
    ? run("docker", ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"])
    : process.env.DOCKER_HOST || run("docker", ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]));
  // Pin the checked endpoint for every later call. Never dump daemon/container env.
  const dockerEnv = { ...process.env, DOCKER_CONTEXT: "", DOCKER_HOST: endpoint };
  const docker = (args, options = {}) => run("docker", ["--host", endpoint, ...args], { env: dockerEnv, ...options });
  requireWorkstation(docker(["info", "--format", "{{.Name}}"]));
  const prefix = "ops392-lab-" + randomUUID();
  const root = fs.mkdtempSync(path.join(repo, "." + prefix + "-"));
  fs.chmodSync(root, 0o755); // Marker and read-only harness visible to uid 1000.
  let compose;
  let imageBuilt = false;
  const image = prefix + ":local";
  const composeArgs = ["compose", "--project-name", prefix, "--file", path.join(root, "compose.json")];
  const dc = args => docker([...composeArgs, ...args]);
  const exec = (service, args) => dc(["exec", "-T", service, "node", "/lab/container.mjs", ...args]);
  try {
    const settings = readSettings();
    const dockerfile = fs.readFileSync(path.join(settings.context, "Dockerfile"), "utf8");
    const base = [...dockerfile.matchAll(/^FROM (\S+)/gm)].at(-1)[1];
    assert.match(base, /^node:22[^@]*@sha256:[a-f0-9]{64}$/);
    fs.writeFileSync(path.join(root, "marker"), prefix, { flag: "wx", mode: 0o644 });
    // A local socket could forward elsewhere: prove this unique local file is visible.
    assert.equal(docker(["run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true", "-v", `${root}:/lab:ro`, base, "node", "-e", "process.stdout.write(require('node:fs').readFileSync('/lab/marker','utf8'))"]), prefix);
    fs.mkdirSync(path.join(root, "harness"), { mode: 0o755 });
    for (const name of ["container.mjs", "worker-faults.mjs"]) fs.copyFileSync(path.join(repo, "scripts/household-v2-lab", name), path.join(root, "harness", name));
    for (const name of ["pusher-harness.mjs", "pusher-dependencies.mjs"]) fs.copyFileSync(path.join(repo, "hosts/hsb0/docker/joe-board-pusher/fixtures", name), path.join(root, "harness", name));
    docker(["build", "--tag", image, settings.context]);
    imageBuilt = true;
    compose = labCompose(settings, prefix, image, root);
    fs.writeFileSync(path.join(root, "compose.json"), JSON.stringify(compose), { mode: 0o600 });
    dc(["run", "--rm", "--no-deps", "--user", "0:0", "--cap-add", "CHOWN", "stage", "node", "/lab/container.mjs", "init"]);
    dc(["run", "--rm", "--no-deps", "stage", "node", "v2-stage-worker.mjs", "--enroll"]);
    dc(["up", "--detach", "--no-build"]);
    const identity = service => JSON.parse(exec(service, ["identity"]));
    const pusherGroup = await until(() => identity("pusher"));
    const stageGroup = await until(() => identity("stage"));
    assert.notEqual(pusherGroup.memoryCgroup, stageGroup.memoryCgroup, "shared_memory_cgroup");
    assert.equal(Number(stageGroup.memoryLimit), 128 * 1024 * 1024);
    console.log("LAB_DISTINCT_MEMORY_CGROUPS=1");
    const stats = () => JSON.parse(exec("pusher", ["stats"]));
    const pair = () => JSON.parse(exec("stage", ["pair"]));
    const baseline = await until(() => { const s = stats(); return s.posts >= 2 && s; });
    assertCadence(baseline, 30_000);
    let prior = await until(() => pair());
    for (const fault of ["oom", "hang", "kill"]) {
      const started = new Date().toISOString();
      const before = stats();
      const worker = JSON.parse(exec("stage", ["worker"]));
      if (fault === "kill") exec("stage", ["kill"]);
      else exec("stage", ["fault", fault]);
      const recovered = await until(() => {
        const next = pair();
        const currentWorker = JSON.parse(exec("stage", ["worker"]));
        const s = stats();
        return next.seq > prior.seq && currentWorker.pid !== worker.pid && s.posts >= before.posts + 2 && { next, s };
      }, 125_000);
      assertCadence(recovered.s, 30_000);
      if (fault === "oom") {
        const events = docker(["events", "--since", started, "--until", new Date().toISOString(), "--filter", `container=${compose.services.stage.container_name}`, "--filter", "event=oom", "--format", "{{.Action}}"]);
        const after = identity("stage");
        assert.ok(events.split("\n").includes("oom") || after.oomKills > stageGroup.oomKills, "kernel_oom_not_observed");
      }
      prior = recovered.next;
      console.log(`LAB_${fault.toUpperCase()}_RECOVERED=1`);
    }
    const final = stats(); assertCadence(final, 30_000);
    assert.equal(final.boot, baseline.boot, "pusher_restarted");
    console.log(JSON.stringify({ result: "ok", posts: final.posts, intervalMs: 30_000, byteIdentical: true, distinctMemoryCgroups: true, faults: ["oom", "hang", "kill"], validPairSeq: prior.seq }));
  } finally {
    let cleanupFailed = false;
    for (const cleanup of [
      () => { if (compose) dc(["down", "--volumes", "--remove-orphans"]); },
      () => { if (imageBuilt) docker(["image", "rm", image]); },
      () => run("trash", [root]),
    ]) {
      try { cleanup(); } catch { cleanupFailed = true; }
    }
    if (cleanupFailed) throw new Error("lab_cleanup_failed");
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(error => {
    const reason = /^[a-z][a-z0-9_]*$/.test(error.message) ? error.message : "assertion_failed";
    console.error("household_v2_rehearsal_failed", reason); process.exitCode = 1;
  });
}
