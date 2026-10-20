# OPS-401: internet uplink for the FRITZ!Box 7530's guest network (the two neighbour
# wallboxes in the Tiefgarage).
#
# Since the Starlink/Omada migration the 7530 only does Wi-Fi/mesh. Its WAN port (LAN 1)
# had no uplink, so the guest network it carries (JHW2211-Gast, broadcast by the garage
# repeater; guests get 192.168.189.x from the 7530) had no internet. IP-client mode is
# not an option: AVM turns guest access off there (KB 3244). So the 7530 stays a router
# and gets a /30 transit link to hsb0, which NATs it out through the Omada:
#
#   7530 LAN 1 (WAN, static 10.255.5.2/30, gateway + DNS 10.255.5.1)
#     -- GS724T -- hsb0 fritzwan0 (macvlan on enp2s0f0) -- NAT -- 192.168.1.1
#
# A macvlan, not a second address on enp2s0f0: adding an address there changes
# enp2s0f0's address unit, which a switch restarts (DNS/DHCP blip for the whole house).
# And AdGuard's DHCP would hand the extra address to every client as a second DNS server.
#
# Guests reach the internet only. The raw-table chain below drops anything from the
# transit to private, CGNAT/tailnet, link-local and multicast ranges, and to hsb0
# itself except DNS and ICMP. raw PREROUTING runs before the filter chains that
# Tailscale and Docker re-order, so their restarts cannot reopen it. AdGuard answers
# the transit only for the allowlisted wallbox, NTP and AVM names
# (guestUplinkDnsRules in configuration.nix), so phones on the guest Wi-Fi get no
# usable internet.
{ lib, ... }:
let
  lanIf = "enp2s0f0";
  uplinkIf = "fritzwan0";
  hsb0Addr = "10.255.5.1";
  # Must match guestUplinkDnsRules ($client=10.255.5.0/30) in configuration.nix.
  transitNet = "10.255.5.0/30";
  chain = "fritz-guest-uplink";
  blockedDestinations = [
    "0.0.0.0/8"
    "10.0.0.0/8" # includes the transit itself; DNS + ICMP to hsb0 return above
    "100.64.0.0/10" # CGNAT + tailnet
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12" # Docker networks
    "192.168.0.0/16" # home LAN + guest LAN
    "224.0.0.0/4"
    "240.0.0.0/4"
  ];
in
{
  networking.macvlans.${uplinkIf} = {
    interface = lanIf;
    mode = "bridge";
  };
  networking.interfaces.${uplinkIf}.ipv4.addresses = [
    {
      address = hsb0Addr;
      prefixLength = 30;
    }
  ];

  networking.nat = {
    enable = true;
    internalIPs = [ transitNet ];
    externalInterface = lanIf;
  };

  networking.firewall = {
    # `! -i lo`: hsb0's own traffic from 10.255.5.1 to itself must not hit the drops.
    extraCommands = ''
      iptables -t raw -N ${chain} 2>/dev/null || true
      iptables -t raw -F ${chain}
      iptables -t raw -A ${chain} -d ${hsb0Addr} -p udp --dport 53 -j RETURN
      iptables -t raw -A ${chain} -d ${hsb0Addr} -p tcp --dport 53 -j RETURN
      iptables -t raw -A ${chain} -d ${hsb0Addr} -p icmp -j RETURN
      ${lib.concatMapStringsSep "\n" (
        net: "iptables -t raw -A ${chain} -d ${net} -j DROP"
      ) blockedDestinations}
      iptables -t raw -A ${chain} -j RETURN
      iptables -t raw -C PREROUTING ! -i lo -s ${transitNet} -j ${chain} 2>/dev/null || \
        iptables -t raw -I PREROUTING ! -i lo -s ${transitNet} -j ${chain}
    '';
    extraStopCommands = ''
      iptables -t raw -D PREROUTING ! -i lo -s ${transitNet} -j ${chain} 2>/dev/null || true
      iptables -t raw -F ${chain} 2>/dev/null || true
      iptables -t raw -X ${chain} 2>/dev/null || true
    '';
  };
}
