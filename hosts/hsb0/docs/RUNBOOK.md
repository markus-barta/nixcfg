# Runbook: hsb0 (DNS/DHCP Server)

**Host**: hsb0 (192.168.1.99)  
**Role**: Primary DNS and DHCP server running AdGuard Home  
**Criticality**: HIGH - Network infrastructure depends on this

---

## Quick Connect

```bash
ssh mba@192.168.1.99
# or
ssh mba@hsb0.lan
```

---

## Common Tasks

### Update & Switch Configuration

```bash
ssh mba@192.168.1.99
cd ~/Code/nixcfg
git pull
just switch
```

### Fix Git Issues & Update

If git has merge conflicts or local changes blocking pull:

```bash
ssh mba@192.168.1.99
cd ~/Code/nixcfg
git status                           # Check what's wrong
git checkout -- .                    # Discard all local changes
# OR for specific file:
git checkout -- path/to/file
git pull
just switch
```

### Rollback to Previous Generation

```bash
ssh mba@192.168.1.99
sudo nixos-rebuild switch --rollback
```

---

## Health Checks

### Quick Status

```bash
ssh mba@192.168.1.99 "systemctl status adguardhome && zpool status | head -10"
```

### DNS Check

```bash
# From any machine on the network
dig @192.168.1.99 google.com
```

### DHCP Leases

```bash
ssh mba@192.168.1.99 "sudo cat /var/lib/private/AdGuardHome/data/leases.json | jq"
```

### ZFS Pool Status

```bash
ssh mba@192.168.1.99 "zpool status"
```

---

## AdGuard Home DNS Management

### Web Interface

Access at: http://192.168.1.99:3000

### View Query Logs

Query logs are stored at `/var/lib/private/AdGuardHome/data/querylog.json`

```bash
# Find all domains a device requested (replace IP with target device)
ssh mba@192.168.1.99 "sudo grep '192.168.1.235' /var/lib/private/AdGuardHome/data/querylog.json | jq -r '.QH' | sort -u"

# Recent queries from a device
ssh mba@192.168.1.99 "sudo grep '192.168.1.235' /var/lib/private/AdGuardHome/data/querylog.json | tail -20 | jq '{time: .T, domain: .QH, result: .Result.Reason}'"

# Find blocked queries for a device
ssh mba@192.168.1.99 "sudo grep '192.168.1.235' /var/lib/private/AdGuardHome/data/querylog.json | jq 'select(.Result.IsFiltered == true) | .QH' | sort -u"
```

### Add Domains to Allowlist (Whitelist)

Allowlist rules bypass ad-blocking for specific domains. Managed declaratively in NixOS config.

**1. Find domains to whitelist:**

```bash
# Get all unique domains a device is trying to access
ssh mba@192.168.1.99 "sudo grep 'DEVICE_IP' /var/lib/private/AdGuardHome/data/querylog.json | jq -r '.QH' | sort -u"
```

**2. Add to configuration:**

Edit `hosts/hsb0/configuration.nix` and add to `services.adguardhome.settings.user_rules`:

```nix
user_rules = [
  # Existing rules...
  # Device Name (IP / hostname)
  "@@||domain.example.com^"  # Purpose of this domain
];
```

For hsb8 (ww87), add to the `dnsAllowlist` variable at the top of `hosts/hsb8/configuration.nix`.

**Format:** `@@||domain^`

- `@@` = allowlist rule (exception)
- `||` = match domain start
- `^` = domain separator/end

**3. Deploy:**

```bash
# For hsb0
ssh mba@192.168.1.99 "cd ~/Code/nixcfg && git pull && just switch"

# For hsb8 (from any machine)
nixos-rebuild switch --flake .#hsb8 --target-host hsb8 --use-remote-sudo
```

### Query Log Field Reference

| Field                | Description                                          |
| -------------------- | ---------------------------------------------------- |
| `.T`                 | Timestamp                                            |
| `.QH`                | Queried hostname (domain)                            |
| `.IP`                | Client IP address                                    |
| `.Result.Reason`     | Why processed (Filtered, NotFilteredAllowList, etc.) |
| `.Result.IsFiltered` | true if blocked                                      |
| `.Elapsed`           | Response time in nanoseconds                         |

---

## Troubleshooting

### AdGuard Home Not Responding

```bash
ssh mba@192.168.1.99
systemctl status adguardhome
journalctl -u adguardhome -n 50 --no-pager
sudo systemctl restart adguardhome
```

### DNS Not Resolving

1. Check if AdGuard Home is running
2. Check upstream DNS: `dig @1.1.1.1 google.com`
3. Check AdGuard config: `sudo cat /var/lib/AdGuardHome/AdGuardHome.yaml`

### DHCP Not Assigning IPs

1. Check AdGuard Home status
2. Verify DHCP is enabled in config
3. Check static leases file: `/run/agenix/static-leases-hsb0`

---

## Emergency Recovery

### If SSH Fails

1. Physical access to Mac mini required
2. Connect keyboard and monitor
3. Login as `mba` or `root`

### Network Fallback

If hsb0 is completely down:

- Devices will use fallback DNS (1.1.1.1) if configured
- Static IPs continue working
- DHCP renewals will fail (24-hour lease)

### Restore from Generation

```bash
# List available generations
sudo nix-env --list-generations -p /nix/var/nix/profiles/system

# Switch to specific generation
sudo nix-env --switch-generation N -p /nix/var/nix/profiles/system
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

### Restore from Backup

**Restore static leases from git history:**

```bash
# Find the commit with the desired version
git log secrets/static-leases-hsb0.age

# Extract the file from a specific commit
git show COMMIT:secrets/static-leases-hsb0.age > secrets/static-leases-hsb0.age

# Verify and redeploy
agenix -d secrets/static-leases-hsb0.age | jq empty
just switch
```

**Restore from ZFS snapshot:**

```bash
# List available snapshots
zfs list -t snapshot | grep zroot

# Rollback to a snapshot (destroys newer data!)
sudo zfs rollback zroot/root@SNAPSHOT_NAME
```

**Emergency: Recover from Time Machine (on Mac):**

1. Navigate to `~/Code/nixcfg` in Time Machine
2. Restore desired files
3. Commit and push: `git add . && git commit -m "restore: from Time Machine backup"`
4. Deploy to hsb0: `ssh mba@hsb0 "cd ~/Code/nixcfg && git pull && just switch"`

---

## Backup

### Backup Frequency

| Backup Type        | Frequency                 | Location               |
| ------------------ | ------------------------- | ---------------------- |
| Git repository     | On each commit/push       | GitHub (remote origin) |
| ZFS auto-snapshots | Hourly/Daily (if enabled) | Local zroot pool       |
| Time Machine       | Automatic (on Mac)        | External drive / NAS   |

**Last Verified:** TODO - Set date after verification

**Note:** Check if ZFS auto-snapshots are enabled in configuration:

```bash
ssh mba@hsb0 "grep -A5 'autoSnapshot' ~/Code/nixcfg/hosts/hsb0/configuration.nix"
```

---

## Maintenance

### Clean Up Disk Space

```bash
ssh mba@192.168.1.99 "cd ~/Code/nixcfg && just cleanup"
```

### ZFS Scrub (Manual)

```bash
ssh mba@192.168.1.99 "sudo zpool scrub zroot"
```

### View Logs

```bash
# Current boot
ssh mba@192.168.1.99 "journalctl -b -e"

# Previous boot
ssh mba@192.168.1.99 "journalctl -b-1"

# Follow logs
ssh mba@192.168.1.99 "journalctl -f"
```

---

## Related Documentation

- [hsb0 README](../README.md) - Full server documentation
- [Static Leases](../README.md#static-dhcp-leases) - Managing DHCP leases
