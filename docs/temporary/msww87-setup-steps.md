# msww87 - Quick Setup Guide

**Goal**: Configure static IP 192.168.1.100 for msww87 Mac mini

**MAC Address**: `40:6c:8f:18:dd:24`  
**Current IP**: 192.168.1.223 (DHCP)  
**Target IP**: 192.168.1.100 (static)

---

## Step 1: Update NixOS Configuration

Edit: `hosts/msww87/configuration.nix`

Replace the current `networking = { ... }` section with:

```nix
networking = {
  # DNS and gateway configuration
  nameservers = [
    "192.168.1.99"  # miniserver99 / AdGuard Home
    "1.1.1.1"       # Cloudflare fallback
  ];
  search = [ "lan" ];
  defaultGateway = "192.168.1.5";

  # Static IP configuration
  # Note: Interface is enp2s0f0 (verified via ip addr)
  interfaces.enp2s0f0 = {
    ipv4.addresses = [
      {
        address = "192.168.1.100";
        prefixLength = 24;
      }
    ];
  };

  # SSH is already enabled by the server-common mixin
  firewall = {
    allowedTCPPorts = [
      80    # HTTP
      443   # HTTPS
      8883  # MQTT
    ];
    allowedUDPPorts = [
      443   # HTTPS
    ];
  };
};
```

---

## Step 2: Fix hardware-configuration.nix (Optional)

The comment in `hosts/msww87/hardware-configuration.nix` line 36 mentions:

```nix
# networking.interfaces.enp3s0f0.useDHCP = lib.mkDefault true;
```

This is **wrong** - the actual interface is `enp2s0f0`. Update the comment:

```nix
# networking.interfaces.enp2s0f0.useDHCP = lib.mkDefault true;
```

---

## Step 3: Add Static DHCP Lease on miniserver99

Edit the encrypted static leases file:

```bash
agenix -e secrets/static-leases-miniserver99.age
```

Add this entry to the JSON array:

```json
{
  "mac": "40:6c:8f:18:dd:24",
  "ip": "192.168.1.100",
  "hostname": "msww87"
}
```

**Note**: This MAC address was previously assigned to "miniserver" in the old Pi-hole config! This might be the same physical machine.

---

## Step 4: Deploy Changes

### On Your Mac (from nixcfg directory):

```bash
# Commit the configuration changes
git add hosts/msww87/configuration.nix
git add secrets/static-leases-miniserver99.age
git commit -m "feat: configure static IP 192.168.1.100 for msww87"

# Deploy to miniserver99 (for static lease)
ssh mba@192.168.1.99
cd ~/Code/nixcfg
git pull
just switch

# Deploy to msww87 (for static IP)
ssh mba@192.168.1.223
# If nixcfg is not cloned yet:
mkdir -p ~/Code
cd ~/Code
git clone <your-repo-url> nixcfg
cd nixcfg

# Or if already cloned:
cd ~/Code/nixcfg
git pull

# Apply the configuration
just switch
```

---

## Step 5: Verify

After reboot or network restart:

```bash
# Test new IP
ping 192.168.1.100

# SSH with new IP
ssh mba@192.168.1.100

# Check interface
ip addr show enp2s0f0

# Verify DNS resolution
dig msww87.lan
ping msww87.lan

# On miniserver99, verify static lease
ssh mba@192.168.1.99
sudo jq '.leases[] | select(.ip == "192.168.1.100")' \
  /var/lib/private/AdGuardHome/data/leases.json
```

Expected output:

```json
{
  "mac": "40:6c:8f:18:dd:24",
  "ip": "192.168.1.100",
  "hostname": "msww87",
  "static": true,
  "expires": ""
}
```

---

## Troubleshooting

### Testing Gerhard's SSH Access

After deploying the configuration:

```bash
# From Gerhard's Mac (imac-gb.local)
ssh gb@192.168.1.223  # current IP
# or
ssh gb@192.168.1.100  # after static IP
ssh gb@msww87.lan
```

Expected: Direct login without password prompt.

### Issue: Can't connect after applying config

**Solution**: The machine may need a reboot or the IP hasn't updated yet.

```bash
# Connect with old IP
ssh mba@192.168.1.223

# Check network status
ip addr show enp2s0f0
systemctl status NetworkManager

# Force network restart
sudo systemctl restart NetworkManager

# Or reboot
sudo reboot
```

### Issue: DNS not resolving

**Solution**: Check AdGuard Home on miniserver99

```bash
ssh mba@192.168.1.99
systemctl status adguardhome
journalctl -u adguardhome -n 50
```

### Issue: Static lease not appearing

**Solution**: Restart AdGuard Home after adding the lease

```bash
ssh mba@192.168.1.99
cd ~/Code/nixcfg
git pull
just switch  # This will reload static leases
```

---

## Quick Commands Reference

```bash
# Connect to msww87 (after setup)
ssh mba@192.168.1.100
ssh mba@msww87.lan

# Update system
cd ~/Code/nixcfg
git pull
just switch

# Check ZFS status
zpool status

# Check network
ip addr show enp2s0f0
ss -tlnp

# Check Docker
docker ps -a
systemctl status docker
```

---

## Notes

### Historical Context

The MAC address `40:6c:8f:18:dd:24` appears in the old Pi-hole configuration at miniserver24 as "miniserver" at 192.168.1.100. This suggests:

- **Possibility 1**: msww87 IS the old "miniserver" that was previously at .100
- **Possibility 2**: The machine was renamed/repurposed

Either way, this machine has a historical claim to the .100 IP address, which makes the assignment even more appropriate!

### Why Static IP?

For a home automation server, a static IP is essential because:

1. MQTT broker clients need a stable address
2. Node-RED flows may reference the IP directly
3. HomeKit devices require consistent connectivity
4. Monitoring systems need reliable endpoints
5. Docker containers may bind to specific IPs

---

## Related Files

- Configuration: `hosts/msww87/configuration.nix`
- Hardware: `hosts/msww87/hardware-configuration.nix`
- Static leases: `secrets/static-leases-miniserver99.age`
- Full notes: `docs/temporary/msww87-server-notes.md`
