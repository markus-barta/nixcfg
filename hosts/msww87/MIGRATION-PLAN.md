# msww87 → hsb8 Migration Plan

**Server**: msww87 → hsb8 (Home Server Barta 8)  
**Migration Type**: Hostname + Hokage Consumer Pattern + Folder Rename  
**Migration Date**: TBD (Guinea pig for naming scheme migration)  
**Location**: Currently at jhw22 (testing), target deployment: ww87 (parents' home)  
**Expected Duration**: 2-3 hours (includes testing)  
**Last Updated**: November 19, 2025

---

## 🎯 Migration Overview

### What's Changing

This is a **triple migration**:

1. **Hostname**: `msww87` → `hsb8` (new naming scheme)
2. **Folder**: `hosts/msww87/` → `hosts/hsb8/` (repo structure)
3. **Hokage Pattern**: Local modules → External hokage consumer (like csb0/csb1)

### Current State

- **Hostname**: `msww87` (Mini-Server WW87)
- **Model**: Mac mini 2011 (Intel i5-2415M)
- **OS**: NixOS 24.11
- **Status**: Running at jhw22 (test location), not yet deployed to ww87
- **Structure**: Uses local hokage modules (not external consumer yet)
- **Location**: Testing configuration - `location = "jhw22"`
- **Static IP**: 192.168.1.100
- **Services**: Basic server infrastructure, AdGuard Home (disabled)

### Target State

- **Hostname**: `hsb8` (Home Server Barta 8 - nod to WW87 without exposing address)
- **Folder**: `hosts/hsb8/`
- **Structure**: External hokage consumer from `github:pbek/nixcfg`
- **Configuration**: Uzumaki namespace for machine-specific config
- **Services**: Same services, declaratively managed
- **Location**: Still at jhw22 for testing, can be deployed to ww87 later
- **Benefits**: Consistent with csb0/csb1 pattern, aligned with new naming scheme

### Why hsb8 First? (Guinea Pig Strategy)

✅ **Low Risk**: Not yet in production at parents' home  
✅ **Test Location**: Currently at your home (easy access if issues)  
✅ **Fresh System**: Recently deployed, no critical dependencies  
✅ **No Users Yet**: Parents not relying on it yet  
✅ **Learn Early**: Test naming scheme + hokage migration before critical servers  
✅ **Rollback Easy**: Can rebuild completely if needed

This makes hsb8 the **perfect guinea pig** before migrating:

- hsb0 (miniserver99 - DNS/DHCP, 200+ days uptime)
- hsb1 (miniserver24 - Home automation)
- imac0, pcg0 (workstations)

---

## 📋 Final Naming Scheme

### Complete Infrastructure

```
SERVERS:
  csb0, csb1              ← Cloud Server Barta (Hetzner VPS) ✓ No change
  hsb0, hsb1, hsb8        ← Home Server Barta

WORKSTATIONS:
  imac0                   ← iMac (Markus)
  imac1                   ← iMac (Mai)
  mbp0                    ← MacBook Pro (Markus, future)

GAMING:
  pcg0                    ← Gaming PC (Markus)
  stm0, stm1              ← Steam Machines (future)
```

### Server Mapping

| Current        | New        | Location           | Role           | IP                | Priority       |
| -------------- | ---------- | ------------------ | -------------- | ----------------- | -------------- |
| `csb0`         | `csb0`     | Hetzner            | Cloud (stable) | cs0.barta.cm      | 5 (last)       |
| `csb1`         | `csb1`     | Hetzner            | Cloud (stable) | cs1.barta.cm      | 4              |
| `miniserver99` | `hsb0`     | Home (jhw22)       | DNS/DHCP       | 192.168.1.99      | 3              |
| `miniserver24` | `hsb1`     | Home (jhw22)       | Automation     | 192.168.1.101     | 2              |
| **`msww87`**   | **`hsb8`** | **Parents (ww87)** | **DNS/DHCP**   | **192.168.1.100** | **1 (first!)** |

---

## 🔄 Migration Components

### 1. Repository Changes

- [ ] Rename `hosts/msww87/` → `hosts/hsb8/`
- [ ] Update `flake.nix` nixosConfiguration name
- [ ] Update all internal references
- [ ] Update DHCP static lease hostname
- [ ] Update documentation

### 2. Hokage Consumer Pattern

- [ ] Add `nixcfg.url = "github:pbek/nixcfg"` to flake inputs
- [ ] Import hokage as external module (not local path)
- [ ] Set `hokage.useInternalInfrastructure = false`
- [ ] Set `hokage.useSecrets = false` (until agenix migration)
- [ ] Set `hokage.useSharedKey = false`
- [ ] Update hokage configuration block

### 3. System Configuration

- [ ] Update hostname in configuration.nix
- [ ] Update DHCP static lease entry (miniserver99)
- [ ] Update networking.hostName
- [ ] Preserve ZFS hostId: `cdbc4e20`
- [ ] Preserve location-based config logic
- [ ] Preserve SSH keys

### 4. Documentation Updates

- [ ] Update hosts/hsb8/README.md (rename from msww87)
- [ ] Update hosts/README.md with new naming table
- [ ] Update enable-ww87 script references
- [ ] Update SSH connection examples

---

## 🚨 Critical Considerations

### Low Risk Factors ✅

1. **Not Production**: Still at test location (jhw22)
2. **No Users**: Parents not using it yet
3. **Fresh Install**: Recently deployed (Nov 16, 2025)
4. **Easy Access**: Physical access at your home
5. **No Dependencies**: Other systems don't rely on it
6. **Rollback Simple**: Can completely rebuild

### Must Preserve

1. **Location Logic**: `location = "jhw22"` or `"ww87"` variable
2. **ZFS Host ID**: `cdbc4e20` (CRITICAL for ZFS)
3. **Static IP**: 192.168.1.100
4. **SSH Keys**: mba and gb user keys
5. **enable-ww87 Script**: Update for new hostname

### Benefits of Doing This First

- **Test naming scheme** before critical servers
- **Test hokage pattern** on fresh system
- **Document lessons** for hsb0/hsb1 migrations
- **Low stakes** - can start over if needed
- **Build confidence** for production migrations

---

## 📝 Pre-Migration Checklist

### Information Gathering ✅

- [x] Current hostname: msww87
- [x] Target hostname: hsb8
- [x] Static IP: 192.168.1.100
- [x] MAC address: 40:6c:8f:18:dd:24
- [x] ZFS hostId: cdbc4e20
- [x] Location: jhw22 (test), target: ww87
- [x] Users: mba, gb
- [x] Services: Basic server + AdGuard (disabled)

### Configuration Preparation ⏳

- [ ] Create `hosts/hsb8/` directory structure
- [ ] Copy configuration files from `hosts/msww87/`
- [ ] Update `configuration.nix` with new hostname
- [ ] Add external hokage input to `flake.nix`
- [ ] Set hokage external consumer flags
- [ ] Update DHCP static lease on miniserver99
- [ ] Update documentation references
- [ ] Test build locally: `nixos-rebuild build --flake .#hsb8`

### Backup Verification

- [ ] Verify system can be rebuilt from scratch (it's fresh)
- [ ] Document current configuration state
- [ ] Backup SSH keys (already in repo)

---

## 🔄 Hokage Consumer Pattern Migration

### From (Current - Local Modules)

```nix
# flake.nix - Uses local modules
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # Local modules in repo
  };
}

# hosts/msww87/configuration.nix
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
    ../../modules/hokage  # Local import
  ];

  hokage = {
    hostName = "msww87";
    # ... config
  };
}
```

### To (Target - External Consumer)

```nix
# flake.nix - External hokage consumer
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixcfg.url = "github:pbek/nixcfg";  # ← External hokage
  };

  outputs = { self, nixpkgs, nixcfg, ... }@inputs: {
    nixosConfigurations.hsb8 = nixpkgs.lib.nixosSystem {
      modules = [
        nixcfg.nixosModules.hokage  # ← External import
        ./hosts/hsb8/configuration.nix
      ];
      specialArgs = {
        inherit inputs;
        lib-utils = nixcfg.lib-utils;
      };
    };
  };
}

# hosts/hsb8/configuration.nix
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
  ];

  hokage = {
    hostName = "hsb8";
    role = "server-home";  # or "server-remote" when at ww87
    userLogin = "mba";
    useInternalInfrastructure = false;  # External consumer
    useSecrets = false;  # Until agenix migration
    useSharedKey = false;  # No omega keys
  };

  # Location-based configuration (preserve!)
  location = "jhw22";  # or "ww87"
}
```

### Key Benefits

1. **Upstream Updates**: Get hokage improvements from Patrizio automatically
2. **Cleaner Separation**: Your customizations in Uzumaki namespace (future)
3. **No Fork Maintenance**: Don't need to merge upstream changes
4. **Standardized**: Same pattern as csb0/csb1 and all external consumers
5. **Future-Proof**: Easy to add customizations without touching hokage

### Critical hsb8 Considerations

1. **Location Logic**: Preserve `location = "jhw22"` or `"ww87"` variable
2. **AdGuard Home**: Service enabled/disabled based on location
3. **Network Settings**: Gateway, DNS, domain depend on location
4. **SSH Keys**: Both mba and gb user access must be preserved
5. **enable-ww87 Script**: Must continue to work for future deployment

### Migration Steps (High Level)

1. **Rename folder** `hosts/msww87/` → `hosts/hsb8/`
2. **Update flake.nix** - Add external hokage input
3. **Import hokage module** from external flake (not local)
4. **Set external consumer flags** (`useInternalInfrastructure = false`, etc.)
5. **Update hostname** in configuration.nix
6. **Preserve location logic** (critical for deployment)
7. **Update DHCP static lease** on miniserver99
8. **Test build locally** before deploying
9. **Deploy to hsb8** and verify
10. **Document lessons learned** for hsb0/hsb1 migrations

---

## 🚀 Migration Procedure

### Phase 1: Repository Changes (Local)

```bash
# 1. Create migration branch
cd ~/Code/nixcfg
git checkout -b migration/hsb8-rename
git status

# 2. Rename directory
mv hosts/msww87 hosts/hsb8

# 3. Update configuration hostname
cd hosts/hsb8
# Edit configuration.nix: change hostName to "hsb8"
# Edit README.md: update all references msww87 → hsb8

# 4. Update flake.nix
cd ~/Code/nixcfg
# Edit flake.nix:
#   - Add nixcfg input (if not already present)
#   - Change nixosConfigurations.msww87 → hsb8
#   - Add hokage module import

# 5. Update DHCP static leases
# Edit secrets/static-leases-miniserver99.age
agenix -e secrets/static-leases-miniserver99.age
# Change: "hostname": "msww87" → "hsb8"

# 6. Update hosts/README.md
# Edit hosts/README.md with new naming table

# 7. Test build
nix flake check
nixos-rebuild build --flake .#hsb8

# 8. Commit changes
git add -A
git commit -m "Rename msww87 → hsb8 (new naming scheme + hokage consumer)"
```

### Phase 2: Deploy to hsb8

```bash
# 1. Deploy new configuration
nixos-rebuild switch --flake .#hsb8 \
  --target-host mba@192.168.1.100 \
  --use-remote-sudo

# Note: Hostname change may require reboot
# System will be briefly unavailable

# 2. Wait for reboot (if needed)
ping 192.168.1.100

# 3. Verify SSH access with new hostname
ssh mba@hsb8.lan
# or
ssh mba@192.168.1.100
```

### Phase 3: Verify System

```bash
# Connect to server
ssh mba@hsb8.lan

# 1. Check hostname
hostname
# Expected: hsb8

# 2. Check NixOS configuration
nixos-version
nixos-rebuild --version

# 3. Check ZFS (CRITICAL)
zpool status
# Verify: pool healthy, correct hostId

# 4. Check network
ip addr show enp2s0f0
# Expected: 192.168.1.100

# 5. Check location configuration
cat /etc/nixos/configuration.nix | grep location
# Expected: location = "jhw22";

# 6. Check services
systemctl status sshd
# AdGuard should be disabled (location = jhw22)

# 7. Check users
id mba
id gb
# Both should exist with correct UIDs

# 8. Test SSH keys
# Try connecting as gb from parents' machine (if available)
```

### Phase 4: Update miniserver99 DHCP

```bash
# Deploy updated DHCP config to miniserver99
nixos-rebuild switch --flake .#miniserver99 \
  --target-host mba@miniserver99 \
  --use-remote-sudo

# Wait for DHCP lease renewal
# Or force renewal on hsb8:
ssh mba@hsb8.lan "sudo dhclient -r enp2s0f0 && sudo dhclient enp2s0f0"

# Verify hostname resolution
dig hsb8.lan @192.168.1.99
ping hsb8.lan
```

---

## 🔄 Rollback Plan

### If Issues During Migration

#### Option 1: Rollback NixOS Configuration

```bash
# SSH to server
ssh mba@192.168.1.100

# List generations
nixos-rebuild list-generations

# Rollback to previous
sudo nixos-rebuild switch --rollback

# Or specific generation
sudo nixos-rebuild switch --switch-generation <N>
```

#### Option 2: Rebuild from Scratch

```bash
# This is a fresh system, easy to rebuild
# Use nixos-anywhere with original msww87 config

# From your Mac
cd ~/Code/nixcfg
git checkout main  # or previous working branch

nixos-anywhere --flake .#msww87 \
  mba@192.168.1.100
```

#### Option 3: Git Rollback

```bash
# Undo repository changes
cd ~/Code/nixcfg
git reset --hard HEAD~1  # Or specific commit

# Rebuild previous config
nixos-rebuild switch --flake .#msww87 \
  --target-host mba@192.168.1.100
```

---

## ✅ Post-Migration Verification

### Immediate Checks (Within 30 minutes)

- [ ] Hostname shows as `hsb8`
- [ ] SSH access working with new hostname
- [ ] ZFS pool healthy and accessible
- [ ] Network configuration correct (192.168.1.100)
- [ ] Location variable preserved
- [ ] User accounts (mba, gb) working
- [ ] SSH keys functional
- [ ] No unexpected errors in logs

### System Health

- [ ] `nixos-version` shows correct version
- [ ] `zpool status` shows pool healthy
- [ ] `systemctl --failed` shows no failed services
- [ ] Network DNS resolution working
- [ ] Can ping miniserver99 and miniserver24
- [ ] Can access from other machines on network

### Documentation Verification

- [ ] hosts/README.md updated with hsb8
- [ ] hosts/hsb8/README.md accurate
- [ ] enable-ww87.md references updated
- [ ] DHCP leases file updated
- [ ] flake.nix references correct

---

## 📝 Post-Migration Tasks

### Immediate

- [ ] Verify system stable for 24 hours
- [ ] Test location switch (jhw22 → ww87) if needed
- [ ] Update any scripts or aliases
- [ ] Document lessons learned below

### Documentation

- [ ] Update hosts/README.md with migration status
- [ ] Record any issues encountered
- [ ] Document hokage consumer setup
- [ ] Create template for hsb0/hsb1 migrations

### Cleanup

- [ ] Remove old Git branches (after verification)
- [ ] Clean up old NixOS generations
- [ ] Archive old documentation if needed

---

## 💡 Lessons Learned

Document here after migration:

### What Went Well

- [To be filled post-migration]

### What Could Be Improved

- [To be filled post-migration]

### Unexpected Issues

- [To be filled post-migration]

### Time Taken

- [To be filled post-migration]

### Apply to Future Migrations (hsb0, hsb1, imac0, pcg0)

- [To be filled post-migration]

---

## 🎯 Success Criteria

### Must Have (Blocking)

- ✅ Hostname changed to hsb8
- ✅ System boots and responds
- ✅ SSH access working
- ✅ ZFS pool healthy
- ✅ Network configuration correct
- ✅ Location logic preserved
- ✅ User accounts functional
- ✅ Hokage pattern working

### Should Have (Important)

- ✅ Documentation updated
- ✅ DHCP resolution working
- ✅ No service failures
- ✅ Git history clean

### Nice to Have (Optional)

- ✅ enable-ww87 script working
- ✅ Lessons documented for next migrations
- ✅ Template created for other hosts

---

## 📊 Risk Assessment

### Very Low Risk ✅

- Fresh system (deployed Nov 16, 2025)
- Not in production use
- No critical services
- No dependencies from other systems
- Easy physical access
- Can completely rebuild if needed
- Perfect guinea pig!

### Mitigation

1. **Fresh System**: Can rebuild from scratch
2. **Test Location**: At your home (easy access)
3. **No Users**: Parents not relying on it yet
4. **Rollback Ready**: Git + NixOS generations
5. **Documentation**: Detailed step-by-step plan

**Overall Risk**: 🟢 VERY LOW - Perfect for testing!

---

## ⏰ Timeline Summary

| Time  | Duration               | Task                                         |
| ----- | ---------------------- | -------------------------------------------- |
| 00:00 | 30 min                 | Repository changes (rename, update configs)  |
| 00:30 | 30 min                 | Test build locally, commit changes           |
| 01:00 | 15 min                 | Deploy to hsb8                               |
| 01:15 | 15 min                 | System reboot / wait for availability        |
| 01:30 | 30 min                 | Verify system, services, network             |
| 02:00 | 30 min                 | Update DHCP on miniserver99, test resolution |
| 02:30 | 30 min                 | Documentation, testing, final checks         |
| 03:00 | **Migration Complete** | Begin monitoring                             |

**Total Window**: 3 hours  
**Expected Downtime**: 15-30 minutes (during deploy + reboot)  
**Complexity**: 🟢 LOW (perfect learning opportunity!)

---

## 🎉 After Migration

### Immediate Benefits

1. **Naming Consistency**: Aligned with csb0/csb1 pattern
2. **Hokage Consumer**: External module pattern tested
3. **Documentation**: Template for other migrations
4. **Confidence**: Proven process for hsb0/hsb1
5. **hsb8 Nod**: Location reference without exposing address

### Next Steps

Once hsb8 stable:

1. Migrate hsb1 (miniserver24) - home automation
2. Migrate hsb0 (miniserver99) - DNS/DHCP (most critical)
3. Migrate workstations (imac0, pcg0)
4. Eventually deploy hsb8 to parents (ww87)

---

**STATUS**: 📝 Plan Complete - Ready to Execute (Guinea Pig!)  
**CONFIDENCE**: 🟢 VERY HIGH (low risk, fresh system)  
**NEXT**: Execute migration, document lessons, apply to production servers
