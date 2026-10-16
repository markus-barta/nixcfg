#!/usr/bin/env node
// Workstation lab only. Uses local Docker, two exact source archives, the real
// swap script, real app images, extracted edge labels and upstream v2 smoke.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { randomUUID, createHash } from "node:crypto";
import { docker, localDockerSocket, runningImage } from "./joedesk-docker.mjs";
import { requireSafeHost, runSwap } from "./joedesk-data-swap.mjs";
import { legacySmoke } from "./joedesk-legacy-smoke.mjs";
const V1 = "db621bf7f00a4c609b0930ef7d5020f3c8935ee9";
const V2 = "9550f81b448110bfa8fb3ea8df0956430012d5e1";
const repo = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const hash = (b) => createHash("sha256").update(b).digest("hex");
function run(command, args, options = {}) {
  try {
    return execFileSync(command, args, {
      encoding: "utf8",
      stdio: ["pipe", "pipe", "pipe"],
      maxBuffer: 32 * 1024 * 1024,
      ...options,
    });
  } catch {
    throw new Error("rehearsal_command_failed");
  }
}
export function requireWorkstation(hostname = os.hostname()) {
  if (/^(csb|hsb|agm)/i.test(hostname.split(".")[0]))
    throw new Error("fleet_is_not_a_lab");
}
export function labelsToDynamic(joeLabels, authLabels, board, auth) {
  const http = {
    routers: {},
    middlewares: {},
    services: {
      "joe-board-csb0": {
        loadBalancer: { servers: [{ url: "http://" + board + ":8080" }] },
      },
    },
  };
  for (const label of [...joeLabels, ...authLabels]) {
    const at = label.indexOf("="),
      key = label.slice(0, at),
      value = label.slice(at + 1);
    const parts = key.split(".");
    if (parts[0] !== "traefik" || parts[1] !== "http") continue;
    const [, , kind, name, field, sub, ...tail] = parts;
    if (kind === "routers") {
      const router = (http.routers[name] ||= {});
      if (field === "tls") continue;
      if (field === "rule")
        router.rule = value.replace(
          "Host(`cs0.barta.cm`)",
          "Host(`127.0.0.1`)",
        );
      else if (field === "entrypoints") router.entryPoints = ["web"];
      else if (field === "middlewares")
        router.middlewares = value.replaceAll("@docker", "@file").split(",");
      else if (field === "priority") router.priority = Number(value);
      else router[field] = value;
    } else if (kind === "middlewares") {
      const middleware = (http.middlewares[name] ||= {});
      if (field === "headers" && sub === "customrequestheaders") {
        middleware.headers ||= { customRequestHeaders: {} };
        middleware.headers.customRequestHeaders[tail.join(".")] = value;
      } else if (field === "redirectregex") {
        middleware.redirectRegex ||= {};
        middleware.redirectRegex[sub] =
          sub === "permanent" ? value === "true" : value.replaceAll("$$", "$");
      } else if (field === "forwardauth") {
        middleware.forwardAuth ||= {};
        if (sub === "address")
          middleware.forwardAuth.address = "http://" + auth + ":4180/";
        else if (sub === "authResponseHeaders")
          middleware.forwardAuth[sub] = value.split(",");
        else if (sub === "trustForwardHeader")
          middleware.forwardAuth[sub] = value === "true";
        else throw new Error("unsupported_auth_label");
      } else throw new Error("unsupported_middleware_label");
    }
  }
  return { http };
}
function exportSource(source, rev, destination) {
  fs.mkdirSync(destination, { mode: 0o700 });
  const files = run("git", ["-C", source, "ls-tree", "-r", "--name-only", rev])
    .trim()
    .split("\n");
  if (
    files.some((f) => /(^|\/)(\.env(?:\..*)?|id_[^/]+)$|\.(age|gpg)$/.test(f))
  )
    throw new Error("source_contains_forbidden_files");
  run("tar", ["-xf", "-", "-C", destination], {
    input: run("git", ["-C", source, "archive", rev], { encoding: "buffer" }),
  });
}
function fixture(root, source) {
  const samples = JSON.parse(
    fs.readFileSync(path.join(source, "fixtures/valid.json")),
  );
  const snapshot = structuredClone(samples.data),
    receipt = snapshot.receivedAt;
  delete snapshot.receivedAt;
  const store = path.join(root, "joe-board");
  fs.mkdirSync(store, { mode: 0o700 });
  const put = (name, value) =>
    fs.writeFileSync(path.join(store, name), JSON.stringify(value), {
      mode: 0o600,
    });
  put("data.json", {
    schema: "inspr.joe.household.v1",
    sentinel: "synthetic legacy fixture",
  });
  put("history.json", { schema: "inspr.joe.household.history.v1", points: [] });
  put("fleet-config.json", samples["fleet-config"]);
  put("fleet-config-actions.json", {
    schema: "inspr.joe.fleet-config.actions.v1",
    entries: [],
  });
  fs.writeFileSync(path.join(root, "snapshot.json"), JSON.stringify(snapshot), {
    mode: 0o600,
  });
  return { store, receipt };
}
const authStub = `import http from 'node:http';
http.createServer((req,res)=>{
  if(['x-auth-request-user','x-auth-request-email','x-forwarded-user'].some(h=>req.headers[h])) { res.writeHead(500);res.end();return; }
  if((req.headers.cookie||'').split(';').some(c=>c.trim()==='lab=authenticated')) { res.writeHead(200,{'X-Auth-Request-User':'lab-authenticated','X-Auth-Request-Email':'lab-authenticated'});res.end();return; }
  res.writeHead(401,{'content-type':'application/json'});res.end('{"error":"unauthenticated"}');
}).listen(4180,'0.0.0.0');`;
async function waitHealth(base, v2 = true) {
  for (let n = 0; n < 60; n++) {
    try {
      const r = await fetch(base + (v2 ? "healthz" : "data.json"), {
        redirect: "manual",
        headers: v2 ? {} : { Cookie: "lab=authenticated" },
        signal: AbortSignal.timeout(1000),
      });
      await r.body?.cancel();
      if (r.status === 200) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error("lab_health_timeout");
}
async function signedInSpoof(base) {
  const request = async (route, options = {}) => {
    const response = await fetch(new URL(route, base), {
      redirect: "manual",
      ...options,
      headers: {
        Cookie: "lab=authenticated",
        "X-Auth-Request-User": "synthetic-spoof",
        "X-Auth-Request-Email": "synthetic-spoof",
        "X-Forwarded-User": "synthetic-spoof",
        ...options.headers,
      },
    });
    if (response.status !== 200) throw new Error("lab_signed_in_spoof_failed");
    return response.json();
  };
  const initial = await request("fleet-config.json");
  async function edit(current, limit) {
    const config = structuredClone(current);
    config.desks.maxBusyDesks = limit;
    const result = await request("fleet-config/propagate", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Origin: new URL(base).origin,
        "Sec-Fetch-Site": "same-origin",
      },
      body: JSON.stringify({ baseRev: current.rev, config }),
    });
    const audit = await request("fleet-config/actions.json");
    const action = audit.entries.at(-1);
    if (
      action.actor !== "lab-authenticated" ||
      action.outcome !== "success" ||
      !action.changedKeys.includes("desks.maxBusyDesks")
    )
      throw new Error("lab_actor_not_replaced");
    return request("fleet-config.json");
  }
  const oldLimit = initial.desks.maxBusyDesks;
  const changed = await edit(initial, oldLimit === 32 ? 31 : oldLimit + 1);
  await edit(changed, oldLimit);
}
async function main() {
  requireWorkstation(); // Before any source work or Docker command.
  const args = process.argv.slice(2);
  let source,
    dryRun = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--source") source = fs.realpathSync(args[++i]);
    else if (args[i] === "--dry-run") dryRun = true;
    else throw new Error("usage");
  }
  if (!source || run("git", ["-C", source, "rev-parse", "HEAD"]).trim() !== V2)
    throw new Error("exact_candidate_source_required");
  const root = fs.mkdtempSync(
    path.join(fs.realpathSync(os.tmpdir()), "ops354-rehearsal-"),
  );
  fs.chmodSync(root, 0o700);
  const oldSource = path.join(root, "v1-source"),
    candidate = path.join(root, "v2-source");
  exportSource(source, V1, oldSource);
  exportSource(source, V2, candidate);
  const { store, receipt } = fixture(root, candidate),
    backup = path.join(root, "v1-backup"),
    staged = path.join(root, "staged-v2");
  const original = Object.fromEntries(
    fs
      .readdirSync(store)
      .map((n) => [n, hash(fs.readFileSync(path.join(store, n)))]),
  );
  if (dryRun) {
    const prepare = (...rest) =>
      run(process.execPath, [
        path.join(candidate, "scripts/prepare-data.mjs"),
        ...rest,
      ]);
    prepare("backup", "--offline", store, backup, "v1");
    prepare("verify", "--offline", backup);
    prepare(
      "migrate-v2",
      "--offline",
      backup,
      staged,
      path.join(root, "snapshot.json"),
      receipt,
    );
    const options = {
      store,
      source: candidate,
      labRoot: root,
      uid: process.getuid(),
      gid: process.getgid(),
      writersStopped: true,
    };
    runSwap({ ...options, direction: "forward", staged });
    runSwap({ ...options, direction: "rollback", backup });
    for (const [name, digest] of Object.entries(original))
      if (hash(fs.readFileSync(path.join(store, name))) !== digest)
        throw new Error("dry_run_restore_mismatch");
    const tests = spawnSync(
      process.execPath,
      ["--test", path.join(repo, "tests/T101-joedesk-operations.mjs")],
      {
        encoding: "utf8",
        env: { ...process.env, JOEDESK_TEST_SOURCE: candidate },
      },
    );
    if (tests.status !== 0) throw new Error("non_docker_tests_failed");
    console.log(
      JSON.stringify({
        ok: true,
        mode: "non-docker",
        sourcePins: "verified",
        backup: "verified",
        forwardSwap: "passed",
        rollbackSwap: "exact-v1-bytes",
        ownership: "current-lab-user",
        recoveryGuards: "passed",
        dockerImagesAndSmokes: "pending",
      }),
    );
    return;
  }
  localDockerSocket(); // Reject remote Docker contexts, including DOCKER_HOST.
  const suffix = randomUUID(),
    network = "ops354-" + suffix,
    board = network + "-board",
    auth = network + "-auth",
    edge = network + "-edge";
  docker([
    "build",
    "--quiet",
    "--iidfile",
    path.join(root, "v1.iid"),
    "-t",
    network + ":v1",
    oldSource,
  ]);
  docker([
    "build",
    "--quiet",
    "--iidfile",
    path.join(root, "v2.iid"),
    "-t",
    network + ":v2",
    candidate,
  ]);
  const oldImage = fs.readFileSync(path.join(root, "v1.iid"), "utf8").trim(),
    image = fs.readFileSync(path.join(root, "v2.iid"), "utf8").trim();
  for (const id of [oldImage, image])
    if (!/^sha256:[0-9a-f]{64}$/.test(id))
      throw new Error("built_image_id_required");
  const helperAs = (user, ...rest) =>
    docker([
      "run",
      "--rm",
      "--network",
      "none",
      "--user",
      user,
      "-v",
      root + ":/lab",
      "-v",
      candidate + ":/source:ro",
      "-v",
      path.join(repo, "scripts") + ":/ops:ro",
      "--entrypoint",
      "node",
      image,
      ...rest,
    ]);
  const helper = (...rest) => helperAs("0:0", ...rest);
  // Keep the private backup readable by the workstation operator. Only the
  // shared swap runs as root to normalize the active store to 1000:1000.
  const prepare = (...rest) =>
    helperAs(
      process.getuid() + ":" + process.getgid(),
      "/source/scripts/prepare-data.mjs",
      ...rest,
    );
  prepare("backup", "--offline", "/lab/joe-board", "/lab/v1-backup", "v1");
  prepare("verify", "--offline", "/lab/v1-backup");
  prepare(
    "migrate-v2",
    "--offline",
    "/lab/v1-backup",
    "/lab/staged-v2",
    "/lab/snapshot.json",
    receipt,
  );
  helper(
    "/ops/joedesk-data-swap.mjs",
    "forward",
    "--store",
    "/lab/joe-board",
    "--source",
    "/source",
    "--staged",
    "/lab/staged-v2",
    "--lab-root",
    "/lab",
    "--gid",
    "1000",
    "--writers-stopped",
  );
  const labels = JSON.parse(
    run("nix", [
      "eval",
      "--json",
      "--file",
      path.join(repo, "hosts/csb0/docker/compose-spec.nix"),
      "--apply",
      'spec: { joe = spec.services.joe-board.labels; auth = builtins.filter (label: builtins.match "traefik.http.middlewares.hostdash-auth-csb0.*" label != null) spec.services.hostdash.labels; }',
    ]),
  );
  const dynamic = labelsToDynamic(labels.joe, labels.auth, board, auth);
  fs.writeFileSync(path.join(root, "dynamic.json"), JSON.stringify(dynamic), {
    mode: 0o644,
  });
  fs.writeFileSync(path.join(root, "auth.mjs"), authStub, { mode: 0o644 });
  const cookieJar = path.join(root, "cookies.txt");
  fs.writeFileSync(
    cookieJar,
    "# Netscape HTTP Cookie File\n127.0.0.1\tFALSE\t/\tFALSE\t0\tlab\tauthenticated\n",
    { mode: 0o600 },
  );
  docker(["network", "create", "--internal", network]);
  try {
    docker([
      "run",
      "-d",
      "--rm",
      "--name",
      auth,
      "--network",
      network,
      "-v",
      path.join(root, "auth.mjs") + ":/lab-auth.mjs:ro",
      image,
      "node",
      "/lab-auth.mjs",
    ]);
    const factory =
      "import {createJoeServer} from '/app/server.mjs'; createJoeServer({clock:()=>" +
      JSON.stringify(receipt) +
      ",inboxToken:'synthetic-lab-inbox-token'}).listen(8080,'0.0.0.0');";
    docker([
      "run",
      "-d",
      "--rm",
      "--name",
      board,
      "--network",
      network,
      "-v",
      store + ":/var/lib/joe-board",
      image,
      "node",
      "--input-type=module",
      "-e",
      factory,
    ]);
    docker([
      "run",
      "-d",
      "--rm",
      "--name",
      edge,
      "--network",
      network,
      "-p",
      "127.0.0.1::8080",
      "-v",
      path.join(root, "dynamic.json") + ":/dynamic.json:ro",
      "traefik:v3",
      "--entrypoints.web.address=:8080",
      "--providers.file.filename=/dynamic.json",
    ]);
    const port = docker(["port", edge, "8080/tcp"]);
    if (!/^127\.0\.0\.1:\d+$/.test(port))
      throw new Error("loopback_edge_required");
    const base = "http://" + port + "/joe/";
    await waitHealth(base);
    if ((await runningImage(board)) !== image)
      throw new Error("candidate_image_mismatch");
    const release = JSON.parse(
      fs.readFileSync(path.join(candidate, "release.json")),
    );
    const evidence = JSON.parse(
      run(process.execPath, [
        path.join(candidate, "scripts/smoke-release.mjs"),
        base,
        release.version_scheme,
        release.version,
      ]),
    );
    if (evidence.ok !== true) throw new Error("forward_smoke_failed");
    for (const method of ["GET", "HEAD"]) {
      const response = await fetch(base + "healthz", {
        method,
        redirect: "manual",
        headers: {
          "X-Auth-Request-User": "synthetic-spoof",
          "X-Auth-Request-Email": "synthetic-spoof",
          "X-Forwarded-User": "synthetic-spoof",
        },
      });
      if (
        response.status !== 200 ||
        response.headers.get("x-joedesk-origin") !== "app"
      )
        throw new Error("lab_exact_health_failed");
      await response.body?.cancel();
    }
    for (const route of ["healthz", "inbox/results/", "inbox/resultsx"]) {
      const response = await fetch(base + route, {
        method: "POST",
        redirect: "manual",
      });
      if (response.status !== 401 || response.headers.has("x-joedesk-origin"))
        throw new Error("lab_protected_negative_failed");
      await response.body?.cancel();
    }
    await signedInSpoof(base);
    docker(["stop", board]);
    helper(
      "/ops/joedesk-data-swap.mjs",
      "rollback",
      "--store",
      "/lab/joe-board",
      "--source",
      "/source",
      "--backup",
      "/lab/v1-backup",
      "--lab-root",
      "/lab",
      "--gid",
      "1000",
      "--writers-stopped",
    );
    docker([
      "run",
      "-d",
      "--rm",
      "--name",
      board,
      "--network",
      network,
      "-v",
      store + ":/var/lib/joe-board",
      oldImage,
    ]);
    await waitHealth(base, false);
    const rollback = await legacySmoke({
      container: board,
      image: oldImage,
      backup,
      base,
      cookieJar,
    });
    const ownership = helper(
      "--input-type=module",
      "-e",
      "import fs from 'node:fs'; const d='/lab/joe-board'; for(const p of [d,...fs.readdirSync(d).map(n=>d+'/'+n)]) { const s=fs.statSync(p); if(s.uid!==1000||s.gid!==1000||(s.mode&511)!==(s.isDirectory()?448:384)) throw Error('ownership'); } console.log('ok');",
    );
    if (rollback.ok !== true || ownership !== "ok")
      throw new Error("rollback_smoke_failed");
    console.log(
      JSON.stringify({
        ok: true,
        sourcePins: "verified",
        images: "built-and-bound",
        backup: "verified-v1",
        forwardSmoke: "passed",
        edge: "traefik-v3-extracted-labels",
        signedInSpoof: "actor-replaced-and-setting-restored",
        swap: "same-production-script",
        ownership: "1000:1000-0700/0600",
        rollbackSmoke: "exact-v1-image-and-data",
        productionEvidence: "still-required",
      }),
    );
  } finally {
    for (const name of [board, edge, auth]) {
      try {
        docker(["stop", name]);
      } catch {}
    }
    try {
      docker(["network", "rm", network]);
    } catch {}
    // Retain only this lab's source archives, images, data and receipts for
    // inspection; no deletion of any pre-existing workstation artifact.
  }
}
if (
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
) {
  try {
    await main();
  } catch (error) {
    console.error(
      "joedesk_rehearsal_failed: " +
        (/^[a-z0-9_]+$/.test(error.message)
          ? error.message
          : "preflight_or_io_error"),
    );
    process.exitCode = 1;
  }
}
