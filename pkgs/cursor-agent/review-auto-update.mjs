// NIX-516 — run in a Cursor CLI bundle directory after check-auto-update.mjs
// failed on a new release. Prints the code to review on stderr and the hashes
// to pin on stdout. Pin them in auto-update-review.json only after reading the
// regions: every automatic updateCursorAgent call must still sit behind the
// disableAutoUpdate guard, the option must still reach that guard unchanged,
// and the updater module must not invoke its updater itself.
//
//   cd <store path>/share/cursor-agent
//   ./node <repo>/pkgs/cursor-agent/review-auto-update.mjs >hashes.json 2>regions.txt
import { scan } from "./auto-update-scan.mjs";

const { occurrences, modules, shown, problems } = scan();
console.error(shown.join("\n\n"));
for (const problem of problems) console.error(`problem: ${problem}`);
console.log(JSON.stringify({ occurrences, modules }, null, 2));
