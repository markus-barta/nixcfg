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
#   - Fish functions: pingt, stress, helpfish, sourcefish, sourceenv
#   - Zellij terminal multiplexer
#   - Role-based defaults (server/desktop/workstation)
#   - Automatic platform detection (NixOS vs Darwin)
#
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.uzumaki;

  # Platform detection: check if we're on NixOS or Darwin
  # NixOS has `config.system.nixos` defined, Darwin doesn't
  isNixOS = (config ? system) && (config.system ? nixos);
  isDarwin = !isNixOS;

  # Import shared fish configuration (consolidated in Phase 3)
  sharedFish = import ../shared/fish;
  fishFunctions = sharedFish.functions;

  # ════════════════════════════════════════════════════════════════════════════
  # NixOS: Convert function definitions to inline Fish functions
  # ════════════════════════════════════════════════════════════════════════════
  mkFishFunction = name: def: ''
    function ${name} --description '${def.description}'
      ${def.body}
    end
  '';

  # Build the fish init string based on enabled functions (NixOS)
  fishInitFunctions = lib.concatStrings (
    lib.optional cfg.fish.functions.pingt (mkFishFunction "pingt" fishFunctions.pingt)
    ++ lib.optional cfg.fish.functions.sourcefish (mkFishFunction "sourcefish" fishFunctions.sourcefish)
    ++ lib.optional cfg.fish.functions.sourceenv (mkFishFunction "sourceenv" fishFunctions.sourceenv)
    ++ lib.optional cfg.fish.functions.stress (mkFishFunction "stress" fishFunctions.stress)
    ++ lib.optional cfg.fish.functions.helpfish (mkFishFunction "helpfish" fishFunctions.helpfish)
  );

  # ════════════════════════════════════════════════════════════════════════════
  # Darwin: Build the functions attrset (Home Manager style)
  # ════════════════════════════════════════════════════════════════════════════
  enabledFunctions =
    { }
    // lib.optionalAttrs cfg.fish.functions.pingt { inherit (fishFunctions) pingt; }
    // lib.optionalAttrs cfg.fish.functions.sourcefish { inherit (fishFunctions) sourcefish; }
    // lib.optionalAttrs cfg.fish.functions.sourceenv { inherit (fishFunctions) sourceenv; }
    // lib.optionalAttrs cfg.fish.functions.stress { inherit (fishFunctions) stress; }
    // lib.optionalAttrs cfg.fish.functions.helpfish { inherit (fishFunctions) helpfish; };

in
{
  # ══════════════════════════════════════════════════════════════════════════════
  # OPTIONS
  # ══════════════════════════════════════════════════════════════════════════════

  imports = [ ./options.nix ];

  # ══════════════════════════════════════════════════════════════════════════════
  # CONFIGURATION
  # ══════════════════════════════════════════════════════════════════════════════

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # ════════════════════════════════════════════════════════════════════════
      # Common: Set detected platform
      # ════════════════════════════════════════════════════════════════════════
      {
        uzumaki.platform = if isNixOS then "nixos" else "darwin";
      }

      # ════════════════════════════════════════════════════════════════════════
      # NixOS Implementation
      # ════════════════════════════════════════════════════════════════════════
      (lib.mkIf isNixOS {
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
        environment.systemPackages = lib.mkIf cfg.zellij.enable [ pkgs.zellij ];
      })

      # ════════════════════════════════════════════════════════════════════════
      # Darwin/Home Manager Implementation
      # ════════════════════════════════════════════════════════════════════════
      (lib.mkIf isDarwin {
        # Fish functions via programs.fish.functions (Home Manager style)
        programs.fish.functions = lib.mkIf cfg.fish.enable enabledFunctions;

        programs.fish.interactiveShellInit = lib.mkIf cfg.fish.enable (
          lib.mkAfter ''
            # ══════════════════════════════════════════════════════════════════
            # Uzumaki - Editor Configuration
            # ══════════════════════════════════════════════════════════════════
            set -gx EDITOR ${cfg.fish.editor}
          ''
        );

        # Packages
        home.packages = lib.mkIf cfg.zellij.enable [ pkgs.zellij ];
      })
    ]
  );
}
