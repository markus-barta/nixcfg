<!--
  Layered doctrine loader for Claude Code.

  Other tools (Cursor, OpenCode, Zed, Codex CLI, etc.) read AGENTS.md
  instead — that's the per-repo thin overlay with universal/profile rules
  pointed-to by URL (those tools don't auto-fetch).

  Role-specific overlays (sysop, openclaw-ops, ppm, etc.) load on demand
  via slash commands like /ops or /ocbots.

  Doctrine source: github.com/markus-barta/inspr-modules vendored as the
  ./doctrine git submodule; bumped intentionally with `git submodule
  update --remote doctrine`.
-->

@./doctrine/docs/AGENTS-CORE.md
@./doctrine/docs/AGENTS-PROFILE-MARKUS.md
@./AGENTS.md
