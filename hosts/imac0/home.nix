{
  pkgs,
  lib,
  inputs,
  ...
}:

let
  # Import shared fish configuration
  sharedFishConfig = import ../../modules/shared/fish-config.nix;
in

{
  # ============================================================================
  # Module Imports
  # ============================================================================
  imports = [
    # Per-host theming (starship, zellij, eza) - auto-detects hostname
    ../../modules/shared/theme-hm.nix
  ];

  # Theme configuration - set hostname for palette lookup
  theme.hostname = "imac0";
  # Home Manager needs a bit of information about you and the paths it should manage
  home.username = "markus";
  home.homeDirectory = "/Users/markus";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  home.stateVersion = "24.11";

  # Let Home Manager install and manage itself
  programs.home-manager.enable = true;

  # ============================================================================
  # Fish Shell Configuration
  # ============================================================================
  programs.fish = {
    enable = true;

    # Shell initialization (config.fish equivalent)
    shellInit = ''
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

    # Functions
    functions = {
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

      # sourceenv - load env vars from file
      sourceenv = ''
        sed -e 's/^/set -gx /' -e 's/=/\ /' $argv | source
      '';

      # sourcefish - load env vars from .env file
      sourcefish = {
        description = "Load env vars from a .env file into current Fish session";
        body = ''
          set file "$argv[1]"
          if test -z "$file"
              echo "Usage: sourcefish PATH_TO_ENV_FILE"
              return 1
          end
          if test -f "$file"
              for line in (cat "$file" | grep -v '^[[:space:]]*#' | grep .)
                  set key (echo $line | cut -d= -f1)
                  set val (echo $line | cut -d= -f2-)
                  set -gx $key "$val"
              end
          else
              echo "File not found: $file"
              return 1
          end
        '';
      };

      # pingt wrapper
      pingt = {
        description = "Timestamped ping (calls ~/Scripts/pingt.sh)";
        body = ''
          /Users/markus/Scripts/pingt.sh $argv
        '';
      };
    };

    # Aliases - merge shared config with macOS-specific aliases
    shellAliases = sharedFishConfig.fishAliases // {
      # macOS specific aliases
      mc = "env LANG=en_US.UTF-8 mc";
      # Force macOS native ping (inetutils ping has bugs on Darwin)
      # See: docs/reference/macos-network-tools.md
      ping = "/sbin/ping";
      # Other macOS network tools for reference
      traceroute = "/usr/sbin/traceroute";
      netstat = "/usr/sbin/netstat";
    };

    # Abbreviations - merge shared config with macOS-specific abbreviations
    shellAbbrs = sharedFishConfig.fishAbbrs // {
      flushdns = "sudo killall -HUP mDNSResponder && echo macOS DNS Cache Reset";
      hsb0 = "ssh mba@192.168.1.99 -t \"zellij attach hsb0 -c\"";
      hsb1 = "ssh mba@192.168.1.101 -t \"zellij attach hsb1 -c\"";
      hsb8 = "ssh mba@192.168.1.100 -t \"zellij attach hsb8 -c\"";
      csb0 = "ssh mba@cs0.barta.cm -p 2222 -t \"zellij attach csb0 -c\"";
      csb1 = "ssh mba@cs1.barta.cm -p 2222 -t \"zellij attach csb1 -c\"";
    };
  };

  # ============================================================================
  # Starship Prompt
  # ============================================================================
  # Config is auto-generated by theme-hm.nix (imported above)
  # This just enables the program and fish integration
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    enableBashIntegration = true;
  };

  # ============================================================================
  # WezTerm Terminal Configuration
  # ============================================================================
  programs.wezterm = {
    enable = true;
    extraConfig = ''
      local wezterm = require("wezterm")
      local act = wezterm.action
      local config = wezterm.config_builder()

      ------------------------------------------------------------
      -- ## Fonts & Text
      ------------------------------------------------------------
      config.font_size = 12
      config.line_height = 1.1
      config.font = wezterm.font("Hack Nerd Font Mono")

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
  };

  # ============================================================================
  # Git Configuration with Dual Identity
  # ============================================================================
  programs.git = {
    enable = true;

    # Global gitignore
    ignores = [
      "*~"
      ".DS_Store"
    ];

    settings = {
      # User settings
      user = {
        name = "Markus Barta";
        email = "markus@barta.com"; # Personal (default)
      };

      # macOS keychain credential helper
      credential.helper = "osxkeychain";

      # Sourcetree diff/merge tools (preserved from existing config)
      difftool.sourcetree = {
        cmd = ''opendiff "$LOCAL" "$REMOTE"'';
        path = "";
      };
      mergetool.sourcetree = {
        cmd = ''/Applications/Sourcetree.app/Contents/Resources/opendiff-w.sh "$LOCAL" "$REMOTE" -ancestor "$BASE" -merge "$MERGED"'';
        trustExitCode = true;
      };

      # Commit template (preserved from existing config)
      commit.template = "/Users/markus/.stCommitMsg";
    };

    # Dual identity: automatic work identity for BYTEPOETS projects
    includes = [
      {
        condition = "gitdir:~/Code/BYTEPOETS/";
        contents = {
          user = {
            name = "mba";
            email = "markus.barta@bytepoets.com";
          };
        };
      }
    ];
  };

  # ============================================================================
  # Zsh Configuration (System Shell)
  # ============================================================================
  programs.zsh = {
    enable = true;

    # Prepend Nix paths to PATH (same as Fish loginShellInit)
    initExtra = ''
      # Ensure Nix paths are prioritized
      export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
    '';
  };

  # ============================================================================
  # Direnv Configuration
  # ============================================================================
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true; # Better Nix integration
    # Fish integration is automatic
    # Zsh integration is automatic
  };

  # ============================================================================
  # Global Packages
  # ============================================================================
  home.packages = with pkgs; [
    # System Tools
    inputs.agenix.packages.x86_64-darwin.default

    # Interpreters (global baseline - always available)
    nodejs # Latest Node.js - for IDEs, scripts, terminal
    python3 # Latest Python 3 - for IDEs, scripts, terminal

    # CLI Development Tools (Stage 4 migration)
    gh # GitHub CLI
    jq # JSON processor
    just # Command runner
    lazygit # Git TUI

    # File Management & Utilities (Stage 4)
    tree # Directory tree viewer
    pv # Pipe viewer (progress for pipes)
    tealdeer # tldr - simplified man pages
    fswatch # File system watcher
    mc # midnight-commander - file manager

    # Terminal Tools (Stage 4)
    zellij # Modern terminal multiplexer
    eza # Modern ls replacement (themed via theme-hm.nix)

    # Networking Tools (Stage 4)
    netcat # Network utility
    wakeonlan # Wake-on-LAN utility (wake remote machines via magic packets)
    # inetutils excluded on macOS - Linux ping has timestamp overflow bug on Darwin
    # Use macOS native /sbin/ping instead (aliased below)
    # For telnet, use: brew install telnet or nc (netcat) as alternative
    websocat # WebSocket client

    # Text Processing (Stage 4)
    lynx # Text-based web browser
    html2text # HTML to text converter

    # Backup & Archive (Stage 4)
    restic # Backup program
    rage # Age encryption (Rust implementation)

    # macOS Built-in Overrides (Stage 4)
    rsync # Modern rsync (macOS has 2006 version!)
    wget # File downloader (not in macOS)

    # CLI tools (migrated from Homebrew earlier)
    zoxide # Smart directory jumper
    bat # Better cat with syntax highlighting
    btop # Better top/htop
    ripgrep # Fast grep (rg)
    fd # Fast find
    fzf # Fuzzy finder
    prettier # Code formatter (was Homebrew dependency)
    nano # Modern nano with syntax highlighting (macOS has ancient version)

    # Utilities
    esptool # ESP32/ESP8266 flashing tool
    nmap # Network scanner

    # Note: evernote-backup not in nixpkgs, keeping in Homebrew for now

    # Fonts
    (pkgs.nerd-fonts.hack)
  ];

  # Enable fontconfig for fonts to be recognized
  fonts.fontconfig.enable = true;

  # Install Hack Nerd Font for macOS (symlink to ~/Library/Fonts/)
  # macOS Font Book and Terminal.app only see fonts in ~/Library/Fonts/
  # WezTerm uses fontconfig and can see Nix fonts directly
  home.activation.installMacOSFonts = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    echo "Installing Hack Nerd Font for macOS..."
    mkdir -p "$HOME/Library/Fonts"

    # Find all Hack Nerd Font files in the Nix store
    FONT_PATH="${pkgs.nerd-fonts.hack}/share/fonts/truetype/NerdFonts/Hack"

    if [ -d "$FONT_PATH" ]; then
      # Symlink all font files to ~/Library/Fonts/
      for font in "$FONT_PATH"/*.ttf; do
        if [ -f "$font" ]; then
          font_name=$(basename "$font")
          target="$HOME/Library/Fonts/$font_name"

          # Remove old symlink if it exists
          if [ -L "$target" ]; then
            rm "$target"
          fi

          # Create new symlink
          if [ ! -e "$target" ]; then
            ln -sf "$font" "$target"
            echo "  Linked: $font_name"
          fi
        fi
      done
      echo "✅ Hack Nerd Font installed for macOS"
    else
      echo "⚠️  Font path not found: $FONT_PATH"
    fi
  '';

  # ============================================================================
  # macOS GUI Applications - Elegant Solution
  # ============================================================================
  # home-manager automatically links GUI apps to ~/Applications/Home Manager Apps/
  # This activation script additionally links important apps to ~/Applications/
  # for easier access (Finder, Dock) while maintaining declarative management.
  #
  # See: docs/macos-gui-apps.md for detailed explanation
  home.activation.linkMacOSApps = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    echo "Linking macOS GUI applications..."

    # Ensure main Applications directory exists
    mkdir -p "$HOME/Applications"

    # Apps to link to main Applications folder (from Home Manager Apps)
    # Add more apps here as you enable them in home.nix
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
    echo "   - Apps available in: ~/Applications/"
    echo "   - Also searchable in Spotlight (⌘+Space)"
    echo "   - Dock icons: Remove broken icons, then re-add from Spotlight"
  '';

  # ============================================================================
  # Nano Configuration
  # ============================================================================
  home.file.".nanorc".text = ''
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

    # Syntax highlighting for common files
    # (Nix includes: nix, yaml, markdown, python, shell, json, xml, etc.)
  '';

  # ============================================================================
  # Karabiner-Elements Configuration (Declarative!)
  # ============================================================================
  # Note: Karabiner-Elements app itself stays in Homebrew (system driver)
  # But the configuration is fully declarative via home-manager
  #
  # Key mappings:
  # - Caps Lock → Hyper (Cmd+Ctrl+Opt+Shift) - for powerful global shortcuts
  # - Function keys work as regular F1-F12 in terminals (no media keys)
  # - E → backtick in Pixelmator Pro (disabled by default)
  #
  # See: docs/karabiner-elements.md for details
  home.file.".config/karabiner/karabiner.json".source = ./config/karabiner.json;

  # ============================================================================
  # Starship, Zellij, Eza Theming
  # ============================================================================
  # Handled by theme-hm.nix module (imported above)
  # Theme: lightGray (Workstation - Home)
  # Features: Powerline gradient, root alert, error badge, sudo, duration, jobs
  # See: modules/shared/theme-palettes.nix for color definitions

  # ============================================================================
  # Scripts Management
  # ============================================================================
  home.file."Scripts" = {
    source = ./scripts/host-user;
    recursive = true; # Links all files in directory
    # Preserves executable permissions from git
  };

  # ============================================================================
  # Additional Settings
  # ============================================================================

  # XDG directories (macOS doesn't use XDG but home-manager expects it)
  xdg.enable = true;

  # Session variables
  home.sessionVariables = {
    # Set default editor for CLI tools (agenix, git, etc.)
    EDITOR = "nano";
  };
}
