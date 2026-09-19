// NIX-516 — fail-closed check that the Cursor CLI bundle in the current
// directory still decides about updating itself exactly like the reviewed
// release (auto-update-review.json, next to this file). The CLI accepts
// unknown options, so a working run proves nothing; this compares the bundle's
// updater and option code byte for byte (auto-update-scan.mjs explains what is
// covered and the limit). Any change fails, including a rebuild that only
// renames minified names: review it with review-auto-update.mjs, then re-pin.
// Runs in installCheck, so at every bump, and in T85 against fixtures.
import { readFileSync } from "node:fs";
import { scan } from "./auto-update-scan.mjs";

const fail = (message) => {
  console.error(`cursor-agent auto-update check: ${message}`);
  process.exit(1);
};
const pinned = JSON.parse(readFileSync(new URL("./auto-update-review.json", import.meta.url), "utf8"));
const { occurrences, modules, problems } = scan();
if (problems.length > 0) fail(problems.join("; "));
const same = (a, b) => JSON.stringify(Object.entries(a).sort()) === JSON.stringify(Object.entries(b ?? {}).sort());
if (!same(occurrences, pinned.occurrences) || !same(modules, pinned.modules)) {
  fail(
    `the updater or option code differs from the release reviewed (${pinned.reviewed ?? "unknown"}). ` +
      "Review it with review-auto-update.mjs (pkgs/cursor-agent), then re-pin auto-update-review.json.",
  );
}
const total = Object.values(occurrences).reduce((sum, n) => sum + n, 0);
console.log(`cursor-agent auto-update check: ${total} references match the review of ${pinned.reviewed}`);
