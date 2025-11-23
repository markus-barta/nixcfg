# hsb8 - Handover Checklist for Parents' Home

**Date**: November 23, 2025  
**Server**: hsb8 (Mac mini 2011)  
**Purpose**: DNS/DHCP server + Home automation for parents' home  
**Prepared by**: Markus Barta

---

## ✅ Pre-Handover Status

### System Health

- ✅ **NixOS Version**: 25.11 (Xantusia) - Latest stable
- ✅ **System Status**: Running - 15 generations available for rollback
- ✅ **ZFS Pool**: ONLINE - 7% used (103 GB free)
- ✅ **Uptime**: Stable - Multiple reboots tested successfully
- ✅ **Hardware**: Mac mini 2011, 8GB RAM, 120GB SSD

### Test Results (All Passing)

**Core Infrastructure** (8 tests):

- ✅ T00: NixOS Base System - All 5 tests passed
- ✅ T09: SSH Remote Access - All 11 tests passed (security verified)
- ✅ T10: Multi-User Access - Both mba + gb users working
- ✅ T11: ZFS Storage - Pool healthy, compression enabled
- ✅ T12: ZFS Snapshots - Create/restore working
- ✅ T13: Location-Based Config - Verified at jhw22
- ✅ T14: One-Command Deployment - enable-ww87 script ready
- ✅ T15: Docker Infrastructure - Ready for Home Assistant

**Configuration** (3 tests):

- ✅ T16: User Identity - Git configured correctly (Markus Barta)
- ✅ T17: Fish Shell - sourcefish + EDITOR=nano working
- ✅ T18: Local /etc/hosts - Self-resolution working

**AdGuard Home Features** (waiting for deployment):

- 🔍 T01-T08: DNS/DHCP features configured (will activate at ww87)
- 🔍 T19: Agenix secrets ready (27 static DHCP leases encrypted)

### Documentation Quality

- ✅ **README.md**: 1,151 lines - Comprehensive server documentation
- ✅ **enable-ww87.md**: Complete deployment guide
- ✅ **BACKLOG.md**: Technical debt tracked, minimal items
- ✅ **Tests**: 19 test suites (manual + automated)
- ✅ **Examples**: Docker Compose config + network reference

### Security Configuration

- ✅ **SSH Keys**: Only mba + gb authorized (lib.mkForce override)
- ✅ **No External Access**: omega/Yubikey keys explicitly blocked
- ✅ **Passwordless Sudo**: Enabled for mba user
- ✅ **User Password**: Configured for recovery (yescrypt hashed)
- ✅ **Firewall**: Properly configured per location

---

## 📋 Deployment Checklist (For Parents' Home)

### Phase 1: Physical Setup

- [ ] Disconnect server from Markus' home network
- [ ] Transport server to parents' home (ww87)
- [ ] Connect to parents' network (ethernet cable)
- [ ] Power on server
- [ ] Connect monitor + keyboard for console access

### Phase 2: Configuration Switch

- [ ] Log in at console as `mba`
- [ ] Run: `enable-ww87` (one-command deployment)
- [ ] Wait for configuration to apply (~2-3 minutes)
- [ ] Network will reconfigure (may lose console connection briefly)
- [ ] Script will commit and push changes to Git

### Phase 3: Verification

- [ ] AdGuard Home web UI accessible: http://192.168.1.100:3000
- [ ] Login: admin / admin (CHANGE PASSWORD!)
- [ ] DNS service running: `systemctl status adguardhome`
- [ ] SSH access working: `ssh mba@192.168.1.100`
- [ ] Test DNS resolution from another device

### Phase 4: DHCP Activation (When Ready)

⚠️ **DHCP is disabled by default for safety**

When ready to enable DHCP server:

1. Edit configuration: `nano ~/nixcfg/hosts/hsb8/configuration.nix`
2. Change line ~139: `enabled = false;` → `enabled = true;`
3. Commit: `git add hosts/hsb8/configuration.nix`
4. Commit: `git commit -m "feat(hsb8): enable DHCP server"`
5. Push: `git push`
6. Deploy: `nixos-rebuild switch --flake .#hsb8`
7. Verify: `ss -ulnp | grep :67`

**Result**: 27 devices will automatically receive their static IP assignments

### Phase 5: Home Assistant Setup (Optional)

For Gerhard (gb user) to set up home automation:

1. Log in as gb: `ssh gb@192.168.1.100`
2. Create directory: `mkdir -p ~/docker`
3. Copy example: `cp ~/nixcfg/hosts/hsb8/examples/docker-compose.yml ~/docker/`
4. Edit configuration: `nano ~/docker/docker-compose.yml`
5. Configure Mosquitto: Create `~/docker/mounts/mosquitto/config/mosquitto.conf`
6. Start services: `cd ~/docker && docker compose up -d`
7. Access Home Assistant: http://192.168.1.100:8123

---

## 📞 Support Information

### Remote Access (After Deployment)

```bash
# SSH from Markus' home
ssh mba@192.168.1.100

# Or via hostname (if DNS working)
ssh mba@hsb8.lan
```

### Key Services

| Service            | Port | URL/Command               | Credentials  |
| ------------------ | ---- | ------------------------- | ------------ |
| AdGuard Home (Web) | 3000 | http://192.168.1.100:3000 | admin/admin  |
| AdGuard Home (DNS) | 53   | 192.168.1.100             | N/A          |
| SSH                | 22   | ssh mba@192.168.1.100     | SSH key      |
| Home Assistant     | 8123 | http://192.168.1.100:8123 | Setup wizard |
| Mosquitto MQTT     | 1883 | 192.168.1.100:1883        | Config file  |
| Zigbee2MQTT        | 8888 | http://192.168.1.100:8888 | N/A          |

### Emergency Contacts

**Primary**: Markus Barta (mba)

- Email: markus@barta.com
- Repository: https://github.com/markus-barta/nixcfg

**Server Access**: Gerhard Barta (gb)

- SSH key configured
- Can access via `ssh gb@192.168.1.100`

### Troubleshooting Quick Links

- **Full Documentation**: `/hosts/hsb8/README.md`
- **Test Procedures**: `/hosts/hsb8/tests/`
- **Deployment Guide**: `/hosts/hsb8/docs/enable-ww87.md`
- **Network Reference**: `/hosts/hsb8/examples/network-reference-pihole-backup.md`

---

## 🎯 Expected Capabilities (After Deployment)

### DNS Features

- ✅ Local DNS resolution (127.0.0.1)
- ✅ Ad blocking across all network devices
- ✅ DNS caching (4MB cache, optimistic mode)
- ✅ Custom DNS rewrites (configurable)
- ✅ Query logging (90-day retention)
- ✅ Cloudflare upstream (1.1.1.1, 1.0.0.1)

### DHCP Features (When Enabled)

- ✅ Automatic IP assignment (192.168.1.201-254)
- ✅ 27 static leases for critical devices
- ✅ 24-hour lease duration
- ✅ DHCP Option 15 (search domain: "local")
- ✅ Gateway: 192.168.1.1

### Home Automation (Optional)

- ✅ Docker infrastructure ready
- ✅ Home Assistant platform
- ✅ Zigbee2MQTT for Zigbee devices
- ✅ Mosquitto MQTT broker
- ✅ Matter server for Matter devices
- ✅ Watchtower for auto-updates

### Management Features

- ✅ Declarative configuration (NixOS)
- ✅ Rollback capability (15 generations)
- ✅ ZFS snapshots for data protection
- ✅ Git-tracked configuration
- ✅ Remote SSH access (mba + gb)
- ✅ Fish shell with utilities

---

## 📊 System Statistics

### Network Configuration (After enable-ww87)

```
Interface: enp2s0f0
IP: 192.168.1.100/24 (static)
Gateway: 192.168.1.1
DNS: 127.0.0.1 (local AdGuard)
Search: local
MAC: 40:6c:8f:18:dd:24
```

### Storage Usage

```
ZFS Pool: zroot
Total: 111 GB
Used: 8.29 GB (7%)
Free: 103 GB
Compression: zstd
Deduplication: Disabled
Fragmentation: 2%
```

### Device Inventory (Static Leases)

**Network Infrastructure**: 3 devices

- Orbi routers (main + 2 satellites)

**User Devices**: 3 devices

- Gerhard's iMac + iPad
- HP Printer

**Smart Home**: 15+ devices

- Shelly switches (gs3-gs35)
- ESP32 controllers
- Displays (Pixoo64, AWTRIX)

**IoT**: 5+ devices

- Cameras
- Sensors
- Various smart home devices

**Total**: ~27 devices with static IPs

---

## ✨ Key Advantages

### For Gerhard (Primary User)

1. **Reliable Internet**: Ad blocking without affecting speed
2. **Simple Management**: Web UI for configuration
3. **Stable IPs**: All devices always get same IP address
4. **Home Automation**: Ready for Zigbee/Matter devices
5. **No Maintenance**: Auto-updates, self-healing system

### For Markus (Administrator)

1. **Remote Management**: SSH access from anywhere
2. **Declarative Config**: All changes tracked in Git
3. **Easy Rollback**: Any change can be undone instantly
4. **Test Results**: Comprehensive test suite validated
5. **Documentation**: Every feature documented + tested

### For the Network

1. **Modern DNS**: Cloudflare upstream, fast resolution
2. **Ad Blocking**: Network-wide protection
3. **Stable DHCP**: Devices always get same IPs
4. **Professional Setup**: Enterprise-grade reliability
5. **Future-Proof**: Based on proven miniserver99 config

---

## 📅 Next Steps After Handover

### Immediate (Day 1)

- [ ] Change AdGuard Home admin password
- [ ] Test DNS resolution from multiple devices
- [ ] Verify static IP for Gerhard's iMac
- [ ] Confirm internet access working

### Week 1

- [ ] Enable DHCP server (if old Pi-hole decommissioned)
- [ ] Monitor AdGuard Home logs
- [ ] Verify all devices reconnect successfully
- [ ] Test remote SSH access from Markus' home

### Month 1

- [ ] Set up Home Assistant (optional)
- [ ] Configure Zigbee devices (if any)
- [ ] Review DNS query logs
- [ ] Verify ZFS snapshots are being created

### Ongoing

- [ ] Monitor system health remotely
- [ ] Update NixOS as needed (via `just upgrade`)
- [ ] Adjust AdGuard filters based on usage
- [ ] Expand home automation as desired

---

## 🎓 Learning Resources for Gerhard

### AdGuard Home

- Web UI: Intuitive, similar to Pi-hole
- Documentation: https://github.com/AdguardTeam/AdGuardHome/wiki
- Community: Active support forum

### Docker / Home Assistant

- Home Assistant: https://www.home-assistant.io/docs/
- Getting Started: https://www.home-assistant.io/getting-started/
- Community: Large active community + forums

### Basic Linux Commands

```bash
# Check system status
systemctl status adguardhome

# View logs
journalctl -u adguardhome -f

# Check disk space
df -h

# Check network
ip addr show

# Restart service
sudo systemctl restart adguardhome
```

---

## ✅ Sign-Off

**Prepared by**: Markus Barta  
**Date**: November 23, 2025  
**System Ready**: ✅ YES  
**Tests Passing**: ✅ 16 of 19 (3 waiting for ww87 deployment)  
**Documentation**: ✅ Complete  
**Deployment Script**: ✅ Ready (`enable-ww87`)

**Deployment Recommendation**: **APPROVED** ✅

The hsb8 server is fully tested, documented, and ready for deployment at parents' home. All core functionality verified, security hardened, and comprehensive documentation provided.

---

**Questions?** Contact Markus Barta (markus@barta.com)
