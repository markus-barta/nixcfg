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
#   - Fish functions: pingt, stress, helpfish, hostcolors, hostsecrets, sourcefish, imacw
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

in
{
  # ══════════════════════════════════════════════════════════════════════════════
  # IMPORTS
  # ══════════════════════════════════════════════════════════════════════════════

  imports = [
    ./options.nix
    ./stasysmo/home-manager.nix # StaSysMo for Home Manager (launchd on macOS)
    ./theme/theme-hm.nix # Per-host theming (starship, zellij, eza)
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
        // lib.optionalAttrs cfg.fish.functions.helpfish { inherit (fishFunctions) helpfish; }
        // lib.optionalAttrs cfg.fish.functions.imacw { inherit (fishFunctions) imacw; };

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
    # Packages
    # ══════════════════════════════════════════════════════════════════════════

    home.packages = [
      pkgs.pingt # Timestamped ping with color-coded output
      pkgs.watch # Run command repeatedly, showing output (not in macOS by default)
      pkgs.age # Modern encryption tool (reference implementation)
    ]
    ++ lib.optionals cfg.zellij.enable [ pkgs.zellij ];

    # ══════════════════════════════════════════════════════════════════════════
    # StaSysMo - System Monitoring
    # ══════════════════════════════════════════════════════════════════════════
    # Enabled via uzumaki.stasysmo.enable
    # The stasysmo/home-manager.nix module handles launchd service setup

    services.stasysmo.enable = cfg.stasysmo.enable;

    # ══════════════════════════════════════════════════════════════════════════
    # Nix Configuration (NCPS Binary Cache Proxy)
    # ══════════════════════════════════════════════════════════════════════════
    # hsb0.lan provides a local cache for the home network.
    # We always manage the file (file handles), but only add the local cache
    # entries if uzumaki.ncps.enable is true.
    nix.package = pkgs.nix;
    nix.settings = {
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
