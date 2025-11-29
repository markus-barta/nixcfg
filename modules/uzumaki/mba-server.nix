# MBA Server Common Configuration
# Provides shared config for mba's servers (csb0, csb1, hsb1, etc.)
# without forcing role or adding SSH keys (those are handled per-host)
#
# Usage in host configuration.nix:
#   imports = [ ../../modules/uzumaki/mba-server.nix ];
#
{ pkgs, lib, ... }:

{
  # ============================================================================
  # FISH SHELL CONFIGURATION
  # ============================================================================
  # sourcefish function for loading .env files (from old server-mba.nix)
  programs.fish.interactiveShellInit = lib.mkAfter ''
    function sourcefish --description 'Load env vars from a .env file into current Fish session'
      set file "$argv[1]"
      if test -z "$file"
        echo "Usage: sourcefish PATH_TO_ENV_FILE"
        return 1
      end
      if test -f "$file"
        for line in (cat "$file" | grep -v '^[[:space:]]*#' | grep .)
          set key (echo $line | cut -d= -f1)
          set val (echo $line | cut -d= -f2-)
          set -gx $key "$val"
        end
      else
        echo "File not found: $file"
        return 1
      end
    end
    set -gx EDITOR nano
  '';

  # ============================================================================
  # ZELLIJ TERMINAL MULTIPLEXER
  # ============================================================================
  # From old modules/mixins/zellij.nix - servers need this too!
  environment.systemPackages = with pkgs; [
    zellij
  ];
}

