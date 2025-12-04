# Uzumaki Desktop - NixOS Desktop Configuration
# Provides shared config for mba's NixOS desktops (gaming-pc, future dev workstations)
# without forcing role or adding SSH keys (those are handled per-host)
#
# Usage in host configuration.nix:
#   imports = [ ../../modules/uzumaki/desktop.nix ];
#
{ pkgs, lib, ... }:

let
  # Import shared function definitions
  fishFunctions = import ./common.nix;

  # Convert function definitions to inline Fish functions for interactiveShellInit
  mkFishFunction = name: def: ''
    function ${name} --description '${def.description}'
      ${def.body}
    end
  '';
in
{
  # ============================================================================
  # FISH SHELL CONFIGURATION
  # ============================================================================
  programs.fish.interactiveShellInit = lib.mkAfter ''
    ${mkFishFunction "pingt" fishFunctions.pingt}
    ${mkFishFunction "sourcefish" fishFunctions.sourcefish}
    ${mkFishFunction "sourceenv" fishFunctions.sourceenv}
    ${mkFishFunction "stress" fishFunctions.stress}
    ${mkFishFunction "helpfish" fishFunctions.helpfish}

    set -gx EDITOR nano
  '';

  # ============================================================================
  # ZELLIJ TERMINAL MULTIPLEXER
  # ============================================================================
  # Desktops also benefit from zellij for session persistence
  environment.systemPackages = with pkgs; [
    zellij
  ];
}
