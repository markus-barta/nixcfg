import "../../tests/paper-desk-account-fixture.mjs";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { openLedger } from "./state.mjs";
import { openJournal } from "../joe-results-producer/journal.mjs";

const moduleDir = path.dirname(fileURLToPath(import.meta.url));

// Run the actual entry point across restarts. Only transports and the broker
// runtime are synthetic; capture, migration, saves and journal I/O are real.
const boot = String.raw`
  import fs from "node:fs";
  import http from "node:http";
  import net from "node:net";
  import { EventEmitter } from "node:events";
  import { Readable } from "node:stream";
  import { registerHooks, syncBuiltinESMExports } from "node:module";
  import { pathToFileURL } from "node:url";
  const [entry, capturePath, root, mode, run] = process.argv.slice(1);
  Object.assign(process.env, { IB_DESK_ACCOUNT: "DU0000001", PAPER_DESK_STATE_DIR: root,
    PAPER_DESK_RESULTS_CAPTURE: "true", PAPER_DESK_ALLOW: '["100.64.0.14"]' });
  const journalInode = fs.statSync(root + "/results-input.jsonl").ino;
  let storageFailed = true;
  const failure = () => Object.assign(new Error("synthetic-private-value /synthetic/path"), { code: "ENOSPC" });
  for (const operation of ["writeSync", "fsyncSync"]) {
    const original = fs[operation];
    fs[operation] = (fd, ...args) => {
      if (mode === (operation === "writeSync" ? "append" : "fsync") && fs.fstatSync(fd).ino === journalInode) throw failure();
      return original(fd, ...args);
    };
  }
  const rename = fs.renameSync;
  fs.renameSync = (from, to) => {
    if (mode === "migration-persist" && storageFailed && to === root + "/ledger.json") throw failure();
    return rename(from, to);
  };
  let intentServer, ready;
  const listening = new Promise(resolve => { ready = resolve; });
  const logs = [];
  console.error = (...args) => {
    logs.push(args.map(value => String(value)).join(" "));
    if (String(args[0]).startsWith("paper-desk-executor listening")) ready();
  };
  http.Server.prototype.listen = function(port, host, callback) {
    if (port === 8470) intentServer = this;
    queueMicrotask(() => { this.emit("listening"); callback?.(); });
    return this;
  };
  http.Server.prototype.address = () => ({ address: "100.64.0.6", port: 8470 });
  net.connect = () => {
    const socket = new EventEmitter();
    socket.setTimeout = () => socket;
    socket.destroy = () => {};
    queueMicrotask(() => socket.emit("error", new Error("synthetic gateway offline")));
    return socket;
  };
  syncBuiltinESMExports();
  registerHooks({ resolve(specifier, context, next) {
    if (context.parentURL === pathToFileURL(entry).href && specifier === "./results/capture.mjs") return { url: pathToFileURL(capturePath).href, shortCircuit: true };
    if (context.parentURL === pathToFileURL(entry).href && specifier === "./executor.mjs") return { url: 'data:text/javascript,' + encodeURIComponent('export function assertRuntime() {} export async function executeIntent(intent) { return { status: "ok", action: intent.action, intentId: intent.intentId, desk: intent.desk, observedAt: new Date().toISOString(), executions: [] }; }'), shortCircuit: true };
    return next(specifier, context);
  } });
  process.argv[1] = entry;
  await import(pathToFileURL(entry).href);
  const deadline = setTimeout(() => { process.stderr.write("startup deadline"); process.exit(2); }, 5000);
  await listening;
  function request(method, url, body) {
    return new Promise(resolve => {
      const req = Readable.from(body ? [Buffer.from(JSON.stringify(body))] : []);
      Object.assign(req, { method, url, headers: {}, socket: { remoteAddress: "100.64.0.14" } });
      const res = { headersSent: false, writeHead(status) { this.status = status; this.headersSent = true; },
        end(body) { resolve({ status: this.status, body: JSON.parse(body) }); } };
      intentServer.emit("request", req, res);
    });
  }
  const health = await request("GET", "/v1/health");
  storageFailed = false;
  const recon = await request("POST", "/v1/intents", { schema: "barta.paper-desk-intent.v2", intentId: "synthetic-startup-" + run,
    desk: "j", action: "recon", createdAt: new Date(Date.now() - 1000).toISOString(), expiresAt: new Date(Date.now() + 60000).toISOString() });
  clearTimeout(deadline);
  process.stdout.write(JSON.stringify({ health, recon, logs }));
  process.exit(0);
`;

for (const mode of ["fsync", "append", "migration-persist"]) {
  test(`startup ${mode} ENOSPC fails open across restart and still accepts recon`, t => {
    const root = mkdtempSync(path.join(tmpdir(), "joed43-startup-"));
    t.after(() => rmSync(root, { recursive: true, force: true }));
    const ledger = openLedger(root);
    ledger.load();
    const legacy = JSON.parse(readFileSync(ledger.statePath));
    delete legacy.reconStorageVersion;
    legacy.intents["synthetic-legacy-recon"] = { action: "recon", desk: "j", status: "done", finishedAt: new Date().toISOString(),
      result: { status: "ok", executions: [{ evidence: "synthetic-retained-evidence" }] } };
    writeFileSync(ledger.statePath, JSON.stringify(legacy));
    const journal = openJournal(path.join(root, "results-input.jsonl"));
    journal.append({ type: "start", at: new Date().toISOString() });
    journal.close();
    for (const run of [1, 2]) {
      const result = spawnSync(process.execPath, ["--input-type=module", "-e", boot,
        path.resolve(moduleDir, "server.mjs"), path.resolve(moduleDir, "../joe-results-producer/capture.mjs"), root, mode, String(run)],
      { encoding: "utf8", timeout: 10000 });
      assert.equal(result.error, undefined);
      assert.equal(result.status, 0, "capture/storage failure must leave main listening");
      const { health, recon, logs } = JSON.parse(result.stdout);
      assert.equal(health.status, 200);
      assert.equal(health.body.resultsCapture.state, "degraded");
      assert.equal(recon.status, 200);
      assert.equal(recon.body.status, "ok");
      assert.doesNotMatch(logs.join("\n"), /synthetic-private-value|synthetic\/path/);
      const disk = JSON.parse(readFileSync(ledger.statePath));
      assert.equal(disk.intents[`synthetic-startup-${run}`].status, "done");
      assert.ok(disk.resultsCaptureAlerts.some(row => row.code === "ENOSPC"));
      if (mode !== "migration-persist") {
        assert.deepEqual(disk.intents["synthetic-legacy-recon"], legacy.intents["synthetic-legacy-recon"]);
      } else {
        assert.equal(disk.resultsCapture.ok, true);
        assert.ok(disk.resultsCaptureAlerts.every(row => row.resolvedAt));
      }
    }
  });
}
