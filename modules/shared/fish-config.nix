# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                   DEPRECATED - Use shared/fish/ instead                      ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# This file is kept for backward compatibility.
# New code should import from: modules/shared/fish
#
# Migration (Phase 3 of uzumaki restructure):
#   OLD: import ../shared/fish-config.nix
#   NEW: import ../shared/fish
#
# The new location provides:
#   - sharedFish.functions (pingt, stress, helpfish, etc.)
#   - sharedFish.aliases (gitc, gitps, ll, etc.)
#   - sharedFish.abbreviations (ping→pingt, tmux→zellij, etc.)
#
# TODO: Remove this file in Phase 6 cleanup after all hosts migrated.
#
import ./fish/config.nix
