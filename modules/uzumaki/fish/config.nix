# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                   Fish Shell Aliases & Abbreviations                         ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Shared fish shell configuration for ALL platforms (NixOS + macOS).
# Contains ONLY aliases and abbreviations - functions are in functions.nix.
#
# Used by:
#   - modules/shared/fish/default.nix (exports for uzumaki module)
#   - modules/common.nix (NixOS base)
#   - modules/uzumaki/macos-common.nix (macOS)
#
# Note: Consolidated from modules/shared/fish-config.nix as part of
# the uzumaki module restructure (Phase 3).
#
{
  # ════════════════════════════════════════════════════════════════════════════
  # ALIASES - Direct command replacements
  # ════════════════════════════════════════════════════════════════════════════
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

  # ════════════════════════════════════════════════════════════════════════════
  # ABBREVIATIONS - Expand on Space (modern CLI replacements)
  # ════════════════════════════════════════════════════════════════════════════
  fishAbbrs = {
    # Override hokage's nano→micro (we prefer nano)
    nano = "nano";
    killall = "pkill";
    "docker-upf" = "docker compose up -d --force-recreate --remove-orphans";
    less = "bat";
    man = "batman";
    du = "dua";
    ncdu = "dua interactive";
    df = "duf";
    tree = "erd";
    tmux = "zellij";
    dig = "dog";
    diff = "difft";
    ping = "pingt"; # Function provided by shared/fish/functions.nix
    tar = "ouch";
    ps = "procs";
    whois = "rdap";
    vim = "hx";
    c = "clear";
    cl = "clear";

    # ═══════════════════════════════════════════════════════════
    # SSH Shortcuts (zellij auto-attach)
    # SSH config handles LAN/Tailscale fallback automatically
    # See: modules/shared/ssh-fleet.nix
    # ═══════════════════════════════════════════════════════════

    # Home network
    hsb0 = "ssh hsb0 -t 'zellij attach hsb0 -c'";
    hsb1 = "ssh hsb1 -t 'zellij attach hsb1 -c'";
    hsb2 = "ssh hsb2 -t 'tmux new-session -A -s hsb2'"; # tmux (ARMv6, no zellij)
    hsb8 = "ssh hsb8 -t 'zellij attach hsb8 -c'";
    gpc0 = "ssh gpc0 -t 'zellij attach gpc0 -c'";
    imac0 = "ssh imac0 -t 'zellij attach imac0 -c'";

    # Work network (nicknames)
    imacw = "ssh imacw -t 'zellij attach imacw -c'"; # → mba-imac-work
    msbp = "ssh msbp -t 'zellij attach msbp -c'"; # → miniserver-bp

    # Portable (nickname)
    mbpw = "ssh mbpw -t 'zellij attach mbpw -c'"; # → mba-mbp-work

    # Cloud
    csb0 = "ssh csb0 -t 'zellij attach csb0 -c'";
    csb1 = "ssh csb1 -t 'zellij attach csb1 -c'";
  };
}
