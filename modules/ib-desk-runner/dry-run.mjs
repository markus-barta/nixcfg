import { readFileSync } from "node:fs";

import { evaluatePlacement, parseIntent } from "./policy.mjs";

const [intentPath, snapshotPath, statePath] = process.argv.slice(2);
if (!intentPath || !snapshotPath) {
  throw new Error("usage: node dry-run.mjs INTENT.json SNAPSHOT.json [STATE.json]");
}
const intent = parseIntent(JSON.parse(readFileSync(intentPath, "utf8")));
const snapshot = JSON.parse(readFileSync(snapshotPath, "utf8"));
const state = statePath ? JSON.parse(readFileSync(statePath, "utf8")) : { initializedAt: new Date(Date.now() - 48 * 60 * 60_000).toISOString(), placements: [] };
const result = intent.action === "place"
  ? evaluatePlacement(intent, snapshot, state, { halt: false, stockType: snapshot.stockType, usdToEur: snapshot.usdToEur })
  : { accepted: true, note: `${intent.action} requires no placement risk budget` };
console.log(JSON.stringify({ dryRun: true, intent, result }, null, 2));
