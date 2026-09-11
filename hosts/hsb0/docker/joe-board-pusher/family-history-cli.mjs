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
  const options = {};
  for (let index = 0; index < rest.length; index += 2) {
    const key = rest[index];
    const value = rest[index + 1];
    if (!key?.startsWith("--") || value === undefined) throw new Error("CLI options must be --name value pairs");
    if (options[key]) throw new Error(`duplicate option ${key}`);
    options[key] = value;
  }
  for (const required of ["--source-type", "--source", "--state", "--from", "--to"]) {
    if (!options[required]) throw new Error(`missing ${required}`);
  }
  if (!["family-ledger", "official-probe"].includes(options["--source-type"])) {
    throw new Error("--source-type must be family-ledger or official-probe");
  }
  if (options["--source-type"] === "official-probe" && !options["--request"]) {
    throw new Error("official-probe import requires --request");
  }
  return { action, options };
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
  const { action, options } = argumentsFrom(process.argv.slice(2));
  const target = { fromInclusive: options["--from"], toExclusive: options["--to"] };
  const capture = options["--source-type"] === "family-ledger"
    ? captureFromFamilyLedgerFile({ filePath: options["--source"], window: target })
    : captureFromOfficialProbeFile({
      filePath: options["--source"],
      requestId: options["--request"],
      window: target,
    });
  const store = createFileFamilyHistoryStore(options["--state"]);
  const loaded = store.load();
  if (!loaded.ok) throw new Error(loaded.reason);
  const state = reconcileExecutionCapture({ prior: loaded.state, capture, target });
  const sourceId = capture.source.id;
  const receipt = state.receipts.find((item) => item.source.id === sourceId);
  if (action === "import") store.save(state);
  process.stdout.write(`${JSON.stringify({ action, ...summary(state, receipt.receiptId) }, null, 2)}\n`);
}

main().catch((error) => fail(error?.message || String(error)));
