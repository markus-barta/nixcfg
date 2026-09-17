# agent-kernel.nix — load the public INSPR kernel into Pi (NIX-506)
#
# Pi does not follow Claude Code `@-ref`s, so a repo `CLAUDE.md` that
# points at `doctrine/docs/AGENTS-KERNEL.md` never reaches a Pi session.
# Pi always concatenates `~/.pi/agent/AGENTS.md`. This module materializes
# that file from the pinned `inspr-modules` kernel.
#
# Kernel bytes come from the existing flake input. This ticket does not
# bump that pin. When the pin includes `homeManagerModules.agent-kernel`
# (INSPR-445), replace this file with that import.
#
# No `force`: a user-owned `~/.pi/agent/AGENTS.md` blocks activation.

{ inputs, ... }:

{
  home.file.".pi/agent/AGENTS.md" = {
    source = "${inputs.inspr-modules}/docs/AGENTS-KERNEL.md";
  };
}
