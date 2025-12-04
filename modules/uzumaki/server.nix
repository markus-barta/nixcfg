# Uzumaki Server - NixOS Server Configuration
# Provides shared config for mba's NixOS servers (csb0, csb1, hsb0, hsb1, hsb8, etc.)
# without forcing role or adding SSH keys (those are handled per-host)
#
# Usage in host configuration.nix:
#   imports = [ ../../modules/uzumaki/server.nix ];
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

    set -gx EDITOR nano
  '';

  # ============================================================================
  # ZELLIJ TERMINAL MULTIPLEXER
  # ============================================================================
  # Servers need zellij for session persistence
  environment.systemPackages = with pkgs; [
    zellij
  ];
}
