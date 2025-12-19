# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                   Uzumaki Module Options                                     ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Options for the uzumaki module - the "son of hokage".
# Provides personalized tooling and theming on top of hokage's foundation.
#
# This file defines the interface. Implementation is in:
#   - nixos.nix (NixOS systems)
#   - darwin.nix (macOS via Home Manager)
#
{ lib, ... }:

{
  options.uzumaki = {
    # ══════════════════════════════════════════════════════════════════════════
    # Core Options
    # ══════════════════════════════════════════════════════════════════════════

    enable = lib.mkEnableOption "Uzumaki module - personalized tooling & theming";

    role = lib.mkOption {
      type = lib.types.enum [
        "server"
        "desktop"
        "workstation"
      ];
      default = "server";
      description = ''
        Host role determines default package sets and configurations:
        - server: Minimal, headless, no GUI packages
        - desktop: Full GUI with Plasma, gaming support
        - workstation: macOS development workstation
      '';
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Feature Flags
    # ══════════════════════════════════════════════════════════════════════════

    fish = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable uzumaki fish functions (pingt, stress, helpfish, imacw, etc.)";
      };

      functions = {
        pingt = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable pingt - timestamped ping with color-coded output";
        };

        stress = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable stress - CPU stress test with all cores";
        };

        helpfish = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable helpfish - show custom functions & abbreviations";
        };

        hostcolors = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable hostcolors - show infrastructure hosts with color themes";
        };

        hostsecrets = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable hostsecrets - show runbook secrets status for all hosts";
        };

        sourcefish = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable sourcefish - load env vars from .env files";
        };

        stasysmod = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable stasysmod - toggle StaSysMo debug mode";
        };

        imacw = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable imacw - SSH to mba-imac-work via BYTEPOETS VPN";
        };

      };

      editor = lib.mkOption {
        type = lib.types.str;
        default = "nano";
        description = "Default EDITOR environment variable";
      };
    };

    zellij = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Install and configure zellij terminal multiplexer";
      };
    };

    stasysmo = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true; # Default ON for all uzumaki hosts
        description = ''
          Enable StaSysMo system monitoring integration.
          When enabled, uzumaki automatically imports and configures the
          stasysmo module (CPU, RAM, Load, Swap in Starship prompt).
        '';
      };
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Platform Detection (set automatically by default.nix)
    # ══════════════════════════════════════════════════════════════════════════

    platform = lib.mkOption {
      type = lib.types.enum [
        "nixos"
        "darwin"
      ];
      internal = true;
      description = "Detected platform (set automatically)";
    };
  };
}
