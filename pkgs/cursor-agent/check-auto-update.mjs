// NIX-516 — fail-closed check that a Cursor CLI bundle still honours
// --disable-auto-update exactly like the reviewed one. Runs in installCheck
// (so at every bump) and in T85 against fixtures. The CLI accepts unknown
// options, so a working run proves nothing; this reads the bundle instead.
//
// It is change detection against a reviewed baseline (auto-update-review.json),
// not an analysis of the minified code: pattern checks on minified JavaScript
// kept missing new spellings of the same thing. The check fingerprints
// - every text window around an occurrence of the name `updateCursorAgent`
//   (strings included), wide enough to hold the disableAutoUpdate guard and
//   the whole call, and
// - every copy of the module that exports the updater,
// after canonical renaming of minified names (short identifiers are numbered
// in order of appearance, so a rebuild that only renames passes and `a..a`
// still differs from `a..b`). Any other change, a new call site, a different
// argument, a new invocation, an edited guard, fails until someone reviews
// the new code and re-pins with --print. index.js must also define the option
// exactly once.
//
// Limit: code that reaches the updater without its name and outside its
// module (a second copy under another name, a name built at runtime) is not
// seen. The live check on the host (the imperative directory stays absent)
// is the behavioural backstop.
//
// Usage: node check-auto-update.mjs <bundle directory> <review json>
//        node check-auto-update.mjs <bundle directory> --print   (new review)
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const [dir, review] = process.argv.slice(2);
const fail = (message) => {
  console.error(`cursor-agent auto-update check: ${message}`);
  process.exit(1);
};
if (!dir || !review) fail("usage: check-auto-update.mjs <bundle directory> <review json | --print>");

const NAME = "updateCursorAgent";
const BEFORE = 160;
const AFTER = 200;
const KEYWORDS = new Set(
  "as do if in of for let new try var case else enum null this true void with await break catch class const false super throw while yield async delete export import return static switch typeof default extends finally continue debugger function instanceof".split(
    " ",
  ),
);
const id = "[A-Za-z_$][\\w$]*";

function canonical(text) {
  const names = new Map();
  return text.replace(/(?<![\w$])[A-Za-z_$][\w$]*/g, (word) => {
    if (word.length > 3 || KEYWORDS.has(word)) return word;
    if (!names.has(word)) names.set(word, `#${names.size}`);
    return names.get(word);
  });
}
const fingerprint = (text) => createHash("sha256").update(canonical(text)).digest("hex");

const index = readFileSync(join(dir, "index.js"), "utf8");
const optionDefinitions = index.split('"--disable-auto-update","Disable auto-updates"').length - 1;
if (optionDefinitions !== 1) fail(`index.js defines --disable-auto-update ${optionDefinitions} times, expected 1`);

const occurrences = {};
const modules = {};
const exportEntry = new RegExp(`[,{]${NAME}:\\(\\)=>${id}[,}]`, "g");
const moduleKey = () => new RegExp(`"\\.{1,2}/[^"]+"\\(${id},${id},${id}\\)\\{`, "g");
for (const file of readdirSync(dir).filter((name) => name.endsWith(".js")).sort()) {
  const source = readFileSync(join(dir, file), "utf8");
  for (let at = source.indexOf(NAME); at >= 0; at = source.indexOf(NAME, at + NAME.length)) {
    const hash = fingerprint(source.slice(Math.max(0, at - BEFORE), at + NAME.length + AFTER));
    occurrences[hash] = (occurrences[hash] ?? 0) + 1;
  }
  for (const entry of source.matchAll(exportEntry)) {
    const starts = [...source.slice(0, entry.index).matchAll(moduleKey())];
    if (starts.length === 0) fail(`${file}@${entry.index}: cannot find the module that exports ${NAME}`);
    const following = moduleKey();
    following.lastIndex = entry.index;
    const next = following.exec(source);
    const hash = fingerprint(source.slice(starts.at(-1).index, next ? next.index : source.length));
    modules[hash] = (modules[hash] ?? 0) + 1;
  }
}
const found = { occurrences, modules };
if (review === "--print") {
  console.log(JSON.stringify(found, null, 2));
  process.exit(0);
}

const pinned = JSON.parse(readFileSync(review, "utf8"));
const same = (a, b) => JSON.stringify(Object.entries(a).sort()) === JSON.stringify(Object.entries(b ?? {}).sort());
if (Object.keys(occurrences).length === 0) fail(`no ${NAME} in the bundle; the vendor changed the updater`);
if (!same(occurrences, pinned.occurrences) || !same(modules, pinned.modules)) {
  fail(
    `the updater code differs from the version reviewed in ${pinned.reviewed ?? review}. Review the new ` +
      `updateCursorAgent call sites and update-core module (is every automatic update still behind ` +
      `disableAutoUpdate?), then re-pin with --print.`,
  );
}
const total = Object.values(occurrences).reduce((sum, n) => sum + n, 0);
console.log(`cursor-agent auto-update check: ${total} updater references match the review of ${pinned.reviewed ?? review}`);
