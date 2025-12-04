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
#   - Fish functions: pingt, stress, helpfish, sourcefish, sourceenv
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
  fishConfig = fishModule.config;

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
        // lib.optionalAttrs cfg.fish.functions.sourceenv { inherit (fishFunctions) sourceenv; }
        // lib.optionalAttrs cfg.fish.functions.stress { inherit (fishFunctions) stress; }
        // lib.optionalAttrs cfg.fish.functions.helpfish { inherit (fishFunctions) helpfish; };

      # Shell aliases from shared config
      shellAliases = fishConfig.fishAliases;

      # Shell abbreviations from shared config
      shellAbbrs = fishConfig.fishAbbrs;

      # Editor environment variable
      interactiveShellInit = lib.mkAfter ''
        # Uzumaki - Editor Configuration
        set -gx EDITOR ${cfg.fish.editor}
      '';
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Packages
    # ══════════════════════════════════════════════════════════════════════════

    home.packages = lib.mkIf cfg.zellij.enable [ pkgs.zellij ];

    # ══════════════════════════════════════════════════════════════════════════
    # StaSysMo - System Monitoring
    # ══════════════════════════════════════════════════════════════════════════
    # Enabled via uzumaki.stasysmo.enable
    # The stasysmo/home-manager.nix module handles launchd service setup

    services.stasysmo.enable = cfg.stasysmo.enable;
  };
}
