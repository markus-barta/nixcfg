# Local inference stays in MTPLX's installed runtime; Nix owns the launcher and Pi profile.
{ config, pkgs, ... }:
let
  agentDir = "${config.home.homeDirectory}/.local/share/pi-local/agent";
  launcherScript = pkgs.writeText "pi-local.py" (
    builtins.replaceStrings
      [ ''"@PI_LOCAL_CONFIG@"'' ]
      [
        (builtins.toJSON (
          builtins.toJSON {
            inherit agentDir;
            pi = "${config.home.homeDirectory}/.npm-global/bin/pi";
            extension = "${./files/pi-local-context.js}";
            providerExtension = "${./files/pi-local-provider.js}";
            telemetryExtension = "${./files/pi-local-telemetry.js}";
          }
        ))
      ]
      (builtins.readFile ./files/pi-local.py)
  );
  launcher = pkgs.writeShellScriptBin "pi-local" ''
    exec ${pkgs.python3}/bin/python3 ${launcherScript} "$@"
  '';
in
{
  home.packages = [ launcher ];
  programs.fish.functions.pi-local = {
    description = "Run Pi here using the MTPLX app engine and its settings";
    body = "${launcher}/bin/pi-local $argv";
  };
  # Model/port/context are discovered from the app by the provider extension.
  # Removing the old immutable models.json also removes its fixed sampler.
}
