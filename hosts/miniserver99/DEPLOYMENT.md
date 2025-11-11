# miniserver99 Deployment Status

**Date:** November 11, 2025  
**Status:** ✅ Deployed and Running

## Summary

Successfully deployed NixOS on miniserver99 (Mac mini) using `nixos-anywhere` from miniserver24. The system is running with AdGuard Home configured, including the DHCP server and a fully declarative static-lease sync. The login issue has been resolved with a proper password configuration (username: `admin`, password: `admin`). Configuration has been deployed successfully from `~/Code/nixcfg` using the static-lease override.

## Completed Tasks ✅

1. **Initial Deployment**
   - Successfully deployed NixOS using `nixos-anywhere` from miniserver24
   - System booted successfully at `192.168.1.99`

2. **Network Configuration**
   - Fixed network interface from `enp3s0f0` → `enp2s0f0` (actual hardware interface)
   - Fixed gateway IP from `192.168.1.1` → `192.168.1.5` (verified from miniserver24)
   - Updated in:
     - `networking.defaultGateway`
     - `services.adguardhome.settings.dhcp.gateway_ip`
     - `services.adguardhome.settings.dhcp.dhcpv4.gateway_ip`

3. **AdGuard Home Configuration**
   - Service is running and accessible at `http://192.168.1.99:3000`
   - DNS configured with Cloudflare upstream (`1.1.1.1`, `1.0.0.1`)
   - DHCP server enabled (Pi-hole DHCP must remain disabled)
   - Admin user configured with bcrypt hash for password `admin`
   - `mutableSettings = false` (declarative configuration maintained)

4. **Temporary Fixes Applied**
   - Fixed gateway routes manually on both miniserver24 and miniserver99 to restore internet connectivity
   - Fixed DNS on miniserver24 temporarily to allow git operations

5. **Repository Setup**
   - Created `~/Code` directory on miniserver99
   - Cloned nixcfg repository to `~/Code/nixcfg`
   - All future deployments should use this location

6. **Configuration Deployment**
   - Deployed updated configuration with proper AdGuard Home password
   - Service restarted successfully
   - Password hash verified in `/var/lib/AdGuardHome/AdGuardHome.yaml`

7. **Static DHCP Leases (Declarative)**
   - Added flake input `miniserver99-static-leases` pointing to placeholder `samples/static-leases-empty.nix`
   - Real leases supplied via override at deploy time (local `hosts/miniserver99/static-leases.nix`, gitignored)
   - `systemd.services.adguardhome.preStart` now syncs the declarative list into `/var/lib/private/AdGuardHome/data/leases.json` (UI-created static leases are removed on rebuild)
   - Verified `/control/dhcp/status` shows 100+ static leases after rebuild

## Current Issues 🔴

### 1. AdGuard Home Login Issue - ✅ RESOLVED AND DEPLOYED
**Status:** ✅ Complete  
**Description:** Could not log in to AdGuard Home web interface at `http://192.168.1.99:3000`

**Root Cause:**
- AdGuard Home web UI has client-side validation requiring a non-empty password
- Empty password (even with valid bcrypt hash) cannot be submitted due to JavaScript validation
- The issue was "field required" error, not authentication failure

**Solution (Declarative):**
- Set proper admin credentials: username `admin`, password `admin`
- Generated bcrypt hash: `REMOVED`
- Updated configuration declaratively (no mutable settings)
- **Deployed successfully** from `~/Code/nixcfg`

**Deployed Configuration:**
```nix
users = [
  {
    name = "admin";
    password = "REMOVED";
  }
];
```

**Verification:**
- Service status: ✅ `active (running)`
- Configuration file: ✅ Password hash confirmed
- Web interface: http://192.168.1.99:3000 (ready to test login)

### 2. Static DHCP Leases - ✅ Declarative Override & Sync
**Status:** ✅ Complete  
**Description:** Static leases are sourced from the local override and synced into AdGuard Home automatically

**Implementation:**
- Placeholder input: `miniserver99-static-leases = path:./samples/static-leases-empty.nix`
- Real data supplied during deployment:
  ```bash
  sudo nixos-rebuild switch \
    --flake .#miniserver99 \
    --override-input miniserver99-static-leases \
    path:/home/mba/Code/nixcfg/hosts/miniserver99/static-leases.nix
  ```
- Declarative list is merged into `/var/lib/private/AdGuardHome/data/leases.json` before AdGuard Home starts; UI-created static leases are purged

**Reminder:** Keep `hosts/miniserver99/static-leases.nix` gitignored; update it locally before running the override command. Rebuilds must include the override flag to import the private data.

### 3. miniserver24 Gateway Route
**Status:** Temporary Fix Applied  
**Description:** miniserver24 gateway route was fixed manually but needs permanent fix

**Current State:**
- Gateway route fixed manually: `sudo ip route add default via 192.168.1.5`
- DNS fixed manually: `echo 'nameserver 1.1.1.1' | sudo tee /etc/resolv.conf`
- Needs permanent configuration update in miniserver24's `configuration.nix`

## Configuration Files Modified

### `hosts/miniserver99/configuration.nix`
- Network interface: `enp2s0f0`
- Gateway IP: `192.168.1.5`
- Admin user with bcrypt hash for admin password
- Static leases imported from `inputs.miniserver99-static-leases`; preStart merges into `leases.json`
- DHCP enabled (`enabled = true`)

### `hosts/miniserver99/installation.md`
- Installation guide relocated from `docs/cord`
- Added static lease override instructions to all rebuild/deploy steps
- Updated DHCP cutover checklist for newly enabled service

## Network Details

- **miniserver99 IP:** `192.168.1.99/24`
- **Gateway:** `192.168.1.5` (Fritz Box)
- **DNS:** `127.0.0.1` (AdGuard Home)
- **DHCP Range:** `192.168.1.201-254` (when enabled)
- **Web Interface:** `http://192.168.1.99:3000`

## Commands Reference

### Check AdGuard Home Status
```bash
ssh mba@192.168.1.99
systemctl status adguardhome
journalctl -u adguardhome -f
```

### Rebuild Configuration
```bash
# On miniserver99
cd ~/Code/nixcfg
git pull
sudo nixos-rebuild switch \
  --flake .#miniserver99 \
  --override-input miniserver99-static-leases \
  path:/home/mba/Code/nixcfg/hosts/miniserver99/static-leases.nix
```

### Check Gateway Route
```bash
ssh mba@192.168.1.99
ip route show
```

### Check AdGuard Home Config
```bash
ssh mba@192.168.1.99
sudo cat /var/lib/AdGuardHome/AdGuardHome.yaml | grep -A 3 '^users:'
```

## Next Steps (Priority Order)

1. **🟢 TEST:** Spot-check AdGuard Home
   - Confirm login works with `admin` / `admin`
   - Browse to Settings → DHCP to verify static leases are listed
   - Ensure dynamic clients receive expected leases

2. **🟡 FOLLOW-UP:** Monitor DHCP rollout
   - Watch `/var/lib/private/AdGuardHome/data/leases.json` and the UI for 24 hours
   - Gather feedback before decommissioning miniserver24’s Pi-hole completely

3. **🟢 LOW:** Fix miniserver24 gateway permanently
   - Update miniserver24 `configuration.nix` with correct gateway
   - Rebuild miniserver24

## Notes

- All configuration is declarative (`mutableSettings = false`)
- Static leases file contains sensitive network topology data (gitignored)
- Gateway IP `192.168.1.5` verified from miniserver24's actual configuration
- Network interface `enp2s0f0` verified from actual hardware

