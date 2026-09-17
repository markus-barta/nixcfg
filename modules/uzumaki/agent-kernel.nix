# agent-kernel.nix — public + private kernel on four CLIs (NIX-511)
#
# Replace: Pi and Grok global AGENTS.md.
# Marker: Codex AGENTS.md and Claude user CLAUDE.md (keep personal text).
# extraSources: studio private kernel. No force on replace slots.

{ inputs, ... }:

{
  imports = [ inputs.inspr-modules.homeManagerModules.agent-kernel ];

  inspr.agent-kernel = {
    enable = true;
    extraSources = [ ../../doctrine-private/docs/AGENTS-KERNEL-PRIVATE.md ];
    harnesses = {
      pi = ".pi/agent/AGENTS.md";
      grok = ".grok/AGENTS.md";
    };
    markerHarnesses = {
      codex = ".codex/AGENTS.md";
      claude = ".claude/CLAUDE.md";
    };
  };

  home.file.".pi/agent/prompts/inspr.md".source = "${inputs.inspr-modules}/commands/inspr.md";
  home.file.".pi/agent/prompts/inspr-versioning.md".source =
    "${inputs.inspr-modules}/commands/inspr-versioning.md";
}
