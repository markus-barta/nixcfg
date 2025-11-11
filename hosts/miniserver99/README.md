# miniserver99 - DNS/DHCP Server

## Purpose

Primary DNS and DHCP server running **AdGuard Home** as a native NixOS service.

## Network Configuration

- **IP Address**: `192.168.1.99/24`
- **Gateway**: `192.168.1.5`
- **DNS**: Uses localhost (127.0.0.1) - AdGuard Home provides DNS
- **DHCP Range**: `192.168.1.201` - `192.168.1.254`
- **Web Interface**: <http://192.168.1.99:3000>

## Firewall Ports

- **TCP 53**: DNS queries
- **UDP 53**: DNS queries
- **UDP 67**: DHCP server
- **TCP 3000**: AdGuard Home web interface
- **TCP 80/443**: Reserved for future use
- **TCP 22**: SSH (enabled by `server-home` role)

## System Details

- **ZFS hostId**: `dabfdb02`
- **User**: `mba` (Markus Barta)
- **Role**: `server-home` (via `serverMba.enable`)

## Enabled Services

This system provides the following services via the `serverMba` module and `server-home` role:

### Core Services

- **AdGuard Home**: DNS filtering, ad-blocking, and DHCP server
  - Declarative configuration via NixOS module
  - Systemd service management
  - Web interface on port 3000
- **SSH**: Key-based authentication with authorized keys
- **Docker**: Container runtime available for additional services
- **ZFS**: Automatic scrubbing and snapshot management via Sanoid
- **Fail2ban**: Intrusion prevention system
- **Firewall**: iptables/nftables-based packet filtering

### AdGuard Home Features

#### DNS Management

- Ad-blocking and tracker blocking
- Custom DNS filtering rules
- DNS-over-HTTPS (DoH) and DNS-over-TLS (DoT) support
- Configurable upstream DNS servers
- DNS query logging and statistics
- Custom DNS rewrites

#### DHCP Management

- DHCP server with configurable IP ranges
- Static DHCP lease assignment
- Custom DHCP options
- Integration with DNS resolution

#### Administration

- Web-based administration interface
- Query log with search and filtering
- Real-time statistics dashboard
- Configurable filter lists and custom rules
- Client identification and per-client settings

## Deployment Steps

### Important: DHCP & Static Lease Management

- ✅ DHCP is **enabled** by default. Ensure **all other DHCP servers** (e.g. miniserver24/Pi-hole) are stopped before rebuilding or booting this host.
- ✅ Static leases live in the gitignored file `hosts/miniserver99/static-leases.nix`.  
  Include them on every rebuild by overriding the flake input:

  ```bash
  sudo nixos-rebuild switch \
    --flake .#miniserver99 \
    --override-input miniserver99-static-leases \
    path:/home/mba/Code/nixcfg/hosts/miniserver99/static-leases.nix
  ```

- The build injects all declarative leases into `/var/lib/private/AdGuardHome/data/leases.json`; any leases created via the UI are removed on the next rebuild.
- Detailed installation and cutover steps live in [`hosts/miniserver99/installation.md`](./installation.md).

### 1. Initial Installation

**Recommended: Install from miniserver24** (can run overnight, native NixOS builds)

```bash
# On miniserver24
ssh mba@192.168.1.101
cd ~/Code/nixcfg

# Deploy with nixos-anywhere (see ./installation.md for details)
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver99 \
  root@<MAC_MINI_IP>
```

Alternative: Traditional installation on target machine after minimal NixOS:

```bash
# 1. Generate hardware configuration
sudo nixos-generate-config --root /mnt

# 2. Copy hardware-configuration.nix to this directory
# 3. Verify network interface name (currently enp2s0f0)
# 4. Deploy
sudo nixos-rebuild switch --flake .#miniserver99
```

### 2. AdGuard Home Initial Setup

After deployment, AdGuard Home starts automatically as a systemd service.

#### Service Management

```bash
# Check service status
systemctl status adguardhome

# View real-time logs
journalctl -u adguardhome -f

# Restart service if needed
sudo systemctl restart adguardhome
```

#### Initial Web Interface Setup

1. Navigate to <http://192.168.1.99:3000>
2. Complete the setup wizard to create an administrator account
3. Configure basic settings (timezone, language, etc.)

### 3. Post-Deployment Configuration

#### DNS Configuration

1. Access the web interface at <http://192.168.1.99:3000>
2. Navigate to **Filters → DNS blocklists**
3. Add recommended filter lists:
   - AdGuard DNS filter
   - AdAway Default Blocklist
   - Steven Black's Unified Hosts
   - HaGeZi's Pro Blocklist
4. Enable **Safe Browsing** and **Parental Control** if desired

#### DHCP Configuration

- DHCP range: 192.168.1.201-254 (configurable in `configuration.nix`)
- Static DHCP leases are **fully declarative** and synced automatically from `static-leases.nix`
  - No manual configuration in the UI required
  - Verify in the web interface: Settings → DHCP settings → Static leases
  - Any changes made via the UI are discarded on the next rebuild

#### Testing

```bash
# Test DNS resolution from this server
dig @localhost google.com

# Test DNS resolution from network client
dig @192.168.1.99 google.com

# Check DHCP leases
cat /var/lib/AdGuardHome/leases.db
```

### 4. Network Infrastructure Integration

#### Router Configuration

1. Configure router to advertise 192.168.1.99 as primary DNS server
2. Disable router's built-in DNS caching if applicable
3. Alternatively, let AdGuard Home's DHCP server handle DNS advertisement

#### Client Testing

1. Renew DHCP lease on a test client: `dhclient -r && dhclient`
2. Verify DNS server: `cat /etc/resolv.conf` (should show 192.168.1.99)
3. Test ad-blocking: Visit a site with known ads
4. Check query logs in AdGuard Home web interface

## Important Notes

### Network Interface

The configuration uses `enp2s0f0` as the network interface. Verify this matches your hardware:

```bash
ip link show
```

If different, update the interface name in `configuration.nix`.

### Hardware Configuration

The `hardware-configuration.nix` is a template copied from miniserver24. You **must** regenerate it on the actual hardware using:

```bash
sudo nixos-generate-config
```

### ZFS Pool

The disk configuration expects `/dev/sda` as the primary disk. Adjust in `disk-config.zfs.nix` if needed.

### System DNS Configuration

The system is configured to use localhost (127.0.0.1) for DNS, which points to AdGuard Home. This is already configured in `configuration.nix`.

## Useful Commands

```bash
# Check ZFS pool status
zpool status

# View Docker containers
lazydocker
# or
docker ps

# Check firewall status
sudo nft list ruleset

# Monitor network traffic
sudo tcpdump -i enp2s0f0 port 53

# Check DNS resolution
dig @localhost example.com

# Check AdGuard Home status
systemctl status adguardhome

# View AdGuard Home config
cat /var/lib/AdGuardHome/AdGuardHome.yaml

# Restart AdGuard Home
sudo systemctl restart adguardhome

# View system logs
journalctl -f
```

## System Architecture

This is a minimal, purpose-built configuration focused exclusively on DNS and DHCP services:

### Included Services

- AdGuard Home (DNS/DHCP)
- SSH remote access
- ZFS filesystem with automatic snapshots
- Firewall with restricted port access
- Fail2ban intrusion prevention
- Firmware update support (fwupd)

### Excluded Components

- No graphical environment (headless server)
- No audio subsystem
- No desktop applications
- No IoT/home automation services
- No media services

### Design Principles

- Minimal attack surface
- Declarative configuration
- Automatic backup and recovery via ZFS
- Low resource utilization
- High availability and reliability

## Configuration Management

### Modifying AdGuard Home Settings

AdGuard Home is configured declaratively in `configuration.nix`. All settings are version-controlled and reproducible.

#### Example: Adjust DHCP Range

```nix
services.adguardhome.settings.dhcp = {
  range_start = "192.168.1.201";
  range_end = "192.168.1.254";
  lease_duration = 86400; # 24 hours in seconds
};
```

#### Example: Change Upstream DNS Providers

```nix
services.adguardhome.settings.dns = {
  bootstrap_dns = [ "9.9.9.9" "149.112.112.112" ]; # Quad9
  upstream_dns = [ "9.9.9.9" "149.112.112.112" ];
};
```

#### Example: Adjust DNS Cache Settings

```nix
services.adguardhome.settings.dns = {
  cache_size = 8388608; # 8MB cache
  cache_optimistic = true;
};
```

#### Applying Configuration Changes

```bash
# Test the configuration
sudo nixos-rebuild test --flake .#miniserver99

# Apply permanently
sudo nixos-rebuild switch --flake .#miniserver99

# Rollback if issues occur
sudo nixos-rebuild rollback
```

## Maintenance

### Updates

```bash
# Update flake inputs
nix flake update

# Rebuild system
sudo nixos-rebuild switch --flake .#miniserver99
```

### ZFS Snapshots

Sanoid automatically creates snapshots of:

- Home directories
- Docker volumes
- Nix store

View snapshots: `zfs list -t snapshot`

### Backup AdGuard Home Configuration

```bash
# AdGuard Home data is stored in /var/lib/AdGuardHome
# It's automatically included in ZFS snapshots

# Manual backup
sudo tar -czf adguardhome-backup-$(date +%Y%m%d).tar.gz \
  /var/lib/AdGuardHome/

# Export settings via web UI:
# Settings → General Settings → Export settings
```

## Migration from miniserver24 (PiHole)

This section describes migrating DNS/DHCP services from **miniserver24** (running PiHole in Docker) to **miniserver99** (running AdGuard Home natively).

### Pre-Migration Checklist

1. **Document miniserver24 configuration:**
   - Current PiHole IP: `192.168.1.101`
   - Export PiHole settings from web interface (Settings → Teleporter)
   - Document custom DNS records and CNAME entries
   - Note static DHCP leases
   - Export filter lists and custom blocklists
   - Document any custom dnsmasq configurations

2. **Prepare miniserver99:**
   - Deploy miniserver99 at `192.168.1.99`
   - Complete AdGuard Home initial setup
   - Configure equivalent blocklists in AdGuard Home
   - Add custom DNS rewrites for internal hosts
   - Test DNS resolution and DHCP functionality
   - Verify connectivity from multiple network segments

### Migration Procedure

#### Phase 1: Parallel Testing (Recommended)

1. **Keep miniserver24 running** with PiHole operational
2. Deploy miniserver99 with AdGuard Home at `192.168.1.99`
3. Manually configure 2-3 test clients to use `192.168.1.99` for DNS:

   ```bash
   # On test clients
   sudo nano /etc/resolv.conf
   # Change nameserver to 192.168.1.99
   ```

4. Monitor both systems for 24-48 hours:
   - Check AdGuard Home query logs at <http://192.168.1.99:3000>
   - Compare with PiHole logs on miniserver24
   - Verify ad-blocking is working on test clients
5. Test DHCP by temporarily connecting new devices to verify lease assignment

#### Phase 2: DNS Cutover

1. During a low-traffic period:
   - Update router DNS settings to point to `192.168.1.99`
   - Keep miniserver24 PiHole as secondary DNS (optional): `192.168.1.101`
   - Monitor AdGuard Home query logs for increased traffic
2. Test from various clients:

   ```bash
   # Verify DNS is resolving through miniserver99
   nslookup google.com
   dig @192.168.1.99 example.com
   ```

3. Monitor for DNS issues for 24 hours before proceeding

#### Phase 3: DHCP Cutover

1. During a planned maintenance window (evening/weekend):
   - Stop PiHole DHCP on miniserver24:

     ```bash
     # On miniserver24
     sudo docker exec pihole pihole-FTL dhcp-discover
     # Then disable DHCP in PiHole web interface
     ```

   - Enable DHCP on miniserver99 (already configured)
   - Update router to disable its DHCP server
2. Force DHCP renewal on critical devices:

   ```bash
   # On Linux clients
   sudo dhclient -r && sudo dhclient
   # On Windows: ipconfig /release && ipconfig /renew
   # On macOS: sudo ipconfig set en0 DHCP
   ```

3. Verify DHCP leases in AdGuard Home web interface

#### Phase 4: Stabilization

1. Monitor miniserver99 for 72 hours
2. Keep miniserver24 running but idle as fallback
3. Address any client-specific issues:
   - Check for devices not receiving DHCP leases
   - Verify static leases are working
   - Ensure all internal DNS names resolve
4. Once stable for 1 week, stop PiHole on miniserver24:

   ```bash
   # On miniserver24
   sudo docker stop pihole
   ```

5. After 2 weeks of stable operation, decommission miniserver24 or repurpose it

### Rollback Plan

If issues occur during migration, miniserver24 can be quickly restored as the primary DNS/DHCP server:

#### Quick Rollback (DNS issues)

```bash
# Update router to point back to miniserver24 PiHole
# Router DNS: 192.168.1.101

# Or on affected clients, manually set DNS
sudo nano /etc/resolv.conf
# nameserver 192.168.1.101
```

#### Full Rollback (DHCP issues)

```bash
# On miniserver99: stop AdGuard Home
sudo systemctl stop adguardhome

# On miniserver24: restart PiHole DHCP
sudo docker restart pihole
# Then re-enable DHCP in PiHole web interface

# Force clients to renew DHCP leases
# dhclient -r && dhclient (on Linux clients)

# After resolving issues, restart AdGuard Home
sudo systemctl start adguardhome
```

### Common Migration Considerations

#### Static DHCP Leases from PiHole

All 115 static DHCP leases from miniserver24 are **configured declaratively** in `static-leases.nix`.

**Declarative Configuration:**

The leases are imported directly into `configuration.nix`:

```nix
dhcp = {
  enabled = true;
  # ... other settings ...
  static_leases = staticLeases.static_leases;
};
```

**Benefits:**

- ✅ **Version controlled**: All leases tracked in Git
- ✅ **Reproducible**: Deployed automatically with `nixos-rebuild`
- ✅ **No manual entry**: All 115 leases configured instantly
- ✅ **Atomic updates**: Changes deployed with configuration updates

**Modifying Leases:**

To add, remove, or modify static leases, edit `static-leases.nix`:

```nix
{ mac = "AA:BB:CC:DD:EE:FF"; ip = "192.168.1.250"; hostname = "new-device"; }
```

Then apply with:

```bash
sudo nixos-rebuild switch --flake .#miniserver99
```

**Source File:**

All static leases are defined in `static-leases.nix` in this directory.

**Security Note:** The `static-leases.nix` file is excluded from Git (via `.gitignore`) as it contains:

- MAC addresses of all network devices
- Internal network topology
- Device inventory and room layout information

**Encryption with agenix:** For secure version control, encrypt the file:

```bash
# Encrypt the file (uses your SSH key from secrets/secrets.nix)
cd /Users/markus/Code/nixcfg
agenix -e secrets/static-leases-miniserver99.age

# Decrypt when needed
agenix -d secrets/static-leases-miniserver99.age > hosts/miniserver99/static-leases.nix
```

**Private-Only Access:** Only your personal SSH key (`~/.ssh/id_rsa`) can decrypt this file - not even Patrizio can access it.

**Backup:** The file is backed up via:

- Time Machine on your Mac
- ZFS snapshots on miniserver99 after deployment
- Encrypted `.age` file in Git (once encrypted)
- Optional: Private key stored in 1Password

See `SSH-KEYS.md` in this directory for key management details.

#### Custom DNS Records

1. Export PiHole custom DNS entries:
   - Local DNS Records from PiHole web interface
   - Or check `/etc/pihole/custom.list` on miniserver24
2. Add to AdGuard Home:
   - Settings → DNS rewrites → Add DNS rewrite
   - Format: `hostname` → `IP address`

#### PiHole Blocklists

PiHole and AdGuard Home use similar blocklist formats:

1. Note which blocklists are enabled in PiHole (Settings → Blocklists)
2. Add equivalent lists in AdGuard Home (Filters → DNS blocklists)
3. Common lists available in both:
   - Steven Black's Unified Hosts
   - AdGuard DNS filter
   - EasyList
   - Many others can be added by URL

#### Internal Hosts (miniserver24 specific)

The following hosts are defined on miniserver24 and should be added as DNS rewrites in AdGuard Home:

```nix
# From miniserver24 configuration.nix:
"192.168.1.32" = "kr-sonnen-batteriespeicher.lan"
"192.168.1.102" = "vr-opus-gateway.lan"
"192.168.1.159" = "wz-pixoo-64-00.lan"
"192.168.1.189" = "wz-pixoo-64-01.lan"
```

Add these in AdGuard Home web interface under Settings → DNS rewrites.
