# Shared Fish shell configuration for ALL platforms (NixOS + macOS)
# Contains ONLY aliases and abbreviations - NO functions!
# Functions are provided by uzumaki/common.nix
#
# Used by:
#   - modules/common.nix (NixOS base)
#   - modules/uzumaki/macos-common.nix (macOS)
#
{
  # Common fish shell aliases used across all systems
  fishAliases = {
    # Git aliases
    gitc = "git commit";
    gitps = "git push";
    gitplr = "git pull --rec";
    gitpl = "git pull && git submodule update --init";
    gitsub = "git submodule update --init";
    gitpls = "git pull";
    gita = "git add -A";
    gitst = "git status";
    gitd = "git diff";
    gitds = "git diff --staged";
    gitl = "git log";

    # Editor aliases
    vim = "nvim";

    # Utility aliases
    ll = "eza -hal --icons --group-directories-first";
    fish-reload = "exec fish";
    lg = "lazygit";
    duai = "dua interactive";
    j = "just";
  };

  # Common fish shell abbreviations used across all systems
  # Note: ping→pingt requires uzumaki module for the pingt function
  fishAbbrs = {
    killall = "pkill";
    less = "bat";
    man = "batman";
    du = "dua";
    ncdu = "dua interactive";
    df = "duf";
    tree = "erd";
    tmux = "zellij";
    dig = "dog";
    diff = "difft";
    ping = "pingt"; # Function provided by uzumaki/common.nix
    tar = "ouch";
    ps = "procs";
    whois = "rdap";
    vim = "hx";
  };
}
