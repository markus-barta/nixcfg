#!/usr/bin/env node
import {
  captureFromFamilyLedgerFile,
  captureFromOfficialProbeFile,
} from "./execution-history.mjs";
import { reconcileExecutionCapture } from "./execution-reconciliation.mjs";
import {
  createFileFamilyHistoryStore,
  projectBestAvailableHistory,
} from "./family-history.mjs";

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
}

function argumentsFrom(argv) {
  const [action, ...rest] = argv;
  if (action !== "preview" && action !== "import") throw new Error("action must be preview or import");
  const seen = new Set();
  let sourceType;
  let sourcePath;
  let statePath;
  let fromInclusive;
  let toExclusive;
  let requestId;
  for (let index = 0; index < rest.length; index += 2) {
    const key = rest[index];
    const value = rest[index + 1];
    if (typeof key !== "string" || !key.startsWith("--")) throw new Error("CLI options must be --name value pairs");
    if (value === undefined || value.startsWith("--")) throw new Error(`missing value for ${key}`);
    if (seen.has(key)) throw new Error(`duplicate option ${key}`);
    seen.add(key);
    switch (key) {
      case "--source-type": sourceType = value; break;
      case "--source": sourcePath = value; break;
      case "--state": statePath = value; break;
      case "--from": fromInclusive = value; break;
      case "--to": toExclusive = value; break;
      case "--request": requestId = value; break;
      default: throw new Error(`unsupported option ${key}`);
    }
  }
  if (!sourceType) throw new Error("missing --source-type");
  if (!sourcePath) throw new Error("missing --source");
  if (!statePath) throw new Error("missing --state");
  if (!fromInclusive) throw new Error("missing --from");
  if (!toExclusive) throw new Error("missing --to");
  if (!["family-ledger", "official-probe"].includes(sourceType)) {
    throw new Error("--source-type must be family-ledger or official-probe");
  }
  if (sourceType === "official-probe" && !requestId) {
    throw new Error("official-probe import requires --request");
  }
  return { action, sourceType, sourcePath, statePath, fromInclusive, toExclusive, requestId };
}

function summary(state, importedReceiptId) {
  const projection = projectBestAvailableHistory({ state });
  return {
    ok: true,
    status: projection.status,
    importedReceiptId,
    receiptCount: state.receipts.length,
    executionCount: state.executions.length,
    commissionCount: state.commissions.length,
    familyExecutionCount: projection.capturedSubtotal.executionCount,
    capturedSubtotal: projection.capturedSubtotal,
    coverage: projection.coverage,
    missingOpeningLots: projection.missingOpeningLots,
    orphanCommissionIds: projection.orphanCommissionIds,
  };
}

async function main() {
  const { action, sourceType, sourcePath, statePath, fromInclusive, toExclusive, requestId } = argumentsFrom(process.argv.slice(2));
  const target = { fromInclusive, toExclusive };
  const capture = sourceType === "family-ledger"
    ? captureFromFamilyLedgerFile({ filePath: sourcePath, window: target })
    : captureFromOfficialProbeFile({
      filePath: sourcePath,
      requestId,
      window: target,
    });
  const store = createFileFamilyHistoryStore(statePath);
  const loaded = store.load();
  if (!loaded.ok) throw new Error(loaded.reason);
  const state = reconcileExecutionCapture({ prior: loaded.state, capture, target });
  const sourceId = capture.source.id;
  const receipt = state.receipts.find((item) => item.source.id === sourceId);
  if (action === "import") store.save(state);
  process.stdout.write(`${JSON.stringify({ action, ...summary(state, receipt.receiptId) }, null, 2)}\n`);
}

main().catch((error) => fail(error?.message || String(error)));
