# OPS-705: independent one-shot alarm transport; no new secret or daemon.
{ config, pkgs, ... }:
let
  sender = pkgs.writeText "hausnetz-cd-alert.py" (
    builtins.replaceStrings [ "@NOTIFICATION_ENV@" ] [ config.age.secrets.csb1-watchtower-env.path ] (
      builtins.readFile ./hausnetz-cd-alert.py
    )
  );
in
{
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "hausnetz-cd-alert";
      runtimeInputs = [ pkgs.python3 ];
      text = ''
        exec python3 -B ${sender} "$@"
      '';
    })
  ];
}
