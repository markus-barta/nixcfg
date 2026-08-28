let
  pkgs = import <nixpkgs> { };
in
pkgs.lib.escapeShellArg "http://127.0.0.1:8123/it's?arg=$(printf injected)"
