#!/usr/bin/env node
// Workstation lab only. Uses local Docker, two exact source archives, the real
// swap script, real app images, extracted edge labels and upstream v2 smoke.
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";
import { randomUUID } from "node:crypto";
import { docker, requireLabDocker, runningImage } from "./joedesk-docker.mjs";
import { legacySmoke } from "./joedesk-legacy-smoke.mjs";
const V1 = "db621bf7f00a4c609b0930ef7d5020f3c8935ee9";
const V2 = "9550f81b448110bfa8fb3ea8df0956430012d5e1";
const repo = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
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
export function createLabRoot(
  base = path.join(os.homedir(), ".cache/joedesk-rehearsal"),
) {
  fs.mkdirSync(base, { recursive: true, mode: 0o700 });
  const root = fs.mkdtempSync(path.join(fs.realpathSync(base), "ops354-"));
  fs.chmodSync(root, 0o700);
  return root;
}
const identityHeaders = [
  "X-Auth-Request-User",
  "X-Auth-Request-Email",
  "X-Auth-Request-Preferred-Username",
  "X-Auth-Request-Groups",
  "X-Forwarded-User",
  "X-Forwarded-Email",
  "X-Forwarded-Preferred-Username",
];
export const spoofHeaders = Object.fromEntries(
  identityHeaders
    .flatMap((name) => [
      name,
      name.replaceAll("-", "_"),
      name.replaceAll("-", "."),
    ])
    .concat(["X-Forwarded_User"])
    .map((name) => [name, "synthetic-spoof"]),
);
export function startLabEdge({ edge, network, root }, command = docker) {
  // Docker does not publish ports for an internal-only container. Publish on
  // bridge first, then attach the edge to the board/auth internal network.
  command([
    "run",
    "-d",
    "--rm",
    "--name",
    edge,
    "--network",
    "bridge",
    "-p",
    "127.0.0.1::8080",
    "-v",
    path.join(root, "dynamic.yml") + ":/dynamic.yml:ro",
    "traefik:v3",
    "--entrypoints.web.address=:8080",
    "--entrypoints.web.http.aliasHeadersStrategy=delete",
    "--providers.file.filename=/dynamic.yml",
  ]);
  command(["network", "connect", network, edge]);
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
  return receipt;
}
// One Linux filesystem holds the active store and every rename/backup sibling.
// The board sees joe-board at its normal /var/lib/joe-board path; helpers see
// the same volume at /lab. Host files are read-only inputs, never the store.
export function labData({ root, candidate, volume, image }, command = docker) {
  if (!/^ops354-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}-data$/.test(volume))
    throw new Error("lab_volume_name_required");
  let created = false;
  const helper = (...args) =>
    command([
      "run",
      "--rm",
      "--network",
      "none",
      "--user",
      "0:0",
      "-v",
      volume + ":/lab",
      "-v",
      path.join(root, "fixtures") + ":/fixtures:ro",
      "-v",
      candidate + ":/source:ro",
      "-v",
      path.join(repo, "scripts") + ":/ops:ro",
      "--entrypoint",
      "node",
      image,
      ...args,
    ]);
  return {
    boardMount: ["-v", volume + ":/var/lib"],
    create() {
      if (created) throw new Error("lab_volume_already_created");
      if (
        command(["volume", "ls", "--format", "{{.Name}}"])
          .split(/\s+/)
          .includes(volume)
      )
        throw new Error("lab_volume_exists");
      command(["volume", "create", volume]);
      created = true;
    },
    cleanup() {
      // Closure binds this exact per-run UUID; never prune or remove an input.
      if (created) {
        command(["volume", "rm", volume]);
        created = false;
      }
    },
    seed() {
      helper(
        "--input-type=module",
        "-e",
        "import fs from 'node:fs'; fs.cpSync('/fixtures/joe-board','/lab/joe-board',{recursive:true,errorOnExist:true,force:false}); fs.chmodSync('/lab/joe-board',0o700);",
      );
    },
    prepare: (...args) => helper("/source/scripts/prepare-data.mjs", ...args),
    swap(direction) {
      return helper(
        "/ops/joedesk-data-swap.mjs",
        direction,
        "--store",
        "/lab/joe-board",
        "--source",
        "/source",
        ...(direction === "forward"
          ? ["--staged", "/lab/staged-v2"]
          : ["--backup", "/lab/v1-backup"]),
        "--lab-root",
        "/lab",
        "--gid",
        "1000",
        "--writers-stopped",
      );
    },
    readBackupFile(file) {
      if (path.posix.dirname(file) !== "/lab/v1-backup")
        throw new Error("lab_backup_path_required");
      // Transport bytes without docker()'s whitespace trimming changing them.
      return Buffer.from(
        helper(
          "--input-type=module",
          "-e",
          "import fs from 'node:fs'; process.stdout.write(fs.readFileSync(process.argv[1]).toString('base64'));",
          file,
        ),
        "base64",
      );
    },
    ownership: () =>
      helper(
        "--input-type=module",
        "-e",
        "import fs from 'node:fs'; const d='/lab/joe-board'; for(const p of [d,...fs.readdirSync(d).map(n=>d+'/'+n)]) { const s=fs.statSync(p); if(s.uid!==1000||s.gid!==1000||(s.mode&511)!==(s.isDirectory()?448:384)) throw Error('ownership'); } console.log('ok');",
      ),
  };
}
export function prepareLabData(data, receipt) {
  data.seed();
  data.prepare("backup", "--offline", "/lab/joe-board", "/lab/v1-backup", "v1");
  data.prepare("verify", "--offline", "/lab/v1-backup");
  data.prepare(
    "migrate-v2",
    "--offline",
    "/lab/v1-backup",
    "/lab/staged-v2",
    "/fixtures/snapshot.json",
    receipt,
  );
  data.swap("forward");
}
const authStub = `import http from 'node:http';
http.createServer((req,res)=>{
  if(${JSON.stringify(Object.keys(spoofHeaders).map((h) => h.toLowerCase()))}.some(h=>req.headers[h])) { res.writeHead(500);res.end();return; }
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
        ...spoofHeaders,
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
    labRoot,
    dryRun = false;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--source") source = fs.realpathSync(args[++i]);
    else if (args[i] === "--lab-root" && args[i + 1])
      labRoot = path.resolve(args[++i]);
    else if (args[i] === "--dry-run") dryRun = true;
    else throw new Error("usage");
  }
  if (!source || run("git", ["-C", source, "rev-parse", "HEAD"]).trim() !== V2)
    throw new Error("exact_candidate_source_required");
  run(process.execPath, [
    path.join(repo, "tests/T102-joedesk-host-gate.mjs"),
    "--joedesk-source",
    source,
  ]);
  const root = createLabRoot(labRoot);
  if (!dryRun) requireLabDocker(root); // Before archives, data, images or networks.
  const oldSource = path.join(root, "v1-source"),
    candidate = path.join(root, "v2-source");
  exportSource(source, V1, oldSource);
  exportSource(source, V2, candidate);
  const fixtures = path.join(root, "fixtures");
  fs.mkdirSync(fixtures, { mode: 0o700 });
  const receipt = fixture(fixtures, candidate);
  const suffix = randomUUID(),
    network = "ops354-" + suffix,
    volume = network + "-data",
    board = network + "-board",
    auth = network + "-auth",
    edge = network + "-edge";
  if (dryRun) {
    // Exercise the exact container data commands with a recording executor.
    // Real offline backup/swap/restore behavior is covered by T101 below;
    // UID/GID normalization needs the Linux volume in the Docker rehearsal.
    const commands = [];
    const data = labData(
      { root, candidate, volume, image: "candidate-image" },
      (args) => {
        commands.push(args);
        return "";
      },
    );
    try {
      data.create();
      prepareLabData(data, receipt);
      data.swap("rollback");
      data.ownership();
    } finally {
      data.cleanup();
    }
    const tests = spawnSync(
      process.execPath,
      ["--test", path.join(repo, "tests/T101-joedesk-operations.mjs")],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          JOEDESK_TEST_SOURCE: candidate,
          JOEDESK_LEGACY_SOURCE: oldSource,
        },
      },
    );
    if (tests.status !== 0) throw new Error("non_docker_tests_failed");
    console.log(
      JSON.stringify({
        ok: true,
        mode: "non-docker-plan",
        sourcePins: "verified",
        offlineSwapTests: "passed",
        dataFilesystem: "per-run-linux-named-volume",
        boardMount: data.boardMount,
        dataCommands: commands,
        ownership: "1000:1000-0700/0600-pending-docker",
        dockerImagesAndSmokes: "pending",
      }),
    );
    return;
  }
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
  const data = labData({ root, candidate, volume, image });
  try {
    data.create();
    prepareLabData(data, receipt);
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
    fs.writeFileSync(path.join(root, "dynamic.yml"), JSON.stringify(dynamic), {
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
      ...data.boardMount,
      image,
      "node",
      "--input-type=module",
      "-e",
      factory,
    ]);
    startLabEdge({ edge, network, root });
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
        headers: spoofHeaders,
      });
      if (
        response.status !== 200 ||
        response.headers.get("x-joedesk-origin") !== "app"
      )
        throw new Error("lab_exact_health_failed");
      await response.body?.cancel();
    }
    for (const route of [
      "",
      "data.json",
      "history.json",
      "fleet-config.json",
      "inbox/results",
    ]) {
      for (const method of ["GET", "HEAD"]) {
        const response = await fetch(base + route, {
          method,
          redirect: "manual",
          headers: spoofHeaders,
        });
        if (response.status !== 401 || response.headers.has("x-joedesk-origin"))
          throw new Error("lab_alias_identity_bypass");
        await response.body?.cancel();
      }
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
    data.swap("rollback");
    docker([
      "run",
      "-d",
      "--rm",
      "--name",
      board,
      "--network",
      network,
      ...data.boardMount,
      oldImage,
    ]);
    await waitHealth(base, false);
    const rollback = await legacySmoke({
      container: board,
      image: oldImage,
      backup: "/lab/v1-backup",
      readBackupFile: data.readBackupFile,
      base,
      cookieJar,
    });
    const ownership = data.ownership();
    if (rollback.ok !== true || ownership !== "ok")
      throw new Error("rollback_smoke_failed");
    console.log(
      JSON.stringify({
        ok: true,
        sourcePins: "verified",
        images: "built-and-bound",
        dataFilesystem: "per-run-linux-named-volume",
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
    data.cleanup();
    // Retain this run's read-only inputs and images for inspection. Mutable
    // synthetic data lived only in the just-removed per-run Linux volume.
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
