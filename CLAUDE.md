<!--
  Layered doctrine loader for Claude Code.

  Loads the kernel + this repo's delta. It deliberately does NOT load
  AGENTS.md: that file exists for tools which read AGENTS.md but do not
  follow @-refs (Cursor, Aider, OpenCode, Codex CLI), and its only
  content is a 🔴 subset of the kernel. Loading it here would make Claude
  read the kernel twice — 1.7 kB of duplication on every turn.

  Doctrine source: github.com/inspr-at/inspr-modules, vendored as the
  ./doctrine submodule; bump with `git submodule update --remote doctrine`.
-->

@./doctrine/docs/AGENTS-KERNEL.md
@./AGENTS-NIXCFG.md
