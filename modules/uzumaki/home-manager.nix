# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                   Uzumaki Module - Home Manager Entry Point                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# The "son of hokage" - Home Manager variant for macOS and NixOS user configs.
# This module provides the same features as default.nix but via Home Manager.
#
# Usage (macOS home.nix):
#   imports = [ ../../modules/uzumaki/home-manager.nix ];
#   uzumaki = {
#     enable = true;
#     role = "workstation";
#   };
#
# Features:
#   - Fish functions: pingt, stress, helpfish, hostcolors, hostsecrets, sourcefish
#   - Zellij terminal multiplexer
#   - StaSysMo system monitoring (launchd on macOS)
#   - Per-host theming (starship, zellij, eza)
#
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.uzumaki;

  # Import fish configuration (consolidated into uzumaki)
  fishModule = import ./fish;
  fishFunctions = fishModule.functions;
  fishAliases = fishModule.aliases;
  fishAbbrs = fishModule.abbreviations;

  # ════════════════════════════════════════════════════════════════════════════
  # Generate function list for helpfish from functions.nix
  # ════════════════════════════════════════════════════════════════════════════
  # Extract function data (name + description) from all functions
  helpfishFunctionList = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: def: ''printf " $color_func%-12s$color_reset %-58s\n" "${name}" "${def.description}"''
    ) fishFunctions
  );

  # Replace @FUNCTION_LIST@ placeholder in helpfish body
  helpfishWithDynamicList = fishFunctions.helpfish // {
    body =
      lib.replaceStrings [ "@FUNCTION_LIST@" ] [ helpfishFunctionList ]
        fishFunctions.helpfish.body;
  };

in
{
  # ══════════════════════════════════════════════════════════════════════════════
  # IMPORTS
  # ══════════════════════════════════════════════════════════════════════════════

  imports = [
    ./options.nix
    ./stasysmo/home-manager.nix # StaSysMo for Home Manager (launchd on macOS)
    ./theme/theme-hm.nix # Per-host theming (starship, zellij, eza)
    ./ai-clis-npm.nix # Always-latest AI CLIs (claude-code, codex, grok, pi) via npm
    ./codex-exit-alias.nix # Codex hook: exact "exit" prompt sends /exit on macOS
    ./claude-skills.nix # Pinned ~/.claude/skills/ (frontend-design, …)
  ];

  # ══════════════════════════════════════════════════════════════════════════════
  # CONFIGURATION (Home Manager - macOS and NixOS home.nix)
  # ══════════════════════════════════════════════════════════════════════════════

  config = lib.mkIf cfg.enable {
    # Platform marker
    uzumaki.platform = "darwin";

    # ══════════════════════════════════════════════════════════════════════════
    # Fish Shell Configuration
    # ══════════════════════════════════════════════════════════════════════════

    programs.fish = lib.mkIf cfg.fish.enable {
      # Fish functions via Home Manager's programs.fish.functions
      functions =
        { }
        // lib.optionalAttrs cfg.fish.functions.pingt { inherit (fishFunctions) pingt; }
        // lib.optionalAttrs cfg.fish.functions.sourcefish { inherit (fishFunctions) sourcefish; }
        // lib.optionalAttrs cfg.fish.functions.stress { inherit (fishFunctions) stress; }
        // lib.optionalAttrs cfg.fish.functions.stasysmod { inherit (fishFunctions) stasysmod; }
        // lib.optionalAttrs cfg.fish.functions.hostcolors { inherit (fishFunctions) hostcolors; }
        // lib.optionalAttrs cfg.fish.functions.hostsecrets { inherit (fishFunctions) hostsecrets; }
        // lib.optionalAttrs cfg.fish.functions.helpfish { helpfish = helpfishWithDynamicList; }
        // lib.optionalAttrs cfg.fish.functions.ccc { inherit (fishFunctions) ccc; };

      # Shell aliases from uzumaki/fish
      shellAliases = fishAliases;

      # Shell abbreviations from uzumaki/fish
      shellAbbrs = fishAbbrs;

      # Editor environment variable
      interactiveShellInit = lib.mkAfter ''
        # Uzumaki - Editor Configuration
        set -gx EDITOR ${cfg.fish.editor}
      '';
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Fresh — terminal IDE / text editor (getfresh.dev)
    # ══════════════════════════════════════════════════════════════════════════
    # Upstream home-manager module (programs.fresh-editor); package is
    # pkgs.fresh-editor (Hydra-cached). Enable only — leave $EDITOR to
    # cfg.fish.editor above; flip defaultEditor per-host if you want it global.
    programs.fresh-editor.enable = true;

    # ══════════════════════════════════════════════════════════════════════════
    # Packages
    # ══════════════════════════════════════════════════════════════════════════

    home.packages = [
      pkgs.pingt # Timestamped ping with color-coded output
      pkgs.watch # Run command repeatedly, showing output (not in macOS by default)
      pkgs.age # Modern encryption tool (reference implementation)
      # pkgs.nixfleet-agent # Disabled (decommissioned, replaced by FleetCom DSC26-52)
    ]
    ++ lib.optionals cfg.zellij.enable [ pkgs.zellij ];

    # ══════════════════════════════════════════════════════════════════════════
    # StaSysMo - System Monitoring
    # ══════════════════════════════════════════════════════════════════════════
    # Enabled via uzumaki.stasysmo.enable
    # The stasysmo/home-manager.nix module handles launchd service setup

    services.stasysmo.enable = cfg.stasysmo.enable;

    # ══════════════════════════════════════════════════════════════════════════
    # Karabiner-Elements configuration
    # ══════════════════════════════════════════════════════════════════════════
    # Config is declarative and fleet-wide. The Karabiner-Elements app itself
    # stays a manual Homebrew install because it is a system-level input-event
    # tool that also requires macOS Input Monitoring approval.
    home.file.".config/karabiner/karabiner.json".source = ../config/karabiner.json;

    home.activation.checkKarabinerInstall = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ "$(uname -s)" = "Darwin" ] && [ ! -d "/Applications/Karabiner-Elements.app" ]; then
        echo "WARN: Karabiner config is managed at ~/.config/karabiner/karabiner.json, but Karabiner-Elements.app is not installed."
        echo "      Install manually: brew install --cask karabiner-elements"
        echo "      Then grant Input Monitoring to karabiner_grabber and Karabiner-Elements."
      fi
    '';

    # ══════════════════════════════════════════════════════════════════════════
    # Nix Configuration (NCPS Binary Cache Proxy)
    # ══════════════════════════════════════════════════════════════════════════
    # hsb0 provides a local binary cache for the home network.
    # .lan resolution works via headscale split DNS → hsb0 AdGuard.
    # Only adds the local cache entries if uzumaki.ncps.enable is true.
    nix.package = pkgs.nix;
    nix.settings = {
      # Allow flakes and nix-command (required for nix flake commands)
      experimental-features = [
        "nix-command"
        "flakes"
      ];

      # Defensive timeouts so a single sick substituter (e.g. hsb0 ncps
      # stalling on a slow upstream stream) can't gate a rebuild for the
      # default 5 minutes. `fallback = true` (system-level default) sends
      # the build straight to the next substituter after the trigger.
      connect-timeout = 5;
      stalled-download-timeout = 30;

      substituters = lib.mkOverride 0 (
        [
          "https://cache.nixos.org"
          "https://nix-community.cachix.org"
        ]
        ++ lib.optionals cfg.ncps.enable [ "http://hsb0.lan:8501" ]
      );
      trusted-public-keys = lib.mkOverride 0 (
        [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ]
        ++ lib.optionals cfg.ncps.enable [ "hsb0.lan-1:jKVnVnEwJPaevI5NyBKBtk7mJGPQ3EMlIoPb7VmPcD0=" ]
      );
    };
  };
}
