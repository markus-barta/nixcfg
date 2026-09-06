import http from "node:http";

const finite = (value) =>
  typeof value === "number" && Number.isFinite(value) && value >= 0;
const number = (value) => value.toFixed(1).replace(".", ",");

// Keep only display values. Snapshots also contain prompt previews: never log,
// persist or forward them to Pi's model context.
export function readMetrics(snapshot, now = Date.now() / 1000) {
  if (
    !finite(snapshot?.ts) ||
    Math.abs(now - snapshot.ts) > 10 ||
    !Array.isArray(snapshot.in_flight) ||
    !finite(snapshot.active_requests)
  ) {
    return { phase: "unavailable" };
  }
  const requests = snapshot.in_flight.filter((r) => !r.cancelled);
  const decoding = requests.filter((r) =>
    finite(r.last_progress?.decode_tok_s),
  );
  const prefill = requests.find((r) => r.prefill_state?.phase);
  let phase = "idle";
  let tps;
  let percent;
  if (decoding.length) {
    phase = "decode";
    tps = decoding.reduce((sum, r) => sum + r.last_progress.decode_tok_s, 0);
  } else if (prefill) {
    phase = "prefill";
    const p = prefill.prefill_state;
    if (finite(p.tokens_done) && finite(p.tokens_total) && p.tokens_total > 0) {
      percent = Math.min(100, (100 * p.tokens_done) / p.tokens_total);
    }
  } else if (snapshot.active_requests > 0) {
    phase = "busy";
  }
  return {
    phase,
    tps,
    percent,
    // Active MLX allocation: weights, KV/session caches and working buffers.
    // Excludes the allocator's unused cache; this is not whole-Mac RAM usage.
    memory:
      snapshot.mem?.ok && finite(snapshot.mem.active_memory_bytes)
        ? snapshot.mem.active_memory_bytes / 2 ** 30
        : undefined,
    pressure: snapshot.memory_pressure_level,
  };
}

export function metricsText(metrics, theme) {
  const dim = (s) => theme.fg("dim", s);
  if (metrics.phase === "unavailable") {
    return dim("MTPLX · nicht erreichbar");
  }
  let activity = "Leerlauf";
  if (metrics.phase === "decode") activity = `${number(metrics.tps)} TPS`;
  if (metrics.phase === "prefill") {
    activity = `Prefill${finite(metrics.percent) ? ` ${Math.round(metrics.percent)}%` : ""}`;
  }
  if (metrics.phase === "busy") activity = "wartet";
  const color = metrics.phase === "decode" ? "accent" : "dim";
  const memoryColor =
    metrics.pressure === 4
      ? "error"
      : metrics.pressure === 2
        ? "warning"
        : "dim";
  const memory = finite(metrics.memory) ? `${number(metrics.memory)} GiB` : "—";
  return (
    dim("MTPLX · ") +
    theme.fg(color, activity) +
    dim(" · ") +
    theme.fg(memoryColor, `RAM ${memory}`)
  );
}

export function alignTelemetry(
  left,
  right,
  width,
  { visibleWidth, truncateToWidth },
) {
  if (width <= 0) return "";
  // Keep room for the repo on narrow terminals; never wrap the footer.
  const rightBudget =
    width >= 60 ? Math.max(1, width - 18) : Math.floor(width * 0.65);
  const rhs = truncateToWidth(right, rightBudget, "…");
  const lhs = truncateToWidth(
    left,
    Math.max(0, width - visibleWidth(rhs) - 2),
    "…",
  );
  return (
    lhs +
    " ".repeat(Math.max(0, width - visibleWidth(lhs) - visibleWidth(rhs))) +
    rhs
  );
}

export function snapshotUrl(connection) {
  const url = new URL(connection.baseUrl);
  if (
    url.protocol !== "http:" ||
    url.hostname !== "127.0.0.1" ||
    url.pathname !== "/v1" ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  ) {
    throw new Error("MTPLX telemetry requires the local app endpoint");
  }
  return new URL(`${url.pathname}/mtplx/snapshot`, url);
}

export function fetchSnapshot(url, signal) {
  return new Promise((resolve, reject) => {
    // node:http avoids proxy configuration and does not follow redirects.
    const request = http.get(url, { signal }, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error("MTPLX snapshot unavailable"));
        return;
      }
      let size = 0;
      const chunks = [];
      response.on("data", (chunk) => {
        size += chunk.length;
        if (size > 8 * 1024 * 1024)
          request.destroy(new Error("MTPLX snapshot too large"));
        else chunks.push(chunk);
      });
      response.on("error", reject);
      response.on("end", () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
        } catch (error) {
          reject(error);
        }
      });
    });
    const deadline = setTimeout(
      () => request.destroy(new Error("MTPLX snapshot timed out")),
      2500,
    );
    deadline.unref();
    request.on("close", () => clearTimeout(deadline));
    request.on("error", reject);
  });
}

// One request at a time; replacing/reloading the footer aborts in-flight I/O.
export function pollMetrics(
  url,
  update,
  fetcher = fetchSnapshot,
  interval = 2000,
) {
  const controller = new AbortController();
  let timer;
  async function poll() {
    let metrics;
    try {
      metrics = readMetrics(await fetcher(url, controller.signal));
    } catch {
      metrics = { phase: "unavailable" };
    }
    if (controller.signal.aborted) return;
    update(metrics);
    timer = setTimeout(poll, interval);
    timer.unref();
  }
  void poll();
  return () => {
    controller.abort();
    clearTimeout(timer);
  };
}

export default async function (pi) {
  if (!process.env.PI_LOCAL_CONNECTION) return;
  const url = snapshotUrl(JSON.parse(process.env.PI_LOCAL_CONNECTION));
  // Lazy imports keep noninteractive use and the metric tests independent of TUI.
  pi.on("session_start", async (_event, ctx) => {
    if (ctx.mode !== "tui") return;
    const { FooterComponent, SettingsManager } = await import(
      "@earendil-works/pi-coding-agent"
    );
    const tuiTools = await import("@earendil-works/pi-tui");
    const settings = SettingsManager.create(
      ctx.cwd,
      process.env.PI_CODING_AGENT_DIR,
      { projectTrusted: ctx.isProjectTrusted() },
    );
    ctx.ui.setFooter((tui, theme, footerData) => {
      // Pi 0.85's exported footer only needs this read-only session view. Reuse
      // it so cache-hit stats, compactions, branch/name and model stay native.
      const session = {
        get state() {
          return { model: ctx.model, thinkingLevel: pi.getThinkingLevel() };
        },
        sessionManager: ctx.sessionManager,
        getContextUsage: () => ctx.getContextUsage(),
        modelRuntime: {
          isUsingSubscription: () =>
            ctx.model ? ctx.modelRegistry.isUsingOAuth(ctx.model) : false,
        },
      };
      const footer = new FooterComponent(session, footerData);
      let metrics = { phase: "unavailable" };
      let disposed = false;
      const unsubscribe = footerData.onBranchChange(() => tui.requestRender());
      const stop = pollMetrics(url, (next) => {
        metrics = next;
        // Read settings without writing; reflect /settings compaction toggles.
        void settings.reload().then(() => {
          if (!disposed) tui.requestRender();
        });
      });
      return {
        render(width) {
          footer.setAutoCompactEnabled(settings.getCompactionEnabled());
          const lines = footer.render(width);
          lines[0] = alignTelemetry(
            lines[0],
            metricsText(metrics, theme),
            width,
            tuiTools,
          );
          return lines;
        },
        invalidate() {
          footer.invalidate();
        },
        dispose() {
          disposed = true;
          stop();
          unsubscribe();
          footer.dispose();
        },
      };
    });
  });
  pi.on("session_shutdown", (_event, ctx) => {
    if (ctx.mode === "tui") ctx.ui.setFooter(undefined);
  });
}
