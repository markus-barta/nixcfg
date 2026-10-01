# One daemon command name, with a platform-native implementation on Darwin.
{ pkgs }:
if pkgs.stdenv.isDarwin then
  pkgs.stdenv.mkDerivation {
    name = "stasysmo-daemon";
    src = ./sampler.c;
    dontUnpack = true;
    buildPhase = ''
      $CC -std=c11 -Wall -Wextra -Werror -O2 "$src" -o stasysmo-daemon
    '';
    installPhase = ''
      install -Dm755 stasysmo-daemon "$out/bin/stasysmo-daemon"
    '';
  }
else
  pkgs.writeShellApplication {
    name = "stasysmo-daemon";
    runtimeInputs = [ pkgs.coreutils ];
    text = builtins.readFile ./daemon.sh;
  }
