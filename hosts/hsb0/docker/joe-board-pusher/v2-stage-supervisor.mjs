import path from "node:path";
import { pathToFileURL } from "node:url";
import { launchLocked } from "./v2-stage-worker.mjs";

// Only these control messages cross into logs. Child output is always discarded.
export function createStageSupervisor({
  launch = launchLocked,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  emit = event => console.log(JSON.stringify(event)),
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
  function watch() {
    clearTimer(watchdog);
    watchdog = setTimer(() => kill("worker_timeout"), 5000);
  }
  function start() {
    if (stopped) return;
    phase = "starting";
    try { child = launch(); } catch {
      event("v2_stage_disabled", "worker_unavailable");
      schedule(); return;
    }
    const current = child;
    current.stdout?.resume();
    current.stderr?.resume();
    watch();
    current.on("message", message => {
      if (current !== child || stopped || !message || typeof message !== "object") return;
      if (message.event === "ready" && phase === "starting") {
        phase = "idle"; clearTimer(watchdog);
      } else if (message.event === "job_start" && phase === "idle") {
        phase = "busy"; watch();
      } else if (message.event === "job_done" && phase === "busy" && ["committed", "skipped"].includes(message.outcome)) {
        phase = "idle"; attempt = 0; clearTimer(watchdog);
        event(message.outcome === "committed" ? "v2_stage_committed" : "v2_stage_skipped", message.outcome === "skipped" ? "observation_rejected" : undefined);
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
