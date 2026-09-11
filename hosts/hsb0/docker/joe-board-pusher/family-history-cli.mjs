#!/usr/bin/env node
import {
  captureFromFamilyLedgerFile,
  captureFromOfficialProbeFile,
  capturesFromOfficialWindowFile,
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
  let targetAccount;
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
      case "--account": targetAccount = value; break;
      default: throw new Error(`unsupported option ${key}`);
    }
  }
  if (!sourceType) throw new Error("missing --source-type");
  if (!sourcePath) throw new Error("missing --source");
  if (!statePath) throw new Error("missing --state");
  if (!fromInclusive) throw new Error("missing --from");
  if (!toExclusive) throw new Error("missing --to");
  if (!["family-ledger", "official-probe", "official-window"].includes(sourceType)) {
    throw new Error("--source-type must be family-ledger, official-probe or official-window");
  }
  if (sourceType === "official-probe" && !requestId) {
    throw new Error("official-probe import requires --request");
  }
  if (sourceType === "official-window" && !targetAccount) {
    throw new Error("official-window import requires --account");
  }
  return { action, sourceType, sourcePath, statePath, fromInclusive, toExclusive, requestId, targetAccount };
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
  const { action, sourceType, sourcePath, statePath, fromInclusive, toExclusive, requestId, targetAccount } = argumentsFrom(process.argv.slice(2));
  const target = { fromInclusive, toExclusive };
  const captures = sourceType === "family-ledger"
    ? [captureFromFamilyLedgerFile({ filePath: sourcePath, window: target })]
    : sourceType === "official-probe" ? [captureFromOfficialProbeFile({
      filePath: sourcePath,
      requestId,
      window: target,
    })] : capturesFromOfficialWindowFile({
      filePath: sourcePath,
      requestedWindow: target,
      targetAccount,
    });
  const store = createFileFamilyHistoryStore(statePath);
  const loaded = store.load();
  if (!loaded.ok) throw new Error(loaded.reason);
  let state = loaded.state;
  for (const capture of captures) state = reconcileExecutionCapture({ prior: state, capture, target });
  const sourceIds = new Set(captures.map((capture) => capture.source.id));
  const importedReceiptIds = state.receipts.filter((item) => sourceIds.has(item.source.id)).map((item) => item.receiptId);
  if (action === "import") store.save(state);
  process.stdout.write(`${JSON.stringify({ action, ...summary(state, importedReceiptIds.length === 1 ? importedReceiptIds[0] : importedReceiptIds) }, null, 2)}\n`);
}

main().catch((error) => fail(error?.message || String(error)));
