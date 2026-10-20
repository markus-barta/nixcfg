// Synthetic entry points and assertions, mounted read-only by the local lab.
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { installPusherDoubles, syntheticState } from "./pusher-harness.mjs";

const statePath = "/var/lib/joe-board-pusher/v2";
const ipcPath = "/run/joe-household-v2";
const mode = process.argv[2];
const output = value => console.log(JSON.stringify(value));
function workerPid() {
  const workers = fs.readdirSync("/proc").filter(name => /^\d+$/.test(name)).filter(name => {
    try {
      const args = fs.readFileSync(`/proc/${name}/cmdline`, "utf8").split("\0");
      return args.includes("--lock-held") && args.some(arg => arg.endsWith("/v2-stage-worker.mjs"));
    } catch { return false; }
  });
  assert.equal(workers.length, 1); return Number(workers[0]);
}
if (mode === "init") {
  for (const directory of [statePath, ipcPath]) { fs.chmodSync(directory, 0o700); fs.chownSync(directory, 1000, 1000); }
} else if (mode === "stage") {
  const { createStageSupervisor } = await import("/app/v2-stage-supervisor.mjs");
  const { launchLocked } = await import("/app/v2-stage-worker.mjs");
  const supervisor = createStageSupervisor({ launch: () => launchLocked({
    spawnWorker(command, args, options) {
      const at = args.indexOf(process.execPath);
      assert.ok(at >= 0);
      args.splice(at + 1, 0, "--import", "/lab/worker-faults.mjs");
      return spawn(command, args, options);
    },
  }) });
  for (const signal of ["SIGINT", "SIGTERM"]) process.on(signal, () => supervisor.stop());
} else if (mode === "pusher") {
  const RealDate = Date;
  const instant = new RealDate(RealDate.now() - 60_000).toISOString();
  const state = syntheticState("normal", instant);
  const pusher = "file:///app/pusher.mjs";
  installPusherDoubles(pusher, state, true);
  process.env.JOE_FLAT_NET_MARKS = "0";
  globalThis.Date = class extends RealDate { constructor(...args) { super(...(args.length ? args : [instant])); } };
  const boot = randomUUID(), received = [], gaps = [];
  let first, equal = true, failures = 0;
  const logError = console.error;
  console.error = () => { failures++; };
  const server = http.createServer((req, res) => {
    if (req.method === "POST" && req.url === "/inbox") {
      const chunks = []; let size = 0;
      req.on("data", bytes => { size += bytes.length; assert.ok(size <= 262144); chunks.push(bytes); });
      req.on("end", () => {
        const bytes = Buffer.concat(chunks);
        first ??= bytes; equal &&= first.equals(bytes);
        const now = performance.now();
        if (received.length) gaps.push(now - received.at(-1));
        received.push(now);
        res.writeHead(200, { "content-type": "application/json" }); res.end('{"ok":true}');
      });
    } else if (req.method === "GET" && req.url === "/stats") {
      res.end(JSON.stringify({ posts: received.length, gaps, equal, boot, failures }));
    } else { res.writeHead(404); res.end(); }
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  // Export only the synthetic loopback port for exec-side stats, via IPC volume.
  fs.writeFileSync(`${ipcPath}/lab-inbox-port`, String(port), { mode: 0o600 });
  const send = globalThis.fetch;
  globalThis.fetch = (url, options) => {
    assert.equal(url, "https://cs0.barta.cm/joe/inbox");
    assert.equal(options.headers.Authorization, "Bearer synthetic-test-token");
    return send(`http://127.0.0.1:${port}/inbox`, options);
  };
  try { await import(pusher); } catch { logError("lab_pusher_import_failed"); process.exitCode = 1; server.close(); }
} else if (mode === "stats") {
  const port = Number(fs.readFileSync(`${ipcPath}/lab-inbox-port`, "utf8"));
  assert.ok(Number.isInteger(port) && port > 0 && port < 65536);
  output(await (await fetch(`http://127.0.0.1:${port}/stats`)).json());
} else if (mode === "identity") {
  const v2 = fs.existsSync("/sys/fs/cgroup/memory.max");
  const directory = v2 ? "/sys/fs/cgroup" : "/sys/fs/cgroup/memory";
  const stat = fs.statSync(directory);
  const memoryLimit = fs.readFileSync(`${directory}/${v2 ? "memory.max" : "memory.limit_in_bytes"}`, "utf8").trim();
  const events = v2 ? fs.readFileSync(`${directory}/memory.events`, "utf8") : "";
  output({ memoryCgroup: `${stat.dev}:${stat.ino}`, memoryLimit, oomKills: Number(events.match(/^oom_kill (\d+)$/m)?.[1] || 0) });
} else if (mode === "pair") {
  const { StageStore } = await import("/app/v2-stage-worker.mjs");
  const store = new StageStore();
  await store.contracts();
  const pointer = store.json("current.json");
  assert.equal(pointer.format, "ops392.v2-stage-current.v1");
  const pair = store.readPair(pointer.pair); // Read-only; never run recovery beside the writer.
  const state = store.json("sequence-state.json"); store.validateState(state);
  assert.ok(pair.value.seq > state.floor && pair.value.seq <= state.lastReservedSeq);
  output({ seq: pair.value.seq });
} else if (mode === "worker") output({ pid: workerPid() });
else if (mode === "kill") process.kill(workerPid(), "SIGKILL");
else if (mode === "fault") {
  assert.ok(["oom", "hang"].includes(process.argv[3]));
  fs.writeFileSync(`${ipcPath}/lab-fault`, process.argv[3], { flag: "wx", mode: 0o600 });
} else throw new Error("lab_mode_invalid");
