// Pi loads one context file per directory but does not expand Claude @imports.
// Expand only the contexts Pi actually selected, preserving its ancestor and
// worktree rules. Private doctrine is read at runtime, never copied into Nix.
import fs from "node:fs";
import path from "node:path";

export function expandContext(
  file,
  content,
  seen = new Set(),
  budget = { bytes: 0 },
) {
  const canonical = fs.realpathSync(file);
  if (seen.has(canonical)) return "";
  seen.add(canonical);
  budget.bytes += Buffer.byteLength(content);
  if (seen.size > 64 || budget.bytes > 512 * 1024) {
    throw new Error("Doctrine imports exceed 64 files / 512 KiB");
  }
  const lines = content.split("\n");
  let fence = false;
  return lines
    .map((line) => {
      if (/^\s*(```|~~~)/.test(line)) fence = !fence;
      const match = !fence && line.match(/^\s*@([^\s]+\.md)\s*$/i);
      if (!match) return line;
      const target = path.resolve(path.dirname(file), match[1]);
      // Only repo-local Markdown imports. Never follow imports into another repo,
      // a home secret directory, or an external URL (including symlink escapes).
      let root = path.dirname(file);
      while (
        !fs.existsSync(path.join(root, ".git")) &&
        path.dirname(root) !== root
      ) {
        root = path.dirname(root);
      }
      if (path.dirname(root) === root) root = path.dirname(file);
      const realTarget = fs.realpathSync(target);
      const relative = path.relative(fs.realpathSync(root), realTarget);
      if (
        relative.startsWith("..") ||
        path.isAbsolute(relative) ||
        /(^|\/)(\.ssh|\.inspr|Secrets|secrets)(\/|$)/.test(relative)
      ) {
        throw new Error(
          `Doctrine import leaves its repository or targets secrets: ${target}`,
        );
      }
      return expandContext(
        target,
        fs.readFileSync(target, "utf8"),
        seen,
        budget,
      );
    })
    .join("\n");
}

export function bridgeContext(file, content) {
  // Explicit overrides retain their native meaning; do not add CLAUDE beside one.
  if (path.basename(file) === "AGENTS.override.md")
    return expandContext(file, content);
  const claude = ["CLAUDE.md", "CLAUDE.MD"]
    .map((name) => path.join(path.dirname(file), name))
    .find((candidate) => fs.existsSync(candidate));
  const seen = new Set();
  const budget = { bytes: 0 };
  const parts = [];
  if (claude)
    parts.push(
      expandContext(claude, fs.readFileSync(claude, "utf8"), seen, budget),
    );
  parts.push(expandContext(file, content, seen, budget));
  return parts.filter(Boolean).join("\n\n");
}

export default function piLocalContext(pi) {
  let contextError;
  pi.on("tool_call", () =>
    contextError ? { block: true, reason: contextError } : undefined,
  );
  pi.on("before_provider_headers", (event, ctx) => {
    if (event.headers["x-mtplx-client"] === "pi") {
      event.headers["x-mtplx-session-id"] = String(
        ctx.sessionManager.getSessionId(),
      );
    }
  });
  pi.on("before_agent_start", (event) => {
    contextError = undefined;
    try {
      let prompt = event.systemPrompt;
      for (const file of event.systemPromptOptions.contextFiles ?? []) {
        const marker = `<project_instructions path="${file.path}">\n${file.content}\n</project_instructions>`;
        const expanded = bridgeContext(file.path, file.content);
        if (!prompt.includes(marker))
          throw new Error(
            "Pi context format changed; check pi-local-context.js",
          );
        prompt = prompt.replace(
          marker,
          () =>
            `<project_instructions path="${file.path}">\n${expanded}\n</project_instructions>`,
        );
      }
      return { systemPrompt: prompt };
    } catch (error) {
      contextError = `pi-local doctrine could not be loaded: ${error.message}. Restore the referenced files before using tools.`;
      throw new Error(contextError);
    }
  });
}
