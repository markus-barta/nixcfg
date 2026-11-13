import assert from "node:assert/strict";
import test from "node:test";
import { runPusher } from "./fixtures/pusher-harness.mjs";

test("flat-net failures log only on reason change and recur after successful sync", async () => {
  const result = await runPusher(new URL("./pusher.mjs", import.meta.url), { refreshTicks: 6,
    flatNetFailures: ["synthetic-count-error", "synthetic-count-error", "synthetic-other-error", null,
      "synthetic-other-error", "synthetic-other-error"] });
  assert.deepEqual(result.warnings.map(([line]) => JSON.parse(line)).filter(event => event.event === "family_unavailable"), [
    { event: "family_unavailable", reason: "synthetic-count-error" },
    { event: "family_unavailable", reason: "synthetic-other-error" },
    { event: "family_unavailable", reason: "synthetic-other-error" },
  ]);
  assert.equal(result.flatNetResets, 5, "every failing sync still resets marks");
});
