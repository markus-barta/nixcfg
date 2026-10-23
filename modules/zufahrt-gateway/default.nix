# HAUSV-916: Zufahrt (access gate) gateway for Howie, on hsb1.
# POST /zufahrt and POST /zufahrt5 only, a bearer token whose sha256 is the only
# copy on this host, 1 accepted call per 60 s, a call log, and the existing
# Node-RED chain (local broker topic scom/jhw22/smarthome) doing the switching.
# Reach: the Headscale ACL admits only tag:paper-desk to this port; the service
# accepts tailnet and loopback sources only (hsb1's host firewall is off for
# HomeKit, so the filter is per service). See gateway.py for the request guards.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.nixcfg.zufahrtGateway;
in
{
  options.nixcfg.zufahrtGateway = {
    enable = lib.mkEnableOption "the HAUSV-916 Zufahrt gateway (/zufahrt and /zufahrt5 only)";

    listenAddress = lib.mkOption {
      type = lib.types.str;
      example = "100.64.0.7";
      description = "Tailnet address to bind (IP_FREEBIND, so tailscaled may come up later).";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8475;
      description = "TCP port; the Headscale ACL must admit exactly this port.";
    };

    tokenHashFile = lib.mkOption {
      type = lib.types.path;
      description = "File holding the sha256 (64 lowercase hex) of the bearer token. Never the token.";
    };

    mqttEnvFile = lib.mkOption {
      type = lib.types.path;
      description = "Env file with MQTT_USER and MQTT_PASS for the local broker.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.zufahrt-gateway = {
      description = "HAUSV-916 Zufahrt gateway for Howie (/zufahrt, /zufahrt5)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "docker.service"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = lib.escapeShellArgs [
          "${pkgs.python3}/bin/python3"
          "-I"
          "${./gateway.py}"
          "--listen"
          cfg.listenAddress
          "--port"
          (toString cfg.port)
          "--state-dir"
          "/var/lib/zufahrt-gateway"
          "--mqtt-host"
          "127.0.0.1"
          "--mqtt-port"
          "1883"
        ];
        DynamicUser = true;
        StateDirectory = "zufahrt-gateway";
        StateDirectoryMode = "0700";
        LoadCredential = [
          "token-sha256:${cfg.tokenHashFile}"
          "mqtt-env:${cfg.mqttEnvFile}"
        ];
        Restart = "on-failure";
        RestartSec = "5s";
        # Tailnet (Howie) and loopback (the local broker) only. Accepted exceptions (gate r1):
        # markus@/gerhard@ have full tailnet reach and local root can publish to the broker
        # directly, so neither gains anything here; the Headscale ACL is what admits
        # tag:paper-desk and no other non-admin identity. Without eBPF support this filter
        # is a no-op, and the bind address, the ACL and the token still hold.
        IPAddressDeny = "any";
        IPAddressAllow = [
          "100.64.0.0/10"
          "fd7a:115c:a1e0::/48"
          "127.0.0.0/8"
          "::1/128"
        ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        UMask = "0077";
      };
    };
  };
}
