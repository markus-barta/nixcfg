# Shared daemon/display options; platform-specific swap bands are intentional.
{ lib, platform }:
let
  defaultConfig = import ./config.nix;
  iconsFile = builtins.readFile ./icons.sh;
  getIconFromFile =
    key:
    let
      matches = builtins.match ".*${key}=\"([^\"]+)\".*" iconsFile;
    in
    if matches != null then builtins.elemAt matches 0 else "?";
in
{
  enable = lib.mkEnableOption "StaSysMo system metrics daemon for Starship prompt";

  # ──────────────────────────────────────────────────────────────────────────
  # Daemon Settings
  # ──────────────────────────────────────────────────────────────────────────

  daemon = {
    interval = lib.mkOption {
      type = lib.types.int;
      default = defaultConfig.daemon.intervalMs;
      description = "Sampling interval in milliseconds";
    };
  };

  # ──────────────────────────────────────────────────────────────────────────
  # Display Settings
  # ──────────────────────────────────────────────────────────────────────────

  display = {
    spacerIconValue = lib.mkOption {
      type = lib.types.str;
      default = defaultConfig.display.spacerIconValue;
      description = "Spacer string between icon and value (e.g., ' ' or '')";
    };

    spacerMetrics = lib.mkOption {
      type = lib.types.str;
      default = defaultConfig.display.spacerMetrics;
      description = "Spacer string between metrics (e.g., ' ' or '  ')";
    };

  };

  # ──────────────────────────────────────────────────────────────────────────
  # Icons (read from icons.sh to preserve Unicode)
  # ──────────────────────────────────────────────────────────────────────────

  icons = {
    cpu = lib.mkOption {
      type = lib.types.str;
      default = getIconFromFile "CPU_ICON";
      description = "Icon for CPU metric (Nerd Font character)";
    };

    ram = lib.mkOption {
      type = lib.types.str;
      default = getIconFromFile "RAM_ICON";
      description = "Icon for RAM metric (Nerd Font character)";
    };

    load = lib.mkOption {
      type = lib.types.str;
      default = getIconFromFile "LOAD_ICON";
      description = "Icon for load metric (Nerd Font character)";
    };

    swap = lib.mkOption {
      type = lib.types.str;
      default = getIconFromFile "SWAP_ICON";
      description = "Icon for swap metric (Nerd Font character)";
    };
  };

  # ──────────────────────────────────────────────────────────────────────────
  # Colors (ANSI 256)
  # ──────────────────────────────────────────────────────────────────────────

  colors = {
    muted = lib.mkOption {
      type = lib.types.int;
      default = defaultConfig.colors.muted;
      description = "ANSI 256 color for normal state (blends in)";
    };

    elevated = lib.mkOption {
      type = lib.types.int;
      default = defaultConfig.colors.elevated;
      description = "ANSI 256 color for elevated state (noticeable)";
    };

    critical = lib.mkOption {
      type = lib.types.int;
      default = defaultConfig.colors.critical;
      description = "ANSI 256 color for critical state (urgent)";
    };
  };

  # ──────────────────────────────────────────────────────────────────────────
  # Metric Thresholds
  # ──────────────────────────────────────────────────────────────────────────

  metrics = {
    cpu = {
      thresholds = {
        elevated = lib.mkOption {
          type = lib.types.int;
          default = defaultConfig.metrics.cpu.thresholds.elevated;
          description = "CPU% threshold for elevated color";
        };
        critical = lib.mkOption {
          type = lib.types.int;
          default = defaultConfig.metrics.cpu.thresholds.critical;
          description = "CPU% threshold for critical color";
        };
      };
    };

    ram = {
      thresholds = {
        elevated = lib.mkOption {
          type = lib.types.int;
          default = defaultConfig.metrics.ram.thresholds.elevated;
          description = "RAM% threshold for elevated color";
        };
        critical = lib.mkOption {
          type = lib.types.int;
          default = defaultConfig.metrics.ram.thresholds.critical;
          description = "RAM% threshold for critical color";
        };
      };
    };

    load = {
      thresholds = {
        elevated = lib.mkOption {
          type = lib.types.number;
          default = defaultConfig.metrics.load.promptThresholds.elevated;
          description = "Load per logical CPU threshold for elevated color";
        };
        critical = lib.mkOption {
          type = lib.types.number;
          default = defaultConfig.metrics.load.promptThresholds.critical;
          description = "Load per logical CPU threshold for critical color";
        };
      };
    };

    swap = {
      thresholds = {
        elevated = lib.mkOption {
          type = lib.types.int;
          default = defaultConfig.metrics.swap.thresholds.${platform}.elevated;
          description = "Swap% threshold for elevated color ";
        };
        critical = lib.mkOption {
          type = lib.types.int;
          default = defaultConfig.metrics.swap.thresholds.${platform}.critical;
          description = "Swap% threshold for critical color ";
        };
      };
    };
  };
}
