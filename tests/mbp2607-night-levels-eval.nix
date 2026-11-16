# Offline: nix-instantiate --eval --strict --json --arg root "$PWD" \
#   --arg moduleOnly true tests/mbp2607-night-levels-eval.nix
{
  root,
  moduleOnly ? true,
}:
let
  # As in aeon-remote-guard-eval.nix, a cached nixpkgs/lib and inert package
  # stubs evaluate the real module without fetching a flake or building.
  lib = import <nixpkgs/lib>;
  pkgs.writeShellScript = name: text: {
    inherit text;
    outPath = "/fixture/${name}";
  };
  evaluated = lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      (root + "/hosts/mbp2607/night-levels.nix")
      {
        options = {
          home.homeDirectory = lib.mkOption { type = lib.types.str; };
          launchd.agents = lib.mkOption { type = lib.types.attrs; };
        };
        config.home.homeDirectory = "/Users/markus";
      }
    ];
  };
  agents =
    if moduleOnly then
      evaluated.config.launchd.agents
    else
      (builtins.getFlake (toString root)).homeConfigurations."markus@mbp2607".config.launchd.agents;
  loop = agents.night-levels.config;
  watcher = agents.night-levels-stale.config;
  env = loop.EnvironmentVariables;
  # Expose the actual rendered script for bash -n and isolated transition tests.
  rendered = import (root + "/hosts/mbp2607/night-levels.nix") {
    config.home.homeDirectory = "/Users/markus";
    pkgs.writeShellScript = _: text: text;
  };
  checks = {
    bothEnabled = agents.night-levels.enable && agents.night-levels-stale.enable;
    keepAlive = loop.KeepAlive;
    runAtLoad = loop.RunAtLoad;
    bash = builtins.head loop.ProgramArguments == "/bin/bash";
    script = lib.hasSuffix "night-levels.sh" (builtins.elemAt loop.ProgramArguments 1);
    redLoad = env.RED_LOAD == "28";
    macHealth = lib.hasSuffix "mac-health.sh" env.NL_MAC_HEALTH;
    unguarded = lib.hasSuffix "mbp2606-unguarded.sh" env.NL_UNGUARDED;
    home = env.HOME == "/Users/markus" && watcher.EnvironmentVariables.HOME == env.HOME;
    macOSPath = env.PATH == "/Users/markus/.nix-profile/bin:/etc/profiles/per-user/markus/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    throttle = loop.ThrottleInterval == 30;
    sameLog = loop.StandardOutPath == "/Users/markus/.local/share/ops-qa/state/brake-night-levels.log"
      && loop.StandardErrorPath == loop.StandardOutPath;
    staleInterval = watcher.StartInterval == 300;
    staleNotAtLoad = !watcher.RunAtLoad;
    staleLog = watcher.StandardOutPath == "/Users/markus/.local/share/ops-qa/state/night-levels-stale.log"
      && watcher.StandardErrorPath == watcher.StandardOutPath;
  };
in
assert builtins.all (value: value) (builtins.attrValues checks);
{
  inherit checks;
  staleScript = builtins.head rendered.launchd.agents.night-levels-stale.config.ProgramArguments;
}
