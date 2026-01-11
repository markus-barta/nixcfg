# P6950: Plex Media Server on hsb1 (Docker + Fritz!Box SMB)

**Status:** 📋 Backlog  
**Priority:** P6 (🟢 Low)  
**Created:** 2026-01-01  
**Estimated Effort:** 4-6 hours  
**Target Host:** hsb1 (192.168.1.101)  
**Client:** PS5 (primary streaming target)  
**Deployment:** Docker container (not NixOS package)  
**Media Source:** Fritz!Box SMB share (`//vr-fritz-box-smb/500GB_NTFS`)

---

## Quick Reference

| Item               | Value                                               |
| ------------------ | --------------------------------------------------- |
| **Host**           | hsb1 (192.168.1.101)                                |
| **Deployment**     | Docker Compose                                      |
| **Web UI**         | `http://hsb1.lan:32400/web`                         |
| **Media Source**   | Fritz!Box SMB: `//vr-fritz-box-smb/500GB_NTFS`      |
| **Mount Point**    | `/mnt/fritzbox-media` (host) → `/media` (container) |
| **Config Storage** | `/var/lib/docker/volumes/plex-config` (ZFS)         |
| **Compose File**   | `~/docker/plex/docker-compose.yml`                  |
| **Start/Stop**     | `docker-compose up -d` / `docker-compose down`      |
| **Client**         | PS5 (official Plex app)                             |

---

## Context

Implement Plex Media Server on hsb1 for streaming to PS5. Initial request was for hsb0, but analysis revealed concerns (crown jewel DNS/DHCP server). Decision: Use hsb1 with Docker deployment for easy deactivation.

---

## Deployment Strategy

### Docker vs NixOS Package

| Aspect           | NixOS Package (`services.plex`) | Docker Container                |
| ---------------- | ------------------------------- | ------------------------------- |
| **Activation**   | Requires `nixos-rebuild switch` | `docker-compose up -d`          |
| **Deactivation** | Requires rebuild + reboot       | `docker-compose down` (instant) |
| **Isolation**    | System-level service            | Containerized (isolated)        |
| **Updates**      | Via flake.lock updates          | Pull new image                  |
| **Rollback**     | NixOS generations               | Previous image tag              |
| **Complexity**   | Simple (declarative)            | Moderate (compose file + mount) |

**Decision:** Use **Docker** for easy start/stop without system rebuilds.

### Media Storage: Fritz!Box SMB Share

**Share Details:**

- **URL:** `http://192.168.1.5/nas#/files/500GB_NTFS`
- **SMB Server:** `vr-fritz-box-smb` (or `192.168.1.5`)
- **Share Name:** `500GB_NTFS`
- **Credentials:**
  - Group: `jhw2211`
  - User: `mba`
  - Password: Via `.env` file (agenix-encrypted)

**Mount Strategy:**

- Mount SMB share on hsb1 host at `/mnt/fritzbox-media`
- Bind mount into Plex Docker container
- Plex cannot access SMB directly (must be host-mounted)

---

## Analysis Results

### Hardware Assessment: hsb1 (Target Host)

| Aspect           | Specification                              | Plex Suitability             |
| ---------------- | ------------------------------------------ | ---------------------------- |
| **CPU**          | Intel i5-2415M (2C/4T, Sandy Bridge 2011)  | ⚠️ Weak for transcoding      |
| **RAM**          | 8 GB                                       | ✅ Meets minimum (4GB+)      |
| **Storage**      | 232 GB SSD (223 GB free)                   | ⚠️ Limited for media library |
| **Network**      | Gigabit Ethernet                           | ✅ Sufficient                |
| **Current Load** | DNS, DHCP, AdGuard, NCPS, Uptime Kuma, UPS | ⚠️ Already busy              |

### Critical Concerns

**1. Role Conflict (🔴 HIGH RISK)**

- hsb0 is **crown jewel** infrastructure (DNS/DHCP)
- Network depends on this host
- Adding media workload risks DNS/DHCP stability
- **Recommendation:** Do NOT use hsb0

**2. CPU Performance**

- 2011 Sandy Bridge CPU is **weak** for transcoding
- Multiple streams or 4K content → expect stuttering
- **Mitigation:** Disable transcoding, use Direct Play only

**3. Storage Constraints**

- 223 GB internal storage insufficient for serious media library
- **Requirement:** External USB drive or NAS mount needed

**4. Network Load**

- Plex streaming adds significant bandwidth
- May impact DNS query response times
- **Mitigation:** Monitor with stasysmo metrics

---

## Recommended Alternatives

### Option A: Use hsb1 (RECOMMENDED)

**Why hsb1 is better:**

| Aspect             | hsb0                  | hsb1                       |
| ------------------ | --------------------- | -------------------------- |
| **Criticality**    | 🔴 HIGH (crown jewel) | 🟡 MEDIUM                  |
| **Current Role**   | DNS/DHCP              | Home automation            |
| **Docker**         | Minimal use           | Already running containers |
| **Impact if down** | Network-wide outage   | Home automation only       |
| **CPU headroom**   | Low                   | Better                     |

**hsb1 Configuration:**

- IP: 192.168.1.101
- Already has Docker + services
- Firewall disabled (easier setup)
- Better candidate for media workload

### Option B: Jellyfin Instead of Plex (REJECTED)

**Why Jellyfin was considered:**

- Open-source (no proprietary concerns)
- No Plex Pass required for features
- Native NixOS support (`services.jellyfin`)

**Why Jellyfin was rejected:**

- ❌ **No PS5 client** (dealbreaker for primary use case)
- PS5 is main streaming target
- Plex has official PS5 app ✅
- Decision: **Use Plex**

### Option C: hsb0 with Constraints (NOT RECOMMENDED)

**Only if hsb1 not viable:**

- Disable transcoding completely (Direct Play only)
- External USB drive for media (not internal storage)
- Monitor CPU/RAM impact on DNS/DHCP with stasysmo
- Test during low-traffic hours
- Rollback plan ready

---

## Technical Implementation

### 1. NixOS Configuration (hsb1)

```nix
# hosts/hsb1/configuration.nix

# Enable Docker
virtualisation.docker.enable = true;

# Add mba to docker group
users.users.mba.extraGroups = [ "docker" ];

# Mount Fritz!Box SMB share
fileSystems."/mnt/fritzbox-media" = {
  device = "//vr-fritz-box-smb/500GB_NTFS";
  fsType = "cifs";
  options = [
    "credentials=/run/agenix/fritzbox-smb-credentials"
    "uid=1000"  # mba user
    "gid=100"   # users group
    "iocharset=utf8"
    "nofail"    # Don't block boot if unavailable
    "x-systemd.automount"  # Mount on access
    "x-systemd.idle-timeout=60"  # Unmount after 60s idle
  ];
};

# Firewall: Open Plex port
networking.firewall.allowedTCPPorts = [ 32400 ];
```

### 2. Agenix Secret (SMB Credentials)

```bash
# Create secret file: secrets/fritzbox-smb-credentials.age
# Content (plain text before encryption):
username=mba
password=YOUR_PASSWORD_HERE
domain=jhw2211

# Encrypt with agenix
agenix -e secrets/fritzbox-smb-credentials.age
```

```nix
# Add to secrets/secrets.nix
"fritzbox-smb-credentials.age".publicKeys = markus ++ hsb1;

# Add to hosts/hsb1/configuration.nix
age.secrets.fritzbox-smb-credentials = {
  file = ../../secrets/fritzbox-smb-credentials.age;
  mode = "400";
  owner = "root";
};
```

### 3. Docker Compose File

```yaml
# /home/mba/docker/plex/docker-compose.yml
version: "3.8"

services:
  plex:
    image: lscr.io/linuxserver/plex:latest
    container_name: plex
    network_mode: host # Required for Plex discovery
    environment:
      - PUID=1000 # mba user ID
      - PGID=100 # users group ID
      - TZ=Europe/Vienna
      - VERSION=docker
    volumes:
      - /var/lib/docker/volumes/plex-config:/config
      - /mnt/fritzbox-media:/media:ro # Read-only media mount
    restart: unless-stopped
```

### 4. ZFS Dataset (Already Exists!)

hsb1 already has ZFS docker dataset configured:

```nix
# hosts/hsb1/disk-config.zfs.nix (existing)
datasets = {
  docker = {
    type = "zfs_fs";
    mountpoint = "/var/lib/docker/volumes";
    options = {
      mountpoint = "legacy";
    };
  };
};
```

**Plex config will be stored in:** `/var/lib/docker/volumes/plex-config` (on ZFS)

### 5. Deployment Commands

```bash
# On hsb1
ssh mba@hsb1.lan

# Create docker compose directory
mkdir -p ~/docker/plex
cd ~/docker/plex

# Create docker-compose.yml (see above)
nano docker-compose.yml

# Start Plex
docker-compose up -d

# Check logs
docker-compose logs -f

# Access web UI
# http://hsb1.lan:32400/web
# or http://192.168.1.101:32400/web

# Stop Plex (if needed)
docker-compose down

# Update Plex (pull latest image)
docker-compose pull
docker-compose up -d
```

---

## PS5 Client Setup

### Installation

1. Open PlayStation Store on PS5
2. Search for "Plex"
3. Download and install official Plex app
4. Launch app and sign in with Plex account

### Known Issues & Solutions

**Problem:** PS5 app can't find local server

**Solutions:**

1. **DNS Settings:** Ensure PS5 uses hsb0 (192.168.1.99) for DNS
2. **Manual Server URL:** Add server manually in app settings:
   - Format: `http://192.168.1.101:32400`
   - Or: `http://hsb1.lan:32400`
3. **Plex Account:** Sign in to link server to account (enables remote access)

**Problem:** Transcoding stutters

**Solutions:**

1. Use Direct Play compatible formats (H.264, AAC)
2. Disable transcoding in Plex settings
3. Convert media to PS5-compatible formats beforehand

### Recommended Settings

```
Plex Server Settings (for PS5):
- Remote Access: Enabled (even for LAN, helps discovery)
- Transcoder: Quality = "Make my CPU hurt" (if needed)
- Network: LAN Networks = 192.168.1.0/24
- Network: Secure connections = Preferred (not Required)
```

---

## Acceptance Criteria

### Phase 1: Infrastructure Setup

- [x] Decision made: hsb1 (not hsb0)
- [x] Software chosen: Plex (not Jellyfin - no PS5 client)
- [x] Deployment method: Docker (not NixOS package)
- [x] Media source: Fritz!Box SMB share
- [ ] Docker enabled in NixOS config
- [ ] SMB credentials encrypted with agenix
- [ ] SMB share mounted at `/mnt/fritzbox-media`
- [ ] Firewall port 32400 opened
- [ ] Docker compose file created
- [ ] Plex container started successfully

### Phase 2: Plex Configuration

- [ ] Plex web UI accessible at `http://hsb1.lan:32400/web`
- [ ] Plex account linked
- [ ] Media library added (pointing to `/media`)
- [ ] Initial library scan completed
- [ ] Remote access enabled (helps PS5 discovery)
- [ ] Transcoding settings reviewed (prefer Direct Play)

### Phase 3: PS5 Integration

- [ ] PS5 Plex app installed
- [ ] PS5 can discover hsb1 server
- [ ] Test playback on PS5 (various formats)
- [ ] Verify Direct Play works (no transcoding)
- [ ] Check network performance (no stuttering)

### Phase 4: Documentation & Monitoring

- [ ] Performance monitoring added (CPU/RAM impact via stasysmo)
- [ ] Documentation updated:
  - [ ] Host README.md (features, ports, Docker setup)
  - [ ] Host RUNBOOK.md (start/stop, troubleshooting)
  - [ ] Test created in `tests/` directory
- [ ] Changes committed and deployed
- [ ] Backup strategy documented (ZFS snapshots for config)

---

## Risks & Mitigations

| Risk                       | Impact                     | Mitigation                                   |
| -------------------------- | -------------------------- | -------------------------------------------- |
| Fritz!Box offline          | 🔴 No media access         | Plex stops working (expected)                |
| SMB mount fails            | 🔴 Plex can't access media | Check credentials, network, Fritz!Box status |
| Network latency (SMB)      | 🟡 Stuttering playback     | Monitor network, consider local cache        |
| CPU overload (transcoding) | 🟡 Stuttering playback     | Disable transcoding, Direct Play only        |
| Docker not enabled         | 🟡 Container won't start   | Add `virtualisation.docker.enable = true`    |
| Port 32400 conflict        | 🟢 Service won't start     | Verify port available with `ss -tlnp`        |
| Wrong SMB credentials      | 🟢 Mount fails             | Verify credentials in agenix secret          |

---

## Troubleshooting

### SMB Mount Issues

**Check if mount is active:**

```bash
ssh mba@hsb1.lan "mount | grep fritzbox"
# Should show: //vr-fritz-box-smb/500GB_NTFS on /mnt/fritzbox-media type cifs
```

**Test SMB connection manually:**

```bash
# Install cifs-utils if needed
nix-shell -p cifs-utils

# Test mount manually
sudo mount -t cifs //vr-fritz-box-smb/500GB_NTFS /mnt/test \
  -o username=mba,password=YOUR_PASSWORD,domain=jhw2211

# List files
ls -la /mnt/test

# Unmount
sudo umount /mnt/test
```

**Check credentials file:**

```bash
ssh mba@hsb1.lan "sudo cat /run/agenix/fritzbox-smb-credentials"
# Should show: username=mba, password=..., domain=jhw2211
```

**Verify Fritz!Box is reachable:**

```bash
ping -c 3 192.168.1.5
ping -c 3 vr-fritz-box-smb
```

### Plex Container Issues

**Check if container is running:**

```bash
ssh mba@hsb1.lan "cd ~/docker/plex && docker-compose ps"
```

**View container logs:**

```bash
ssh mba@hsb1.lan "cd ~/docker/plex && docker-compose logs -f"
```

**Check if media is accessible inside container:**

```bash
ssh mba@hsb1.lan "docker exec plex ls -la /media"
```

**Restart container:**

```bash
ssh mba@hsb1.lan "cd ~/docker/plex && docker-compose restart"
```

### PS5 Can't Find Server

**Solutions:**

1. Enable Remote Access in Plex settings (even for LAN)
2. Add server manually in PS5 app: `http://192.168.1.101:32400`
3. Sign in to Plex account on both server and PS5
4. Check firewall: `ssh mba@hsb1.lan "sudo nft list ruleset | grep 32400"`

---

## Resources

- [NixOS Wiki: Plex](https://wiki.nixos.org/wiki/Plex)
- [NixOS Wiki: Jellyfin](https://nixos.wiki/wiki/Jellyfin)
- [Plex Requirements](https://support.plex.tv/articles/200375666-plex-media-server-requirements/)
- [hsb0 README](../../hosts/hsb0/README.md)
- [hsb1 README](../../hosts/hsb1/README.md)

---

## Decision Log

**2026-01-01 (Initial Analysis):**

- Analysis completed
- Recommendation: Use hsb1, not hsb0
- Awaiting user decision

**2026-01-01 (Host & Software Decision):**

- ✅ **Host:** hsb1 (not hsb0)
- ✅ **Software:** Plex (not Jellyfin)
- **Reason:** PS5 is primary streaming target. Jellyfin has no PS5 client. Plex has official PS5 app.

**2026-01-01 (Deployment Strategy):**

- ✅ **Method:** Docker container (not NixOS package)
- **Reason:** Easy start/stop without system rebuilds. Better for testing/deactivation.
- ✅ **Media Source:** Fritz!Box SMB share (`//vr-fritz-box-smb/500GB_NTFS`)
- **Credentials:** Via agenix-encrypted file
  - Group: `jhw2211`
  - User: `mba`
  - Password: To be provided by user
- **Next:** Implement Docker + SMB mount on hsb1

---

## Notes

### Storage & Media

- **Media Source:** Fritz!Box SMB share (existing 500GB NTFS)
- **Plex Config:** `/var/lib/docker/volumes/plex-config` (on ZFS)
- **SMB Mount:** `/mnt/fritzbox-media` (read-only for Plex)
- **Network Dependency:** Plex requires Fritz!Box to be online

### Performance

- **Transcoding:** hsb1 has better CPU than hsb0, but still prefer Direct Play
- **SMB Performance:** Network share may introduce latency vs local storage
- **Monitoring:** Use stasysmo to watch CPU/RAM/network impact

### Deployment

- **Docker:** Easy start/stop: `docker-compose up -d` / `docker-compose down`
- **No System Rebuild:** Changes don't require `nixos-rebuild switch`
- **Isolation:** Container crash won't affect other hsb1 services

### Backup & Recovery

- **Plex Config:** Backed up via ZFS snapshots (docker volumes dataset)
- **Media:** Lives on Fritz!Box (separate backup strategy)
- **Rollback:** `docker-compose down` to completely remove

### PS5 Integration

- **Official App:** Plex has native PS5 client
- **Discovery:** May need manual server URL if auto-discovery fails
- **Jellyfin:** Not viable (no PS5 client support)

### Security

- **SMB Credentials:** Encrypted with agenix (not plain text)
- **Container:** Runs as user `mba` (UID 1000), not root
- **Media Mount:** Read-only in container (safety)
