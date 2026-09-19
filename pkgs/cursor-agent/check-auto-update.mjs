// NIX-516 — fail-closed check that a Cursor CLI bundle still honours
// --disable-auto-update exactly like the reviewed one. Runs in installCheck
// (so at every bump) and in T85 against fixtures. The CLI accepts unknown
// options, so a working run proves nothing; this reads the bundle instead.
//
// It is change detection against a reviewed baseline (auto-update-review.json),
// not an analysis of the minified code: pattern checks on minified JavaScript
// kept missing new spellings of the same thing, and normalising minified names
// hid real changes (another module's `disableAutoUpdate`). The check hashes the
// exact bytes of
// - every text window around an occurrence of the name `updateCursorAgent`
//   (strings included), wide enough to hold the disableAutoUpdate guard and
//   the whole call, and
// - every copy of the module that exports the updater.
// Any change fails the bump, including a rebuild that only renames minified
// names: review the code `--show` prints (is every automatic update still
// behind disableAutoUpdate, and does the module still not invoke its updater
// itself?), then re-pin with --print. index.js must also define the option
// exactly once.
//
// Limit: code that reaches the updater without its name and outside its
// module (a second copy under another name, a name built at runtime) is not
// seen. The live check on the host (the imperative directory stays absent)
// is the behavioural backstop.
//
// Usage: node check-auto-update.mjs <bundle directory> <review json>
//        node check-auto-update.mjs <bundle directory> --show    (code to review)
//        node check-auto-update.mjs <bundle directory> --print   (hashes to pin)
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const [dir, review] = process.argv.slice(2);
const fail = (message) => {
  console.error(`cursor-agent auto-update check: ${message}`);
  process.exit(1);
};
if (!dir || !review) fail("usage: check-auto-update.mjs <bundle directory> <review json | --show | --print>");

const NAME = "updateCursorAgent";
const BEFORE = 160;
const AFTER = 200;
const id = "[A-Za-z_$][\\w$]*";
const fingerprint = (text) => createHash("sha256").update(text).digest("hex");

const index = readFileSync(join(dir, "index.js"), "utf8");
const optionDefinitions = index.split('"--disable-auto-update","Disable auto-updates"').length - 1;
if (optionDefinitions !== 1) fail(`index.js defines --disable-auto-update ${optionDefinitions} times, expected 1`);

const occurrences = {};
const modules = {};
const shown = [];
const exportEntry = new RegExp(`[,{]${NAME}:\\(\\)=>${id}[,}]`, "g");
const moduleKey = () => new RegExp(`"\\.{1,2}/[^"]+"\\(${id},${id},${id}\\)\\{`, "g");
for (const file of readdirSync(dir).filter((name) => name.endsWith(".js")).sort()) {
  const source = readFileSync(join(dir, file), "utf8");
  for (let at = source.indexOf(NAME); at >= 0; at = source.indexOf(NAME, at + NAME.length)) {
    const window = source.slice(Math.max(0, at - BEFORE), at + NAME.length + AFTER);
    const hash = fingerprint(window);
    occurrences[hash] = (occurrences[hash] ?? 0) + 1;
    shown.push(`--- ${file}@${at} (reference window)\n${window}`);
  }
  for (const entry of source.matchAll(exportEntry)) {
    const starts = [...source.slice(0, entry.index).matchAll(moduleKey())];
    if (starts.length === 0) fail(`${file}@${entry.index}: cannot find the module that exports ${NAME}`);
    const following = moduleKey();
    following.lastIndex = entry.index;
    const next = following.exec(source);
    const body = source.slice(starts.at(-1).index, next ? next.index : source.length);
    const hash = fingerprint(body);
    modules[hash] = (modules[hash] ?? 0) + 1;
    shown.push(`--- ${file}@${entry.index} (updater module)\n${body}`);
  }
}
const found = { occurrences, modules };
if (review === "--show") {
  console.log(shown.join("\n\n"));
  process.exit(0);
}
if (review === "--print") {
  console.log(JSON.stringify(found, null, 2));
  process.exit(0);
}

const pinned = JSON.parse(readFileSync(review, "utf8"));
const same = (a, b) => JSON.stringify(Object.entries(a).sort()) === JSON.stringify(Object.entries(b ?? {}).sort());
if (Object.keys(occurrences).length === 0) fail(`no ${NAME} in the bundle; the vendor changed the updater`);
if (!same(occurrences, pinned.occurrences) || !same(modules, pinned.modules)) {
  fail(
    `the updater code differs from the version reviewed in ${pinned.reviewed ?? review}. Review ` +
      `\`node ${process.argv[1]} ${dir} --show\` (is every automatic update still behind ` +
      `disableAutoUpdate?), then re-pin with --print.`,
  );
}
const total = Object.values(occurrences).reduce((sum, n) => sum + n, 0);
console.log(`cursor-agent auto-update check: ${total} updater references match the review of ${pinned.reviewed ?? review}`);
