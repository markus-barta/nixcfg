# Retained because modules/uzumaki/fish/functions.nix calls stasysmo-reader.
{
  lib,
  pkgs,
  cfg,
  snapshot,
}:
let
  init = import ./fish-init.nix { inherit lib cfg snapshot; };
  script = pkgs.writeText "stasysmo-reader.fish" ''
    ${init}
    __stasysmo_read "$STASYSMO_NOW"
    if set -q STASYSMO_DEBUG
      printf 'StaSysMo snapshot: %s\n' "$STASYSMO_SNAPSHOT"
    end
    printf '%s\n' (string join "$STASYSMO_SPACER_METRICS" -- $__stasysmo_metrics)
  '';
in
pkgs.writeShellScriptBin "stasysmo-reader" ''
  export STASYSMO_FISH=${pkgs.fish}/bin/fish
  export STASYSMO_READER_CONFIG=${script}
  ${builtins.readFile ./reader.sh}
''
