# gpc0 Wake-on-LAN Configuration

## Description

Enable Wake-on-LAN on gpc0 (Gaming PC) so it can be remotely powered on via magic packets.

## Background

- WOL worked when gpc0 ran Windows 10 (~8 months ago)
- BIOS/hardware supports WOL
- NixOS needs NIC configuration to enable WOL receiving

## MAC Address

```
4C:CC:6A:B2:3E:38
```

## Implementation

Add to `hosts/gpc0/configuration.nix`:

```nix
# Option 1: systemd-networkd (recommended)
systemd.network = {
  enable = true;
  networks."40-enp9s0" = {
    matchConfig.Name = "enp9s0";
    networkConfig.DHCP = "yes";
    linkConfig.WakeOnLan = "magic";
  };
};
networking.useDHCP = false;

# Option 2: ethtool service (if keeping traditional networking)
systemd.services.wol-enable = {
  description = "Enable Wake-on-LAN";
  after = [ "network.target" ];
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "${pkgs.ethtool}/bin/ethtool -s enp9s0 wol g";
  };
};
environment.systemPackages = [ pkgs.ethtool ];
```

## Testing

From imac0 or any host with `wakeonlan`:

```bash
wakeonlan 4C:CC:6A:B2:3E:38
# Or specify broadcast address if needed
wakeonlan -i 192.168.1.255 4C:CC:6A:B2:3E:38
```

## Acceptance Criteria

- [ ] WOL config added to gpc0/configuration.nix
- [ ] Rebuild applied (requires physical access first time)
- [ ] Test WOL from imac0
- [ ] Verify gpc0 wakes from power-off state

## Priority

Low — convenience feature, gpc0 is not critical infrastructure.

## Notes

- Requires physical access to apply the first time
- After first rebuild, can wake remotely for future updates
