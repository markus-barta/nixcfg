# NixFleet Agent for Home Manager (macOS/Linux user-level)
#
# Usage:
#   imports = [ ./modules/home/nixfleet-agent.nix ];
#   services.nixfleet-agent = {
#     enable = true;
#     tokenFile = "~/.config/nixfleet/token";
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
    text = builtins.readFile ../../pkgs/nixfleet/agent/nixfleet-agent.sh;
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
      type = lib.types.str;
      default = "~/.config/nixfleet/token";
      description = "Path to file containing the API token";
    };

    interval = lib.mkOption {
      type = lib.types.int;
      default = 10;
      description = "Poll interval in seconds";
    };

    nixcfgPath = lib.mkOption {
      type = lib.types.str;
      default = "~/Code/nixcfg";
      description = "Path to nixcfg repository";
    };

    # New fields for dashboard display
    location = lib.mkOption {
      type = lib.types.enum [
        "cloud"
        "home"
        "work"
      ];
      default = "home";
      description = "Physical location category (cloud/home/work)";
    };

    deviceType = lib.mkOption {
      type = lib.types.enum [
        "server"
        "desktop"
        "laptop"
        "gaming"
      ];
      default = "desktop";
      description = "Device type (server/desktop/laptop/gaming)";
    };

    themeColor = lib.mkOption {
      type = lib.types.str;
      default = "#769ff0";
      description = "Theme color hex (from theme-palettes.nix)";
    };
  };

  config = lib.mkIf cfg.enable {
    # macOS launchd service
    launchd.agents.nixfleet-agent = lib.mkIf pkgs.stdenv.isDarwin {
      enable = true;
      config = {
        Label = "com.nixfleet.agent";
        ProgramArguments = [
          "/bin/bash"
          "-c"
          ''
            # Add Nix paths so home-manager is available
            export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
            export NIXFLEET_URL="${cfg.url}"
            export NIXFLEET_NIXCFG="${cfg.nixcfgPath}"
            export NIXFLEET_INTERVAL="${toString cfg.interval}"
            export NIXFLEET_LOCATION="${cfg.location}"
            export NIXFLEET_DEVICE_TYPE="${cfg.deviceType}"
            export NIXFLEET_THEME_COLOR="${cfg.themeColor}"
            export NIXFLEET_TOKEN="$(cat ${cfg.tokenFile})"
            exec ${agentScript}/bin/nixfleet-agent
          ''
        ];
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "/tmp/nixfleet-agent.log";
        StandardErrorPath = "/tmp/nixfleet-agent.err";
      };
    };

    # Linux systemd user service
    systemd.user.services.nixfleet-agent = lib.mkIf pkgs.stdenv.isLinux {
      Unit = {
        Description = "NixFleet Agent";
        After = [ "network-online.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${agentScript}/bin/nixfleet-agent";
        Restart = "always";
        RestartSec = 30;
        Environment = [
          "NIXFLEET_URL=${cfg.url}"
          "NIXFLEET_NIXCFG=${cfg.nixcfgPath}"
          "NIXFLEET_INTERVAL=${toString cfg.interval}"
          "NIXFLEET_LOCATION=${cfg.location}"
          "NIXFLEET_DEVICE_TYPE=${cfg.deviceType}"
          "NIXFLEET_THEME_COLOR=${cfg.themeColor}"
        ];
        EnvironmentFile = cfg.tokenFile;
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
