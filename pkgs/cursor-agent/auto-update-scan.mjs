// NIX-516 — scans the Cursor CLI bundle in the current directory for the code
// that decides whether it updates itself. Shared by check-auto-update.mjs
// (installCheck, T85) and review-auto-update.mjs (re-pinning after a review).
//
// It records the exact bytes, nothing normalised, of
// - a window around every occurrence of the updater's name and of the
//   option's names (`updateCursorAgent`, `disableAutoUpdate`,
//   `disable-auto-update`), strings included: the option definition, its
//   forwarding into the chat run, the disableAutoUpdate guard and every call;
// - every copy of the module that exports the updater.
// Pattern checks on minified JavaScript kept missing new spellings, and
// normalising minified names hid real changes, so the check compares these
// bytes with a reviewed baseline instead of analysing them.
//
// Limit: code that reaches the updater, or decides the option, without these
// names and outside that module (a second copy under another name, a name
// built at runtime) is not seen. The live check on the host (the imperative
// directory stays absent) is the behavioural backstop.
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";

const NAMES = ["updateCursorAgent", "disableAutoUpdate", "disable-auto-update"];
const BEFORE = 160;
const AFTER = 200;
const id = "[A-Za-z_$][\\w$]*";
const exportEntry = new RegExp(`[,{]updateCursorAgent:\\(\\)=>${id}[,}]`, "g");
const moduleKey = () => new RegExp(`"\\.{1,2}/[^"]+"\\(${id},${id},${id}\\)\\{`, "g");
const hash = (text) => createHash("sha256").update(text).digest("hex");

export function scan() {
  const occurrences = {};
  const modules = {};
  const shown = [];
  const problems = [];
  const index = readFileSync("index.js", "utf8");
  const optionDefinitions = index.split('"--disable-auto-update","Disable auto-updates"').length - 1;
  if (optionDefinitions !== 1) problems.push(`index.js defines --disable-auto-update ${optionDefinitions} times, expected 1`);
  for (const file of readdirSync(".").filter((name) => name.endsWith(".js")).sort()) {
    const source = readFileSync(file, "utf8");
    for (const name of NAMES) {
      for (let at = source.indexOf(name); at >= 0; at = source.indexOf(name, at + name.length)) {
        const window = source.slice(Math.max(0, at - BEFORE), at + name.length + AFTER);
        occurrences[hash(window)] = (occurrences[hash(window)] ?? 0) + 1;
        shown.push(`--- ${file}@${at} (${name})\n${window}`);
      }
    }
    for (const entry of source.matchAll(exportEntry)) {
      const starts = [...source.slice(0, entry.index).matchAll(moduleKey())];
      if (starts.length === 0) {
        problems.push(`${file}@${entry.index}: cannot find the module that exports updateCursorAgent`);
        continue;
      }
      const following = moduleKey();
      following.lastIndex = entry.index;
      const next = following.exec(source);
      const body = source.slice(starts.at(-1).index, next ? next.index : source.length);
      modules[hash(body)] = (modules[hash(body)] ?? 0) + 1;
      shown.push(`--- ${file}@${entry.index} (updater module)\n${body}`);
    }
  }
  if (Object.keys(occurrences).length === 0) problems.push("no updater or option names in the bundle");
  return { occurrences, modules, shown, problems };
}
