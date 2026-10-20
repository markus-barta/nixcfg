import { realpathSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { registerHooks } from "node:module";
import { setImmediate as nextTurn } from "node:timers/promises";
import { Worker, isMainThread, workerData, parentPort } from "node:worker_threads";
import { EventEmitter } from "node:events";
import { configure } from "./pusher-dependencies.mjs";

let generation = 0;
export const instant = "2026-10-19T07:00:00.000Z";

export function syntheticState(variant = "normal", at = instant) {
  return {
    variant,
    book: { ts: variant === "no-timestamp" ? null : at, gatewayLastSeenAt: at, gateway: variant !== "outage", summary: {}, portfolio: [], positions: [] },
    retained: variant === "retained" ? { observedAt: at, status: "retained", desks: {} } : null,
    failure: { ok: false, reason: "synthetic-unavailable" }, reads: 0, observes: 0,
  };
}

// Hooks select fixed local test doubles, never transform/evaluate source text.
export function installPusherDoubles(moduleURL, state, realHandoff = false) {
  configure(state);
  return registerHooks({
    resolve(specifier, context, nextResolve) {
      if (context.parentURL === moduleURL && specifier !== "./project.mjs" && !(realHandoff && specifier === "./v2-stage-handoff.mjs")) {
        return { url: new URL("./pusher-dependencies.mjs", import.meta.url).href, shortCircuit: true };
      }
      return nextResolve(specifier, context);
    },
  });
}

export async function runPusher(moduleURL, options = {}) {
  // Global clock/timer doubles belong to a worker, never the test runner.
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL(import.meta.url), { workerData: { kind: "pusher-byte-check", moduleURL: String(moduleURL), options }, execArgv: [] });
    worker.once("message", result => {
      for (const request of result.requests) request.body = Buffer.from(request.body);
      resolve(result);
    });
    worker.once("error", reject);
    worker.once("exit", code => { if (code) reject(new Error("pusher_fixture_failed")); });
  });
}
async function executePusher(moduleURL, { variant = "normal", stageState = "busy", fetchError, bodyError, cycles = 1 } = {}) {
  const { createStageHandoff } = await import("../v2-stage-handoff.mjs");
  class Socket extends EventEmitter {
    writable = true; writableLength = 0; destroyed = false; connecting = false;
    connect() {}
    destroy() { this.destroyed = true; }
    write() { if (stageState === "throw") throw new Error("synthetic"); return stageState !== "backpressure"; }
  }
  const transport = new Socket();
  const socket = createStageHandoff({ socketPath: "/run/joe-household-v2/stage.sock", makeSocket: () => transport, defer: () => ({}) });
  if (["idle", "backpressure", "throw"].includes(stageState)) transport.emit("data", Buffer.from([1]));
  if (["nonzero-exit", "OOM", "corrupt-state"].includes(stageState)) { transport.emit("error", new Error("synthetic")); transport.emit("close"); }
  const state = syntheticState(variant);
  const before = JSON.stringify({ book: state.book, retained: state.retained });
  const requests = [], observations = [], trace = [], errors = [], logs = [], timers = [];
  state.handoff = { offer(source) { trace.push("handoff"); observations.push(source.book.ts); return socket?.offer(source); }, stop() {} };
  const url = pathToFileURL(realpathSync(fileURLToPath(moduleURL))); url.searchParams.set("fixture", String(++generation));
  const hooks = installPusherDoubles(url.href, state);
  const saved = { fetch: globalThis.fetch, Date: globalThis.Date, setTimeout: globalThis.setTimeout, setInterval: globalThis.setInterval, log: console.log, warn: console.warn, error: console.error };
  const oldSocket = process.env.JOE_V2_STAGE_SOCKET, oldMarks = process.env.JOE_FLAT_NET_MARKS;
  process.env.JOE_V2_STAGE_SOCKET = "/run/joe-household-v2/stage.sock";
  process.env.JOE_FLAT_NET_MARKS = "0";
  Object.assign(globalThis, {
    Date: class extends saved.Date { constructor(...args) { super(...(args.length ? args : [instant])); } },
    setTimeout: (fn, delay) => { timers.push({ fn, delay, kind: "timeout" }); return 1; },
    setInterval: (fn, delay) => { timers.push({ fn, delay, kind: "interval" }); return 1; },
    fetch: async (destination, options) => {
      requests.push({ url: destination, ...options, body: Buffer.from(options.body) }); trace.push("fetch");
      if (fetchError) { trace.push("fetch-rejected"); throw fetchError; }
      return { ok: true, status: 200, text: async () => {
        trace.push("response-settled"); if (bodyError) throw bodyError; return '{"ok":true}';
      } };
    },
  });
  console.log = (...args) => logs.push(args);
  console.warn = () => {};
  console.error = (...args) => errors.push(args);
  const listeners = new Map(["SIGINT", "SIGTERM"].map(signal => [signal, process.listeners(signal)]));
  try {
    await import(url.href);
    timers.find(timer => timer.kind === "timeout" && timer.delay === 8000).fn();
    await nextTurn(); // Drain the actual push promise and its caller's handlers.
    for (let cycle = 1; cycle < cycles; cycle++) {
      timers.find(timer => timer.kind === "interval" && timer.delay === 30_000).fn();
      await nextTurn();
    }
    return {
      requests, observations, trace, errors,
      errorIdentityPreserved: errors.at(-1)?.[1] === (fetchError || bodyError),
      result: logs.map(([line]) => { try { return JSON.parse(line); } catch { return {}; } }).find(line => Object.hasOwn(line, "inbox")),
      inputsUnchanged: before === JSON.stringify({ book: state.book, retained: state.retained }),
      counts: { reads: state.reads, observes: state.observes },
      deskEvents: logs.map(([line]) => { try { return JSON.parse(line); } catch { return {}; } }).filter(line => line.event === "v2_desk_state"),
      schedule: timers.map(({ kind, delay }) => ({ kind, delay })),
    };
  } finally {
    socket.stop();
    hooks.deregister();
    Object.assign(globalThis, { fetch: saved.fetch, Date: saved.Date, setTimeout: saved.setTimeout, setInterval: saved.setInterval });
    Object.assign(console, { log: saved.log, warn: saved.warn, error: saved.error });
    for (const [key, value] of [["JOE_V2_STAGE_SOCKET", oldSocket], ["JOE_FLAT_NET_MARKS", oldMarks]]) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    for (const [signal, previous] of listeners) {
      for (const listener of process.listeners(signal)) if (!previous.includes(listener)) process.removeListener(signal, listener);
    }
  }
}

if (!isMainThread && workerData?.kind === "pusher-byte-check") {
  parentPort.postMessage(await executePusher(workerData.moduleURL, workerData.options));
}
