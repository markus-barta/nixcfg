import assert from "node:assert/strict";
import http from "node:http";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import {
  readMetrics,
  metricsText,
  alignTelemetry,
  snapshotUrl,
  fetchSnapshot,
  pollMetrics,
} from "../hosts/mbp2607/files/pi-local-telemetry.js";

const snapshot = (overrides = {}) => ({
  ts: Date.now() / 1000,
  active_requests: 0,
  in_flight: [],
  mem: {
    ok: true,
    active_memory_bytes: 32 * 2 ** 30,
    cache_memory_bytes: 4 * 2 ** 30,
  },
  memory_pressure_level: 1,
  ...overrides,
});
const plainTheme = { fg: (_color, value) => value };

test("live decode, prefill, queued and idle never confuse old TPS with current TPS", () => {
  const active = readMetrics(
    snapshot({
      active_requests: 1,
      in_flight: [{ last_progress: { decode_tok_s: 14.42 } }],
    }),
  );
  assert.equal(
    metricsText(active, plainTheme),
    "MTPLX · 14,4 TPS · RAM 32,0 GiB",
  );
  assert.equal(active.memory, 32); // Unused allocator cache is excluded.
  const prefill = readMetrics(
    snapshot({
      active_requests: 1,
      in_flight: [
        {
          prefill_state: { phase: "chunk", tokens_done: 75, tokens_total: 100 },
        },
      ],
      latest: { decode_tok_s: 99 },
    }),
  );
  assert.equal(
    metricsText(prefill, plainTheme),
    "MTPLX · Prefill 75% · RAM 32,0 GiB",
  );
  assert.equal(readMetrics(snapshot({ active_requests: 1 })).phase, "busy");
  const idle = readMetrics(
    snapshot({
      latest: { decode_tok_s: 99 },
      rolling: { live_history: [{ tok_s: 99 }] },
    }),
  );
  assert.equal(
    metricsText(idle, plainTheme),
    "MTPLX · Leerlauf · RAM 32,0 GiB",
  );
  assert.equal(idle.tps, undefined);
});

test("stale/malformed data and unavailable memory are explicit; normal pressure is not a warning", () => {
  for (const bad of [
    null,
    {},
    snapshot({ ts: 1 }),
    snapshot({ ts: Infinity }),
    snapshot({ active_requests: -1 }),
  ]) {
    assert.equal(readMetrics(bad).phase, "unavailable");
  }
  assert.equal(
    metricsText(readMetrics(snapshot({ mem: { ok: false } })), plainTheme),
    "MTPLX · Leerlauf · RAM —",
  );
  for (const [level, expected] of [
    [0, "dim"],
    [1, "dim"],
    [2, "warning"],
    [4, "error"],
  ]) {
    const colors = [];
    metricsText(readMetrics(snapshot({ memory_pressure_level: level })), {
      fg(color, text) {
        if (text.startsWith("RAM")) colors.push(color);
        return text;
      },
    });
    assert.deepEqual(colors, [expected]);
  }
});

test("right alignment preserves the repo, fits narrow widths and delegates terminal-cell measurement", () => {
  const calls = [];
  const cells = {
    visibleWidth: (s) => s.length,
    truncateToWidth(s, width, ellipsis) {
      calls.push(width);
      return s.length > width
        ? s.slice(0, Math.max(0, width - ellipsis.length)) +
            (width ? ellipsis : "")
        : s;
    },
  };
  const metrics = "MTPLX · 14,4 TPS · RAM 32,0 GiB";
  const row = alignTelemetry("~/Code/nuncid (main)", metrics, 140, cells);
  assert.ok(row.startsWith("~/Code/nuncid (main)"));
  assert.ok(row.endsWith(metrics));
  assert.equal(row.length, 140);
  for (const width of [0, 1, 2, 10, 30, 60])
    assert.equal(
      alignTelemetry("a very long repository", metrics, width, cells).length,
      width,
    );
  assert.ok(calls.every((width) => width >= 0));
});

test("only the app's loopback endpoint is accepted", () => {
  assert.equal(
    snapshotUrl({ baseUrl: "http://127.0.0.1:8123/v1" }).href,
    "http://127.0.0.1:8123/v1/mtplx/snapshot",
  );
  for (const baseUrl of [
    "https://127.0.0.1/v1",
    "http://example.com/v1",
    "http://127.0.0.1/admin",
    "http://user:pass@127.0.0.1/v1",
    "http://127.0.0.1/v1?key=abc",
  ])
    assert.throws(() => snapshotUrl({ baseUrl }));
});

test("HTTP failures, malformed responses, redirects and cancellation fail closed", async () => {
  let hits = 0;
  const server = http.createServer((req, res) => {
    hits++;
    if (req.url === "/ok") res.end(JSON.stringify(snapshot()));
    else if (req.url === "/bad") res.end("not JSON");
    else if (req.url === "/redirect") {
      res.writeHead(302, { Location: "/ok" });
      res.end();
    } else if (req.url === "/hang") {
      /* Wait for client abort. */
    } else {
      res.writeHead(503);
      res.end();
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const base = `http://127.0.0.1:${server.address().port}`;
    assert.equal(readMetrics(await fetchSnapshot(base + "/ok")).phase, "idle");
    for (const path of ["/bad", "/redirect", "/error"])
      await assert.rejects(fetchSnapshot(base + path));
    assert.equal(hits, 4); // The redirect was not followed.
    const controller = new AbortController();
    const pending = fetchSnapshot(base + "/hang", controller.signal);
    controller.abort();
    await assert.rejects(pending);
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});

test("polling is serial, recovers after failure, and disposal aborts without late renders", async () => {
  const updates = [];
  let calls = 0;
  let concurrent = 0;
  let maximum = 0;
  let pendingSignal;
  const stop = pollMetrics(
    "unused",
    (value) => updates.push(value.phase),
    async (_url, signal) => {
      calls++;
      pendingSignal = signal;
      concurrent++;
      maximum = Math.max(maximum, concurrent);
      try {
        await delay(10, undefined, { signal });
        if (calls === 1) throw new Error("offline");
        return snapshot();
      } finally {
        concurrent--;
      }
    },
    1,
  );
  try {
    for (let i = 0; updates.length < 2 && i < 100; i++) await delay(5);
    assert.deepEqual(updates.slice(0, 2), ["unavailable", "idle"]);
    assert.equal(maximum, 1);
  } finally {
    stop();
  }
  const before = updates.length;
  await delay(30);
  assert.equal(pendingSignal.aborted, true);
  assert.equal(updates.length, before);
});
