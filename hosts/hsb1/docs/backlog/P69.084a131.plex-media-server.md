# plex-media-server

**Host**: hsb1
**Priority**: P69
**Status**: Backlog
**Created**: 2026-01-01

---

## Problem

Need media streaming solution for PS5. Jellyfin rejected (no PS5 client). hsb0 rejected (crown jewel DNS/DHCP server, too risky). Media stored on Fritz!Box SMB share.

## Solution

Deploy Plex Media Server on hsb1 via Docker (not NixOS package for easy start/stop). Mount Fritz!Box SMB share, serve media to PS5 via official Plex app.

## Implementation

### Infrastructure Setup

- [ ] Enable Docker in NixOS config: `virtualisation.docker.enable = true`
- [ ] Add mba to docker group
- [ ] Create agenix secret for SMB credentials: `secrets/fritzbox-smb-credentials.age`
- [ ] Add to secrets.nix with hsb1 publicKeys
- [ ] Configure SMB mount in configuration.nix:
  - Mount: `//vr-fritz-box-smb/500GB_NTFS` → `/mnt/fritzbox-media`
  - Options: credentials from agenix, uid=1000, nofail, x-systemd.automount
- [ ] Open firewall port 32400
- [ ] Create docker-compose.yml in `~/docker/plex/`
- [ ] Deploy NixOS changes: `nixos-rebuild switch`

### Plex Configuration

- [ ] Start Plex container: `docker-compose up -d`
- [ ] Access web UI: `http://hsb1.lan:32400/web`
- [ ] Link Plex account
- [ ] Add media library (pointing to `/media` in container)
- [ ] Complete initial library scan
- [ ] Enable Remote Access (helps PS5 discovery)
- [ ] Configure transcoding: Prefer Direct Play (CPU weak for transcoding)

### PS5 Integration

- [ ] Install Plex app from PlayStation Store
- [ ] Sign in with Plex account
- [ ] Discover hsb1 server (or add manually: `http://192.168.1.101:32400`)
- [ ] Test playback (various formats)
- [ ] Verify Direct Play works (no transcoding)
- [ ] Check network performance (no stuttering)

### Documentation

- [ ] Update hosts/hsb1/README.md (features, ports, Docker setup)
- [ ] Update hosts/hsb1/docs/RUNBOOK.md (start/stop, troubleshooting)
- [ ] Create test in tests/ directory
- [ ] Document backup strategy (ZFS snapshots for config)

## Acceptance Criteria

- [ ] SMB share mounted at `/mnt/fritzbox-media`
- [ ] Plex web UI accessible
- [ ] Media library scanned
- [ ] PS5 can stream content
- [ ] Direct Play working (no transcoding stuttering)
- [ ] Performance monitoring added (stasysmo)
- [ ] Documentation complete

## Notes

### Decision Log

- **Host**: hsb1 (not hsb0 - crown jewel risk)
- **Software**: Plex (not Jellyfin - no PS5 client)
- **Method**: Docker (not NixOS package - easy start/stop)
- **Media**: Fritz!Box SMB (`//vr-fritz-box-smb/500GB_NTFS`)
- **Credentials**: Group jhw2211, user mba (via agenix)

### Technical Details

- **Container**: lscr.io/linuxserver/plex:latest
- **Network**: host mode (required for discovery)
- **Config Storage**: `/var/lib/docker/volumes/plex-config` (on ZFS)
- **Media Mount**: Read-only in container

### Performance Concerns

- **CPU**: i5-2415M (2011 Sandy Bridge) - weak for transcoding
- **Mitigation**: Disable transcoding, Direct Play only
- **Network**: SMB may add latency vs local storage
- **Monitoring**: Watch CPU/RAM/network with stasysmo

### Risks

- 🔴 Fritz!Box offline → No media access
- 🟡 SMB latency → Stuttering (monitor network)
- 🟡 CPU overload if transcoding → Disable transcoding
- 🟢 Port conflict → Verify 32400 available

### Troubleshooting Commands

```bash
# Check SMB mount
ssh mba@hsb1.lan "mount | grep fritzbox"

# Test Plex container
ssh mba@hsb1.lan "cd ~/docker/plex && docker-compose ps"

# View logs
ssh mba@hsb1.lan "docker-compose logs -f"

# Check media accessible in container
ssh mba@hsb1.lan "docker exec plex ls -la /media"
```

- Effort: 4-6 hours
- Client: PS5 (primary streaming target)
- Reference: NixOS Wiki Plex, Plex requirements docs
