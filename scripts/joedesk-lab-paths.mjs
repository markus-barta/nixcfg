// Fixed workstation lab parents, shared by rehearsal setup and source readers.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Resolve existing ancestors without creating the requested directory. The
// default cache parent need not exist yet on a fresh workstation or CI runner.
function canonicalPath(value) {
  let current = path.resolve(value);
  const tail = [];
  for (;;) {
    try {
      return path.join(fs.realpathSync(current), ...tail);
    } catch (error) {
      if (error.code !== "ENOENT" || path.dirname(current) === current)
        throw error;
      tail.unshift(path.basename(current));
      current = path.dirname(current);
    }
  }
}
export function labParents() {
  return [
    canonicalPath(path.join(os.homedir(), ".cache", "joedesk-rehearsal")),
    fs.realpathSync(os.tmpdir()),
    fs.realpathSync("/tmp"),
  ];
}
export function validateLabRoot(value) {
  const parents = labParents();
  const root = canonicalPath(value ?? parents[0]);
  const parent = parents.find(
    (p) => root === p || root.startsWith(p + path.sep),
  );
  if (!parent) throw new Error("lab_root_outside_allowed_parents");
  return path.join(parent, path.relative(parent, root));
}
