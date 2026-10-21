#!/usr/bin/env node
// Read-only executor/family inputs. The sole output file is pusher-owned memory.
import path from "node:path";
import { pathToFileURL } from "node:url";
import { configuredPaperAccount } from "./paper-account.mjs";
import { J_FAMILY_CLASSIFIER } from "./execution-history.mjs";
import { FAMILY_BASELINE_PERIOD_START, createFileFamilyStateStore } from "./family-state.mjs";
import { mergeExecutionRecords } from "./family-ledger.mjs";
import { EXECUTOR_CLIENT_IDS, createExecutorAttribution, isExecutorClient } from "./executor-attribution.mjs";
import { createFileExecutorAttributionMemory, readBoundedJson } from "./executor-attribution-memory.mjs";

const SNAPSHOT_ROOTS = Object.freeze(["/dev/shm/recovery", "/tmp/recovery", "/recovery"]);

function readSnapshot(snapshotFile, allowedRoots) {
  if (typeof snapshotFile !== "string" || !path.isAbsolute(snapshotFile)) throw new Error("seed snapshot unavailable");
  const resolvedSnapshotFile = path.resolve(snapshotFile);
  // Tests can use private temporary roots; the CLI always fixes all three roots.
  const [sharedMemoryRoot, temporaryRoot, mountedRoot] = allowedRoots;
  if (resolvedSnapshotFile.startsWith(sharedMemoryRoot + path.sep)) {
    return readBoundedJson(resolvedSnapshotFile, 16 * 1024 * 1024);
  }
  if (resolvedSnapshotFile.startsWith(temporaryRoot + path.sep)) {
    return readBoundedJson(resolvedSnapshotFile, 16 * 1024 * 1024);
  }
  if (resolvedSnapshotFile.startsWith(mountedRoot + path.sep)) {
    return readBoundedJson(resolvedSnapshotFile, 16 * 1024 * 1024);
  }
  throw new Error("seed snapshot unavailable");
}

export function seedAttributionMemory({ snapshotFile, account = configuredPaperAccount(),
  clientIds = process.env.JOE_EXECUTOR_CLIENT_IDS === undefined ? EXECUTOR_CLIENT_IDS : JSON.parse(process.env.JOE_EXECUTOR_CLIENT_IDS),
  familyFile = "/var/lib/joe-board-pusher/family-ledger.json", memoryFile,
  now = () => new Date().toISOString(), allowedRoots = SNAPSHOT_ROOTS } = {}) {
  const ledger = readSnapshot(snapshotFile, allowedRoots);
  if (ledger?.schema !== "barta.paper-desk-executor-state.v1" || ledger.account !== account ||
      !ledger.intents || typeof ledger.intents !== "object" || Array.isArray(ledger.intents) || !Array.isArray(ledger.executions)) {
    throw new Error("seed snapshot unavailable");
  }
  const loaded = createFileFamilyStateStore(familyFile).load({ account, periodStart: FAMILY_BASELINE_PERIOD_START,
    classifier: J_FAMILY_CLASSIFIER });
  if (!loaded.ok || !loaded.state) throw new Error("seed family ledger unavailable");
  const memory = createFileExecutorAttributionMemory({ account, file: memoryFile });
  const proofs = [];
  // Collect exact proofs, then validate/merge/persist them once. A large backup
  // must not clone or serialize the growing memory once per execution.
  const collector = { account, get: () => null, isConflict: () => false,
    record(entry) { proofs.push(entry); return "added"; } };
  const rows = mergeExecutionRecords([], loaded.state.executions);
  const attribution = createExecutorAttribution({ account, clientIds, ledger, executionRows: rows,
    memory: collector, proofSource: "seed", now, onEvent() {} });
  let unmatched = 0;
  for (const row of rows) {
    if (["SXR8", "TSLA"].includes(String(row.contract.symbol).trim().toUpperCase()) ||
        !isExecutorClient(row.execution.clientId, attribution)) continue;
    try {
      // OPS-test rows are intentionally not evidence of any desk ownership.
      if (attribution.attribute(row.execution).cause === "ops_test") unmatched++;
    } catch (error) {
      if (error.executorCause === "ledger_unavailable") throw new Error("seed proof unavailable");
      unmatched++;
    }
  }
  const statuses = memory.recordMany(proofs);
  return { seeded: statuses.filter(status => status === "added").length,
    alreadyPresent: statuses.filter(status => status === "alreadyPresent").length,
    conflicts: statuses.filter(status => status === "conflict").length, unmatched };
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    if (process.argv.length !== 3) throw new Error("seed requires one snapshot");
    console.log(JSON.stringify(seedAttributionMemory({ snapshotFile: process.argv[2], allowedRoots: SNAPSHOT_ROOTS })));
  } catch {
    console.log(JSON.stringify({ ok: false, cause: "seed_inputs_unavailable" }));
    process.exitCode = 1;
  }
}
