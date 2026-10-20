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
# Guests reach only the wallbox cloud (an IP allowlist, below), NTP (whatever server they
# ask, the request goes to Google's time1, so port 123 cannot carry a tunnel), and DNS and
# ICMP on hsb0. Everything else they send is dropped: the home LAN, the tailnet,
# hsb0's other services and the rest of the internet. So phones on the guest Wi-Fi get
# nothing, not even with their own DNS or a VPN. raw PREROUTING runs before the filter
# chains that Tailscale and Docker re-order, so their restarts cannot reopen it.
#
# The 7530's own traffic (AVM updates, MyFRITZ, its clock) is not limited: it may reach any
# public address. It shares the transit address with the guests (the 7530 NATs them), so it
# is told apart by TTL. The 7530 sends with TTL 64 and decrements forwarded guest packets,
# which arrive one below their sender's initial TTL: 63, 127 or 254 (measured 2026-10-20:
# AVM 64, guests 63 and 254). Only a guest deliberately sending with TTL 65 arrives with 64.
# Guest DNS does not pass the 7530 this way: its forwarder asks AdGuard from its LAN side.
# No public address leads back home: hsb0 has only private addresses (its Docker DNAT
# matches only those), and the Omada sits behind Starlink CGNAT (no inbound path; probed
# from hsb0 on 2026-10-20).
#
# There is no MAC filter, because none is possible: FRITZ!OS does not apply its MAC filter
# to guest access (AVM KB 250), and hsb0 never sees the guests' MACs behind the 7530's NAT.
# The wallboxes' SSID and password cannot change (Markus, 2026-10-20), so this lock stays.
{ lib, ... }:
let
  lanIf = "enp2s0f0";
  uplinkIf = "fritzwan0";
  hsb0Addr = "10.255.5.1";
  transitNet = "10.255.5.0/30";
  chain = "fritz-guest-uplink";
  # RETURNs for every non-public destination, then ACCEPT: "the public internet only".
  publicChain = "fritz-guest-public";
  nonPublic = [
    "0.0.0.0/8"
    "10.0.0.0/8" # includes the transit and hsb0's 10.255.5.1
    "100.64.0.0/10" # tailnet and Starlink CGNAT
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.168.0.0/16" # home LAN
    "224.0.0.0/3" # multicast, reserved, broadcast
  ];
  # NTP: the wallbox asks pool.ntp.org and ts1.univie.ac.at. Every NTP request from the
  # transit is redirected to time1.google.com (fixed anycast address), so the clock is right
  # and no other server can be reached on port 123. A mangle FORWARD guard (after DNAT)
  # drops any transit udp/123 not going to that address: it covers the reload window before
  # the DNAT is back and conntrack entries made in it, and it is never removed (fail-closed).
  ntpServer = "216.239.35.0";
  # The only place the guest network may reach besides NTP (Markus: only the two wallboxes
  # online). Resolved 2026-10-20: cert.prod.devices.elli.eco -> 34.22.219.237 (single A,
  # Google Cloud). A wallbox endpoint missing here shows up as "fritz-guest-drop" with a TTL
  # other than 64 in the kernel log (journalctl -k). Guest DNS reaches AdGuard as client 192.168.1.5 (the
  # 7530's LAN side), not from the transit. Add the address here.
  wallboxCloud = [ "34.22.219.237" ];
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

  # ARP flux: enp2s0f0 and fritzwan0 share one wire, and by default Linux answers ARP for any
  # local address on any interface. enp2s0f0 then also answers the 7530's "who has
  # 10.255.5.1", the 7530 caches enp2s0f0's MAC, and from then on ignores fritzwan0's ARP
  # requests for 10.255.5.2, so nothing reaches the 7530 any more (seen 2026-10-20 21:15:
  # INCOMPLETE on fritzwan0, Elli replies answered with ICMP unreachable). arp_ignore=1 answers
  # only for addresses on the receiving interface; arp_announce=2 uses the outgoing
  # interface's own address in ARP requests. Also keeps fritzwan0 from answering for
  # 192.168.1.99 on the home LAN. "all", because fritzwan0's per-interface keys do not
  # exist yet when systemd-sysctl runs at boot.
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.arp_ignore" = 1;
    "net.ipv4.conf.all.arp_announce" = 2;
  };

  networking.nat = {
    enable = true;
    internalIPs = [ transitNet ];
    externalInterface = lanIf;
    # Runs after the raw chain below has let the request through (raw comes before nat).
    extraCommands = ''
      iptables -t nat -A nixos-nat-pre -s ${transitNet} -p udp --dport 123 -j DNAT --to-destination ${ntpServer}
    '';
  };

  # Fail closed. raw PREROUTING holds two transit rules: the jump into the chain at the top,
  # and a backstop DROP at the end. The chain ACCEPTs what may pass. Anything else, including
  # every packet while the chain is being flushed and refilled on a firewall reload, falls
  # through to the backstop. Stopping or failing the firewall removes only the jump and keeps
  # the backstop, so the transit closes instead of opening. An older generation without this
  # module never removes the backstop either. (Rollback: unplug the 7530's LAN 1 first.)
  # The public chain is flushed only after the main chain, and filled RETURNs first, so a
  # half-built state never ACCEPTs a private destination.
  # `! -i lo`: hsb0's own traffic from 10.255.5.1 to itself must not hit any of this.
  networking.firewall = {
    extraCommands = ''
      iptables -t raw -C PREROUTING ! -i lo -s ${transitNet} -j DROP 2>/dev/null || \
        iptables -t raw -A PREROUTING ! -i lo -s ${transitNet} -j DROP
      iptables -t mangle -C FORWARD -s ${transitNet} -p udp --dport 123 ! -d ${ntpServer} -j DROP 2>/dev/null || \
        iptables -t mangle -I FORWARD -s ${transitNet} -p udp --dport 123 ! -d ${ntpServer} -j DROP
      iptables -t raw -N ${chain} 2>/dev/null || true
      iptables -t raw -N ${publicChain} 2>/dev/null || true
      iptables -t raw -F ${chain}
      iptables -t raw -F ${publicChain}
      ${lib.concatMapStringsSep "\n" (
        net: "iptables -t raw -A ${publicChain} -d ${net} -j RETURN"
      ) nonPublic}
      iptables -t raw -A ${publicChain} -j ACCEPT
      iptables -t raw -A ${chain} -d ${hsb0Addr} -p udp --dport 53 -j ACCEPT
      iptables -t raw -A ${chain} -d ${hsb0Addr} -p tcp --dport 53 -j ACCEPT
      iptables -t raw -A ${chain} -d ${hsb0Addr} -p icmp -j ACCEPT
      iptables -t raw -A ${chain} -m ttl --ttl-eq 64 -j ${publicChain}
      ${lib.concatMapStringsSep "\n" (
        ip: "iptables -t raw -A ${chain} -d ${ip} -p tcp -j ACCEPT"
      ) wallboxCloud}
      iptables -t raw -A ${chain} -p udp --dport 123 -j ${publicChain}
      iptables -t raw -A ${chain} -m limit --limit 6/min --limit-burst 10 -j LOG --log-prefix "fritz-guest-drop "
      iptables -t raw -A ${chain} -j DROP
      iptables -t raw -C PREROUTING ! -i lo -s ${transitNet} -j ${chain} 2>/dev/null || \
        iptables -t raw -I PREROUTING ! -i lo -s ${transitNet} -j ${chain}
    '';
    extraStopCommands = ''
      iptables -t raw -C PREROUTING ! -i lo -s ${transitNet} -j DROP 2>/dev/null || \
        iptables -t raw -A PREROUTING ! -i lo -s ${transitNet} -j DROP
      iptables -t raw -D PREROUTING ! -i lo -s ${transitNet} -j ${chain} 2>/dev/null || true
      iptables -t raw -F ${chain} 2>/dev/null || true
      iptables -t raw -X ${chain} 2>/dev/null || true
      iptables -t raw -F ${publicChain} 2>/dev/null || true
      iptables -t raw -X ${publicChain} 2>/dev/null || true
    '';
  };
}
