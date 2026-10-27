import path from "node:path";
import { pathToFileURL } from "node:url";
import { launchLocked } from "./v2-stage-worker.mjs";

export const STARTUP_TIMEOUT_MS = 60_000;
export const JOB_TIMEOUT_MS = 5_000;

// Only these control messages cross into logs. Child output is always discarded.
export function createStageSupervisor({
  launch = launchLocked,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  emit = event => console.log(JSON.stringify(event)),
  now = () => performance.now(),
} = {}) {
  let child;
  let watchdog;
  let retry;
  let stopped = false;
  let attempt = 0;
  let phase = "starting";
  const backoff = [1000, 2000, 4000, 8000, 16000, 30000];
  const event = (name, reason) => emit({ event: name, ...(reason ? { reason } : {}) });
  function kill(reason) {
    clearTimer(watchdog);
    event("v2_stage_disabled", reason);
    child?.kill("SIGKILL"); // flock --no-fork: this is the actual lock owner.
  }
  function watch(delay, reason = "worker_timeout") {
    clearTimer(watchdog);
    watchdog = setTimer(() => kill(reason), delay);
  }
  function start() {
    if (stopped) return;
    phase = "starting";
    const startedAt = now();
    try { child = launch(); } catch {
      event("v2_stage_disabled", "worker_unavailable");
      schedule(); return;
    }
    const current = child;
    current.stdout?.resume();
    current.stderr?.resume();
    watch(STARTUP_TIMEOUT_MS, "worker_startup_timeout");
    current.on("message", message => {
      if (current !== child || stopped || !message || typeof message !== "object") return;
      if (message.event === "v1_unbound") {
        event("v1_cycle_unbound", "store_unavailable"); return;
      }
      if (message.event === "ready" && phase === "starting") {
        if (!["full", "tail"].includes(message.scanMode) || !Number.isSafeInteger(message.rowsScanned)
          || message.rowsScanned < 0) { kill("worker_protocol"); return; }
        phase = "idle"; clearTimer(watchdog);
        emit({ event: "v2_stage_ready", startupMs: Math.max(0, Math.ceil(now() - startedAt)),
          rowsScanned: message.rowsScanned, scanMode: message.scanMode });
      } else if (message.event === "job_start" && phase === "idle") {
        phase = "busy"; watch(JOB_TIMEOUT_MS);
      } else if (message.event === "job_done" && phase === "busy" && ["committed", "skipped"].includes(message.outcome)) {
        phase = "idle"; attempt = 0; clearTimer(watchdog);
        if (message.outcome === "committed") {
          if (!Number.isSafeInteger(message.seq) || message.seq <= 0) { kill("worker_protocol"); return; }
          emit({ event: "v2_stage_committed", seq: message.seq });
        } else event("v2_stage_skipped", "observation_rejected");
      } else kill("worker_protocol");
    });
    current.on("error", () => kill("worker_unavailable"));
    current.on("close", () => {
      if (child !== current) return;
      child = undefined;
      clearTimer(watchdog);
      if (!stopped) schedule();
    });
  }
  function schedule() {
    if (stopped) return;
    const delay = backoff[Math.min(attempt++, backoff.length - 1)];
    event("v2_stage_restarting");
    retry = setTimer(start, delay);
  }
  start();
  return {
    stop() {
      stopped = true; clearTimer(retry); clearTimer(watchdog);
      child?.kill("SIGKILL");
    },
  };
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  process.umask(0o077);
  const supervisor = createStageSupervisor();
  process.on("SIGINT", () => supervisor.stop());
  process.on("SIGTERM", () => supervisor.stop());
}
