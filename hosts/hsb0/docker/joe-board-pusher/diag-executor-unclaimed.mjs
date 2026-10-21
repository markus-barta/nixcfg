#!/usr/bin/env node
// Read-only, value-free attribution inventory over the pusher's own inputs.
import path from "node:path";
import { pathToFileURL } from "node:url";
import { configuredPaperAccount } from "./paper-account.mjs";
import { J_FAMILY_CLASSIFIER } from "./execution-history.mjs";
import { FAMILY_BASELINE_PERIOD_START, createFileFamilyStateStore } from "./family-state.mjs";
import { mergeExecutionRecords } from "./family-ledger.mjs";
import { EXECUTOR_CLIENT_IDS, isExecutorClient, readExecutorAttribution, validatedExecutionTime } from "./executor-attribution.mjs";

const CAUSES = ["matched", "ops_test", "ops_test_not_flat", "intent_unmatched", "ledger_unavailable",
  "identity_invalid", "identity_ambiguous", "order_key_missing", "intent_ambiguous", "intent_desk_invalid"];

export function summarizeExecutorUnclaimed(rows, attribution) {
  const causes = Object.fromEntries(CAUSES.map(cause => [cause, { count: 0, first: null, last: null }]));
  for (const row of mergeExecutionRecords([], rows)) {
    if (["SXR8", "TSLA"].includes(String(row.contract.symbol).trim().toUpperCase()) ||
        !isExecutorClient(row.execution.clientId, attribution)) continue;
    let cause;
    try { cause = attribution.attribute(row.execution).cause === "ops_test" ? "ops_test" : "matched"; }
    catch (error) { cause = CAUSES.includes(error.executorCause) ? error.executorCause : "ledger_unavailable"; }
    const group = causes[cause];
    group.count++;
    const time = validatedExecutionTime(row.execution.time);
    if (time) {
      if (group.first === null || time < group.first) group.first = time;
      if (group.last === null || time > group.last) group.last = time;
    }
  }
  return { ok: true, causes, instrumentsNotFlat: attribution.instrumentsNotFlat };
}

export function executorUnclaimedDiagnostic({ account = configuredPaperAccount(), clientIds = process.env.JOE_EXECUTOR_CLIENT_IDS === undefined
  ? EXECUTOR_CLIENT_IDS : JSON.parse(process.env.JOE_EXECUTOR_CLIENT_IDS),
  familyFile = "/var/lib/joe-board-pusher/family-ledger.json", executorFile } = {}) {
  const loaded = createFileFamilyStateStore(familyFile).load({ account, periodStart: FAMILY_BASELINE_PERIOD_START,
    classifier: J_FAMILY_CLASSIFIER });
  if (!loaded.ok || !loaded.state) return { ok: false, cause: "family_ledger_unavailable" };
  const rows = loaded.state.executions;
  const attribution = readExecutorAttribution({ account, clientIds, file: executorFile, executionRows: rows, onEvent() {} });
  return summarizeExecutorUnclaimed(rows, attribution);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  let report;
  try { report = executorUnclaimedDiagnostic(); }
  catch { report = { ok: false, cause: "diagnostic_inputs_unavailable" }; }
  console.log(JSON.stringify(report));
  if (!report.ok) process.exitCode = 1;
}
