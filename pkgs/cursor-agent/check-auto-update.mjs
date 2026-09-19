// NIX-516 — fail-closed check that the Cursor CLI bundle still honours
// --disable-auto-update. Runs in installCheck (so at every bump) and in T85
// against fixtures. The CLI accepts unknown options, so a working run proves
// nothing; this reads the bundle instead.
//
// Every call of the vendor updater must be classified: explicit
// (isAutoUpdate false: the `update`, `upgrade` and `set-channel` commands) or
// automatic (isAutoUpdate true). Every automatic call must sit directly behind
// the exact guard `null!==(x=o.disableAutoUpdate)&&void 0!==x&&x||"static"===
// <config>.channel||setTimeout(...)`. Anything else (no automatic call, an
// unknown value, an inverted or different guard, a missing option) fails.
//
// Usage: node check-auto-update.mjs <bundle directory>
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const dir = process.argv[2];
const fail = (message) => {
  console.error(`cursor-agent auto-update check: ${message}`);
  process.exit(1);
};
if (!dir) fail("usage: check-auto-update.mjs <bundle directory>");

const index = readFileSync(join(dir, "index.js"), "utf8");
const definitions = index.split('"--disable-auto-update","Disable auto-updates"').length - 1;
if (definitions !== 1) fail(`index.js defines --disable-auto-update ${definitions} times, expected 1`);

const id = "[A-Za-z_$][\\w$]*";
const guard = new RegExp(
  `null!==\\((${id})=${id}\\.disableAutoUpdate\\)&&void 0!==\\1&&\\1\\|\\|` +
    `"static"===${id}(?:\\.${id})*\\.channel\\|\\|setTimeout\\(\\(\\(\\)=>\\{` +
    `\\(0,${id}\\.updateCursorAgent\\)\\(\\{`,
  "g",
);
const call = /\.updateCursorAgent\)\(\{/g;

let explicit = 0;
let automatic = 0;
for (const file of readdirSync(dir).filter((name) => name.endsWith(".js")).sort()) {
  const source = readFileSync(join(dir, file), "utf8");
  const guarded = new Set([...source.matchAll(guard)].map((m) => m.index + m[0].length));
  for (const m of source.matchAll(call)) {
    const argsStart = m.index + m[0].length;
    const args = source.slice(argsStart, source.indexOf("}", argsStart));
    const value = /(?:^|,)isAutoUpdate:([^,}]*)/.exec(args)?.[1];
    if (value === "!1" || value === "false") {
      explicit += 1;
    } else if (value === "!0" || value === "true") {
      if (!guarded.has(argsStart)) fail(`${file}: an automatic update is not behind the disableAutoUpdate guard`);
      automatic += 1;
    } else {
      fail(`${file}: an updateCursorAgent call has isAutoUpdate ${value === undefined ? "missing" : `= ${value}`}`);
    }
  }
}
if (automatic === 0) fail("no guarded automatic update found; the vendor changed the updater, re-verify NIX-516");
console.log(`cursor-agent auto-update check: ${automatic} automatic update(s) guarded, ${explicit} explicit`);
