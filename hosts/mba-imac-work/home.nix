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
  imports = [
    # Uzumaki: Fish functions, theming, stasysmo (all-in-one)
    ../../modules/uzumaki/home-manager.nix
    # nixfleet-agent is now loaded via flake input (inputs.nixfleet.homeManagerModules.nixfleet-agent)
  ];

  # ============================================================================
  # NixFleet Agent - Fleet Management
  # ============================================================================
  # NixFleet v2 agent - connects to fleet.barta.cm via WebSocket
  # Token stored in ~/.config/nixfleet/token
  services.nixfleet-agent = {
    enable = true;
    url = "wss://fleet.barta.cm/ws"; # v2 uses WebSocket
    interval = 5; # Heartbeat interval in seconds
    tokenFile = "/Users/markus/.config/nixfleet/token";
    repoUrl = "https://github.com/markus-barta/nixcfg.git"; # Isolated repo mode
    logLevel = "info";
    nixpkgsVersion = inputs.nixpkgs.shortRev; # Pass nixpkgs version to agent
    location = "work";
    deviceType = "desktop";
    # Theme color from palette (P7200 - single source of truth)
    themeColor = config.theme.palette.gradient.primary;
  };

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
  theme.hostname = "mba-imac-work";
  # Home Manager needs a bit of information about you and the paths it should manage
  home.username = "markus";
  home.homeDirectory = "/Users/markus";

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
  # Core config (functions, aliases, abbrs) provided by uzumaki/home-manager.nix
  # Add host-specific overrides here
  programs.fish = {
    enable = true;

    # Shell initialization
    shellInit = ''
      set -gx TERM xterm-256color
      set -gx ZOXIDE_CMD z

      # Add Nix profile completions to fish (enables completions for just, fd, etc.)
      if test -d ~/.nix-profile/share/fish/vendor_completions.d
        set -p fish_complete_path ~/.nix-profile/share/fish/vendor_completions.d
      end
    '';

    # Login shell initialization - prepend Nix paths to PATH
    loginShellInit = ''
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

    # Host-specific functions
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

    # macOS-specific aliases (merged with uzumaki's)
    shellAliases = {
      mc = "env LANG=en_US.UTF-8 mc";
      ping = "/sbin/ping";
      traceroute = "/usr/sbin/traceroute";
      netstat = "/usr/sbin/netstat";
    };

    # macOS-specific abbreviations (merged with uzumaki's)
    shellAbbrs = {
      flushdns = "sudo killall -HUP mDNSResponder && echo macOS DNS Cache Reset";
    };
  };

  # ============================================================================
  # Starship Prompt Configuration
  # ============================================================================
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
  };

  # ============================================================================
  # WezTerm Terminal Configuration (from shared config)
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

      # Commit template (preserved from existing config)
      commit.template = "/Users/markus/.stCommitMsg";
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
  };

  # ============================================================================
  # Global Packages (common only - no host-specific additions)
  # ============================================================================
  home.packages =
    macosCommon.commonPackages
    ++ (with pkgs; [
      # System Tools
      inputs.agenix.packages.x86_64-darwin.default
    ]);

  # Enable fontconfig for fonts to be recognized
  fonts.fontconfig.enable = true;

  # Font installation (from shared config)
  home.activation.installMacOSFonts = macosCommon.fontActivation pkgs;

  # macOS app linking (from shared config)
  # DISABLED: Requires UI interaction (Finder permission) - see RUNBOOK.md
  # home.activation.linkMacOSApps = macosCommon.appLinkActivation;

  # ============================================================================
  # Nano Configuration (from shared config)
  # ============================================================================
  home.file.".nanorc".text = macosCommon.nanoConfig pkgs;

  # ============================================================================
  # Karabiner-Elements Configuration (Declarative!)
  # ============================================================================
  home.file.".config/karabiner/karabiner.json".source = ./config/karabiner.json;

  # ============================================================================
  # Starship Config - NOW MANAGED BY theme-hm.nix (auto-detected hostname)
  # ============================================================================
  # Theme: darkGray (workstation-work category)
  # See: modules/uzumaki/theme/theme-palettes.nix for color definitions

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

  # XDG directories (macOS doesn't use XDG but home-manager expects it)
  xdg.enable = true;

  # Session variables
  home.sessionVariables = {
    EDITOR = "nano";
  };
}
