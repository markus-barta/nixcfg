# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                     SYSMON MODULE - System Metrics for Starship              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Provides system metrics (CPU, RAM, Load, Swap) in the Starship prompt via a
# background daemon that pre-computes values for instant reading.
#
# This is a NixOS module for systemd services. For macOS/Home Manager, use
# sysmon-hm.nix instead.
#
# Usage (NixOS - configuration.nix):
#   imports = [ ../../modules/shared/sysmon.nix ];
#   services.sysmon.enable = true;
#
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.sysmon;

  # ════════════════════════════════════════════════════════════════════════════
  # SCRIPT PACKAGES
  # ════════════════════════════════════════════════════════════════════════════

  # Daemon script package
  sysmon-daemon = pkgs.writeShellScriptBin "sysmon-daemon" (builtins.readFile ./sysmon-daemon.sh);

  # Reader script package with configuration baked in
  sysmon-reader = pkgs.writeShellScriptBin "sysmon-reader" ''
    # Configuration from Nix options
    export SYSMON_MAX_BUDGET="${toString cfg.maxBudget}"
    export SYSMON_MIN_TERMINAL="${toString cfg.minTerminalWidth}"
    export SYSMON_STALE_THRESHOLD="${toString cfg.staleThreshold}"

    # CPU thresholds
    export SYSMON_CPU_ELEVATED="${toString (builtins.elemAt cfg.metrics.cpu.thresholds 0)}"
    export SYSMON_CPU_CRITICAL="${toString (builtins.elemAt cfg.metrics.cpu.thresholds 1)}"

    # RAM thresholds
    export SYSMON_RAM_ELEVATED="${toString (builtins.elemAt cfg.metrics.ram.thresholds 0)}"
    export SYSMON_RAM_CRITICAL="${toString (builtins.elemAt cfg.metrics.ram.thresholds 1)}"

    # Load thresholds
    export SYSMON_LOAD_ELEVATED="${toString (builtins.elemAt cfg.metrics.load.thresholds 0)}"
    export SYSMON_LOAD_CRITICAL="${toString (builtins.elemAt cfg.metrics.load.thresholds 1)}"

    # Swap thresholds
    export SYSMON_SWAP_ELEVATED="${toString (builtins.elemAt cfg.metrics.swap.thresholds 0)}"
    export SYSMON_SWAP_CRITICAL="${toString (builtins.elemAt cfg.metrics.swap.thresholds 1)}"

    # Icons
    export SYSMON_ICON_CPU="${cfg.metrics.cpu.icon}"
    export SYSMON_ICON_RAM="${cfg.metrics.ram.icon}"
    export SYSMON_ICON_LOAD="${cfg.metrics.load.icon}"
    export SYSMON_ICON_SWAP="${cfg.metrics.swap.icon}"

    # Run the reader script
    ${builtins.readFile ./sysmon-reader.sh}
  '';

in
{
  # ════════════════════════════════════════════════════════════════════════════
  # MODULE OPTIONS
  # ════════════════════════════════════════════════════════════════════════════

  options.services.sysmon = {
    enable = lib.mkEnableOption "sysmon system metrics daemon for Starship";

    interval = lib.mkOption {
      type = lib.types.int;
      default = 5000;
      description = "Sampling interval in milliseconds";
    };

    maxBudget = lib.mkOption {
      type = lib.types.int;
      default = 45;
      description = "Maximum character budget for metrics display";
    };

    minTerminalWidth = lib.mkOption {
      type = lib.types.int;
      default = 100;
      description = "Minimum terminal width to show metrics (hidden if narrower)";
    };

    staleThreshold = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Seconds after which data is considered stale";
    };

    metrics = {
      cpu = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable CPU percentage metric";
        };
        icon = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Icon for CPU metric (Nerd Font)";
        };
        thresholds = lib.mkOption {
          type = lib.types.listOf lib.types.int;
          default = [
            50
            80
          ];
          description = "Thresholds for [elevated, critical] coloring";
        };
        priority = lib.mkOption {
          type = lib.types.int;
          default = 100;
          description = "Display priority (higher = more important)";
        };
      };

      ram = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable RAM percentage metric";
        };
        icon = lib.mkOption {
          type = lib.types.str;
          default = "";
          description = "Icon for RAM metric (Nerd Font)";
        };
        thresholds = lib.mkOption {
          type = lib.types.listOf lib.types.int;
          default = [
            70
            90
          ];
          description = "Thresholds for [elevated, critical] coloring";
        };
        priority = lib.mkOption {
          type = lib.types.int;
          default = 90;
          description = "Display priority (higher = more important)";
        };
      };

      load = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable load average metric";
        };
        icon = lib.mkOption {
          type = lib.types.str;
          default = "󰊚";
          description = "Icon for load metric (Nerd Font)";
        };
        thresholds = lib.mkOption {
          type = lib.types.listOf lib.types.number;
          default = [
            2.0
            4.0
          ];
          description = "Thresholds for [elevated, critical] coloring";
        };
        priority = lib.mkOption {
          type = lib.types.int;
          default = 70;
          description = "Display priority (higher = more important)";
        };
      };

      swap = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable swap percentage metric";
        };
        icon = lib.mkOption {
          type = lib.types.str;
          default = "󰾴";
          description = "Icon for swap metric (Nerd Font)";
        };
        thresholds = lib.mkOption {
          type = lib.types.listOf lib.types.int;
          default = [
            10
            50
          ];
          description = "Thresholds for [elevated, critical] coloring";
        };
        priority = lib.mkOption {
          type = lib.types.int;
          default = 60;
          description = "Display priority (higher = more important)";
        };
      };
    };
  };

  # ════════════════════════════════════════════════════════════════════════════
  # NIXOS CONFIGURATION (systemd)
  # ════════════════════════════════════════════════════════════════════════════

  config = lib.mkIf cfg.enable {
    # Install scripts to PATH
    environment.systemPackages = [
      sysmon-daemon
      sysmon-reader
    ];

    # Systemd service
    systemd.services.sysmon-daemon = {
      description = "System metrics daemon for Starship prompt";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];

      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 5;
        ExecStart = "${sysmon-daemon}/bin/sysmon-daemon ${toString cfg.interval}";

        # Security hardening
        DynamicUser = true;
        RuntimeDirectory = "sysmon";
        RuntimeDirectoryMode = "0755";

        # Allow writing to /dev/shm
        ReadWritePaths = [ "/dev/shm" ];

        # Minimal capabilities
        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
      };
    };
  };
}
