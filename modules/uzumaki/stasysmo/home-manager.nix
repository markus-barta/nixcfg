# Per-account fish compositor; native launchd sampler on Darwin only.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.stasysmo;
  defaults = import ./config.nix;
  darwin = pkgs.stdenv.isDarwin;
  directory = "${config.home.homeDirectory}/${defaults.daemon.darwinDir}";
  snapshot = if darwin then "${directory}/snapshot" else "${defaults.daemon.linuxDir}/snapshot";
  daemon = import ./package.nix { inherit pkgs; };
  reader = import ./reader-package.nix {
    inherit
      lib
      pkgs
      cfg
      snapshot
      ;
  };
  # NIX-603 established that mba has no GUI launchd domain on this Mac.
  # Preserve its StaSysMo setting (fish can still render), omit an unloadable job.
  hasLaunchdDomain = !((config.theme.hostname or "") == "mbp2606" && config.home.username == "mba");
in
{
  options.services.stasysmo = import ./options.nix {
    inherit lib;
    platform = if darwin then "darwin" else "linux";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ reader ] ++ lib.optional darwin daemon;
    programs.fish.interactiveShellInit = lib.mkOrder 1600 (
      import ./fish-init.nix { inherit lib cfg snapshot; }
    );

    home.activation.stasysmoDirectories = lib.mkIf (darwin && hasLaunchdDomain) (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        # The native helper verifies owner/mode and rejects an unsafe leaf.
        run mkdir -p ${lib.escapeShellArg "${config.home.homeDirectory}/Library/Caches"}
        run mkdir -p ${lib.escapeShellArg "${config.home.homeDirectory}/Library/Logs"}
      ''
    );

    launchd.agents.stasysmo-daemon = lib.mkIf darwin {
      enable = hasLaunchdDomain;
      config = {
        Label = "com.stasysmo.daemon";
        ProgramArguments = [
          "${daemon}/bin/stasysmo-daemon"
          (toString cfg.daemon.interval)
          directory
        ];
        KeepAlive = true;
        RunAtLoad = true;
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/stasysmo-daemon.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/stasysmo-daemon.error.log";
      };
    };
  };
}
