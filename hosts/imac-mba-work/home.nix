{
  pkgs,
  lib,
  inputs,
  ...
}:

let
  # Import shared macOS configuration
  macosCommon = import ../../modules/shared/macos-common.nix { inherit pkgs lib; };
in

{
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
  # Fish Shell Configuration (from shared config)
  # ============================================================================
  programs.fish = macosCommon.fishConfig;

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
  home.packages = macosCommon.commonPackages ++ (with pkgs; [
    # System Tools
    inputs.agenix.packages.x86_64-darwin.default
  ]);

  # Enable fontconfig for fonts to be recognized
  fonts.fontconfig.enable = true;

  # Font installation (from shared config)
  home.activation.installMacOSFonts = macosCommon.fontActivation pkgs;

  # macOS app linking (from shared config)
  home.activation.linkMacOSApps = macosCommon.appLinkActivation;

  # ============================================================================
  # Nano Configuration (from shared config)
  # ============================================================================
  home.file.".nanorc".text = macosCommon.nanoConfig pkgs;

  # ============================================================================
  # Karabiner-Elements Configuration (Declarative!)
  # ============================================================================
  home.file.".config/karabiner/karabiner.json".source = ./config/karabiner.json;

  # ============================================================================
  # Starship Config File (shared across all macOS hosts)
  # ============================================================================
  home.file.".config/starship.toml" = {
    source = ../../modules/shared/starship.toml;
  };

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
