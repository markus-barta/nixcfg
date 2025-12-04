# Uzumaki macOS Common - Shared macOS configuration for all Mac hosts
# Provides common fish, starship, and wezterm settings
#
# Usage in home.nix (for imac-mba-work style):
#   let macosCommon = import ../../modules/uzumaki/macos-common.nix { inherit pkgs lib; };
#   in { programs.fish = macosCommon.fishConfig; ... }
#
{ pkgs, lib, ... }:

let
  sharedFishConfig = import ../shared/fish-config.nix;
  # Import uzumaki common functions (pingt, sourcefish, sourceenv)
  uzumakiFunctions = import ./common.nix;
in
{
  # ============================================================================
  # Fish Shell Configuration (macOS-specific)
  # ============================================================================
  fishConfig = {
    enable = true;

    # Shell initialization (config.fish equivalent)
    shellInit = ''
      # NOTE: Mouse tracking reset removed - was breaking Starship $fill
      # See: pm/backlog/2025-12-04-starship-fill-broken-hsb1.md

      # Environment variables
      set -gx TERM xterm-256color
      set -gx EDITOR nano

      # zoxide integration
      set -gx ZOXIDE_CMD z
    '';

    # Login shell initialization - prepend Nix paths to PATH
    loginShellInit = ''
      # Ensure Nix paths are prioritized
      fish_add_path --prepend --move ~/.nix-profile/bin
      fish_add_path --prepend --move /nix/var/nix/profiles/default/bin
    '';

    interactiveShellInit = ''
      # Custom greeting
      function fish_greeting
          set_color cyan
          echo -n "Welcome to fish, the friendly interactive shell "
          set_color green
          echo -n (whoami)"@"(hostname -s)
          set_color yellow
          echo -n " · "(date "+%Y-%m-%d %H:%M")
          set_color normal
      end

      # Initialize zoxide
      zoxide init fish | source
    '';

    # Functions - uzumaki functions (pingt, sourcefish, sourceenv) + macOS-specific
    functions = {
      # Uzumaki shared functions
      inherit (uzumakiFunctions) pingt sourcefish sourceenv;

      # Custom cd function using zoxide
      cd = ''
        if set -q ZOXIDE_CMD
            z $argv
        else
            builtin cd $argv
        end
      '';

      # Sudo with !! support
      sudo = {
        description = "Sudo with !! support";
        body = ''
          if test "$argv" = "!!"
              eval command sudo $history[1]
          else
              command sudo $argv
          end
        '';
      };

      # Homebrew maintenance
      brewall = ''
        brew update
        brew upgrade
        brew cleanup
        brew doctor
      '';
    };

    # Aliases - merge shared config with macOS-specific aliases
    shellAliases = sharedFishConfig.fishAliases // {
      # macOS specific aliases
      mc = "env LANG=en_US.UTF-8 mc";
      # Force macOS native ping (inetutils ping has bugs on Darwin)
      ping = "/sbin/ping";
      # Other macOS network tools for reference
      traceroute = "/usr/sbin/traceroute";
      netstat = "/usr/sbin/netstat";
    };

    # Abbreviations - merge shared config with macOS-specific abbreviations
    # SSH shortcuts (hsb0, hsb1, hsb8, gpc0, csb0, csb1) are in shared/fish-config.nix
    shellAbbrs = sharedFishConfig.fishAbbrs // {
      flushdns = "sudo killall -HUP mDNSResponder && echo macOS DNS Cache Reset";
    };
  };

  # ============================================================================
  # WezTerm Configuration
  # ============================================================================
  weztermConfig = ''
    local wezterm = require("wezterm")
    local act = wezterm.action
    local os = require("os")
    local config = wezterm.config_builder()

    ------------------------------------------------------------
    -- ## Fonts & Text
    ------------------------------------------------------------
    config.font_size = 12
    config.line_height = 1.1

    -- Primary font with proper fallback chain
    config.font = wezterm.font_with_fallback({
        { family = "Hack Nerd Font Mono", weight = "Regular" },
        { family = "Hack Nerd Font", weight = "Regular" },
        "Apple Color Emoji",
        "Menlo",
    })

    -- Ensure symbols and icons render properly
    config.harfbuzz_features = { "calt=1", "clig=1", "liga=1" }
    config.freetype_load_flags = "NO_HINTING"
    config.freetype_load_target = "Light"

    ------------------------------------------------------------
    -- ## Colors & Cursor
    ------------------------------------------------------------
    config.color_scheme = "tokyonight_night"
    config.colors = {
        cursor_bg = "#7aa2f7",
        cursor_border = "#7aa2f7",
        cursor_fg = "black",
    }
    config.default_cursor_style = "BlinkingBar"

    ------------------------------------------------------------
    -- ## Window Look & Feel
    ------------------------------------------------------------
    config.window_decorations = "RESIZE|INTEGRATED_BUTTONS"
    config.hide_tab_bar_if_only_one_tab = false
    config.native_macos_fullscreen_mode = true

    config.window_background_opacity = 0.9
    config.macos_window_background_blur = 10
    config.window_padding = { left = 8, right = 8, top = 8, bottom = 8 }

    -- Double terminal grid size
    config.initial_cols = 160
    config.initial_rows = 48

    ------------------------------------------------------------
    -- ## Behavior
    ------------------------------------------------------------
    config.adjust_window_size_when_changing_font_size = false
    config.audible_bell = "Disabled"

    -- Always launch Nix-managed fish with Starship/Tokyo Night config
    config.default_prog = { os.getenv("HOME") .. "/.nix-profile/bin/fish", "-l" }

    -- Make sure Starship in WezTerm uses the shared Tokio Night config
    config.set_environment_variables = {
        STARSHIP_CONFIG = os.getenv("HOME") .. "/.config/starship.toml",
    }

    -- macOS Alt keys
    config.send_composed_key_when_left_alt_is_pressed = true
    config.send_composed_key_when_right_alt_is_pressed = true

    ------------------------------------------------------------
    -- ## Keys
    ------------------------------------------------------------
    config.keys = {
        { key = "c",   mods = "CMD",       action = act.CopyTo("Clipboard") },
        { key = "v",   mods = "CMD",       action = act.PasteFrom("Clipboard") },

        { key = "-",   mods = "CMD",       action = act.DecreaseFontSize },
        { key = "0",   mods = "CMD",       action = act.ResetFontSize },
        { key = "=",   mods = "CMD",       action = act.IncreaseFontSize },
        { key = "=",   mods = "CMD|SHIFT", action = act.IncreaseFontSize },

        -- Fullscreen
        { key = "f",   mods = "CMD|CTRL",  action = act.ToggleFullScreen },
        { key = "F11", mods = "",          action = act.ToggleFullScreen },

        -- Tabs & windows
        { key = "t",   mods = "CMD",       action = act.SpawnTab("CurrentPaneDomain") },
        { key = "w",   mods = "CMD",       action = act.CloseCurrentPane({ confirm = true }) },
        { key = "n",   mods = "CMD",       action = act.SpawnWindow },
    }

    ------------------------------------------------------------
    -- ## Mouse
    ------------------------------------------------------------
    config.mouse_bindings = {
        {
            event = { Down = { streak = 1, button = { WheelUp = 1 } } },
            mods = "CMD",
            action = act.IncreaseFontSize,
        },
        {
            event = { Down = { streak = 1, button = { WheelDown = 1 } } },
            mods = "CMD",
            action = act.DecreaseFontSize,
        },
    }

    return config
  '';

  # ============================================================================
  # Common macOS Packages
  # ============================================================================
  commonPackages = with pkgs; [
    # Interpreters (global baseline - always available)
    nodejs # Latest Node.js - for IDEs, scripts, terminal
    python3 # Latest Python 3 - for IDEs, scripts, terminal

    # CLI Development Tools
    cloc # Count lines of code
    gh # GitHub CLI
    jq # JSON processor
    just # Command runner
    lazygit # Git TUI

    # File Management & Utilities
    tree # Directory tree viewer
    pv # Pipe viewer (progress for pipes)
    tealdeer # tldr - simplified man pages
    fswatch # File system watcher
    mc # midnight-commander - file manager
    procps # Linux utilities (watch, ps, etc.)

    # Terminal Multiplexer
    zellij # Modern terminal multiplexer

    # Networking Tools
    netcat # Network utility
    wakeonlan # Wake-on-LAN utility
    websocat # WebSocket client

    # Text Processing
    lynx # Text-based web browser
    html2text # HTML to text converter

    # Backup & Archive
    restic # Backup program
    rage # Age encryption (Rust implementation)

    # macOS Built-in Overrides
    rsync # Modern rsync (macOS has 2006 version!)
    wget # File downloader (not in macOS)

    # CLI tools
    zoxide # Smart directory jumper
    bat # Better cat with syntax highlighting
    btop # Better top/htop
    ripgrep # Fast grep (rg)
    fd # Fast find
    fzf # Fuzzy finder
    eza # Modern ls replacement (used by ll alias)
    prettier # Code formatter
    nano # Modern nano with syntax highlighting

    # Utilities
    nmap # Network scanner

    # Fonts
    (pkgs.nerd-fonts.hack)
  ];

  # ============================================================================
  # Nano Configuration
  # ============================================================================
  nanoConfig = pkgs: ''
    # Modern nano configuration with syntax highlighting

    # Enable syntax highlighting from Nix package
    include ${pkgs.nano}/share/nano/*.nanorc

    # Auto-indent
    set autoindent

    # Convert tabs to spaces
    set tabstospaces
    set tabsize 2

    # Line numbers
    set linenumbers

    # Use mouse
    set mouse

    # Better search
    set casesensitive
    set regexp

    # Backup files
    set backup
    set backupdir "~/.nano/backups"

    # Show cursor position
    set constantshow

    # Auto-detect file type
    set matchbrackets "(<[{)>]}"
  '';

  # ============================================================================
  # Font Installation Activation Script
  # ============================================================================
  fontActivation =
    pkgs:
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      echo "Installing Hack Nerd Font for macOS..."
      mkdir -p "$HOME/Library/Fonts"

      # Find all Hack Nerd Font files in the Nix store
      FONT_PATH="${pkgs.nerd-fonts.hack}/share/fonts/truetype/NerdFonts/Hack"

      if [ -d "$FONT_PATH" ]; then
        # COPY font files to ~/Library/Fonts/ (not symlink - macOS needs real files)
        for font in "$FONT_PATH"/*.ttf; do
          if [ -f "$font" ]; then
            font_name=$(basename "$font")
            target="$HOME/Library/Fonts/$font_name"

            # Remove old file/symlink if it exists
            if [ -e "$target" ] || [ -L "$target" ]; then
              rm -f "$target"
            fi

            # Copy the font file (macOS Font Book doesn't always follow symlinks)
            cp "$font" "$target"
            echo "  Copied: $font_name"
          fi
        done
        
        # Clear font cache
        if command -v atsutil >/dev/null 2>&1; then
          atsutil databases -remove >/dev/null 2>&1 || true
        fi
        
        echo "✅ Hack Nerd Font installed for macOS"
        echo "   ⚠️  You may need to restart apps or log out/in for fonts to appear"
      else
        echo "⚠️  Font path not found: $FONT_PATH"
      fi
    '';

  # ============================================================================
  # macOS App Linking Activation Script
  # ============================================================================
  appLinkActivation = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    echo "Linking macOS GUI applications..."

    # Ensure main Applications directory exists
    mkdir -p "$HOME/Applications"

    # Apps to link to main Applications folder (from Home Manager Apps)
    apps=(
      "WezTerm.app"
    )

    for app in "''${apps[@]}"; do
      source="$HOME/Applications/Home Manager Apps/$app"
      target="$HOME/Applications/$app"

      if [ -e "$source" ]; then
        # Remove old symlink or Homebrew version
        if [ -L "$target" ] || [ -e "$target" ]; then
          echo "  Removing old $app..."
          rm -rf "$target"
        fi

        # Create new symlink
        echo "  Linking $app"
        ln -sf "$source" "$target"
      fi
    done

    echo "✅ macOS GUI applications linked"
  '';
}
