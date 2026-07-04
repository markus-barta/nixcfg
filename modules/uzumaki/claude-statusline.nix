# claude-statusline.nix — declarative Claude Code statusline
#
# Ships ~/.claude/statusline.sh as a read-only symlink into /nix/store:
# single-line transparent typographic footer (truecolor, nerd-font glyphs,
# catppuccin-mocha accents, no backgrounds) rendering session · repo · git ·
# PR · model · effort · context battery with auto-compact notch · € cost
# (cached ECB rate) + burn rate · 5h/7d Anthropic rate limits · duration ·
# diff · clock, joined by dim · separators.
#
# The companion script (claude-statusline.sh, same directory) is plain bash
# and directly executable for local iteration; at build time the imperative
# jq path is rewritten to the nix-pinned store path, so the deployed copy
# never depends on ~/.nix-profile.
#
# NOTE: ~/.claude/settings.json stays imperative — Claude Code rewrites it at
# runtime (model switches, permission acks), so it must NOT be an HM symlink.
# The statusline is activated there via:
#   "statusLine": { "type": "command", "command": "~/.claude/statusline.sh",
#                   "padding": 0, "refreshInterval": 5 }
#
# Payload reference: https://code.claude.com/docs/en/statusline
# Design provenance: NIX session 2026-07-04 — catppuccin-tmux pill formula,
# glyphs codepoint-verified against nerd-fonts glyphnames.json.
{ lib, pkgs, ... }:

{
  home.file.".claude/statusline.sh" = {
    executable = true;
    text = builtins.replaceStrings [ "/Users/markus/.nix-profile/bin/jq" ] [ (lib.getExe pkgs.jq) ] (
      builtins.readFile ./claude-statusline.sh
    );
  };
}
