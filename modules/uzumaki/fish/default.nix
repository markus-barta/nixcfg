# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                   Fish Shell Configuration - Shared                          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Consolidated fish shell configuration for all platforms.
# This is the single source of truth for fish functions, aliases, and abbreviations.
#
# Structure:
#   - functions.nix: Custom functions (pingt, stress, helpfish, etc.)
#   - config.nix: Aliases and abbreviations
#
# Used by:
#   - modules/uzumaki/default.nix (the uzumaki module)
#   - modules/common.nix (NixOS base config)
#   - modules/uzumaki/macos-common.nix (macOS config)
#
{
  # Fish functions (pingt, stress, helpfish, sourcefish)
  functions = import ./functions.nix;

  # Fish aliases (gitc, gitps, ll, etc.)
  aliases = (import ./config.nix).fishAliases;

  # Fish abbreviations (ping→pingt, tmux→zellij, ssh shortcuts, etc.)
  abbreviations = (import ./config.nix).fishAbbrs;
}
