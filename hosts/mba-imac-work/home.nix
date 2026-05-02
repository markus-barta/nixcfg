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
    # Fleet SSH config with Tailscale fallback
    ../../modules/shared/ssh-fleet.nix
    # markus-defaults bundles all 3 INSPR public modules + Markus's values
    ../../modules/shared/markus-defaults.nix
    # nixfleet-agent is now loaded via flake input (inputs.nixfleet.homeManagerModules.nixfleet-agent)
  ];

  # ============================================================================
  # INSPR — Git identity (personal default + BYTEPOETS via remote-URL match)
  # ============================================================================
  inspr.git-identity.enable = true;

  # ============================================================================
  # SSH KEYS - Host-specific Git SSH config (preserved from manual ~/.ssh/config)
  # ============================================================================
  programs.ssh.matchBlocks = {
    "github-bp" = {
      hostname = "github.com";
      user = "git";
      identityFile = "~/.ssh/id_ed25519_bytepoets_office";
    };
    "5.75.130.206" = {
      hostname = "5.75.130.206";
      user = "git";
      identityFile = "~/.ssh/ops-bytepoets-com";
    };
  };

  # ============================================================================
  # NIXFLEET AGENT - Disabled (decommissioned, replaced by FleetCom DSC26-52)
  # ============================================================================
  # services.nixfleet-agent = {
  #   enable = true;
  #   url = "wss://fleet.barta.cm/ws";
  #   interval = 5;
  #   tokenFile = "/Users/markus/.config/nixfleet/token";
  #   repoUrl = "https://github.com/markus-barta/nixcfg.git";
  #   logLevel = "info";
  #   nixpkgsVersion = inputs.nixpkgs.shortRev;
  #   location = "work";
  #   deviceType = "desktop";
  #   themeColor = config.theme.palette.gradient.primary;
  # };

  # ============================================================================
  # UZUMAKI MODULE - All personal config in one place
  # ============================================================================
  uzumaki = {
    enable = true;
    role = "workstation";
    fish.editor = "nano";
    stasysmo.enable = true; # System metrics in Starship prompt
    ncps.enable = false; # Work iMac: Never sees hsb0
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
      # VSCodium CLI (codium) - installed via Homebrew cask
      fish_add_path --append /Applications/VSCodium.app/Contents/Resources/app/bin
      # User local bin (e.g. claude code)
      fish_add_path --append ~/.local/bin
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

      # ── PAIMOS instance shortcuts ────────────────────────────────────────
      # `ppm <args>` / `pmo <args>` → `paimos --instance <name> <args>`.
      # If the instance isn't in ~/.paimos/config.yaml yet, print a setup
      # hint pointing at ~/Secrets/<instance>/ instead of letting the raw
      # paimos error scroll past. One-time auth stays imperative (API key
      # is a secret — not declarative).
      __paimos_has_instance = {
        description = "internal: exit 0 if ~/.paimos/config.yaml has the named instance";
        body = ''
          set -l cfg $HOME/.paimos/config.yaml
          test -f $cfg; and grep -qE "^[[:space:]]+$argv[1]:" $cfg
        '';
      };
      ppm = {
        description = "paimos → pm.barta.cm (personal)";
        body = ''
          if not __paimos_has_instance ppm
              echo "paimos: instance 'ppm' not configured on this machine." >&2
              echo "  One-time setup:" >&2
              echo "    source ~/Secrets/ppm/PPMAPIKEY.env" >&2
              echo '    paimos auth login --url https://pm.barta.cm --api-key $PPMAPIKEY --name ppm' >&2
              echo "  Secrets live in ~/Secrets/ppm/ (see README.md there if any .env file is missing)." >&2
              return 2
          end
          paimos --instance ppm $argv
        '';
      };
      pmo = {
        description = "paimos → pm.bytepoets.com (bytepoets)";
        body = ''
          if not __paimos_has_instance pmo
              echo "paimos: instance 'pmo' not configured on this machine." >&2
              echo "  One-time setup:" >&2
              echo "    source ~/Secrets/PMO/PMOAPIKEY.env" >&2
              echo "    source ~/Secrets/PMO/PMOURL.env" >&2
              echo '    paimos auth login --url $PMOURL --api-key $PMOAPIKEY --name pmo' >&2
              echo "  Secrets live in ~/Secrets/PMO/ (see README.md there if any .env file is missing)." >&2
              return 2
          end
          paimos --instance pmo $argv
        '';
      };
    };

    # macOS-specific aliases (merged with uzumaki's)
    shellAliases = {
      mc = "env LANG=en_US.UTF-8 mc";
      ping = "/sbin/ping";
      traceroute = "/usr/sbin/traceroute";
      netstat = "/usr/sbin/netstat";
    };

    # macOS-specific abbreviations (merged with uzumaki's)
    shellAbbrs = macosCommon.fishConfig.shellAbbrs;
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
  # Git Configuration
  # ============================================================================
  # Identity is managed by modules/shared/git-identity.nix (see imports above).
  # This block owns host-specific bits only.
  programs.git = {
    ignores = [
      "*~"
      ".DS_Store"
    ];

    settings = {
      # macOS keychain credential helper
      credential.helper = "osxkeychain";

      # Sourcetree diff/merge tools
      difftool.sourcetree = {
        cmd = ''opendiff "$LOCAL" "$REMOTE"'';
        path = "";
      };
      mergetool.sourcetree = {
        cmd = ''/Applications/Sourcetree.app/Contents/Resources/opendiff-w.sh "$LOCAL" "$REMOTE" -ancestor "$BASE" -merge "$MERGED"'';
        trustExitCode = true;
      };

      # Commit template (path is /Users/markus/ — host-historical; preserved as-is)
      commit.template = "/Users/markus/.stCommitMsg";
    };
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
  # Global Packages (common only - no host-specific additions)
  # ============================================================================
  home.packages =
    macosCommon.commonPackages
    ++ (with pkgs; [
      # System Tools
      inputs.agenix.packages.x86_64-darwin.default

      # PAIMOS
      paimos-cli # Agent-facing CLI for PAIMOS (github.com/markus-barta/paimos)
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
  # SSOT: modules/config/karabiner.json (shared across all macOS hosts)
  home.file.".config/karabiner/karabiner.json".source = ../../modules/config/karabiner.json;

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
