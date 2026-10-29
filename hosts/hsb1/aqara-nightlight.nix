# OPS-496: local light + built-in sounds for the two LAN Aqara gateways.
{ pkgs, ... }:
let
  # zoneinfo must have Vienna's DST rules even in the hardened service root.
  pythonEnv = pkgs.python3.withPackages (ps: [
    ps.python-miio
    ps.tzdata
  ]);
in
{
  systemd.services.aqara-nightlight = {
    description = "Aqara nightlight and quiet built-in sounds (OPS-496)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    wants = [
      "network-online.target"
      "tailscaled.service"
    ];
    # IP_FREEBIND keeps LAN/loopback available even before tailnet is assigned.
    startLimitIntervalSec = 0;
    environment = {
      PYTHONUNBUFFERED = "1";
      AQARA_LISTEN_ADDRESSES = "127.0.0.1,192.168.1.101,100.64.0.7";
      AQARA_PORT = "8765";
      AQARA_PAGE_FILE = "${./aqara-nightlight-page.html}";
    };
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pythonEnv}/bin/python3 ${./aqara-nightlight.py}";
      Restart = "on-failure";
      RestartSec = 5;
      TimeoutStopSec = 10;
      DynamicUser = true;
      StateDirectory = "aqara-nightlight";
      StateDirectoryMode = "0700";
      UMask = "0077";
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      NoNewPrivileges = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      SystemCallArchitectures = "native";
      # hsb1's firewall is disabled for HomeKit. This applies to ingress AND
      # egress; keep both UDP/54321 peers explicitly allowed. The HTTP handler
      # also checks peer addresses, including when cgroup BPF is unavailable.
      IPAddressDeny = "any";
      IPAddressAllow = [
        "127.0.0.0/8"
        "::1/128"
        "192.168.1.0/24"
        "100.64.0.0/10"
        "192.168.1.106/32"
        "192.168.1.108/32"
      ];
    };
  };
}
