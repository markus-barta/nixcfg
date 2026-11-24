# Offline: nix-instantiate --eval --strict --json --arg root "$PWD" \
#   --arg moduleOnly true tests/mbp2607-night-levels-eval.nix
{
  root,
  moduleOnly ? true,
}:
let
  # As in aeon-remote-guard-eval.nix, a cached nixpkgs/lib and inert package
  # stubs evaluate the real module without fetching a flake or building.
  lib = (import <nixpkgs/lib>).extend (
    _: _: {
      # Inert Home Manager DAG entry with the same shape as entryBetween.
      hm.dag.entryBetween = before: after: data: { inherit before after data; };
    }
  );
  pkgs.writeShellScript = name: text: {
    inherit text;
    outPath = "/fixture/${name}";
  };
  evaluated = lib.evalModules {
    specialArgs = { inherit lib pkgs; };
    modules = [
      (root + "/hosts/mbp2607/night-levels.nix")
      {
        options = {
          home.homeDirectory = lib.mkOption { type = lib.types.str; };
          home.profileDirectory = lib.mkOption { type = lib.types.str; };
          home.activation = lib.mkOption { type = lib.types.attrs; };
          launchd.agents = lib.mkOption { type = lib.types.attrs; };
        };
        config.home.homeDirectory = "/Users/markus";
        config.home.profileDirectory = "/Users/markus/.nix-profile";
      }
    ];
  };
  hostConfig =
    if moduleOnly then
      evaluated.config
    else
      (builtins.getFlake (toString root)).homeConfigurations."markus@mbp2607".config;
  agents = hostConfig.launchd.agents;
  loop = agents.night-levels.config;
  watcher = agents.night-levels-stale.config;
  env = loop.EnvironmentVariables;
  # Expose the actual rendered script for bash -n and night-levels-stale-test.sh.
  rendered = import (root + "/hosts/mbp2607/night-levels.nix") {
    config.home.homeDirectory = "/Users/markus";
    config.home.profileDirectory = "/Users/markus/.nix-profile";
    inherit lib;
    pkgs.writeShellScript = _: text: text;
  };
  staleScript = builtins.head rendered.launchd.agents.night-levels-stale.config.ProgramArguments;
  loopScript = builtins.readFile (root + "/hosts/mbp2607/files/night-levels/night-levels.sh");
  count = needle: text: builtins.length (lib.splitString needle text) - 1;
  sshCount = count "ssh -o" loopScript;
  checks = {
    bothEnabled = agents.night-levels.enable && agents.night-levels-stale.enable;
    keepAlive = loop.KeepAlive;
    runAtLoad = loop.RunAtLoad;
    bash = builtins.head loop.ProgramArguments == "/bin/bash";
    script = lib.hasSuffix "night-levels.sh" (builtins.elemAt loop.ProgramArguments 1);
    redLoad = env.RED_LOAD == "28";
    retiredMbp2606 = env.NL_RETIRED == "mbp2606";
    retiredSwitch = lib.hasInfix ''case " ''${NL_RETIRED:-} " in *" mbp2606 "*) retired6=1 ;; esac'' loopScript;
    noTestHooksInLaunchd = !(env ? NL_ONCE) && !(env ? NL_LEAD_DIR);
    macHealth = lib.hasSuffix "mac-health.sh" env.NL_MAC_HEALTH;
    unguarded = lib.hasSuffix "mbp2606-unguarded.sh" env.NL_UNGUARDED;
    home = env.HOME == "/Users/markus" && watcher.EnvironmentVariables.HOME == env.HOME;
    macOSPath =
      env.PATH
      == "/Users/markus/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin:/etc/profiles/per-user/markus/bin:/run/current-system/sw/bin";
    sshServerAlive = sshCount > 0 && sshCount == count "ServerAliveInterval=15" loopScript;
    permanentPolicy = !lib.hasInfix "-f /Users/markus/.aeon/lead/aeon/WEEKEND-MODE" loopScript;
    policyMaxload = lib.hasInfix "ml=\${RED_LOAD:-28}" loopScript;
    policyBlocksOnlyRed = lib.hasInfix ''[ "$l6" = RED ] && bl=1 || bl=0'' loopScript;
    noWeekdayMaxload = !lib.hasInfix "ml=12" loopScript;
    staleKickstart = lib.hasInfix "launchctl kickstart -k" staleScript;
    staleFallback = lib.hasInfix "maxload 12" staleScript;
    activationExists = hostConfig.home.activation ? nightLevelsStateDirectory;
    activationOrdering =
      hostConfig.home.activation.nightLevelsStateDirectory.before == [ "setupLaunchAgents" ]
      && hostConfig.home.activation.nightLevelsStateDirectory.after == [ "writeBoundary" ];
    activationMkdir = lib.hasInfix "run mkdir -p ${lib.escapeShellArg "/Users/markus/.local/share/ops-qa/state"}" hostConfig.home.activation.nightLevelsStateDirectory.data;
    throttle = loop.ThrottleInterval == 30;
    sameLog =
      loop.StandardOutPath == "/Users/markus/.local/share/ops-qa/state/brake-night-levels.log"
      && loop.StandardErrorPath == loop.StandardOutPath;
    staleInterval = watcher.StartInterval == 300;
    staleNotAtLoad = !watcher.RunAtLoad;
    staleLog =
      watcher.StandardOutPath == "/Users/markus/.local/share/ops-qa/state/night-levels-stale.log"
      && watcher.StandardErrorPath == watcher.StandardOutPath;
  };
in
assert builtins.all (value: value) (builtins.attrValues checks);
{
  inherit checks staleScript;
}
