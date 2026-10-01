# Fish-native reader configuration. Shell quoting keeps custom icons/spacers data.
{
  lib,
  cfg,
  snapshot,
}:
let
  quote = lib.escapeShellArg;
  effectiveInterval = lib.min 60000 (lib.max 500 cfg.daemon.interval);
  stale = lib.max 15 (builtins.div (effectiveInterval * 3 + 999) 1000);
  bands =
    band:
    lib.concatStringsSep " " (
      map (metric: toString cfg.metrics.${metric}.thresholds.${band}) [
        "cpu"
        "ram"
        "swap"
        "load"
      ]
    );
in
''
  set -g STASYSMO_SNAPSHOT ${quote snapshot}
  set -g STASYSMO_STALE_SECONDS ${toString stale}
  set -g STASYSMO_ELEVATED ${bands "elevated"}
  set -g STASYSMO_CRITICAL ${bands "critical"}
  set -g STASYSMO_COLOR_MUTED ${toString cfg.colors.muted}
  set -g STASYSMO_COLOR_ELEVATED ${toString cfg.colors.elevated}
  set -g STASYSMO_COLOR_CRITICAL ${toString cfg.colors.critical}
  set -g STASYSMO_ICONS ${
    lib.concatStringsSep " " (
      map (metric: quote cfg.icons.${metric}) [
        "cpu"
        "ram"
        "swap"
        "load"
      ]
    )
  }
  set -g STASYSMO_SPACER_ICON_VALUE ${quote cfg.display.spacerIconValue}
  set -g STASYSMO_SPACER_METRICS ${quote cfg.display.spacerMetrics}
  source ${./reader.fish}
  source ${./prompt.fish}
''
