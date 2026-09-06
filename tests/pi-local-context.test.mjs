import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import extension, {
  bridgeContext,
} from "../hosts/mbp2607/files/pi-local-context.js";

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "pi-context-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, ".git"));
  const write = (name, text) => {
    const file = path.join(root, name);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, text);
    return file;
  };
  return { root, write };
}

test("Claude imports retain kernel/private/repo order and deduplicate cycles", (t) => {
  const { write } = fixture(t);
  const agents = write("AGENTS.md", "REPO RULES");
  write(
    "CLAUDE.md",
    "@./doctrine/kernel.md\n@./private/kernel.md\n@./AGENTS.md",
  );
  write("doctrine/kernel.md", "INSPR KERNEL\n@../CLAUDE.md");
  write("private/kernel.md", "PRIVATE KERNEL");
  const result = bridgeContext(agents, "REPO RULES");
  assert.match(result, /INSPR KERNEL[\s\S]*PRIVATE KERNEL[\s\S]*REPO RULES/);
  assert.equal(result.match(/REPO RULES/g).length, 1);
});

test("explicit override excludes the neighboring Claude loader", (t) => {
  const { write } = fixture(t);
  const agents = write("AGENTS.override.md", "OVERRIDE");
  write("CLAUDE.md", "@./missing.md");
  assert.equal(bridgeContext(agents, "OVERRIDE"), "OVERRIDE");
});

test("fenced examples stay literal; ordinary repos gain no OPS context", (t) => {
  const { write } = fixture(t);
  const text = "Ordinary repo\n```\n@./missing.md\n```";
  const agents = write("AGENTS.md", text);
  assert.equal(bridgeContext(agents, text), text);
});

test("missing imports and symlink escapes fail visibly", (t) => {
  const { root, write } = fixture(t);
  const agents = write("AGENTS.md", "RULES");
  write("CLAUDE.md", "@./missing.md");
  assert.throws(() => bridgeContext(agents, "RULES"), /ENOENT/);
  fs.symlinkSync(os.tmpdir(), path.join(root, "escape"));
  write("CLAUDE.md", "@./escape/outside.md");
  // Use another fixture outside this repository, without creating shared filenames.
  const other = fixture(t);
  other.write("outside.md", "OTHER CONTEXT");
  fs.symlinkSync(
    path.join(other.root, "outside.md"),
    path.join(root, "linked.md"),
  );
  write("CLAUDE.md", "@./linked.md");
  assert.throws(() => bridgeContext(agents, "RULES"), /leaves its repository/);
});

test("extension replaces only the selected context and adds MTPLX session affinity", (t) => {
  const { write } = fixture(t);
  const file = write("AGENTS.md", "REPO");
  write("CLAUDE.md", "@./kernel.md\n@./AGENTS.md");
  write("kernel.md", "KERNEL");
  const handlers = {};
  extension({
    on: (event, handler) => {
      handlers[event] = handler;
    },
  });
  const result = handlers.before_agent_start({
    systemPrompt: `OTHER EXTENSION\n<project_instructions path="${file}">\nREPO\n</project_instructions>\nSKILLS`,
    systemPromptOptions: { contextFiles: [{ path: file, content: "REPO" }] },
  });
  assert.match(
    result.systemPrompt,
    /^OTHER EXTENSION[\s\S]*KERNEL[\s\S]*REPO[\s\S]*SKILLS$/,
  );
  const request = { headers: { "x-mtplx-client": "pi" } };
  handlers.before_provider_headers(request, {
    sessionManager: { getSessionId: () => "session-1" },
  });
  assert.equal(request.headers["x-mtplx-session-id"], "session-1");
  write("CLAUDE.md", "@./missing.md");
  assert.throws(
    () =>
      handlers.before_agent_start({
        systemPrompt: "",
        systemPromptOptions: {
          contextFiles: [{ path: file, content: "REPO" }],
        },
      }),
    /could not be loaded/,
  );
  assert.equal(handlers.tool_call().block, true);
});
