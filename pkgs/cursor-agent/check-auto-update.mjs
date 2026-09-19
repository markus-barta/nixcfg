// NIX-516 — fail-closed check that the Cursor CLI bundle still honours
// --disable-auto-update. Runs in installCheck (so at every bump) and in T85
// against fixtures. The CLI accepts unknown options, so a working run proves
// nothing; this reads the bundle instead.
//
// Every occurrence of the name `updateCursorAgent` anywhere in the bundle,
// strings included, must be one of two exact shapes, or the check fails:
// - the module export entry `updateCursorAgent:()=>b`;
// - a call `(0,x.updateCursorAgent)({...})` whose argument is a plain object
//   literal (no spread, no nesting) with exactly one isAutoUpdate key. An
//   explicit call (false: the `update`, `upgrade` and `set-channel` commands)
//   passes; an automatic call (true) must sit directly behind the exact
//   guard `null!==(x=o.disableAutoUpdate)&&void 0!==x&&x||"static"===
//   <config>.channel||setTimeout(...)`, which must start a sequence or
//   statement (a `!` or any other prefix fails).
// Inside the updater's own module the local binding `b` may not be called
// except where it is defined. At least one guarded automatic call must exist,
// and index.js must define the option exactly once.
//
// Limit: this is a text check on minified code without scope analysis. It
// cannot follow `b` through an alias inside its module (the minifier reuses
// the name for shadowed locals there), nor a second copy of the updater under
// another name. The live check on the host (the imperative directory stays
// absent) is the behavioural backstop.
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
const optionDefinitions = index.split('"--disable-auto-update","Disable auto-updates"').length - 1;
if (optionDefinitions !== 1) fail(`index.js defines --disable-auto-update ${optionDefinitions} times, expected 1`);

const NAME = "updateCursorAgent";
const id = "[A-Za-z_$][\\w$]*";
const guard = new RegExp(
  `(?<=[,;{}])null!==\\((${id})=${id}\\.disableAutoUpdate\\)&&void 0!==\\1&&\\1\\|\\|` +
    `"static"===${id}(?:\\.${id})*\\.channel\\|\\|setTimeout\\(\\(\\(\\)=>\\{` +
    `\\(0,${id}\\.${NAME}\\)\\(`,
  "g",
);
const callPrefix = new RegExp(`\\(0,${id}\\.$`);
const exportTail = new RegExp(`^:\\(\\)=>(${id})[,}]`);
const moduleKey = () => new RegExp(`"\\.{1,2}/[^"]+"\\(${id},${id},${id}\\)\\{`, "g");

let explicit = 0;
let automatic = 0;
let exports = 0;
for (const file of readdirSync(dir).filter((name) => name.endsWith(".js")).sort()) {
  const source = readFileSync(join(dir, file), "utf8");
  const guarded = new Set([...source.matchAll(guard)].map((m) => m.index + m[0].length));
  for (let at = source.indexOf(NAME); at >= 0; at = source.indexOf(NAME, at + NAME.length)) {
    const where = `${file}@${at}`;
    const end = at + NAME.length;
    const before = source.slice(Math.max(0, at - 64), at);
    const exported = exportTail.exec(source.slice(end, end + 72));
    if (exported && /[,{]$/.test(before)) {
      exports += 1;
      checkLocalBinding(source, at, exported[1], where);
      continue;
    }
    if (!callPrefix.test(before) || !source.startsWith(")({", end)) {
      fail(`${where}: a reference to ${NAME} that is neither the export entry nor a (0,x.${NAME})({...}) call`);
    }
    const argsStart = end + 3;
    const argsEnd = source.indexOf("}", argsStart);
    const args = source.slice(argsStart, argsEnd);
    if (argsEnd < 0 || args.includes("{") || args.includes("...") || args.includes("[")) {
      fail(`${where}: the ${NAME} argument is not a plain object literal`);
    }
    const values = [...args.matchAll(/(?:^|,)isAutoUpdate:([^,}]*)/g)].map((m) => m[1]);
    if (values.length !== 1 || args.split("isAutoUpdate").length !== 2) {
      fail(`${where}: the ${NAME} argument must set isAutoUpdate exactly once`);
    }
    if (values[0] === "!1" || values[0] === "false") {
      explicit += 1;
    } else if (values[0] === "!0" || values[0] === "true") {
      if (!guarded.has(end + 2)) fail(`${where}: an automatic update is not behind the disableAutoUpdate guard`);
      automatic += 1;
    } else {
      fail(`${where}: isAutoUpdate = ${values[0]} is neither true nor false`);
    }
  }
}
if (exports === 0) fail(`no ${NAME} export found; the vendor changed the updater, re-verify NIX-516`);
if (automatic === 0) fail("no guarded automatic update found; the vendor changed the updater, re-verify NIX-516");
console.log(
  `cursor-agent auto-update check: ${automatic} automatic update(s) guarded, ${explicit} explicit, ${exports} export(s)`,
);

// Within the module that exports the updater, its local binding may only be
// called where it is defined; any other call would bypass the guard.
function checkLocalBinding(source, at, binding, where) {
  const starts = [...source.slice(0, at).matchAll(moduleKey())];
  if (starts.length === 0) fail(`${where}: cannot find the module that exports ${NAME}`);
  const start = starts.at(-1).index;
  const following = moduleKey();
  following.lastIndex = at;
  const next = following.exec(source);
  const body = source.slice(start, next ? next.index : source.length);
  const escaped = binding.replace(/\$/g, "\\$");
  const calls = [...body.matchAll(new RegExp(`(?<![\\w$.])${escaped}\\(`, "g"))].length;
  const definitions = [...body.matchAll(new RegExp(`function\\s*\\*?\\s*${escaped}\\(`, "g"))].length;
  if (calls !== definitions) fail(`${where}: the updater's local binding ${binding} is called inside its module`);
}
