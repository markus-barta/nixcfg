# Paper IB Gateway session-readiness supervisor — HOSTD-58.
#
# Docker Up and socat 4004 are not a broker session. This unit classifies
# slowstarting / authenticating / api_ready / upstream_unavailable, restarts
# only allowlisted ib-gateway through the existing composeStack lock, and
# keeps a one-attempt budget on disk across reboots. Alerts use a configured
# adapter; the default is disabled and secret-free until a live receiver exists.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.nixcfg.ibGatewaySession;
  stack = config.nixcfg.composeStack;
  fleetEngine = ../shared/fleet-alerts/engine.py;
  blocker = "alert adapter disabled: nixcfg.ibGatewaySession.alert.enable is false. hsb0 has no declared WATCHTOWER_NOTIFICATION_URL secret. To activate Amy paging, add an agenix env decryptable by hsb0 with WATCHTOWER_NOTIFICATION_URL (same fleet-alerts shape as csb1-watchtower-env / hsb1-tailnet-watch-env), then set alert.enable=true, alert.transport=shoutrrr, alert.notificationEnvFile to that path. openclaw-gateway is parked so agent-bus is not a live receiver. Do not invent an endpoint.";
  supervisor = pkgs.runCommand "ib-gateway-session-supervisor" { } ''
    mkdir -p "$out"
    cp ${./supervisor.py} "$out/supervisor.py"
    cp ${fleetEngine} "$out/engine.py"
    cp ${./notification_state.py} "$out/notification_state.py"
    cp ${./notification_delivery.py} "$out/notification_delivery.py"
  '';
in
{
  options.nixcfg.ibGatewaySession = {
    enable = lib.mkEnableOption "paper IB Gateway session-readiness supervisor on hsb0";

    alert = {
      enable = lib.mkEnableOption "send bounded session alerts through a declared adapter";
      transport = lib.mkOption {
        type = lib.types.enum [
          "none"
          "agent-bus"
          "shoutrrr"
          "email-agent-bus"
        ];
        default = "none";
        description = ''
          Declared mechanic only. `none` is the default: hsb0 has no
          WATCHTOWER_NOTIFICATION_URL secret, and OpenClaw is parked. Do not
          invent a Telegram URL. The shoutrrr path uses the existing
          fleet-alerts engine once notificationEnvFile is set.
        '';
      };
      destinationFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Managed private JSON with email destination and the existing Amy agent-bus route; loaded as a systemd credential.";
      };
      paimosApiKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Dedicated PAI-1018 machine-notifier key bound to the declared chat target; null leaves chat unavailable while email can still deliver. General or personal PPM keys are not supported.";
      };
      notificationEnvFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Agenix env file containing WATCHTOWER_NOTIFICATION_URL in the same
          shoutrrr form as csb1-watchtower-env / hsb1-tailnet-watch-env. Null
          means no receiver is declared on this host.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          !(cfg.alert.enable && cfg.alert.transport == "email-agent-bus")
          || cfg.alert.destinationFile != null;
        message = "ibGatewaySession email-agent-bus requires managed destinations";
      }
      {
        assertion = stack.enable;
        message = "ibGatewaySession requires nixcfg.composeStack so recovery can use the managed compose lock";
      }
      {
        assertion = lib.hasAttr "ib-gateway" (stack.spec.services or { });
        message = "ibGatewaySession: spec has no ib-gateway service to supervise";
      }
    ];

    systemd.services.ib-gateway-session = {
      description = "Paper IB Gateway session-readiness supervisor (HOSTD-58)";
      after = [
        "docker.service"
        "compose-${stack.stackName}.service"
      ];
      wants = [ "docker.service" ];
      serviceConfig = {
        Type = "oneshot";
        LoadCredential = lib.optionals (cfg.alert.enable && cfg.alert.transport == "email-agent-bus") (
          [ "destinations.json:${toString cfg.alert.destinationFile}" ]
          ++ lib.optional (
            cfg.alert.paimosApiKeyFile != null
          ) "ppm-api-key:${toString cfg.alert.paimosApiKeyFile}"
        );
        ExecStart = "${pkgs.python3}/bin/python3 ${supervisor}/supervisor.py";
        StateDirectory = "ib-gateway-session";
        StateDirectoryMode = "0700";
        SuccessExitStatus = [
          0
          1
        ];
        TimeoutStartSec = "90";
      };
      environment = {
        IBGSS_STATE_PATH = "/var/lib/ib-gateway-session/supervisor.json";
        IBGSS_ALERT_STATE_PATH = "/var/lib/ib-gateway-session/alerts.json";
        IBGSS_OPERATOR_CLEAR_PATH = "/var/lib/ib-gateway-session/operator-clear";
        IBGSS_COMPOSE_LOCK = "/run/lock/compose-${stack.stackName}.lock";
        IBGSS_COMPOSE_FILE = "${stack.renderedFile}";
        IBGSS_COMPOSE_PROJECT = stack.project;
        IBGSS_COMPOSE_PROJECT_DIR = lib.optionalString (
          stack.projectDirectory != null
        ) stack.projectDirectory;
        IBGSS_COMPOSE_BIN = "${pkgs.docker-compose}/bin/docker-compose";
        IBGSS_FLOCK_BIN = "${pkgs.util-linux}/bin/flock";
        IBGSS_DOCKER_BIN = "${config.virtualisation.docker.package}/bin/docker";
        IBGSS_STARTUP_GRACE_SEC = "720";
        IBGSS_AUTH_TIMEOUT_SEC = "900";
        IBGSS_STALE_GENERATED_AT_SEC = "600";
        IBGSS_MAX_RESTARTS_PER_OUTAGE = "1";
        IBGSS_ALERT_ENABLE = if cfg.alert.enable then "1" else "0";
        IBGSS_ALERT_TRANSPORT = cfg.alert.transport;
        IBGSS_NOTIFICATION_ENV = lib.optionalString (cfg.alert.notificationEnvFile != null) (
          toString cfg.alert.notificationEnvFile
        );
        IBGSS_ALERT_BLOCKER = blocker;
      };
      path = [
        config.virtualisation.docker.package
        pkgs.docker-compose
        pkgs.util-linux
        pkgs.coreutils
      ];
    };

    systemd.timers.ib-gateway-session = {
      description = "Recurring paper IB Gateway session-readiness check (HOSTD-58)";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "5m";
        Persistent = true;
        Unit = "ib-gateway-session.service";
      };
    };
  };
}
