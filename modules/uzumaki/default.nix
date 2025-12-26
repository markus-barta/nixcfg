# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                   Uzumaki Module - Entry Point                               ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# The "son of hokage" - builds on hokage's infrastructure to add personalized
# tooling and theming. Hokage handles heavy lifting (user management, system
# setup); Uzumaki adds the personal touch (fish functions, per-host themes).
#
# Usage (NixOS):
#   imports = [ ../../modules/uzumaki ];
#   uzumaki = {
#     enable = true;
#     role = "server";  # or "desktop"
#   };
#
# Usage (macOS Home Manager):
#   imports = [ ../../modules/uzumaki ];
#   uzumaki = {
#     enable = true;
#     role = "workstation";
#   };
#
# Features:
#   - Fish functions: pingt, stress, helpfish, hostcolors, hostsecrets, sourcefish
#   - Zellij terminal multiplexer
#   - StaSysMo system monitoring (opt-in via uzumaki.stasysmo.enable)
#   - Role-based defaults (server/desktop/workstation)
#
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.uzumaki;

  # Import fish configuration (consolidated into uzumaki)
  fishModule = import ./fish;
  fishFunctions = fishModule.functions;

  # Import theme palettes for nixfleet-agent color wiring
  themePalettes = import ./theme/theme-palettes.nix;

  # ════════════════════════════════════════════════════════════════════════════
  # Convert function definitions to inline Fish functions for interactiveShellInit
  # ════════════════════════════════════════════════════════════════════════════
  mkFishFunction = name: def: ''
    function ${name} --description '${def.description}'
      ${def.body}
    end
  '';

  # Build the fish init string based on enabled functions
  fishInitFunctions = lib.concatStrings (
    lib.optional cfg.fish.functions.pingt (mkFishFunction "pingt" fishFunctions.pingt)
    ++ lib.optional cfg.fish.functions.sourcefish (mkFishFunction "sourcefish" fishFunctions.sourcefish)
    ++ lib.optional cfg.fish.functions.stress (mkFishFunction "stress" fishFunctions.stress)
    ++ lib.optional cfg.fish.functions.stasysmod (mkFishFunction "stasysmod" fishFunctions.stasysmod)
    ++ lib.optional cfg.fish.functions.hostcolors (mkFishFunction "hostcolors" fishFunctions.hostcolors)
    ++ lib.optional cfg.fish.functions.hostsecrets (
      mkFishFunction "hostsecrets" fishFunctions.hostsecrets
    )
    ++ lib.optional cfg.fish.functions.helpfish (mkFishFunction "helpfish" fishFunctions.helpfish)
  );

in
{
  # ══════════════════════════════════════════════════════════════════════════════
  # IMPORTS
  # ══════════════════════════════════════════════════════════════════════════════

  imports = [
    ./options.nix
    ./stasysmo/nixos.nix # StaSysMo options (enabled via uzumaki.stasysmo.enable)
  ];

  # ══════════════════════════════════════════════════════════════════════════════
  # CONFIGURATION (NixOS only)
  # ══════════════════════════════════════════════════════════════════════════════
  # NOTE: This module is for NixOS system-level configuration only.
  # Darwin/macOS uses a separate Home Manager pattern - see hosts/imac0/home.nix

  config = lib.mkIf cfg.enable {
    # Platform marker
    uzumaki.platform = "nixos";

    # Fish functions via interactiveShellInit
    programs.fish.interactiveShellInit = lib.mkIf cfg.fish.enable (
      lib.mkAfter ''
        # ══════════════════════════════════════════════════════════════════
        # Uzumaki Fish Functions
        # ══════════════════════════════════════════════════════════════════
        ${fishInitFunctions}

        # Editor
        set -gx EDITOR ${cfg.fish.editor}
      ''
    );

    # Packages
    environment.systemPackages = [
      pkgs.pingt # Timestamped ping with color-coded output
      pkgs.age # Modern encryption tool (reference implementation)
    ]
    ++ lib.optionals cfg.zellij.enable [ pkgs.zellij ];

    # StaSysMo - System monitoring in Starship prompt
    services.stasysmo.enable = cfg.stasysmo.enable;

    # ══════════════════════════════════════════════════════════════════════════
    # Nix Configuration (NCPS Binary Cache Proxy)
    # ══════════════════════════════════════════════════════════════════════════
    # hsb0.lan provides a local cache for the home network.
    # We always manage the settings, but only add the local cache
    # entries if uzumaki.ncps.enable is true.
    nix.settings = {
      substituters = lib.mkOverride 0 (
        [
          "https://cache.nixos.org"
          "https://nix-community.cachix.org"
        ]
        ++ lib.optionals cfg.ncps.enable [ "http://hsb0.lan:8501" ]
      );
      trusted-public-keys = lib.mkOverride 0 (
        [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ]
        ++ lib.optionals cfg.ncps.enable [ "hsb0.lan-1:jKVnVnEwJPaevI5NyBKBtk7mJGPQ3EMlIoPb7VmPcD0=" ]
      );
    };

    # ══════════════════════════════════════════════════════════════════════════
    # NIXFLEET AGENT - Auto-wire theme color from palette
    # See: P7200-host-colors-single-source-of-truth.md
    # ══════════════════════════════════════════════════════════════════════════
    # This sets the agent's themeColor from the palette's primary gradient color,
    # so the NixFleet dashboard shows each host with its correct starship color.
    #
    services.nixfleet-agent.themeColor =
      let
        hostname = config.networking.hostName;
        paletteName = themePalettes.hostPalette.${hostname} or themePalettes.defaultPalette;
        palette = themePalettes.palettes.${paletteName};
      in
      lib.mkIf (config.services.nixfleet-agent.enable or false) palette.gradient.primary;
  };
}
