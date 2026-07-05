{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixcfg.markusLogin;

  baseGroups = [
    "networkmanager"
    "wheel"
    "docker"
    "dialout"
    "input"
  ];
in
{
  options.nixcfg.markusLogin = {
    enable = lib.mkEnableOption "additive markus Unix login for NixOS fleet hosts";

    extraGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional groups for the additive markus login on this host.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.markus = {
      isNormalUser = true;
      description = "Markus Barta";
      home = "/home/markus";
      createHome = true;
      extraGroups = baseGroups ++ cfg.extraGroups;
      shell = pkgs.fish;

      # SSH-only for the additive phase. Existing per-host mba console passwords
      # remain the recovery path until a separate ticket decides otherwise.
      hashedPassword = "!";
    };

    inspr.ssh.authorized = {
      enable = true;
      users.markus = {
        trust = config._inspr.trustPresets.personalHosts;
        force = true;
      };
    };
  };
}
