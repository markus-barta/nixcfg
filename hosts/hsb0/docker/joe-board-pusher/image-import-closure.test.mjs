import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(root, "../../../..");
const imagePath = value => path.posix.resolve("/app", value);
const read = file => fs.readFileSync(file, "utf8");

function copyTree(files, source, destination) {
  if (fs.statSync(source).isDirectory()) {
    for (const name of fs.readdirSync(source)) copyTree(files, path.join(source, name), path.posix.join(destination, name));
  } else files.set(destination, read(source));
}

// Process every COPY, including directory contents and continuation/JSON forms.
// Keep stages separate: a builder-only source cannot satisfy a runtime import.
function dockerFiles(dockerfile) {
  const stages = new Map();
  let files;
  let workdir = "/";
  let cmd = [];
  let stageIndex = 0;
  for (const raw of dockerfile.replace(/\\\r?\n\s*/g, " ").split(/\r?\n/)) {
    const line = raw.trim();
    if (/^FROM\s/i.test(line)) {
      files = new Map();
      const alias = line.match(/\sAS\s+(\S+)$/i)?.[1];
      stages.set(String(stageIndex++), files);
      if (alias) stages.set(alias, files);
      workdir = "/";
    } else if (/^WORKDIR\s/i.test(line)) {
      workdir = path.posix.resolve(workdir, line.replace(/^WORKDIR\s+/i, ""));
    } else if (/^CMD\s/i.test(line)) {
      cmd = JSON.parse(line.replace(/^CMD\s+/i, ""));
    } else if (/^COPY\s/i.test(line)) {
      let args = line.replace(/^COPY\s+/i, "");
      const flags = [];
      while (args.startsWith("--")) {
        const flag = args.match(/^--\S+\s+/);
        assert.ok(flag, `unsupported COPY flags: ${line}`);
        flags.push(flag[0].trim());
        args = args.slice(flag[0].length);
      }
      const words = args.startsWith("[") ? JSON.parse(args)
        : [...args.matchAll(/"([^"]*)"|'([^']*)'|(\S+)/g)].map(match => match[1] ?? match[2] ?? match[3]);
      const destination = words.pop();
      const target = path.posix.resolve(workdir, destination);
      const from = flags.find(flag => flag.startsWith("--from="))?.slice(7);
      for (const source of words) {
        if (from) {
          // Generated SDK/system files contain no repository JS modules.
          for (const [name, contents] of stages.get(from) ?? []) {
            const prefix = source.replace(/\/$/, "") + "/";
            if (name === source) files.set(destination.endsWith("/") ? path.posix.join(target, path.posix.basename(source)) : target, contents);
            else if (name.startsWith(prefix)) files.set(path.posix.join(target, name.slice(prefix.length)), contents);
          }
        } else {
          assert.doesNotMatch(source, /[*?$]/, `unsupported COPY source: ${source}`);
          const local = path.resolve(root, source);
          const directory = fs.statSync(local).isDirectory();
          const to = !directory && (destination.endsWith("/") || words.length > 1)
            ? path.posix.join(target, path.basename(local)) : target;
          copyTree(files, local, to);
        }
      }
    }
  }
  return { files, cmd };
}

function publishedFiles(files, nixFile, destination) {
  const nix = read(nixFile);
  for (const match of nix.matchAll(/\bcp\s+(?:-r\s+)?\$\{(\.[^}]+)\}\s+"\$out(?:\/([^"\n]+))?"/g)) {
    copyTree(files, path.resolve(path.dirname(nixFile), match[1]), path.posix.join(destination, match[2] ?? ""));
  }
  for (const match of nix.matchAll(/substituteInPlace "\$out\/([^"]+)" --replace-fail '([^']+)' '([^']+)'/g)) {
    const target = path.posix.join(destination, match[1]);
    assert.ok(files.get(target)?.includes(match[2]), `unhandled mounted-source substitution: ${target}`);
    files.set(target, files.get(target).replaceAll(match[2], match[3]));
  }
  return nix;
}

function runtime(dockerfile) {
  const { files, cmd } = dockerFiles(dockerfile);
  const executorPath = path.join(repo, "modules/paper-desk-executor/default.nix");
  const executor = publishedFiles(files, executorPath, "/executor");
  assert.ok(executor.includes('"${source}:/executor:ro"'), "executor source must be mounted at /executor");
  const results = executor.match(/cp -r \$\{import (\.\.\/[^\s]+\/source\.nix)/)?.[1];
  assert.ok(results, "account for the executor's optional results source closure");
  publishedFiles(files, path.resolve(path.dirname(executorPath), results), "/executor/results");

  const entrypoints = new Set(["pusher.mjs", "v2-stage-supervisor.mjs", "v2-stage-worker.mjs",
    "verify-contracts-entry.mjs", "family-history-cli.mjs"].map(imagePath));
  assert.equal(cmd[0], "node");
  for (const token of cmd.slice(1).filter(token => token.endsWith(".mjs"))) entrypoints.add(imagePath(token));
  // Includes split entrypoint = [ "node" ]; command = [ "/executor/server.mjs" ].
  // The executor is mounted source; its imports must come from that publication
  // or the same Dockerfile, never from arbitrary files in the checkout.
  for (const nix of [read(path.join(root, "../compose-spec.nix")), executor]) {
    for (const command of nix.matchAll(/\b(?:command|entrypoint)\s*=\s*(\[[\s\S]*?\]|"[^"\n]*")\s*;/g)) {
      for (const token of command[1].matchAll(/(?:^|["\s])([^"\s]+\.mjs)(?=["\s]|$)/g)) entrypoints.add(imagePath(token[1]));
    }
    for (const command of nix.matchAll(/\bnode\s+["']?((?:\.\/|\/app\/)[\w./-]+\.mjs)/g)) entrypoints.add(imagePath(command[1]));
  }
  return { files, entrypoints };
}

function imports(source) {
  const staticImports = /\b(?:import|export)\s+(?:[^;"']*?\s+from\s*)?(["'])(\.{1,2}\/[^"']+)\1/g;
  const dynamicImports = /\bimport\s*\(\s*(["'])(\.{1,2}\/[^"']+)\1\s*[,)]/g;
  return [...source.matchAll(staticImports), ...source.matchAll(dynamicImports)].map(match => match[2]);
}

function missingImports(files, entrypoints) {
  const visited = new Set();
  const missing = new Set();
  const visit = (module, importer = "entrypoint") => {
    if (!files.has(module)) { missing.add(`${module} (imported by ${importer})`); return; }
    if (visited.has(module)) return;
    visited.add(module);
    if (!/\.[cm]?js$/.test(module)) return;
    for (const specifier of imports(files.get(module))) visit(path.posix.resolve(path.posix.dirname(module), specifier), module);
  };
  for (const entrypoint of entrypoints) visit(entrypoint);
  return [...missing].sort();
}

test("Dockerfile COPY contains the full import closure of every Node entrypoint", () => {
  const { files, entrypoints } = runtime(read(path.join(root, "Dockerfile")));
  assert.ok(entrypoints.has("/executor/server.mjs"), "include the executor's declared command");
  assert.deepEqual(missingImports(files, entrypoints), [], "modules missing from Dockerfile COPY or declared runtime mounts");
});

test("image closure guard rejects the pre-fix missing executor-attribution COPY", () => {
  const dockerfile = read(path.join(root, "Dockerfile")).replace(/\bexecutor-attribution\.mjs\s*/g, "");
  const { files, entrypoints } = runtime(dockerfile);
  assert.ok(missingImports(files, entrypoints).some(message => message.startsWith("/app/executor-attribution.mjs ")));
});

test("image closure follows re-exports, side-effect imports and literal dynamic imports transitively", () => {
  const files = new Map([
    ["/app/start.mjs", 'import { value } from "./one.mjs";'],
    ["/app/one.mjs", 'export { value } from "./two.mjs";'],
    ["/app/two.mjs", 'import "./side.mjs"; export const value = import("./contracts/lazy.mjs");'],
    ["/app/side.mjs", ""],
    ["/app/contracts/lazy.mjs", 'export * from "../missing.mjs";'],
  ]);
  assert.deepEqual(missingImports(files, ["/app/start.mjs"]), ["/app/missing.mjs (imported by /app/contracts/lazy.mjs)"]);
});

test("COPY parser includes files and directories from all runtime COPY instructions", () => {
  const { files } = dockerFiles(`FROM scratch AS builder
WORKDIR /builder
COPY executor-attribution.mjs ./
FROM scratch
WORKDIR /app
COPY ["pusher.mjs", "./"]
COPY --chown=node:node contracts/ ./contracts/
COPY project.mjs \\
  positions-state.mjs ./
CMD ["node", "pusher.mjs"]`);
  for (const module of ["pusher.mjs", "project.mjs", "positions-state.mjs", "contracts/index.mjs", "contracts/data.schema.json"]) {
    assert.ok(files.has(imagePath(module)), module);
  }
  assert.equal(files.has("/builder/executor-attribution.mjs"), false);
  assert.equal(files.has("/app/executor-attribution.mjs"), false, "builder-only COPY must not satisfy a runtime dependency");
});
