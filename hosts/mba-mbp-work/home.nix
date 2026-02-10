{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:

let
  macosCommon = import ../../modules/uzumaki/macos-common.nix { inherit pkgs lib; };
in
{
  # ============================================================================
  # Module Imports
  # ============================================================================
  imports = [
    # Uzumaki: Fish functions, theming, stasysmo (all-in-one)
    ../../modules/uzumaki/home-manager.nix
    # nixfleet-agent is now loaded via flake input (inputs.nixfleet.homeManagerModules.nixfleet-agent)
  ];

  # ============================================================================
  # UZUMAKI MODULE - All personal config in one place
  # ============================================================================
  uzumaki = {
    enable = true;
    role = "workstation";
    fish.editor = "nano";
    stasysmo.enable = true; # System metrics in Starship prompt
  };

  # Theme configuration - set hostname for palette lookup
  theme.hostname = "mba-mbp-work";

  # ============================================================================
  # NixFleet Agent - Fleet Management
  # ============================================================================
  # NIXFLEET AGENT v2 - Token stored in ~/.config/nixfleet/token
  services.nixfleet-agent = {
    enable = true;
    url = "wss://fleet.barta.cm/ws"; # v2 uses WebSocket
    interval = 5; # Heartbeat interval in seconds
    tokenFile = "/Users/mba/.config/nixfleet/token";
    repoUrl = "https://github.com/markus-barta/nixcfg.git";
    logLevel = "info";
    nixpkgsVersion = inputs.nixpkgs.shortRev; # Pass nixpkgs version to agent
    location = "work";
    deviceType = "laptop";
    # Theme color from palette (P7200 - single source of truth)
    themeColor = config.theme.palette.gradient.primary;
  };

  # Home Manager needs a bit of information about you and the paths it should manage
  home.username = "mba";
  home.homeDirectory = "/Users/mba";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  home.stateVersion = "24.11";

  # Disable Home Manager / Nixpkgs version mismatch warning
  # (Using HM 25.11 with Nixpkgs 26.05 is intentional)
  home.enableNixpkgsReleaseCheck = false;

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

      # Add Nix profile completions to fish (enables completions for just, fd, etc.)
      if test -d ~/.nix-profile/share/fish/vendor_completions.d
        set -p fish_complete_path ~/.nix-profile/share/fish/vendor_completions.d
      end
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

    # Functions (pingt, sourcefish, stress, helpfish are provided by uzumaki)
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
    };

    # macOS-specific aliases (merged with uzumaki's shellAliases)
    shellAliases = {
      mc = "env LANG=en_US.UTF-8 mc";
      # Force macOS native ping (inetutils ping has bugs on Darwin)
      ping = "/sbin/ping";
      traceroute = "/usr/sbin/traceroute";
      netstat = "/usr/sbin/netstat";
    };

    # macOS-specific abbreviations (merged with uzumaki's shellAbbrs)
    shellAbbrs = macosCommon.fishConfig.shellAbbrs;
  };

  # ============================================================================
  # Starship Prompt
  # ============================================================================
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    enableBashIntegration = true;
  };

  # ============================================================================
  # WezTerm Terminal Configuration (Shared Config)
  # ============================================================================
  programs.wezterm = {
    enable = true;
    extraConfig = macosCommon.weztermConfig;
  };

  # ============================================================================
  # Git Configuration - Work Identity (BYTEPOETS default)
  # ============================================================================
  programs.git = {
    enable = true;

    # Global gitignore
    ignores = [
      "*~"
      ".DS_Store"
    ];

    settings = {
      # User settings - Work identity as default for work machine
      user = {
        name = "mba";
        email = "markus.barta@bytepoets.com";
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

      # Commit template
      commit.template = "/Users/mba/.stCommitMsg";
    };

    # Dual identity: personal identity for personal projects
    includes = [
      {
        condition = "gitdir:~/Code/personal/";
        contents = {
          user = {
            name = "Markus Barta";
            email = "markus@barta.com";
          };
        };
      }
      {
        condition = "gitdir:~/Code/nixcfg/";
        contents = {
          user = {
            name = "Markus Barta";
            email = "markus@barta.com";
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
    dotDir = "${config.xdg.configHome}/zsh"; # XDG-compliant (keeps home directory clean)

    # Prepend Nix paths to PATH (same as Fish loginShellInit)
    initContent = ''
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

    # CLI Development Tools
    devenv # Development environments CLI (for .envrc)
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

    # Terminal Tools
    zellij # Modern terminal multiplexer
    eza # Modern ls replacement (themed via theme-hm.nix)

    # Networking Tools
    netcat # Network utility
    wakeonlan # Wake-on-LAN utility
    speedtest-go # Speed test CLI
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
    prettier # Code formatter
    nano # Modern nano with syntax highlighting

    # Utilities
    esptool # ESP32/ESP8266 flashing tool
    nmap # Network scanner

    # Fonts
    (pkgs.nerd-fonts.hack)
  ];

  # Enable fontconfig for fonts to be recognized
  fonts.fontconfig.enable = true;

  # Install Hack Nerd Font for macOS (symlink to ~/Library/Fonts/)
  home.activation.installMacOSFonts = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    echo "Installing Hack Nerd Font for macOS..."
    mkdir -p "$HOME/Library/Fonts"

    FONT_PATH="${pkgs.nerd-fonts.hack}/share/fonts/truetype/NerdFonts/Hack"

    if [ -d "$FONT_PATH" ]; then
      for font in "$FONT_PATH"/*.ttf; do
        if [ -f "$font" ]; then
          font_name=$(basename "$font")
          target="$HOME/Library/Fonts/$font_name"

          if [ -L "$target" ]; then
            rm "$target"
          fi

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

  # macOS GUI Applications - create macOS aliases (not symlinks!)
  # Symlinks to /nix/store don't get indexed by Spotlight, but aliases do.
  home.activation.linkMacOSApps = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    echo "Linking macOS GUI applications..."
    mkdir -p "$HOME/Applications"

    apps=(
      "WezTerm.app"
    )

    for app in "''${apps[@]}"; do
      source="$HOME/Applications/Home Manager Apps/$app"
      target="$HOME/Applications/$app"

      if [ -e "$source" ]; then
        # Cleanup potential duplicates from buggy Finder script
        find "$HOME/Applications" -name "$app alias*" -delete 2>/dev/null || true

        if [ -L "$target" ] || [ -e "$target" ]; then
          echo "  Removing old $app..."
          rm -rf "$target"
        fi

        # Create macOS alias (not symlink!) - Spotlight indexes aliases properly
        echo "  Creating alias for $app"
        /usr/bin/osascript -e "tell application \"Finder\" to make alias file to POSIX file \"$source\" at POSIX file \"$HOME/Applications\" with properties {name:\"$app\"}" >/dev/null 2>&1
      fi
    done

    echo "✅ macOS GUI applications aliased"
    echo "   Apps will appear in Spotlight (⌘+Space)"
  '';

  # ============================================================================
  # Nano Configuration
  # ============================================================================
  home.file.".nanorc".text = ''
    # Modern nano configuration with syntax highlighting
    include ${pkgs.nano}/share/nano/*.nanorc

    set autoindent
    set tabstospaces
    set tabsize 2
    set linenumbers
    set mouse
    set casesensitive
    set regexp
    set backup
    set backupdir "~/.nano/backups"
    set constantshow
    set matchbrackets "(<[{)>]}"
  '';

  # ============================================================================
  # Karabiner-Elements Configuration (Declarative!)
  # ============================================================================
  # Note: Karabiner-Elements app itself stays in Homebrew (system driver)
  # But the configuration is fully declarative via home-manager
  # SSOT: modules/config/karabiner.json (shared across all macOS hosts)
  #
  # Key mappings:
  # - Caps Lock → Hyper (Cmd+Ctrl+Opt+Shift) - for powerful global shortcuts
  # - Function keys work as regular F1-F12 in terminals (no media keys)
  # - VSCodium: Shift+Enter → Ctrl+J
  home.file.".config/karabiner/karabiner.json".source = ../../modules/config/karabiner.json;

  # ============================================================================
  # Scripts Management
  # ============================================================================
  home.file."Scripts" = {
    source = ./scripts/host-user;
    recursive = true;
  };

  # ============================================================================
  # Additional Settings
  # ============================================================================
  xdg.enable = true;

  home.sessionVariables = {
    EDITOR = "nano";
  };
}
