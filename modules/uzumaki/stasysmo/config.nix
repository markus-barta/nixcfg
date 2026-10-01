# StaSysMo defaults. HostDash also consumes metrics.*.{type,thresholds}; preserve
# its disk and raw-load contracts even though this prompt never samples disk.
rec {
  presets = {
    interval = {
      realtime = 500;
      fast = 1000;
      normal = 2000;
      relaxed = 5000;
      lazy = 10000;
    };
    spacer = {
      none = "";
      hair = " ";
      thin = " ";
      narrow = " ";
      normal = " ";
      en = " ";
      em = " ";
      double = "  ";
      pipe = " │ ";
      dot = " • ";
      diamond = " ◆ ";
      bar = " | ";
    };
  };
  daemon = {
    intervalMs = presets.interval.normal;
    linuxDir = "/run/stasysmo";
    darwinDir = "Library/Caches/stasysmo"; # Relative to the account home
  };
  display = {
    spacerIconValue = presets.spacer.hair;
    spacerMetrics = presets.spacer.double;
  };
  colors = {
    muted = 242;
    elevated = 255;
    critical = 196;
  };
  # Actual glyphs remain in the generated icons.sh, read by options.nix.
  metrics = {
    cpu = {
      thresholds = {
        elevated = 50;
        critical = 80;
      };
      priority = 100; # highest, first to show (HostDash contract)
      suffix = "%";
      type = "int";
    };
    ram = {
      thresholds = {
        elevated = 70;
        critical = 90;
      };
      priority = 90;
      suffix = "%";
      type = "int";
    };
    # Root mount band used by HostDash; deliberately not a prompt metric.
    disk = {
      thresholds = {
        elevated = 80;
        critical = 90;
      };
      priority = 80;
      suffix = "%";
      type = "int";
    };
    load = {
      # The rail compares loadavg1 / logical CPU count.
      promptThresholds = {
        elevated = 0.7;
        critical = 1.0;
      };
      thresholds = {
        elevated = 2.0;
        critical = 4.0;
      }; # Existing dashboard contract
      priority = 70;
      suffix = "";
      type = "float";
    };
    swap = {
      thresholds = {
        linux = {
          elevated = 33;
          critical = 66;
        };
        darwin = {
          elevated = 50;
          critical = 75;
        };
      };
      priority = 60;
      suffix = "%";
      type = "int";
    };
  };
}
