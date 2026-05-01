# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                                THEME PALETTES                                ║
# ║                            Per-Host Accent Colors                            ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# This file defines color palettes for per-host theming across the infrastructure.
# Each host gets a distinct accent color that flows through:
#   - Starship prompt (powerline segments)
#   - Zellij terminal multiplexer (frame/UI colors)
#   - Eza file listings (directory colors)
#
# The goal: Instantly recognize which server you're on by color alone.
#
# ════════════════════════════════════════════════════════════════════════════════
# DESIGN PHILOSOPHY
# ════════════════════════════════════════════════════════════════════════════════
#
# 1. SEMANTIC COLOR ASSIGNMENT
#    Colors are chosen based on host category for intuitive recognition:
#
#    ┌─────────────────┬────────────────────┬─────────────────────────────────┐
#    │ Category        │ Color Range        │ Rationale                       │
#    ├─────────────────┼────────────────────┼─────────────────────────────────┤
#    │ Cloud Servers   │ White → Blue       │ "Cloud" = sky colors, clean     │
#    │ Home Servers    │ Yellow → Green     │ "Home" = warm, organic, alive   │
#    │ Gaming Systems  │ Purple → Pink      │ "Fun" = vibrant, playful        │
#    │ Workstations    │ Gray spectrum      │ "Work" = neutral, professional  │
#    └─────────────────┴────────────────────┴─────────────────────────────────┘
#
# 2. INSTANT RECOGNITION
#    When SSH'd into multiple servers, the colored prompt immediately tells you:
#    - Yellow prompt? You're on hsb0 (DNS/DHCP - be careful!)
#    - Green prompt? You're on hsb1 (home automation)
#    - Purple prompt? You're on your gaming PC (safe to experiment)
#
# 3. SAFETY THROUGH COLOR
#    More "dangerous" servers (production, critical infra) get more distinct
#    colors so you don't accidentally run destructive commands on them.
#
# 4. STATUS AWARENESS
#    Beyond host identity, the prompt communicates system state:
#    - Root user? Bright red warning segment appears
#    - Command failed? Error badge and red prompt character
#    - Sudo cached? Lock icon shows elevated privileges available
#    - Long command? Duration displayed
#
# ════════════════════════════════════════════════════════════════════════════════
# POWERLINE GRADIENT STRUCTURE
# ════════════════════════════════════════════════════════════════════════════════
#
# The starship prompt uses a "powerline" style with angled segment separators.
# Segments flow left-to-right from LIGHT to DARK backgrounds:
#
#    ┌───────────────────────────────────────────────────────────────────────────────┐
#    │  Left side (context & identity)                   Right side (state & info)   │
#    │                                                                               │
#    │  [Alert] ░▒▓ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░▒▓       │
#    │     ↑                                                                         │
#    │  (root only)                                                                  │
#    │                                                                               │
#    │  ┌───────┬────┬─────────┬───────────┬─────┬──────┬────────┬──────┬────┬─────┐ │
#    │  │ Alert │ OS │Directory│ User@Host │Jobs │ Git  │Language│Status│Time│ Nix │ │
#    │  └───────┴────┴─────────┴───────────┴─────┴──────┴────────┴──────┴────┴─────┘ │
#    │      ↑                                 ↑                     ↑                │
#    │   (root)                           (bg jobs)            (on error)            │
#    │                                                                               │
#    │          lightest PRIMARY  secondary      midDark  dark        darker darkest │
#    │             ◄─────────────────────────────────────────────────────────────►   │
#    │                         Background gradient: light → dark                     │
#    └───────────────────────────────────────────────────────────────────────────────┘
#
# Each palette defines 7 gradient stops:
#
#    gradient.lightest  │ OS icon background (leftmost, brightest)
#    gradient.primary   │ Directory path - THE MAIN ACCENT COLOR
#    gradient.secondary │ Username@hostname
#    gradient.midDark   │ Git branch, status, commit count
#    gradient.dark      │ Language versions (nodejs, python, etc.)
#    gradient.darker    │ Time display
#    gradient.darkest   │ Nix shell indicator (rightmost, near-black)
#
# The PRIMARY color is the most visible and defines the palette's identity.
# All other colors are calculated to maintain the same hue while shifting
# lightness to create the gradient effect.
#
# ════════════════════════════════════════════════════════════════════════════════
# TEXT COLOR STRATEGY
# ════════════════════════════════════════════════════════════════════════════════
#
# Text colors are carefully chosen for readability at each gradient position:
#
#    ┌─────────────────┬────────────────────┬──────────────────────────────────┐
#    │ Text Color      │ Used On            │ Purpose                          │
#    ├─────────────────┼────────────────────┼──────────────────────────────────┤
#    │ text.onLightest │ lightest bg        │ Dark text (icon, high contrast)  │
#    │ text.onMedium   │ primary/secondary  │ Black #000 (path, high contrast) │
#    │ text.accent     │ dark backgrounds   │ Bright accent (git branch, lang) │
#    │ text.muted      │ midDark bg         │ Subtle/dim (git commit count)    │
#    │ text.mutedLight │ darker bg          │ Softer accent (time display)     │
#    └─────────────────┴────────────────────┴──────────────────────────────────┘
#
# CONTRAST HIERARCHY:
#
#    Most Important    ───────────────────────────────────────►  Least Important
#    ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
#    │  Directory   │  │  Git Branch  │  │  Git Count   │  │     Time     │
#    │  onMedium    │  │    accent    │  │    muted     │  │  mutedLight  │
#    │  (bright)    │  │  (visible)   │  │  (subtle)    │  │  (subdued)   │
#    └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘
#
# The git commit count (#1234) is intentionally "stark" compared to the branch
# name - it's useful info but shouldn't compete for attention with the branch.
#
# ════════════════════════════════════════════════════════════════════════════════
# STATUS INDICATORS
# ════════════════════════════════════════════════════════════════════════════════
#
# Beyond the gradient, additional indicators communicate system state.
# These use UNIVERSAL colors (same across all palettes) for consistency:
#
#    ┌─────────────────┬────────────────────┬──────────────────────────────────┐
#    │ Indicator       │ When Shown         │ Purpose                          │
#    ├─────────────────┼────────────────────┼──────────────────────────────────┤
#    │ Root Alert      │ Logged in as root  │ DANGER - you have full power     │
#    │ Error Badge     │ Last cmd failed    │ Exit code visible, needs action  │
#    │ Sudo Cached     │ sudo credentials   │ Elevated privileges available    │
#    │ Command Duration│ cmd > 2 seconds    │ How long the last command took   │
#    │ Background Jobs │ Suspended procs    │ Reminder of background work      │
#    └─────────────────┴────────────────────┴──────────────────────────────────┘
#
# ROOT ALERT (leftmost, before gradient):
#    Appears ONLY when logged in as root. Creates a visual "gate" you must
#    pass through, impossible to miss. Uses bright red background.
#
#    ┌─────────────────────────────────────────────────────────────────────────┐
#    │  NORMAL USER:                                                           │
#    │  ░▒▓  ~/Code/nixcfg  mba@hsb0  main  node  14:32  nix                   │
#    │  ❯ _                                                                    │
#    │                                                                         │
#    │  ROOT USER:                                                             │
#    │  ⚠ ░▒▓  /etc/nixos  root@hsb0  main  14:32  nix                        │
#    │  # _                                                                    │
#    │  ↑                      ↑                                               │
#    │  Red alert segment      Red username                                    │
#    └─────────────────────────────────────────────────────────────────────────┘
#
# ERROR BADGE (right side, before time):
#    Only appears when last command exited with non-zero status.
#    Shows exit code for debugging. Uses consistent red.
#
#    ┌─────────────────────────────────────────────────────────────────────────┐
#    │  SUCCESS (exit 0):     ...  node  14:32  nix   (nothing)                │
#    │  FAILURE (exit 127):   ...  node  ✘ 127  14:32  nix                     │
#    └─────────────────────────────────────────────────────────────────────────┘
#
# SUDO CACHED (right side, after time):
#    Shows lock icon when sudo credentials are cached (you can run sudo
#    without password). Uses warm amber - "caution" not "danger".
#
# COMMAND DURATION (right side, before status):
#    Shows how long the last command took. Only appears when duration
#    exceeds threshold (default: 2 seconds). Essential for build monitoring.
#
#    ┌─────────────────────────────────────────────────────────────────────────┐
#    │  SHORT COMMAND:   ...  node  14:32  nix   (hidden)                      │
#    │  LONG COMMAND:    ...  node  ⏱ 3m 42s  14:32  nix                       │
#    └─────────────────────────────────────────────────────────────────────────┘
#
# BACKGROUND JOBS (after user@host):
#    Shows count of suspended/background processes. Prevents "oops I forgot
#    I had vim open" situations before logout.
#
# CHARACTER (prompt on new line):
#    Immediate feedback for last command result:
#    - Success: ❯ in palette accent color
#    - Error: ✗ in red (matches error badge)
#    - Root: # in red
#
# ════════════════════════════════════════════════════════════════════════════════
# ZELLIJ THEME MAPPING
# ════════════════════════════════════════════════════════════════════════════════
#
# Zellij uses a different color model (terminal 16-color style). Each palette
# provides colors for the zellij UI elements:
#
#    zellij.bg        │ Text selection background
#    zellij.fg        │ Footer button background
#    zellij.frame     │ Tab/pane frame color
#    zellij.black     │ Header/footer background (usually near-black)
#    zellij.white     │ Primary text color
#    zellij.highlight │ Highlighted/active elements
#
# The PRIMARY accent color is used for zellij.bg and zellij.frame to maintain
# visual consistency with the starship prompt.
#
# ════════════════════════════════════════════════════════════════════════════════
# HOST ASSIGNMENT VISUAL
# ════════════════════════════════════════════════════════════════════════════════
#
#    CLOUD (Internet-facing)          HOME (Local network)
#    ┌─────────────────────┐          ┌─────────────────────┐
#    │  csb0    🧊 IceBlue │          │  hsb0    🟨 Yellow  │
#    │  csb1    🔵 Blue    │          │  hsb1    🟢 Green   │
#    └─────────────────────┘          │  hsb8    🟠 Orange  │
#                                     └─────────────────────┘
#
#    GAMING                           WORKSTATIONS
#    ┌─────────────────────┐          ┌─────────────────────┐
#    │  gpc0    🟣 Purple  │          │  imac0   🟫 W-Gray  │
#    │  stm0    🩷 Pink    │          │  imac1   🔘 M-Gray  │
#    │  stm1    🩷 Pink    │          │  work    ⚫ D-Gray  │
#    └─────────────────────┘          │  mbp     🩶 L-Gray  │
#                                     └─────────────────────┘
#
# ════════════════════════════════════════════════════════════════════════════════

{
  # ============================================================================
  # PALETTE DEFINITIONS
  # ============================================================================

  palettes = {

    # --------------------------------------------------------------------------
    # CLOUD SERVERS: White → Blue spectrum
    # --------------------------------------------------------------------------

    iceBlue = {
      name = "Ice Blue";
      category = "cloud";
      description = "Subtle icy blue tint (csb0)";

      # Powerline gradient (light → dark) - subtle blue tint, not as saturated as csb1
      gradient = {
        lightest = "#c8d8e8"; # OS icon bg - pale ice blue
        primary = "#98b8d8"; # Directory bg - soft sky blue
        secondary = "#6890b8"; # User/host bg - steel blue
        midDark = "#3a5068"; # Git section bg - dark slate blue
        dark = "#243040"; # Languages bg - deep blue-gray
        darker = "#1a2530"; # Time bg - darker blue-gray
        darkest = "#12181e"; # Nix shell bg - near black with blue
      };

      # Text colors
      text = {
        onLightest = "#182838"; # Dark blue-ish text on lightest bg
        onMedium = "#000000"; # Black for path (high contrast)
        accent = "#a8c8e8"; # Accent fg on dark bg - pale blue
        muted = "#506070"; # Git count, subtle info
        mutedLight = "#8098b0"; # Time text - muted sky blue
      };

      # Zellij theme colors
      zellij = {
        bg = "#98b8d8";
        fg = "#6890b8";
        frame = "#98b8d8";
        black = "#12181e";
        white = "#f0f6fc";
        highlight = "#c8d8e8";
      };
    };

    blue = {
      name = "Blue";
      category = "cloud";
      description = "Monitoring, analytics (csb1)";

      # Powerline gradient (light → dark) - current Tokyo Night inspired
      gradient = {
        lightest = "#a3aed2"; # OS icon bg
        primary = "#769ff0"; # Directory bg - bright blue
        secondary = "#5a7fb8"; # User/host bg
        midDark = "#394260"; # Git section bg
        dark = "#212736"; # Languages bg
        darker = "#1d2230"; # Time bg
        darkest = "#13161f"; # Nix shell bg
      };

      # Text colors
      text = {
        onLightest = "#090c0c"; # Dark text on lightest bg
        onMedium = "#000000"; # Black for path (high contrast)
        accent = "#769ff0"; # Accent fg on dark bg
        muted = "#1a1a2e"; # Git count (intentionally stark/subtle)
        mutedLight = "#a0a9cb"; # Time text
      };

      # Zellij theme colors
      zellij = {
        bg = "#769ff0";
        fg = "#5a7fb8";
        frame = "#769ff0";
        black = "#13161f";
        white = "#ffffff";
        highlight = "#a3aed2";
      };
    };

    # --------------------------------------------------------------------------
    # HOME SERVERS: Yellow → Green → Orange spectrum
    # --------------------------------------------------------------------------

    yellow = {
      name = "Yellow";
      category = "home";
      description = "Core infrastructure, DNS/DHCP (hsb0)";

      # Powerline gradient (light → dark)
      gradient = {
        lightest = "#e8e0a8"; # OS icon bg - soft cream
        primary = "#d4c060"; # Directory bg - golden yellow
        secondary = "#a89840"; # User/host bg - darker gold
        midDark = "#504820"; # Git section bg - olive
        dark = "#303018"; # Languages bg
        darker = "#242010"; # Time bg
        darkest = "#18160c"; # Nix shell bg
      };

      # Text colors
      text = {
        onLightest = "#2a2810"; # Dark text on lightest bg
        onMedium = "#000000"; # Black for path (high contrast)
        accent = "#e8d878"; # Accent fg on dark bg
        muted = "#3a3518"; # Git count, subtle
        mutedLight = "#b8b088"; # Time text
      };

      # Zellij theme colors
      zellij = {
        bg = "#d4c060";
        fg = "#a89840";
        frame = "#d4c060";
        black = "#18160c";
        white = "#f8f4e8";
        highlight = "#e8e0a8";
      };
    };

    green = {
      name = "Green";
      category = "home";
      description = "Home automation, dynamic (hsb1)";

      # Powerline gradient (light → dark)
      gradient = {
        lightest = "#b8e0c0"; # OS icon bg - soft mint
        primary = "#68c878"; # Directory bg - fresh green
        secondary = "#48a058"; # User/host bg
        midDark = "#284830"; # Git section bg
        dark = "#1a3020"; # Languages bg
        darker = "#142818"; # Time bg
        darkest = "#0c1810"; # Nix shell bg
      };

      # Text colors
      text = {
        onLightest = "#0c2010"; # Dark text on lightest bg
        onMedium = "#000000"; # Black for path (high contrast)
        accent = "#88e898"; # Accent fg on dark bg
        muted = "#1a2818"; # Git count, subtle
        mutedLight = "#88a890"; # Time text
      };

      # Zellij theme colors
      zellij = {
        bg = "#68c878";
        fg = "#48a058";
        frame = "#68c878";
        black = "#0c1810";
        white = "#f0f8f2";
        highlight = "#b8e0c0";
      };
    };

    orange = {
      name = "Orange";
      category = "home";
      description = "Remote home server, parents (hsb8)";

      # Powerline gradient (light → dark)
      gradient = {
        lightest = "#f0d0a8"; # OS icon bg - peach
        primary = "#e09050"; # Directory bg - warm orange
        secondary = "#b87040"; # User/host bg
        midDark = "#583820"; # Git section bg
        dark = "#382410"; # Languages bg
        darker = "#2a1c0c"; # Time bg
        darkest = "#1a1208"; # Nix shell bg
      };

      # Text colors
      text = {
        onLightest = "#2a1808"; # Dark text on lightest bg
        onMedium = "#000000"; # Black for path (high contrast)
        accent = "#f0a868"; # Accent fg on dark bg
        muted = "#3a2810"; # Git count, subtle
        mutedLight = "#c0a080"; # Time text
      };

      # Zellij theme colors
      zellij = {
        bg = "#e09050";
        fg = "#b87040";
        frame = "#e09050";
        black = "#1a1208";
        white = "#fff8f0";
        highlight = "#f0d0a8";
      };
    };

    # --------------------------------------------------------------------------
    # GAMING: Purple → Pink spectrum
    # --------------------------------------------------------------------------

    purple = {
      name = "Purple";
      category = "gaming";
      description = "Gaming PC (gpc0)";

      # Powerline gradient (light → dark)
      gradient = {
        lightest = "#d0b8e8"; # OS icon bg - lavender
        primary = "#9868d0"; # Directory bg - vibrant purple
        secondary = "#7850a8"; # User/host bg
        midDark = "#402860"; # Git section bg
        dark = "#281840"; # Languages bg
        darker = "#1e1230"; # Time bg
        darkest = "#140c20"; # Nix shell bg
      };

      # Text colors
      text = {
        onLightest = "#1a0c28"; # Dark text on lightest bg
        onMedium = "#000000"; # Black for path (high contrast)
        accent = "#b888e8"; # Accent fg on dark bg
        muted = "#2a1840"; # Git count, subtle
        mutedLight = "#a088b8"; # Time text
      };

      # Zellij theme colors
      zellij = {
        bg = "#9868d0";
        fg = "#7850a8";
        frame = "#9868d0";
        black = "#140c20";
        white = "#f8f0ff";
        highlight = "#d0b8e8";
        keybindFg = "#ffffff"; # White keybind letters (red on pink is ugly)
      };
    };

    pink = {
      name = "Pink";
      category = "gaming";
      description = "Steam machines (stm0, stm1)";

      # Powerline gradient (light → dark)
      gradient = {
        lightest = "#f0c0d8"; # OS icon bg - soft pink
        primary = "#e070a0"; # Directory bg - hot pink
        secondary = "#b85080"; # User/host bg
        midDark = "#602848"; # Git section bg
        dark = "#401830"; # Languages bg
        darker = "#301028"; # Time bg
        darkest = "#200c1c"; # Nix shell bg
      };

      # Text colors
      text = {
        onLightest = "#2a0c18"; # Dark text on lightest bg
        onMedium = "#000000"; # Black for path (high contrast)
        accent = "#f090b8"; # Accent fg on dark bg
        muted = "#401028"; # Git count, subtle
        mutedLight = "#b888a0"; # Time text
      };

      # Zellij theme colors
      zellij = {
        bg = "#e070a0";
        fg = "#b85080";
        frame = "#e070a0";
        black = "#200c1c";
        white = "#fff0f8";
        highlight = "#f0c0d8";
      };
    };

    # --------------------------------------------------------------------------
    # WORKSTATIONS: Gray spectrum (bright → dark)
    # --------------------------------------------------------------------------

    lightGray = {
      name = "Light Gray";
      category = "workstation";
      description = "Work MacBook Pro (mba-mbp-work)";

      # Powerline gradient (light → dark)
      gradient = {
        lightest = "#e0e2e8"; # OS icon bg - bright silver
        primary = "#a8aeb8"; # Directory bg - light gray
        secondary = "#888e98"; # User/host bg
        midDark = "#484e58"; # Git section bg
        dark = "#303438"; # Languages bg
        darker = "#242628"; # Time bg
        darkest = "#181a1c"; # Nix shell bg
      };

      # Text colors
      text = {
        onLightest = "#181a1c"; # Dark text on lightest bg
        onMedium = "#000000"; # Black for path (high contrast)
        onSecondary = "#d8dce0"; # Slightly muted for user@host
        accent = "#c0c8d0"; # Accent fg on dark bg
        muted = "#707478"; # Git count - lighter for readability on dark
        mutedLight = "#909498"; # Time text
      };

      # Zellij theme colors
      zellij = {
        bg = "#a8aeb8";
        fg = "#888e98";
        frame = "#a8aeb8";
        black = "#181a1c";
        white = "#f8f9fa";
        highlight = "#e0e2e8";
      };
    };

    darkGray = {
      name = "Dark Gray";
      category = "workstation";
      description = "Work workstation (mba-imac-work)";

      # Powerline gradient (light → dark) - starts darker
      gradient = {
        lightest = "#909498"; # OS icon bg - medium gray
        primary = "#686c70"; # Directory bg - dark gray
        secondary = "#505458"; # User/host bg
        midDark = "#383c40"; # Git section bg
        dark = "#282c30"; # Languages bg
        darker = "#1c2024"; # Time bg
        darkest = "#101214"; # Nix shell bg
      };

      # Text colors (work iMac: white path, brighter muted)
      text = {
        onLightest = "#101214"; # Dark text on lightest bg
        onMedium = "#ffffff"; # White for path (work preference)
        onSecondary = "#cccccc"; # Light gray for user@host (80% white)
        accent = "#b8c0c8"; # Accent fg on dark bg (brighter)
        muted = "#606468"; # Git count (brighter, was #282c30)
        mutedLight = "#909498"; # Time text (brighter, was #707478)
      };

      # Zellij theme colors
      zellij = {
        bg = "#686c70";
        fg = "#505458";
        frame = "#686c70";
        black = "#101214";
        white = "#f0f2f4";
        highlight = "#909498";
      };
    };

    mediumGray = {
      name = "Medium Gray";
      category = "workstation";
      description = "Secondary workstation (imac1)";

      # Powerline gradient (light → dark) - between light and dark
      gradient = {
        lightest = "#c8ccd0"; # OS icon bg
        primary = "#909498"; # Directory bg
        secondary = "#707478"; # User/host bg
        midDark = "#404448"; # Git section bg
        dark = "#2c3034"; # Languages bg
        darker = "#202428"; # Time bg
        darkest = "#14161a"; # Nix shell bg
      };

      # Text colors
      text = {
        onLightest = "#14161a"; # Dark text on lightest bg
        onMedium = "#000000"; # Black for path (high contrast)
        accent = "#b0b8c0"; # Accent fg on dark bg
        muted = "#303438"; # Git count, subtle
        mutedLight = "#808488"; # Time text
      };

      # Zellij theme colors
      zellij = {
        bg = "#909498";
        fg = "#707478";
        frame = "#909498";
        black = "#14161a";
        white = "#f4f6f8";
        highlight = "#c8ccd0";
      };
    };

    warmGray = {
      name = "Warm Gray";
      category = "workstation";
      description = "Home workstation (imac0)";

      # Powerline gradient (light → dark) - warm/brownish tint
      gradient = {
        lightest = "#d8d4d0"; # OS icon bg - warm silver
        primary = "#a8a098"; # Directory bg - taupe
        secondary = "#888078"; # User/host bg
        midDark = "#484440"; # Git section bg
        dark = "#302c28"; # Languages bg
        darker = "#242220"; # Time bg
        darkest = "#181614"; # Nix shell bg
      };

      # Text colors
      text = {
        onLightest = "#181614"; # Dark text on lightest bg
        onMedium = "#000000"; # Black for path (high contrast)
        accent = "#c0b8b0"; # Accent fg on dark bg
        muted = "#383430"; # Git count, subtle
        mutedLight = "#908880"; # Time text
      };

      # Zellij theme colors
      zellij = {
        bg = "#a8a098";
        fg = "#888078";
        frame = "#a8a098";
        black = "#181614";
        white = "#f8f6f4";
        highlight = "#d8d4d0";
      };
    };

    roseGold = {
      name = "Rose Gold";
      category = "workstation";
      description = "Wife's iMac (imac1)";

      # Powerline gradient (light → dark) - subtle pink/copper tint
      gradient = {
        lightest = "#e8d8d4"; # OS icon bg - pale rose
        primary = "#c8a8a0"; # Directory bg - rose gold
        secondary = "#a08880"; # User/host bg - dusty rose
        midDark = "#584844"; # Git section bg
        dark = "#382c28"; # Languages bg
        darker = "#2a2220"; # Time bg
        darkest = "#1a1614"; # Nix shell bg
      };

      # Text colors
      text = {
        onLightest = "#2a1818"; # Dark text on lightest bg
        onMedium = "#000000"; # Black for path (high contrast)
        accent = "#d8b8b0"; # Accent fg on dark bg
        muted = "#483838"; # Git count, subtle
        mutedLight = "#a89090"; # Time text
      };

      # Zellij theme colors
      zellij = {
        bg = "#c8a8a0";
        fg = "#a08880";
        frame = "#c8a8a0";
        black = "#1a1614";
        white = "#fff8f6";
        highlight = "#e8d8d4";
      };
    };

    # --------------------------------------------------------------------------
    # OFFICE SERVERS: Very Dark Gray
    # --------------------------------------------------------------------------
    veryDarkGray = {
      name = "Very Dark Gray";
      category = "office";
      description = "Office test server (miniserver-bp)";

      # Powerline gradient (light → very dark)
      gradient = {
        lightest = "#707478"; # OS icon bg - muted medium gray
        primary = "#404448"; # Directory bg - VERY DARK GRAY
        secondary = "#303438"; # User/host bg
        midDark = "#202428"; # Git section bg
        dark = "#181c20"; # Languages bg
        darker = "#121618"; # Time bg
        darkest = "#0a0c10"; # Nix shell bg (near-black)
      };

      # Text colors (high contrast on very dark bgs)
      text = {
        onLightest = "#0a0c10"; # Dark text on lightest
        onMedium = "#ffffff"; # White path text (matches darkGray work pref)
        accent = "#a0a8b0"; # Accent fg (muted blue-gray)
        muted = "#505458"; # Git count
        mutedLight = "#707478"; # Time text
      };

      # Zellij (frame/UI very dark gray)
      zellij = {
        bg = "#404448";
        fg = "#303438";
        frame = "#404448";
        black = "#0a0c10";
        white = "#e8e8e8";
        highlight = "#707478";
      };
    };

    # --------------------------------------------------------------------------
    # CUSTOM PALETTES (auto-generated from NixFleet dashboard)
    # --------------------------------------------------------------------------

    # P2950: Auto-generated custom palette for hsb8
    custom-hsb8 = {
      name = "Custom (hsb8)";
      category = "custom";
      description = "User-defined color for hsb8";

      gradient = {
        lightest = "#ecba93";
        primary = "#e09051";
        secondary = "#c26923";
        midDark = "#572f0f";
        dark = "#341c09";
        darker = "#231306";
        darkest = "#160c04";
      };

      text = {
        onLightest = "#2b1708";
        onMedium = "#000000";
        accent = "#e8ac7d";
        muted = "#341c09";
        mutedLight = "#dc833c";
      };

      zellij = {
        bg = "#e09051";
        fg = "#c26923";
        frame = "#e09051";
        black = "#160c04";
        white = "#fbf1e9";
        highlight = "#ecba93";
      };
    };

  };

  # ============================================================================
  # UNIVERSAL STATUS COLORS
  # ============================================================================
  #
  # These colors are CONSISTENT across all palettes. Danger should always look
  # like danger, regardless of which host you're on. This ensures:
  #   - Root warning is always recognizable
  #   - Errors always stand out the same way
  #   - Sudo indicator is always the same amber
  #
  # These colors are NOT part of the host's accent palette - they're overlays
  # that communicate state independent of host identity.
  #

  statusColors = {
    # Root alert - bright red, impossible to miss
    # Used for: Alert segment when logged in as root
    root = {
      bg = "#e04040"; # Bright red background
      fg = "#ffffff"; # White text/icon
    };

    # Error/failure - slightly softer red than root
    # Used for: Exit status badge, error character
    error = {
      bg = "#c04040"; # Medium red background
      fg = "#f0f0f0"; # Off-white text
    };

    # Sudo cached - warm amber (caution, not danger)
    # Used for: Lock icon when sudo credentials cached
    sudo = {
      fg = "#f0a868"; # Amber/orange (no bg, uses time segment bg)
    };

    # Command duration - informational, not alerting
    # Used for: Duration display when command > threshold
    duration = {
      fg = "#a0a8b8"; # Muted light (same as time text)
    };

    # Background jobs - subtle reminder
    # Used for: Job count indicator
    jobs = {
      fg = "#a0a8b8"; # Muted light
    };

    # Success character - uses palette accent
    # (defined per-palette via text.accent)

    # Root character
    rootChar = {
      fg = "#e04040"; # Same as root alert
      symbol = "#"; # Traditional root prompt
    };
  };

  # ============================================================================
  # HOST → PALETTE MAPPING
  # ============================================================================
  #
  # Maps hostname to palette name. Unknown hosts default to "blue" (the original
  # Tokyo Night theme).
  #
  # DISPLAY ORDER CONVENTION (for all lists):
  #   1. Servers before workstations
  #   2. Cloud before home (for servers)
  #   3. Home before play before work (for workstations)
  #

  hostPalette = {
    # Cloud servers
    csb0 = "iceBlue";
    csb1 = "blue";

    # Home servers
    hsb0 = "yellow";
    hsb1 = "green";
    hsb8 = "custom-hsb8";

    # Gaming
    gpc0 = "purple";
    stm0 = "pink";
    stm1 = "pink";

    # Workstations (home > work)
    imac0 = "warmGray";
    imac1 = "roseGold"; # Wife's iMac (future)
    "mba-imac-work" = "darkGray";
    "mba-mbp-work" = "lightGray";
    "mba-mbp-m5-work" = "lightGray"; # M5 work portable — same lightGray family as the predecessor it replaces
    miniserver-bp = "veryDarkGray";
  };

  # Default palette for unknown hosts
  defaultPalette = "blue";

  # Display order for CLI tools (follows: server>workstation, cloud>home, home>play>work)
  hostDisplayOrder = [
    # Cloud servers
    "csb0"
    "csb1"
    # Home servers
    "hsb0"
    "hsb1"
    "hsb8"
    # Office servers
    "miniserver-bp"
    # Gaming
    "gpc0"
    "stm0"
    "stm1"
    # Workstations (home > work)
    "imac0"
    "imac1"
    "mba-imac-work"
    "mba-mbp-work"
    "mba-mbp-m5-work"
  ];

  # ============================================================================
  # CATEGORY BULLETS (for CLI tools like runbook-secrets)
  # ============================================================================
  categoryBullets = {
    cloud = "◆";
    home = "●";
    office = "◾";
    gaming = "▶";
    workstation = "◼";
    unknown = "○";
  };

  # ============================================================================
  # PORTABLE HOST CONFIGURATION
  # ============================================================================
  #
  # Some hosts are portable (laptops, Steam Deck) and benefit from battery
  # indicator in the prompt. This list identifies which hosts should show
  # battery status.
  #

  portableHosts = [
    "stm0" # Steam Deck / Steam Machine
    "stm1" # Steam Deck / Steam Machine
    # Note: gpc0 (gaming PC) is not portable, even though it's in gaming category
  ];

  # Battery indicator colors (universal, like status colors)
  batteryColors = {
    high = {
      # > 50%
      fg = "#68c878"; # Green
    };
    medium = {
      # 20-50%
      fg = "#d4c060"; # Yellow/amber
    };
    low = {
      # < 20%
      fg = "#e04040"; # Red (same as root alert)
    };
  };

  # ============================================================================
  # EZA THEME
  # ============================================================================
  #
  # Eza colors are now defined in a YAML theme file for better maintainability:
  #   modules/uzumaki/theme/eza-themes/tokyonight-uzumaki.yml
  #
  # Based on Tokyo Night theme with enhanced visibility modifications:
  # https://github.com/eza-community/eza-themes/blob/main/themes/tokyonight.yml
  #
  # The theme file is installed to ~/.config/eza/theme.yml by theme-hm.nix
  #

  # ============================================================================
  # FEATURE SUMMARY
  # ============================================================================
  #
  # ALWAYS SHOWN:
  #   - OS icon (NixOS/macOS/Linux)
  #   - Directory path (full)
  #   - Username@hostname
  #   - Git branch + status + commit count (in git repos)
  #   - Language versions (when detected)
  #   - Time
  #   - Nix shell indicator (in nix shells)
  #   - Character prompt (❯ or # for root)
  #
  # CONDITIONALLY SHOWN:
  #   - Root alert ⚠ (only when logged in as root)
  #   - Error badge ✘ (only when last command failed)
  #   - Sudo indicator  (only when sudo credentials cached)
  #   - Command duration ⏱ (only when > 2 seconds)
  #   - Background jobs (only when jobs exist)
  #   - Battery 🔋 (only on portable hosts, only on battery)
  #
}
