# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║          mbp2606 — Mailina Barta's user (second user on this host)          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Sibling of ./home.nix (Markus's `mba` backup/admin user on the same machine).
# Both are active independently — Home Manager standalone is per-user, so each
# account has its own $HOME, profile and generations and neither can clobber the
# other. Apply with:
#
#   home-manager switch --flake <checkout>#mailina@mbp2606
#
# ⚠️  ONE SHARED RESOURCE: Homebrew (/opt/homebrew + /Applications) is
# machine-wide, not per-user. `just bundle` is additive and safe from either
# account. `just bundle-cleanup` is NOT — it uninstalls every cask absent from
# the *invoking* user's Brewfile, so running it here would remove Markus's apps
# and vice versa. Do not run bundle-cleanup on this host (NIX-216).
#
# Deliberately NOT imported: modules/shared/markus-defaults.nix. That bundle
# carries Markus's git identity, his agent-secret roots and his PAIMOS instances
# — none of which belong in another person's account. She gets the tooling and
# comfort layer, with her own identity (NIX-216 decision, 2026-08-07).
#
{
  pkgs,
  lib,
  config,
  ...
}:

let
  macosCommon = import ../../modules/uzumaki/macos-common.nix { inherit pkgs lib; };
in
{
  # ============================================================================
  # Module Imports
  # ============================================================================
  # ssh-fleet.nix is intentionally absent: it force-manages ~/.ssh/config with
  # the fleet alias matrix, which is Markus's admin surface, not hers.
  imports = [
    ../../modules/uzumaki/home-manager.nix
  ];

  # ============================================================================
  # UZUMAKI — fish functions, theming, prompt
  # ============================================================================
  uzumaki = {
    enable = true;
    role = "workstation";
    fish.editor = "nano";
    stasysmo.enable = true; # system metrics in the Starship prompt
  };

  # Theme is per-HOST, so this matches ./home.nix — both users see the same
  # machine identity colour. Palette entry: modules/uzumaki/theme/theme-palettes.nix
  theme.hostname = "mbp2606";

  # ============================================================================
  # USER SETTINGS
  # ============================================================================
  home.username = "mailina";
  home.homeDirectory = "/Users/mailina";

  home.stateVersion = "24.11";
  home.enableNixpkgsReleaseCheck = false;
  programs.home-manager.enable = true;

  # ============================================================================
  # Git — her own identity
  # ============================================================================
  # userEmail is deliberately NOT set here: Mailina's address was never stated,
  # and inventing an identity is forbidden. Markus supplies it, then this line
  # gets uncommented. Until then git works for reading; a commit will ask for
  # an email rather than silently attributing it to the wrong person.
  programs.git = {
    enable = true;
    userName = "Mailina Barta";
    # userEmail = "…";   # ← Markus to fill in (NIX-216)
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };

  # ============================================================================
  # Fish Shell — same comfort as Markus's setup
  # ============================================================================
  programs.fish = {
    enable = true;

    shellInit = ''
      set -gx TERM xterm-256color
      set -gx EDITOR nano
      set -gx ZOXIDE_CMD z

      if test -d ~/.nix-profile/share/fish/vendor_completions.d
        set -p fish_complete_path ~/.nix-profile/share/fish/vendor_completions.d
      end
    '';

    loginShellInit = ''
      fish_add_path --prepend --move ~/.nix-profile/bin
      fish_add_path --prepend --move /nix/var/nix/profiles/default/bin
      # Homebrew (Apple Silicon) before system /usr/bin — brew-doctor compliance
      fish_add_path --prepend --move /opt/homebrew/bin
    '';

    interactiveShellInit = ''
      function fish_greeting
          set_color cyan
          echo -n "Welcome to fish, the friendly interactive shell "
          set_color green
          echo -n (whoami)"@"(hostname -s)
          set_color yellow
          echo -n " · "(date "+%Y-%m-%d %H:%M")
          set_color normal
      end

      zoxide init fish | source
    '';
  };

  # ============================================================================
  # Packages — the shared macOS toolkit (includes `just`)
  # ============================================================================
  # Same single source of truth as every other macOS host, so anything added to
  # commonPackages reaches her too. Markus's agent tooling (agenix, the inspr
  # CLI) is deliberately excluded — it is bound to his credentials.
  home.packages = macosCommon.commonPackages;

  # macOS `defaults` (SSOT: macos-common.nix) — stops Finder writing .DS_Store
  # to network shares and USB drives.
  targets.darwin.defaults = macosCommon.darwinDefaults;

  home.activation.checkLoginShell = macosCommon.loginShellCheckActivation "${config.home.homeDirectory}/.nix-profile/bin/fish";

  # ============================================================================
  # Brewfile — her GUI apps (apply with `just bundle`)
  # ============================================================================
  # Baseline only: ghostty, karabiner-elements, zen, google-chrome, stats,
  # rustdesk come from macosCommon's commonCasks. NO third-party taps here on
  # purpose — steipete/tap and darrylmorley/whatcable each need a one-time
  # `brew trust` per host, and those tools are Markus's, not hers.
  #
  # Apps she already uses that were installed by hand belong in extraCasks so
  # they become reproducible instead of manual (NIX-216). Add them as they are
  # identified — an empty list here means "baseline only", not "nothing".
  home.file.".config/homebrew/Brewfile".text = macosCommon.mkBrewfile {
    extraCasks = [
      # e.g. "spotify", "whatsapp" — to be filled from what is actually
      # installed on the machine today.
    ];
  };
}
