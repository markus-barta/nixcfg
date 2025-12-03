# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                   StaSysMo CONFIGURATION - Centralized Settings              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# All StaSysMo configuration in one place. No magic numbers!
# Import this file in nixos.nix and home-manager.nix.
#
# Icons use Unicode escape sequences to avoid corruption when processed by
# Nix strings or shell heredocs. The reader script interprets these with printf.
#
rec {
  # ════════════════════════════════════════════════════════════════════════════
  # PRESETS - Convenient predefined values
  # ════════════════════════════════════════════════════════════════════════════
  # Use these constants instead of typing Unicode or remembering numbers.
  # Example: spacerIconValue = presets.spacer.thin;
  #          daemon.interval = presets.interval.fast;

  presets = {
    # ──────────────────────────────────────────────────────────────────────────
    # Spacer Characters
    # ──────────────────────────────────────────────────────────────────────────
    # For spacerIconValue and spacerMetrics
    spacer = {
      none = ""; # No space at all
      hair = " "; # U+200A - Hair space (thinnest)
      thin = " "; # U+2009 - Thin space
      narrow = " "; # U+202F - Narrow no-break space
      normal = " "; # Regular ASCII space
      en = " "; # U+2002 - En space (half em)
      em = " "; # U+2003 - Em space (full width)
      double = "  "; # Two regular spaces
      pipe = " │ "; # Space + box drawing pipe + space
      dot = " • "; # Space + bullet + space (U+2022)
      diamond = " ◆ "; # Space + diamond + space (U+25C6)
      bar = " | "; # Space + ASCII pipe + space
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Daemon Interval (milliseconds)
    # ──────────────────────────────────────────────────────────────────────────
    interval = {
      realtime = 500; # 0.5 second - very responsive, use sparingly
      fast = 1000; # 1 second - responsive
      normal = 2500; # 2.5 seconds - balanced (default)
      relaxed = 5000; # 5 seconds - low overhead
      lazy = 10000; # 10 seconds - minimal updates
    };
    # ──────────────────────────────────────────────────────────────────────────
    # Character Budget (max width of metrics display)
    # ──────────────────────────────────────────────────────────────────────────
    budget = {
      minimal = 20; # Just CPU and RAM
      compact = 30; # CPU, RAM, maybe Load
      normal = 45; # All metrics comfortably (default)
      wide = 60; # Generous spacing
      unlimited = 200; # Effectively no limit
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Stale Threshold (seconds before showing "?")
    # ──────────────────────────────────────────────────────────────────────────
    stale = {
      strict = 5; # Mark stale quickly
      normal = 10; # Default
      tolerant = 20; # More forgiving
      relaxed = 60; # Very tolerant
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Terminal Width Thresholds (progressive metric hiding)
    # ──────────────────────────────────────────────────────────────────────────
    # When terminal is narrow, metrics gracefully disappear to preserve
    # essential prompt info (path, username, git status).
    # Values are terminal column widths.
    terminalWidth = {
      # Below this: show nothing (hide StaSysMo completely)
      hideAll = 80;
      # Below this: show 1 metric (CPU only)
      showOne = 100;
      # Below this: show 2 metrics (CPU + RAM)
      showTwo = 120;
      # Below this: show 3 metrics (CPU + RAM + Load)
      showThree = 150;
      # Above showThree: show all 4 metrics
    };
  };

  # ════════════════════════════════════════════════════════════════════════════
  # DAEMON SETTINGS
  # ════════════════════════════════════════════════════════════════════════════

  daemon = {
    # Sampling interval in milliseconds
    # Use: presets.interval.normal, presets.interval.fast, etc.
    intervalMs = presets.interval.normal;

    # Output directories (platform-specific)
    linuxDir = "/dev/shm/stasysmo";
    darwinDir = "/tmp/stasysmo";
  };

  # ════════════════════════════════════════════════════════════════════════════
  # READER / DISPLAY SETTINGS
  # ════════════════════════════════════════════════════════════════════════════

  display = {
    # Maximum character budget for metrics display
    # Use: presets.budget.normal, presets.budget.compact, etc.
    maxBudget = presets.budget.normal;

    # Minimum terminal width to show metrics (hidden if narrower)
    # Set to 0 to always show
    minTerminalWidth = 0;

    # Seconds after which daemon data is considered stale (shows "?")
    # Use: presets.stale.normal, presets.stale.strict, etc.
    staleThresholdSec = presets.stale.normal;

    # Spacer between icon and value (e.g., "C5%" vs "C 5%")
    # Use: presets.spacer.none, presets.spacer.thin, presets.spacer.normal, etc.
    spacerIconValue = presets.spacer.hair;

    # Spacer between metrics (e.g., "5% 52%" vs "5% • 52%")
    # Use: presets.spacer.normal, presets.spacer.dot, presets.spacer.pipe, etc.
    spacerMetrics = presets.spacer.double;
  };

  # ════════════════════════════════════════════════════════════════════════════
  # ICONS - Nerd Font (Documentation Only)
  # ════════════════════════════════════════════════════════════════════════════
  # Actual icons are stored in sysmon-icons.sh (generated by Python).
  # This avoids Unicode corruption when processing through Nix/shell.
  #
  # To change icons, edit sysmon-icons.sh using Python:
  #   python3 -c "print('\uf4bc')"  # Test the character first
  #
  # Find icons at: https://www.nerdfonts.com/cheat-sheet
  #
  # Current icons (for reference):
  #   CPU:  nf-oct-cpu (\uf4bc)
  #   RAM:  nf-md-memory (\uefc5)
  #   Load: 󰊚 nf-md-pulse (\U000f029a)
  #   Swap: 󰾴 nf-md-swap_horizontal_variant (\U000f0fb4)
  #

  # ════════════════════════════════════════════════════════════════════════════
  # COLORS - ANSI 256 Color Codes
  # ════════════════════════════════════════════════════════════════════════════

  colors = {
    # Normal state - blends into background
    muted = 242; # Gray

    # Elevated state - noticeable but not alarming
    elevated = 255; # White

    # Critical state - demands attention
    critical = 196; # Red
  };

  # ════════════════════════════════════════════════════════════════════════════
  # METRIC DEFINITIONS
  # ════════════════════════════════════════════════════════════════════════════
  # Each metric has:
  #   - thresholds: [elevated, critical] - values that trigger color changes
  #   - priority: higher = more important, shown first when space is limited
  #   - suffix: appended to value (e.g., "%" for percentages)
  #   - type: "int" or "float" for threshold comparison
  #

  metrics = {
    cpu = {
      thresholds = {
        elevated = 50;
        critical = 80;
      };
      priority = 100; # Highest - always show first
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

    load = {
      thresholds = {
        elevated = 2.0;
        critical = 4.0;
      };
      priority = 70;
      suffix = ""; # Load has no suffix
      type = "float";
    };

    swap = {
      thresholds = {
        elevated = 33;
        critical = 66;
      };
      priority = 60; # Lowest - hidden first when space is limited
      suffix = "%";
      type = "int";
      hideIfZero = true; # Don't show if swap is 0%
    };
  };
}
