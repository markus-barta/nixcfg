# agent-kernel.nix — public + private kernel on four CLIs (NIX-511)
#
# Replace: Pi and Grok global AGENTS.md.
# Marker: Codex AGENTS.md and Claude user CLAUDE.md (keep personal text).
# extraSources: studio private kernel. No force on replace slots.
# OPS-737: opting into aeonOperatorMac replaces Claude's inline marker payload
# with two single-source imports. The default retains the four-CLI behavior.

{
  config,
  inputs,
  lib,
  ...
}:

{
  imports = [
    inputs.inspr-modules.homeManagerModules.agent-kernel
    ./aeon-operator-mac.nix
  ];

  inspr.agent-kernel = {
    enable = true;
    extraSources = [ ./agent-kernel-private.md ];
    harnesses = {
      pi = ".pi/agent/AGENTS.md";
      grok = ".grok/AGENTS.md";
    };
    markerHarnesses = {
      codex = ".codex/AGENTS.md";
    }
    // lib.optionalAttrs (!config.inspr.aeonOperatorMac.enable) {
      claude = ".claude/CLAUDE.md";
    };
  };

  home.file.".pi/agent/prompts/inspr.md".source = "${inputs.inspr-modules}/commands/inspr.md";
  home.file.".pi/agent/prompts/inspr-versioning.md".source =
    "${inputs.inspr-modules}/commands/inspr-versioning.md";
}
