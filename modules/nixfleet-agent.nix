# NixFleet Agent Module
#
# Provides automatic fleet management agent that polls the dashboard
# for commands and reports host status.
#
# Usage:
#   imports = [ ./modules/nixfleet-agent.nix ];
#   services.nixfleet-agent = {
#     enable = true;
#     tokenFile = config.age.secrets.nixfleet-token.path;
#   };
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nixfleet-agent;

  agentScript = pkgs.writeShellApplication {
    name = "nixfleet-agent";
    runtimeInputs = with pkgs; [
      curl
      jq
      git
      hostname
    ];
    text = builtins.readFile ../pkgs/nixfleet/agent/nixfleet-agent.sh;
  };
in
{
  options.services.nixfleet-agent = {
    enable = lib.mkEnableOption "NixFleet agent for fleet management";

    url = lib.mkOption {
      type = lib.types.str;
      default = "https://fleet.barta.cm";
      description = "NixFleet dashboard URL";
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing the API token";
    };

    interval = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Poll interval in seconds";
    };

    nixcfgPath = lib.mkOption {
      type = lib.types.str;
      default = "/home/mba/Code/nixcfg";
      description = "Path to nixcfg repository";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "mba";
      description = "User to run the agent as (needs sudo access for nixos-rebuild)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Allow agent user to run nixos-rebuild without password
    security.sudo.extraRules = [
      {
        users = [ cfg.user ];
        commands = [
          {
            command = "/run/current-system/sw/bin/nixos-rebuild";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    systemd.services.nixfleet-agent = {
      description = "NixFleet Agent";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        NIXFLEET_URL = cfg.url;
        NIXFLEET_NIXCFG = cfg.nixcfgPath;
        NIXFLEET_INTERVAL = toString cfg.interval;
        HOME = "/home/${cfg.user}"; # Ensure SSH keys are found
      };

      path = [ "/run/current-system/sw" ]; # For nixos-rebuild and sudo

      serviceConfig = {
        Type = "simple";
        ExecStart = "${agentScript}/bin/nixfleet-agent";
        Restart = "always";
        RestartSec = 30;

        # Read token from file
        EnvironmentFile = cfg.tokenFile;

        # Run as regular user (uses sudo for nixos-rebuild)
        User = cfg.user;
        Group = "users";

        # Logging
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
  };
}
