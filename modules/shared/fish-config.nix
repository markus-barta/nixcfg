# Shared fish shell configuration for both NixOS and macOS
# Can be imported by both system configurations and Home Manager
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
    ping = "pingt"; # not "gping"
    tar = "ouch";
    ps = "procs";
    whois = "rdap";
    vim = "hx";
    # nano = "micro"; # no one likes micro
  };
}
