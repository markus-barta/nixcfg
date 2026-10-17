{ lib }:
let
  evaluate =
    overrides:
    let
      evaluated = lib.evalModules {
        modules = [
          ../modules/adguard-users-secret.nix
          {
            options = {
              networking.hostName = lib.mkOption { type = lib.types.str; };
              services.adguardhome = {
                enable = lib.mkOption { default = true; };
                port = lib.mkOption { default = 3000; };
                settings = lib.mkOption {
                  default = {
                    dns.bootstrap_dns = [ ];
                  };
                };
                mutableSettings = lib.mkOption { default = false; };
              };
              age.secrets = lib.mkOption {
                default = { };
                type = lib.types.attrsOf (
                  lib.types.submodule (
                    { name, ... }:
                    {
                      options = {
                        file = lib.mkOption { type = lib.types.path; };
                        path = lib.mkOption { default = "/run/agenix/${name}"; };
                        owner = lib.mkOption { };
                        group = lib.mkOption { };
                        mode = lib.mkOption { };
                      };
                    }
                  )
                );
              };
              systemd.services = lib.mkOption {
                default = { };
                type = lib.types.attrsOf (
                  lib.types.submodule {
                    freeformType = lib.types.attrs;
                    options.restartTriggers = lib.mkOption { default = [ ]; };
                    options.serviceConfig = {
                      LoadCredential = lib.mkOption {
                        default = [ ];
                        type = lib.types.listOf lib.types.str;
                      };
                      ExecStartPre = lib.mkOption {
                        default = [ ];
                        type = lib.types.listOf lib.types.str;
                      };
                      SetCredential = lib.mkOption { default = [ ]; };
                      RuntimeDirectory = lib.mkOption { default = "AdGuardHome"; };
                      RuntimeDirectoryMode = lib.mkOption { default = ""; };
                      Type = lib.mkOption { default = ""; };
                      ExecStart = lib.mkOption { default = ""; };
                    };
                  }
                );
              };
              systemd.timers = lib.mkOption { default = { }; };
              warnings = lib.mkOption { default = [ ]; };
              assertions = lib.mkOption {
                default = [ ];
                type = lib.types.listOf lib.types.attrs;
              };
            };
            config = {
              networking.hostName = "hsb0";
              services.adguardhome.usersSecretFile = lib.mkDefault ./ops372-deliberately-absent;
              _module.args.pkgs = {
                writeShellScript = _: _: "/inject-users";
                coreutils = "/coreutils";
              };
            };
          }
          overrides
        ];
      };
      cfg = evaluated.config;
    in
    {
      secrets = lib.mapAttrs (_: secret: {
        inherit (secret)
          path
          owner
          group
          mode
          ;
      }) cfg.age.secrets;
      services = cfg.systemd.services;
      inherit (cfg) warnings;
      failures = map (entry: entry.message) (lib.filter (entry: !entry.assertion) cfg.assertions);
      valid = lib.all (entry: entry.assertion) cfg.assertions;
    };
in
{
  pending = evaluate { };
  # A harmless existing source file exercises pathExists=true. Never create a
  # fake .age file or provision/decrypt anything in this contract probe.
  provisioned = evaluate {
    services.adguardhome.usersSecretFile = ../modules/adguard-users-secret.py;
  };
  missingPeer = evaluate {
    services.adguardhome.usersSecretFile = ../modules/adguard-users-secret.py;
    services.adguardhome.usersSecretPeers = [ ./ops372-deliberately-absent-peer ];
  };
  provisionedPair = evaluate {
    services.adguardhome.usersSecretFile = ../modules/adguard-users-secret.py;
    services.adguardhome.usersSecretPeers = [ ./adguard-users-secret-eval.nix ];
  };
  disabled = evaluate { services.adguardhome.enable = false; };
  unconfigured = evaluate { services.adguardhome.usersSecretFile = null; };
  mutable = evaluate { services.adguardhome.mutableSettings = true; };
  inlineUsers = evaluate { services.adguardhome.settings.users = [ ]; };
}
