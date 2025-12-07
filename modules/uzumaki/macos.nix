# Uzumaki macOS - Home Manager Configuration for macOS
# Provides shared Fish functions for mba's macOS machines (imac0, imac-mba-work, etc.)
#
# Usage in home.nix:
#   imports = [ ../../modules/uzumaki/macos.nix ];
#
# Note: This is a Home Manager module, not a NixOS module!
#
{ ... }:

let
  # Import shared function definitions from the consolidated fish module
  fishModule = import ./fish;
  fishFunctions = fishModule.functions;
in
{
  # ============================================================================
  # FISH SHELL FUNCTIONS
  # ============================================================================
  # These are added to programs.fish.functions (Home Manager style)
  programs.fish.functions = {
    inherit (fishFunctions) pingt sourcefish;
  };
}
