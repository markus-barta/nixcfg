# OPS-207: applied to the complete hsb0 config in CI, including upstream defaults.
{ config, lib }:
let
  cfg = config.services.hausnetz;
  fw = config.networking.firewall;
  unit = config.systemd.services.hausnetz.serviceConfig;
  has = builtins.elem;
  ifaceTcp = name: fw.interfaces.${name}.allowedTCPPorts or [ ];
  ifaceUdp = name: fw.interfaces.${name}.allowedUDPPorts or [ ];
  allInterfaces = builtins.attrNames fw.interfaces;
  inRange = port: ranges: builtins.any (r: r.from <= port && port <= r.to) ranges;
in
{
  enabled = cfg.enable;
  listen = cfg.listen == "0.0.0.0:8377";
  firewallEnabled = fw.enable;
  lanNotTrusted = !(has "enp2s0f0" fw.trustedInterfaces);
  iptablesBridgeGlob = !config.networking.nftables.enable;
  noGlobalTcpPort = !(has 8377 fw.allowedTCPPorts);
  noGlobalTcpRange = !(inRange 8377 fw.allowedTCPPortRanges);
  bridgeOnly =
    cfg.firewallInterfaces == [
      "br-+"
      "docker0"
    ];
  bridgeReachable = has 8377 (ifaceTcp "br-+") && has 8377 (ifaceTcp "docker0");
  noOtherInterfaceTcp = builtins.all (
    name:
    has name [
      "br-+"
      "docker0"
    ]
    || (
      !(has 8377 (ifaceTcp name)) && !(inRange 8377 (fw.interfaces.${name}.allowedTCPPortRanges or [ ]))
    )
  ) allInterfaces;
  noSeed = cfg.seed == null;
  # HNET-228 (approved 2026-10-17, see the ticket): leases come from AdGuard's DHCP file through the
  # root copy unit; hausnetz itself reads only the copy via its supplementary group.
  leasesFromAdguard = toString cfg.discovery.leasesFile == "/var/lib/AdGuardHome/data/leases.json";
  leasesCopyGroupOnly = (unit.SupplementaryGroups or [ ]) == [ "hausnetz-leases" ];
  noExtraArguments = cfg.extraArgs == [ ];
  noLeasesBind = (unit.BindReadOnlyPaths or [ ]) == [ ];
  durableEmptyState = unit.StateDirectory == "hausnetz";
  mdnsEnabled = cfg.discovery.openFirewallMdns;
  mdnsLanOnly = cfg.discovery.mdnsInterfaces == [ "enp2s0f0" ];
  mdnsReachable = has 5353 (ifaceUdp "enp2s0f0");
  noGlobalMdns = !(has 5353 fw.allowedUDPPorts) && !(inRange 5353 fw.allowedUDPPortRanges);
  noOtherInterfaceMdns = builtins.all (
    name:
    name == "enp2s0f0"
    || (
      !(has 5353 (ifaceUdp name)) && !(inRange 5353 (fw.interfaces.${name}.allowedUDPPortRanges or [ ]))
    )
  ) allInterfaces;
  ssdpEnabled = cfg.discovery.openFirewallSsdp;
  ssdpPort = cfg.discovery.ssdpPort == 1901;
  ssdpLanOnly = cfg.discovery.ssdpInterfaces == [ "enp2s0f0" ];
  ssdpReachable = has 1901 (ifaceUdp "enp2s0f0");
  noGlobalSsdp = !(has 1901 fw.allowedUDPPorts) && !(inRange 1901 fw.allowedUDPPortRanges);
  noOtherInterfaceSsdp = builtins.all (
    name:
    name == "enp2s0f0"
    || (
      !(has 1901 (ifaceUdp name)) && !(inRange 1901 (fw.interfaces.${name}.allowedUDPPortRanges or [ ]))
    )
  ) allInterfaces;
  ssdpArgument = lib.hasInfix "\"--ssdp-port\" \"1901\"" unit.ExecStart;
  netlinkAllowed = has "AF_NETLINK" unit.RestrictAddressFamilies;
  # OPS-355 2026-10-17: passive ARP/DHCP listener, LAN interface only.
  passiveEnabled = cfg.discovery.passive;
  passiveLanOnly = cfg.discovery.passiveInterfaces == [ "enp2s0f0" ];
  passiveArgument = lib.hasInfix "\"--passive\" \"--passive-interfaces\" \"enp2s0f0\"" unit.ExecStart;
  # OPS-355 pin 7 (LEAD): the web source stays hard off on hsb0 until the trial.
  # OPS-355 web-check trial: the host allows the source (still off per site setting).
  webCheckAllowed = cfg.discovery.webCheck;
  noWebCheckFlag = !(lib.hasInfix "\"--web-check=false\"" unit.ExecStart);
  packetAllowed = has "AF_PACKET" unit.RestrictAddressFamilies;
  memoryLimit = unit.MemoryMax == "512M";
  cpuLimit = unit.CPUQuota == "50%";
  nice = unit.Nice == 10;
  proxySource = lib.hasSuffix "/hosts/hsb0/docker/hsb0-home-hausnetz.conf" (
    toString config.environment.etc."hsb0-home-hausnetz.conf".source
  );
  proxyRestartTriggers =
    builtins.all
      (
        snippet:
        builtins.any (
          trigger: lib.hasSuffix ("/hosts/hsb0/docker/" + snippet) (toString trigger)
        ) config.nixcfg.composeStack.extraRestartTriggers
      )
      [
        "hsb0-home-hausnetz.conf"
        "hsb0-home-inflight.conf"
        "hsb0-home-videos.conf"
      ];
}
