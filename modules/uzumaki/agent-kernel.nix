# agent-kernel.nix — load the public INSPR kernel into Pi (NIX-508)
#
# Thin consumer of inspr-modules' `homeManagerModules.agent-kernel`.
# Pi does not follow Claude Code `@-ref`s; the atelier module materializes
# `docs/AGENTS-KERNEL.md` at `~/.pi/agent/AGENTS.md`. No `force`.

{ inputs, ... }:

{
  imports = [ inputs.inspr-modules.homeManagerModules.agent-kernel ];

  inspr.agent-kernel.enable = true;
}
