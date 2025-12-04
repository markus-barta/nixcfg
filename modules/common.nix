{
  config,
  pkgs,
  lib,
  utils,
  ...
}:
let
  inherit (config) hokage;
  inherit (hokage) userLogin;
  inherit (hokage) userNameLong;
  inherit (hokage) useInternalInfrastructure;
  inherit (hokage) excludePackages;

  inherit (lib)
    mkDefault
    ;

  # Import shared fish configuration
  sharedFishConfig = import ./shared/fish-config.nix;
in
{
  # Disable hokage's starship (we configure our own with shared TOML file)
  hokage.programs.starship.enable = false;

  # Disable atuin - causes fish shell to hang on some systems
  hokage.programs.atuin.enable = false;

  # Set some fish config
  # Note: Fish functions (pingt, sourcefish, etc.) are provided by uzumaki modules
  programs = {
    fish = {
      enable = true;
      shellInit = ''
        # Fix: Help messages to be shown in English, instead of German
        set -e LANGUAGE

        # NOTE: Mouse tracking reset removed - was breaking Starship $fill on hsb1
        # See: pm/backlog/2025-12-04-starship-fill-broken-hsb1.md
      '';
      shellAliases = lib.mapAttrs (_: v: mkDefault v) sharedFishConfig.fishAliases;
      shellAbbrs = (lib.mapAttrs (_: v: mkDefault v) sharedFishConfig.fishAbbrs) // {
        # Force overrides for abbrs we want to take precedence over hokage
        nano = lib.mkForce "nano"; # hokage sets nano→micro, we want nano
        ping = lib.mkForce "pingt"; # hokage sets ping→gping, we want pingt
      };
      # interactiveShellInit is set by uzumaki/server.nix or uzumaki/desktop.nix
    };

    bash.shellAliases = config.programs.fish.shellAliases;

    # yet-another-nix-helper
    # https://github.com/viperML/nh
    nh = {
      enable = true;
      clean.enable = true;
      clean.extraArgs = "--keep-since 14d --keep 4";
    };

    # fuzzy finder TUI
    # https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/programs/television.nix
    television = {
      enable = true;
      # https://github.com/alexpasmantier/television/wiki/Shell-Autocompletion
      enableFishIntegration = true;
      enableBashIntegration = true;
    };
  };

  # Define a user account. Don't forget to set a password with "passwd".
  users.users = lib.genAttrs hokage.users (_userName: {
    isNormalUser = mkDefault true;
    description = mkDefault userNameLong;
    extraGroups = mkDefault [
      "networkmanager"
      "wheel"
      "docker"
      "dialout"
      "input"
    ];
    shell = mkDefault pkgs.fish;
    packages = mkDefault (
      with pkgs;
      [
      ]
    );
    # Set empty password initially. Don't forget to set a password with "passwd".
    initialHashedPassword = mkDefault "";
  });

  # Set your time zone.
  time.timeZone = "Europe/Vienna";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    # LC_ALL = "de_AT.UTF-8";
    LC_ADDRESS = "de_AT.UTF-8";
    LC_COLLATE = "de_AT.UTF-8";
    LC_CTYPE = "en_US.UTF-8";
    LC_IDENTIFICATION = "de_AT.UTF-8";
    LC_MEASUREMENT = "de_AT.UTF-8";
    LC_MONETARY = "de_AT.UTF-8";
    LC_NAME = "de_AT.UTF-8";
    LC_NUMERIC = "de_AT.UTF-8";
    LC_PAPER = "de_AT.UTF-8";
    LC_TELEPHONE = "de_AT.UTF-8";
    LC_TIME = "de_AT.UTF-8";
    # Use English for messages (e.g. error messages)
    # Although LANGUAGE still needed to be unset in fish shell
    LC_MESSAGES = "en_US.UTF-8";
  };

  # Configure console keymap
  console.keyMap = lib.mkDefault "de-latin1-nodeadkeys";

  networking = {
    networkmanager.enable = mkDefault true;
  };

  nix = {
    settings = {
      # Allow flakes
      experimental-features = [
        "nix-command"
        "flakes"
      ];

      # To do a "nix-build --repair" without sudo
      # We still need that to not get a "lacks a signature by a trusted key" error when building on a remote machine
      # https://wiki.nixos.org/wiki/Nixos-rebuild
      trusted-users = [
        "root"
        "@wheel"
      ];

      # Above is more dangerous than below
      # https://fosstodon.org/@lhf/112773183844782048
      # https://github.com/NixOS/nix/issues/9649#issuecomment-1868001568
      trusted-substituters = [
        "root"
        "@wheel"
      ];

      # Allow fallback from local caches
      connect-timeout = 5;
      fallback = true;
    };

    # Use symlink to the latest nixpkgs of the flake as nixpkgs, e.g. for nix-shell
    nixPath = [ "nixpkgs=/run/current-system/nixpkgs" ];

    # Try out the latest nix version
    package = mkDefault pkgs.nixVersions.latest;
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget

  environment.systemPackages =
    with pkgs;
    let
      requiredPackages = [
      ];
      optionalPackages = [
        # ══════════════════════════════════════════════════════════════════════
        # Core Tools
        # ══════════════════════════════════════════════════════════════════════
        wget # HTTP/FTP file downloader
        fish # Friendly interactive shell
        tmux # Terminal multiplexer (legacy)
        less # Pager for viewing files
        gnumake # Build automation tool

        # ══════════════════════════════════════════════════════════════════════
        # Git & Version Control
        # ══════════════════════════════════════════════════════════════════════
        gitFull # Git with gitk GUI
        gitflow # Git branching model extensions
        lazygit # Git TUI

        # ══════════════════════════════════════════════════════════════════════
        # System Monitoring
        # ══════════════════════════════════════════════════════════════════════
        htop # Interactive process viewer
        atop # Advanced system monitor
        btop # Beautiful resource monitor
        procs # Modern ps replacement
        lsof # List open files

        # ══════════════════════════════════════════════════════════════════════
        # File Management
        # ══════════════════════════════════════════════════════════════════════
        mc # Midnight Commander file manager
        ranger # Terminal file manager with vim bindings
        broot # Fast directory navigator (br alias)
        erdtree # Modern tree replacement
        ouch # Compress/decompress archives

        # ══════════════════════════════════════════════════════════════════════
        # Modern CLI Replacements
        # ══════════════════════════════════════════════════════════════════════
        ripgrep # Fast grep replacement (rg)
        fd # Fast find replacement
        eza # Modern ls replacement
        bat # Cat with syntax highlighting
        bat-extras.batgrep # Ripgrep + bat integration
        bat-extras.batman # Man pages with bat
        tldr # Simplified man pages
        dust # Disk usage analyzer (du replacement)
        duf # Disk free viewer (df replacement)
        dua # Disk usage interactive (ncdu replacement)
        dogdns # Modern dig replacement
        difftastic # Structural diff (syntax-aware)
        rdap # Modern whois replacement

        # ══════════════════════════════════════════════════════════════════════
        # Networking
        # ══════════════════════════════════════════════════════════════════════
        inetutils # Network utilities (ping, telnet, etc.)
        dig # DNS lookup utility
        netcat-openbsd # Netcat with Unix socket support
        nmap # Network scanner
        gping # Graphical ping
        speedtest-go # Internet speed test CLI

        # ══════════════════════════════════════════════════════════════════════
        # Terminal & Multiplexing
        # ══════════════════════════════════════════════════════════════════════
        zellij # Modern terminal multiplexer
        starship # Cross-shell prompt (config via theme-hm.nix)
        nano # Simple text editor

        # ══════════════════════════════════════════════════════════════════════
        # Development & Build Tools
        # ══════════════════════════════════════════════════════════════════════
        jq # JSON processor
        just # Modern make alternative
        devenv # Development environments CLI
        nix-tree # Explore Nix store dependencies
        nix-output-monitor # Beautiful nix build output with ETA (nom)

        # ══════════════════════════════════════════════════════════════════════
        # Backup & Security
        # ══════════════════════════════════════════════════════════════════════
        restic # Fast, encrypted backups

        # ══════════════════════════════════════════════════════════════════════
        # System Administration
        # ══════════════════════════════════════════════════════════════════════
        sysz # Systemctl with fzf interface
        neosay # Send messages to Matrix rooms

        # ══════════════════════════════════════════════════════════════════════
        # Disabled packages
        # ══════════════════════════════════════════════════════════════════════
        # neovim              # Replaced by helix
        # pingu               # Colorful ping (prefer gping)
        # television          # Fuzzy finder TUI (broken)
        # isd                 # Systemd TUI (broken in unstable)
      ];
    in
    requiredPackages ++ utils.removePackagesByName optionalPackages excludePackages;

  # Do garbage collection
  # Disabled for "programs.nh.clean.enable"
  #  nix.gc = {
  #    automatic = true;
  #    dates = "weekly";
  #    options = "--delete-older-than 20d";
  #  };

  # Add Restic Security Wrapper
  # https://wiki.nixos.org/wiki/Restic
  # Use lib.mkForce to prevent capability duplication from external hokage
  security.wrappers.restic = {
    source = "${pkgs.restic.out}/bin/restic";
    owner = userLogin;
    group = "users";
    permissions = "u=rwx,g=,o=";
    capabilities = lib.mkForce "cap_dac_read_search=+ep";
  };

  # Enable memory-safe implementation of the sudo command
  security.sudo-rs.enable = true;

  system = {
    # NOTE: nixpkgs symlink is created by external hokage's common.nix
    # See: https://discourse.nixos.org/t/do-flakes-also-set-the-system-channel/19798/18

    # Careful with this, see https://wiki.nixos.org/wiki/FAQ/When_do_I_update_stateVersion
    # Also see https://mynixos.com/nixpkgs/option/system.stateVersion
    stateVersion = "24.11";
  };

  # https://rycee.gitlab.io/home-manager/options.html
  # https://nix-community.github.io/home-manager/options.html#opt-home.file
  # Backup existing files instead of failing when they would be clobbered
  home-manager.backupFileExtension = "hm-backup";

  home-manager.users = lib.genAttrs hokage.usersWithRoot (_userName: {
    imports = [
      # Themed starship, zellij, and eza
      ./shared/theme-hm.nix
    ];

    # Pass hostname explicitly (builtins.getEnv doesn't work during NixOS eval)
    theme.hostname = config.networking.hostName;

    # The home.stateVersion option does not have a default and must be set
    home.stateVersion = "24.11";

    # Starship config now managed by theme-hm.nix (per-host colors)
    # Old static config removed: home.file.".config/starship.toml".source = ./shared/starship.toml;

    # Enable fish and bash in home-manager to use enableFishIntegration and enableBashIntegration
    programs = {
      # Starship: Disable hokage's programs.starship so theme-hm.nix can manage config
      # (defensive - hokage.catppuccin.enable = false should also prevent conflicts)
      starship.enable = lib.mkForce false;
      # Enable https://direnv.net/
      direnv = {
        enable = true;
        nix-direnv.enable = true;
      };

      fish = {
        enable = true;
        shellAliases = lib.mapAttrs (_: v: mkDefault v) sharedFishConfig.fishAliases;
        shellAbbrs = (lib.mapAttrs (_: v: mkDefault v) sharedFishConfig.fishAbbrs) // {
          # Force overrides for abbrs we want to take precedence over hokage
          nano = lib.mkForce "nano"; # hokage sets nano→micro, we want nano
          ping = lib.mkForce "pingt"; # hokage sets ping→gping, we want pingt
        };
        # Starship init (since programs.starship is disabled to allow theme-hm.nix config)
        interactiveShellInit = lib.mkAfter ''
          if test "$TERM" != "dumb"
            starship init fish | source
          end
        '';
      };
      bash.enable = true;

      # Run nix-shell, etc. in the fish shell instead of bash
      nix-your-shell = {
        enable = true;
        enableFishIntegration = true;
      };

      # Zellij: COMPLETELY disable hokage's programs.zellij
      # We manage config via theme-hm.nix home.file instead
      # Zellij binary is installed via environment.systemPackages
      zellij = {
        enable = lib.mkForce false;
        settings = lib.mkForce { };
        enableFishIntegration = lib.mkForce false;
        enableBashIntegration = lib.mkForce false;
      };

      # A smarter cd command
      # https://github.com/ajeetdsouza/zoxide
      zoxide = {
        enable = true;
        enableFishIntegration = true;
        enableBashIntegration = true;
        # Use mkForce to prevent duplication with external hokage
        options = lib.mkForce [ "--cmd cd" ];
      };

      # Post-modern editor (like vim)
      helix = {
        enable = true;
        defaultEditor = useInternalInfrastructure;
        settings = {
          # Tokyo Night to match our theme system (overrides hokage's catppuccin)
          # https://helix-editor.vercel.app/reference/list-of-themes#tokyonight_storm
          theme = lib.mkForce "tokyonight_storm";
        };
      };
    };
  });

  # Enable ZRAM swap to get more memory
  # https://search.nixos.org/options?channel=23.11&from=0&size=50&sort=relevance&type=packages&query=zram
  zramSwap = {
    enable = mkDefault true;
  };
}
