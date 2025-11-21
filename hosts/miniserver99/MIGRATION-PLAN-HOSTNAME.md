# miniserver99 → hsb0 Hostname Migration Plan

**Server**: miniserver99 (DNS/DHCP Infrastructure Server)  
**Migration Type**: Hostname Change + Directory Rename  
**From**: `miniserver99` → **To**: `hsb0` (Home Server Barta 0)  
**Risk Level**: 🔴 **HIGH** - Critical network infrastructure (DNS/DHCP for entire network)  
**Status**: 📋 **PLANNING** - No changes made yet  
**Created**: November 21, 2025  
**Last Updated**: November 21, 2025

---

## 🎯 MIGRATION OBJECTIVE

Rename `miniserver99` to `hsb0` as part of the unified naming scheme for all managed devices in the infrastructure.

**Key Constraint**: **ZERO DOWNTIME** - This server provides DNS/DHCP for the entire network!

**Scope**: This migration handles **ONLY the hostname change**. The hokage migration (local → external) will be done **separately** after this completes.

---

## 📊 NAMING SCHEME CONTEXT

### Current Name: `miniserver99`

- **Origin**: Mini-Server at IP .99
- **Issue**: Not aligned with new unified naming scheme
- **Status**: Legacy naming pattern

### New Name: `hsb0`

- **Format**: `hsb` + `0`
- **Meaning**: **H**ome **S**erver **B**arta + sequential number
- **Position**: First home server (hsb0), distinguishes from test servers (hsb8, future hsb1)
- **Benefits**: Consistent with cloud servers (csb0, csb1) and workstations (imac0, imac1)

### Related Naming Scheme

| Server       | Type          | Location | Owner  | Role                       |
| ------------ | ------------- | -------- | ------ | -------------------------- |
| **hsb0**     | Home Server 0 | jhw22    | Markus | **DNS/DHCP** (this server) |
| hsb1         | Home Server 1 | jhw22    | Markus | Home automation (future)   |
| hsb8         | Home Server 8 | jhw22    | Markus | Parents' home automation   |
| miniserver24 | Legacy name   | jhw22    | Markus | Home automation + MQTT     |
| csb0         | Cloud Server  | Hetzner  | Markus | Cloud infrastructure       |
| csb1         | Cloud Server  | Hetzner  | Markus | Cloud infrastructure       |

---

## 🔍 CURRENT STATE ANALYSIS

### Server Information

| Attribute         | Value                                    |
| ----------------- | ---------------------------------------- |
| **Hostname**      | `miniserver99`                           |
| **Target Name**   | `hsb0`                                   |
| **Role**          | DNS/DHCP server (AdGuard Home)           |
| **Criticality**   | 🔴 **CRITICAL** - Network infrastructure |
| **IP Address**    | `192.168.1.99` (will remain unchanged)   |
| **Uptime**        | 8+ days                                  |
| **NixOS Version** | 25.11.20251117.89c2b23 (Xantusia)        |
| **Services**      | AdGuard Home, SSH, NetworkManager        |
| **ZFS hostId**    | `dabfdb02` (must be preserved!)          |

### Critical Services

1. **AdGuard Home** (DNS Server)
   - Port: 53 (TCP/UDP)
   - Web UI: http://192.168.1.99:3000
   - Provides DNS for entire network
   - **Downtime Impact**: All network devices lose DNS resolution

2. **DHCP Server** (via AdGuard Home)
   - Port: 67 (UDP)
   - Range: 192.168.1.201 - 192.168.1.254
   - Manages static leases for all infrastructure
   - **Downtime Impact**: New devices can't get IP addresses

### What Changes

✅ **Changes**:

- Hostname: `miniserver99` → `hsb0`
- Configuration folder: `hosts/miniserver99/` → `hosts/hsb0/`
- flake.nix definition: `miniserver99 = mkServerHost` → `hsb0 = mkServerHost`
- `/etc/hosts` entries referencing `miniserver99`
- DNS hostname resolution
- SSH config entries (on other machines)
- Static lease file: `static-leases-miniserver99.age` → `static-leases-hsb0.age`
- agenix secret references

❌ **Does NOT Change**:

- IP address: `192.168.1.99` (stays the same!)
- ZFS hostId: `dabfdb02` (critical - must be preserved!)
- AdGuard Home configuration (DNS/DHCP settings)
- Services and functionality
- Network configuration
- Firewall rules
- Hardware configuration

---

## 🔍 COMPARISON TO hsb8 MIGRATION

### Similarities

| Aspect               | hsb8 (msww87 → hsb8)  | miniserver99 (→ hsb0) |
| -------------------- | --------------------- | --------------------- |
| **Migration Type**   | Hostname + folder     | Hostname + folder     |
| **Hardware**         | Mac mini 2011         | Mac mini 2011         |
| **Storage**          | ZFS (hostId required) | ZFS (hostId required) |
| **NixOS Version**    | 25.11                 | 25.11                 |
| **Hokage Module**    | Local (not changed)   | Local (not changed)   |
| **Migration Phases** | 6 phases              | 6 phases (similar)    |
| **Test Build**       | On miniserver24       | On miniserver24       |
| **Deployment**       | Feature branch first  | Feature branch first  |

### Critical Differences

| Aspect                  | hsb8 (msww87 → hsb8)                    | miniserver99 (→ hsb0)                                                  |
| ----------------------- | --------------------------------------- | ---------------------------------------------------------------------- |
| **Risk Level**          | 🟡 **MEDIUM** (test server)             | 🔴 **HIGH** (critical DNS/DHCP)                                        |
| **Service Type**        | Home automation (future)                | **DNS/DHCP** (network infrastructure)                                  |
| **Downtime Impact**     | Low (not in production)                 | **CRITICAL** (entire network loses DNS)                                |
| **Rollback Urgency**    | Can wait hours                          | **Must be instant** (<1 min)                                           |
| **Testing Strategy**    | Deploy, then verify                     | **Extensive pre-deployment testing required**                          |
| **Physical Access**     | Easy (at your home)                     | Easy (at your home) ✅                                                 |
| **Deployment Window**   | Anytime                                 | **Evening/weekend preferred** (when network usage is lower)            |
| **Verification Time**   | 5 minutes acceptable                    | **Must verify within 30 seconds** (DNS failures noticed immediately)   |
| **Users Affected**      | None (pre-production)                   | **All household members** (Markus, Mailina, guests)                    |
| **Configuration Lines** | ~400 lines, location-based with scripts | **~280 lines**, AdGuard-centric                                        |
| **Static Leases**       | Manages hsb8 lease (1 entry)            | **Manages ALL leases** (10-15 devices) - must rename secret file       |
| **/etc/hosts Impact**   | Only hsb8 references                    | **hsb0 + ALL other devices reference miniserver99** in their configs   |
| **Secret Files**        | `static-leases-miniserver99.age` (edit) | `static-leases-miniserver99.age` → `static-leases-hsb0.age` (rename)   |
| **Location Scripts**    | Has enable-ww87 script (update)         | No location scripts ✅                                                 |
| **Lessons Available**   | N/A (first hostname migration)          | **Can apply hsb8 experience** (folder rename, flake changes, rollback) |

### What We Learned from hsb8

1. ✅ **Feature Branch Strategy**: Deploy from branch, verify, THEN merge to main
2. ✅ **Test Build First**: miniserver24 is the right choice (16GB RAM, fast)
3. ✅ **Separate Commits**: One commit per phase for easy rollback
4. ✅ **Global Search**: Use `rg -n <old-name>` to find ALL references
5. ✅ **Secret File Updates**: Must manually edit .age files with `agenix -e`
6. ✅ **Zero Downtime**: NixOS generation switch is fast and reliable
7. ✅ **Immediate Documentation**: Update docs right after deployment
8. ✅ **Keep Hokage Separate**: Don't mix hostname and hokage migrations

---

## 📋 MIGRATION PLAN

### Pre-Migration Checklist

#### 1. Risk Assessment ✅

- [x] Criticality level: 🔴 **HIGH** (DNS/DHCP infrastructure)
- [x] Downtime tolerance: **ZERO** (network breaks without DNS)
- [x] Physical access: ✅ Available (at jhw22)
- [x] Backup DNS: ❌ Not configured (would require device reconfiguration)
- [x] Rollback method: NixOS generations + Git branches (instant)
- [x] Testing server: miniserver24 available ✅

#### 2. Network Impact Assessment

- [x] Affected devices: **All network devices** (~10-15 devices)
- [x] Affected users: **All household members**
- [x] Affected services: DNS resolution, DHCP assignments, static leases
- [x] DNS fallback: Devices may have Cloudflare (1.1.1.1) as secondary
- [x] DHCP impact: Existing leases continue during migration (no immediate impact)
- [x] Hostname resolution: All devices that reference `miniserver99` in SSH config, /etc/hosts

#### 3. Timing Considerations

**Best Time**:

- 🌙 **Weekend afternoon (2-4 PM)** - Recommended (Markus available, good visibility)
- 📅 Evening (8-10 PM) - Alternative (lower network usage)
- ⚠️ **Avoid**: During work hours, video calls, streaming

**Estimated Duration**: 45-60 minutes (including verification)

#### 4. Backup Strategy

- [x] **NixOS Generations**: Automatic rollback available
- [x] **Git Branches**: Feature branch for testing before main
- [x] **Configuration Backup**: Current config in git
- [x] **Service State**: AdGuard Home settings in git (declarative)
- [x] **DHCP Leases**: Encrypted in `static-leases-miniserver99.age` (will be renamed)

#### 5. Communication Plan

- [ ] **Inform household members**: "DNS server maintenance, brief internet interruption possible"
- [ ] **Expected duration**: "30-45 minutes, internet may be briefly affected"
- [ ] **What to do if issues**: "Tell Markus immediately"

#### 6. Dependencies to Update

Files/locations that reference `miniserver99`:

- [ ] `flake.nix` - Server definition
- [ ] `hosts/miniserver99/` - Directory name
- [ ] `hosts/miniserver99/configuration.nix` - hostname setting
- [ ] `secrets/static-leases-miniserver99.age` - Secret file name
- [ ] `secrets/secrets.nix` - Secret reference
- [ ] `/etc/hosts` on ALL servers - hsb8, miniserver24, mba-gaming-pc reference miniserver99
- [ ] SSH configs on workstations - May have `miniserver99` shortcuts
- [ ] Documentation - README files, migration plans

---

## 🚀 EXECUTION PHASES

### Phase 0: Prepare Feature Branch

**Status**: ⏸️ Not Started  
**Duration**: 2 minutes  
**Risk**: 🟢 **LOW** (local git only)

**Actions**:

```bash
cd ~/Code/nixcfg

# Create feature branch for hostname migration
git checkout -b feat/miniserver99-to-hsb0
echo "✓ Created feature branch"

# Verify we're on the branch
git branch --show-current
# Should show: feat/miniserver99-to-hsb0
```

**Verification**:

- [ ] Feature branch created
- [ ] Branch name correct: `feat/miniserver99-to-hsb0`
- [ ] Working directory clean

**Rollback**: `git checkout main && git branch -D feat/miniserver99-to-hsb0`

---

### Phase 1: Rename Directory

**Status**: ⏸️ Not Started  
**Duration**: 1 minute  
**Risk**: 🟢 **LOW** (local change only, not deployed yet)

**Actions**:

```bash
cd ~/Code/nixcfg

# Rename the directory
git mv hosts/miniserver99 hosts/hsb0
echo "✓ Directory renamed"

# Verify
ls -la hosts/ | grep hsb0

# Commit
git add -A
git commit -m "refactor(miniserver99): rename directory miniserver99 → hsb0 (step 1/6)"
```

**Verification**:

- [ ] Directory `hosts/hsb0/` exists
- [ ] Directory `hosts/miniserver99/` does not exist
- [ ] All files moved correctly
- [ ] Git commit successful

**Rollback**: `git reset --hard HEAD~1`

---

### Phase 2: Update flake.nix

**Status**: ⏸️ Not Started  
**Duration**: 2 minutes  
**Risk**: 🟢 **LOW** (local change only, not deployed yet)

**File**: `flake.nix` (line ~211)

**Current**:

```nix
miniserver99 = mkServerHost "miniserver99" [ disko.nixosModules.disko ];
```

**Target**:

```nix
# DNS/DHCP Server (AdGuard Home) - Home Server Barta 0
hsb0 = mkServerHost "hsb0" [ disko.nixosModules.disko ];
```

**Actions**:

```bash
cd ~/Code/nixcfg

# Update flake.nix
nano flake.nix
# Find line ~211: miniserver99 = mkServerHost "miniserver99"
# Replace with: hsb0 = mkServerHost "hsb0"
# Add comment above

# Verify change
grep -n "hsb0 = mkServerHost" flake.nix
grep -c "miniserver99 = mkServerHost" flake.nix  # Should be 0

# Commit
git add flake.nix
git commit -m "refactor(miniserver99): update flake.nix miniserver99 → hsb0 (step 2/6)"
```

**Verification**:

- [ ] `hsb0 = mkServerHost "hsb0"` exists in flake.nix
- [ ] No `miniserver99 = mkServerHost` in flake.nix
- [ ] Comment added for clarity
- [ ] Git commit successful

**Rollback**: `git reset --hard HEAD~1`

---

### Phase 3: Update configuration.nix Hostname

**Status**: ⏸️ Not Started  
**Duration**: 1 minute  
**Risk**: 🟢 **LOW** (local change only, not deployed yet)

**File**: `hosts/hsb0/configuration.nix` (line 276)

**Current**:

```nix
hokage = {
  hostName = "miniserver99";
  zfs.hostId = "dabfdb02";
  audio.enable = false;
  serverMba.enable = true;
};
```

**Target**:

```nix
hokage = {
  hostName = "hsb0";  # ← CHANGED
  zfs.hostId = "dabfdb02";  # ← KEEP UNCHANGED! Critical for ZFS
  audio.enable = false;
  serverMba.enable = true;
};
```

**Actions**:

```bash
cd ~/Code/nixcfg

# Update hostname in configuration.nix
sed -i '' 's/hostName = "miniserver99";/hostName = "hsb0";/' hosts/hsb0/configuration.nix

# Verify
grep 'hostName = "hsb0"' hosts/hsb0/configuration.nix
grep 'zfs.hostId = "dabfdb02"' hosts/hsb0/configuration.nix  # MUST still exist!

# Commit
git add hosts/hsb0/configuration.nix
git commit -m "refactor(miniserver99): update hostname miniserver99 → hsb0 (step 3/6)"
```

**Verification**:

- [ ] `hostName = "hsb0"` in configuration.nix
- [ ] `zfs.hostId = "dabfdb02"` **UNCHANGED** (critical!)
- [ ] No other unintended changes
- [ ] Git commit successful

**Rollback**: `git reset --hard HEAD~1`

---

### Phase 4: Update /etc/hosts References

**Status**: ⏸️ Not Started  
**Duration**: 2 minutes  
**Risk**: 🟢 **LOW** (local change only, not deployed yet)

**File**: `hosts/hsb0/configuration.nix` (line 196-199)

**Current**:

```nix
# This DNS/DHCP server itself - self-resolution for services and management
"192.168.1.99" = [
  "miniserver99"
  "miniserver99.lan"
];
```

**Target**:

```nix
# This DNS/DHCP server itself - self-resolution for services and management
"192.168.1.99" = [
  "hsb0"
  "hsb0.lan"
];
```

**Actions**:

```bash
cd ~/Code/nixcfg

# Update /etc/hosts entry in hsb0's configuration.nix
nano hosts/hsb0/configuration.nix
# Find lines 196-199 with "miniserver99" and "miniserver99.lan"
# Replace with "hsb0" and "hsb0.lan"

# Verify
grep -A 2 '192.168.1.99' hosts/hsb0/configuration.nix | grep hsb0

# Commit
git add hosts/hsb0/configuration.nix
git commit -m "refactor(miniserver99): update /etc/hosts references hsb0 (step 4/6)"
```

**Verification**:

- [ ] `"hsb0"` in /etc/hosts entry for 192.168.1.99
- [ ] `"hsb0.lan"` in /etc/hosts entry for 192.168.1.99
- [ ] No `"miniserver99"` references in networking.hosts
- [ ] Git commit successful

**Rollback**: `git reset --hard HEAD~1`

---

### Phase 5: Rename and Update Secret Files

**Status**: ⏸️ Not Started  
**Duration**: 5 minutes  
**Risk**: 🟡 **MEDIUM** - Involves encrypted secrets (but tested before deployment)

**Files**:

1. `secrets/static-leases-miniserver99.age` → `secrets/static-leases-hsb0.age`
2. `secrets/secrets.nix` - Update secret definition
3. `hosts/hsb0/configuration.nix` - Update secret reference

**⚠️ CRITICAL**: Secret files contain all DHCP leases. Must be handled carefully!

**Actions**:

```bash
cd ~/Code/nixcfg

# 1. Rename the encrypted secret file
git mv secrets/static-leases-miniserver99.age secrets/static-leases-hsb0.age
echo "✓ Renamed secret file"

# 2. Update secrets.nix
nano secrets/secrets.nix
# Find: "static-leases-miniserver99.age" = ...
# Replace with: "static-leases-hsb0.age" = ...

# 3. Update configuration.nix secret reference
nano hosts/hsb0/configuration.nix
# Find: age.secrets.static-leases-miniserver99 = {
#       file = ../../secrets/static-leases-miniserver99.age;
# Replace with:
#       age.secrets.static-leases-hsb0 = {
#       file = ../../secrets/static-leases-hsb0.age;

# Also update the preStart script reference:
# Find: static_leases_file="/run/agenix/static-leases-miniserver99"
# Replace: static_leases_file="/run/agenix/static-leases-hsb0"

# Verify changes
ls -la secrets/ | grep static-leases-hsb0.age  # Should exist
ls -la secrets/ | grep static-leases-miniserver99.age  # Should NOT exist
grep "static-leases-hsb0" secrets/secrets.nix
grep "static-leases-hsb0" hosts/hsb0/configuration.nix

# Commit
git add secrets/secrets.nix secrets/static-leases-hsb0.age hosts/hsb0/configuration.nix
git commit -m "refactor(miniserver99): rename secret files miniserver99 → hsb0 (step 5/6)"
```

**Verification**:

- [ ] Secret file renamed: `secrets/static-leases-hsb0.age`
- [ ] `secrets.nix` updated with new filename
- [ ] `configuration.nix` secret reference updated (2 places)
- [ ] No `miniserver99` references in secret config
- [ ] Git commit successful

**Rollback**: `git reset --hard HEAD~1`

---

### Phase 6: Global Search and Cleanup

**Status**: ⏸️ Not Started  
**Duration**: 3 minutes  
**Risk**: 🟢 **LOW** (verification and documentation)

**Actions**:

```bash
cd ~/Code/nixcfg

# Search for any remaining miniserver99 references
echo "=== Searching for remaining 'miniserver99' references ==="
rg -n miniserver99 --type nix --type md

# Expected results (should be minimal or zero):
# - This migration plan (MIGRATION-PLAN-HOSTNAME.md) - OK, historical reference
# - hosts/README.md - May need update
# - Other documentation - May need update

# If found in configs/flake, fix them now!
# If found in docs, update them

# Update hosts/README.md if needed
nano hosts/README.md
# Update any miniserver99 references to hsb0

# Commit any doc updates
git add hosts/README.md
git commit -m "docs(miniserver99): update README references miniserver99 → hsb0 (step 6/6)"
```

**Verification**:

- [ ] No `miniserver99` in flake.nix (except comments)
- [ ] No `miniserver99` in hosts/hsb0/configuration.nix (except comments)
- [ ] No `miniserver99` in secrets/secrets.nix
- [ ] Documentation updated
- [ ] All commits successful

**Rollback**: `git reset --hard HEAD~1`

---

### Phase 7: Test Build on miniserver24

**Status**: ⏸️ Not Started  
**Duration**: 5 minutes  
**Risk**: 🟢 **LOW** (test build only, no deployment)

**Rationale**: Test on miniserver24 (not your Mac) to:

- ✅ Native Linux build (no macOS cross-platform issues)
- ✅ Catches Linux-specific problems
- ✅ 16GB RAM (2x more than hsb0's 8GB)
- ✅ Proven reliable from hsb8 migration

**Actions**:

```bash
# Push feature branch to GitHub
cd ~/Code/nixcfg
git push -u origin feat/miniserver99-to-hsb0

# SSH to miniserver24 (test build server)
ssh mba@miniserver24.lan

# On miniserver24:
cd ~/Code/nixcfg
git fetch
git checkout feat/miniserver99-to-hsb0
git pull

echo "=== Testing hsb0 build ==="
nixos-rebuild build --flake .#hsb0 --show-trace

# If build fails:
# 1. Check error messages carefully
# 2. Verify all references changed correctly
# 3. Check secret file paths
# 4. Fix on Mac, push, pull, retry

echo "✓ Build successful!"

# Verify build output
ls -la result/
readlink result  # Shows /nix/store path

# Exit back to Mac
exit
```

**Expected Result**: Build should succeed

**Common Issues**:

- ❌ `error: attribute 'miniserver99' missing` → Good! Means rename worked
- ❌ `error: path '/nix/store/.../hosts/hsb0/...' does not exist` → File missing, check git
- ❌ Secret file not found → Check renamed paths

**Verification**:

- [ ] Build completes without errors
- [ ] No warnings about missing files
- [ ] Result path created: `/nix/store/...-nixos-system-hsb0-...`
- [ ] hsb0 hostname in result

**Rollback**: N/A (no changes to live server)

---

### Phase 8: Deploy to hsb0 (CRITICAL PHASE)

**Status**: ⏸️ Not Started  
**Duration**: 5-10 minutes  
**Risk**: 🔴 **HIGH** - This is the critical deployment!

**⚠️ CRITICAL SAFETY MEASURES**:

1. **Inform household members** (brief DNS interruption possible)
2. **Have physical access** to hsb0 (miniserver99) ready
3. **Keep terminal open** for instant rollback if needed
4. **Monitor network connectivity** from another device

**Pre-Deployment Checks**:

```bash
# SSH to current miniserver99 (will be hsb0 after deployment)
ssh mba@192.168.1.99

# 1. Verify current state
hostname  # Should be: miniserver99
systemctl is-active adguardhome  # Should be: active
nixos-version  # Note current version

# 2. Check Git repository
cd ~/Code/nixcfg
git status  # Should be clean
git fetch
git checkout feat/miniserver99-to-hsb0
git pull  # Get latest changes from feature branch

# 3. Verify changes
hostname  # Still miniserver99 (will change after switch)
grep 'hostName = "hsb0"' hosts/hsb0/configuration.nix  # Should find it
grep -c "miniserver99" flake.nix  # Should be 0 (or only in comments)

# 4. Pre-deployment test (dry-build)
nixos-rebuild dry-build --flake .#hsb0
# Should succeed

# 5. Verify ZFS hostId is preserved
grep 'zfs.hostId = "dabfdb02"' hosts/hsb0/configuration.nix
# CRITICAL: Must exist!
```

**Deployment Execution**:

```bash
# Still on miniserver99 (about to become hsb0):

echo "=== DEPLOYING HOSTNAME CHANGE: miniserver99 → hsb0 ==="
echo "Starting at: $(date)"

# Deploy!
sudo nixos-rebuild switch --flake .#hsb0

# This will:
# - Build new configuration with hostname hsb0
# - Switch system to new generation
# - Update /etc/hostname
# - Restart affected services
# - Should take 30-60 seconds

echo "Deployment completed at: $(date)"
```

**Immediate Verification** (within 30 seconds):

```bash
# 1. Check new hostname
hostname
# Should be: hsb0 ✅

# 2. Check AdGuard Home
systemctl status adguardhome
# Should be: active (running) ✅

# 3. Test DNS locally
nslookup google.com 127.0.0.1
# Should resolve ✅

# 4. Check web UI
curl -I http://192.168.1.99:3000
# Should return HTTP 200 ✅

# 5. Verify system
nixos-version
systemctl is-system-running
# Should be: running ✅

# 6. Check ZFS
zpool status
# Should show pool healthy ✅
```

**Test from Another Device** (immediately):

```bash
# From your Mac:

# 1. DNS resolution
nslookup google.com 192.168.1.99
# Should resolve ✅

# 2. DNS rewrite (csb0 test)
nslookup csb0 192.168.1.99
# Should return cs0.barta.cm ✅

# 3. Internet connectivity
ping -c 3 google.com
# Should work ✅

# 4. SSH still works (old name via IP)
ssh mba@192.168.1.99 'echo "SSH OK"'
# Should work ✅

# 5. New hostname resolves (after DNS update)
ssh mba@hsb0.lan 'echo "New hostname OK"'
# May take a few minutes for DNS propagation
```

**Verification**:

- [ ] Hostname changed: `hostname` returns `hsb0`
- [ ] AdGuard Home: active and running
- [ ] DNS resolution: working locally (127.0.0.1)
- [ ] DNS resolution: working from network (192.168.1.99)
- [ ] DNS rewrites: csb0 → cs0.barta.cm working
- [ ] DHCP: systemctl status shows DHCP active
- [ ] Web UI: http://192.168.1.99:3000 accessible
- [ ] SSH: Access working (via IP)
- [ ] System: `systemctl is-system-running` returns "running"
- [ ] ZFS: Pool healthy
- [ ] Internet: Other devices can access internet
- [ ] Static leases: Known devices still have correct IPs

**If ANY check fails**:

```bash
# IMMEDIATE ROLLBACK!
sudo nixos-rebuild switch --rollback

# Verify rollback worked:
hostname  # Should be back to miniserver99
systemctl is-active adguardhome
nslookup google.com 127.0.0.1

# If still broken, reboot:
sudo reboot
# (Will boot to previous generation automatically)
```

**Rollback**: `sudo nixos-rebuild switch --rollback` or reboot

---

### Phase 9: Verify and Merge to Main

**Status**: ⏸️ Not Started  
**Duration**: 5 minutes  
**Risk**: 🟢 **LOW** (verification and git operations)

**Actions**:

```bash
# On hsb0 (via SSH):
ssh mba@192.168.1.99  # Or ssh mba@hsb0.lan once DNS updated

# Extended verification
echo "=== Extended Verification ==="
hostname
nixos-version
uptime
systemctl is-system-running

# Check critical services
systemctl is-active adguardhome
systemctl is-active NetworkManager
systemctl is-active sshd

# Check ZFS
zpool status
zfs list

echo "✅ All verifications complete on hsb0!"

# Exit back to Mac
exit

# On Mac:
cd ~/Code/nixcfg

# Merge feature branch to main
git checkout main
git merge feat/miniserver99-to-hsb0 --no-ff -m "feat(miniserver99): complete hostname migration miniserver99 → hsb0

- Renamed directory: hosts/miniserver99 → hosts/hsb0
- Updated flake.nix: hsb0 = mkServerHost
- Updated hostname in configuration.nix
- Updated /etc/hosts references
- Renamed secret files: static-leases-miniserver99.age → static-leases-hsb0.age
- Updated documentation

Migration completed successfully with zero downtime.
All services verified operational: DNS, DHCP, SSH, AdGuard Home.
"

# Push to GitHub
git push

# Clean up feature branch
git branch -d feat/miniserver99-to-hsb0
git push origin --delete feat/miniserver99-to-hsb0

echo "✅ Migration merged to main and feature branch cleaned up"
```

**Verification**:

- [ ] All services verified on hsb0
- [ ] Feature branch merged to main
- [ ] Changes pushed to GitHub
- [ ] Feature branch deleted (local and remote)
- [ ] Git history clean

**Rollback**: N/A (already deployed successfully)

---

### Phase 10: Update Other Servers' /etc/hosts

**Status**: ⏸️ Not Started  
**Duration**: 10 minutes  
**Risk**: 🟡 **MEDIUM** - Requires updates on multiple servers

**Rationale**: Other servers (hsb8, miniserver24, mba-gaming-pc) have `miniserver99` in their `/etc/hosts`. These need to be updated to `hsb0`.

**Servers to Update**:

1. **hsb8** - `hosts/hsb8/configuration.nix`
2. **miniserver24** - `hosts/miniserver24/configuration.nix`
3. **mba-gaming-pc** - `hosts/mba-gaming-pc/configuration.nix`

**Actions**:

```bash
cd ~/Code/nixcfg

# Search for miniserver99 in other hosts' configs
rg "miniserver99" hosts/*/configuration.nix

# Update each server's configuration.nix
# Replace "miniserver99" with "hsb0" in networking.hosts entries

# Example for hsb8:
nano hosts/hsb8/configuration.nix
# Find: "miniserver99" and "miniserver99.lan"
# Replace: "hsb0" and "hsb0.lan"

# Repeat for miniserver24 and mba-gaming-pc

# Commit all changes
git add hosts/*/configuration.nix
git commit -m "refactor(all): update /etc/hosts references miniserver99 → hsb0"
git push

# Deploy to each server (can be done gradually):
# For hsb8:
ssh mba@hsb8.lan 'cd ~/Code/nixcfg && git pull && sudo nixos-rebuild switch --flake .#hsb8'

# For miniserver24:
ssh mba@miniserver24.lan 'cd ~/Code/nixcfg && git pull && sudo nixos-rebuild switch --flake .#miniserver24'

# For mba-gaming-pc:
ssh mba@mba-gaming-pc.lan 'cd ~/Code/nixcfg && git pull && sudo nixos-rebuild switch --flake .#mba-gaming-pc'
```

**Verification**:

- [ ] All servers' configs updated
- [ ] Changes committed and pushed
- [ ] Each server deployed successfully
- [ ] Each server can resolve `hsb0.lan`

**Note**: This phase can be done later if needed. The hostname migration on hsb0 itself is complete and functional.

---

### Phase 11: Update Documentation

**Status**: ⏸️ Not Started  
**Duration**: 5 minutes  
**Risk**: 🟢 **LOW** (documentation only)

**Files to Update**:

1. **`hosts/hsb0/MIGRATION-PLAN-HOSTNAME.md`** (this file)
   - Mark status as ✅ COMPLETE
   - Add completion date
   - Note any issues encountered

2. **`hosts/hsb0/README.md`**
   - Update hostname references
   - Add migration note
   - Update changelog

3. **`hosts/README.md`**
   - Update server table with hsb0
   - Note migration complete

**Actions**:

```bash
cd ~/Code/nixcfg

# Update documentation
# (Detailed edits based on actual migration results)

git add hosts/hsb0/*.md hosts/README.md
git commit -m "docs(hsb0): hostname migration complete miniserver99 → hsb0 ✅"
git push
```

**Verification**:

- [ ] This file marked as COMPLETE
- [ ] README.md updated with new hostname
- [ ] Changelog updated
- [ ] All documentation committed and pushed

**Rollback**: N/A (documentation only)

---

## 🛡️ COMPREHENSIVE ROLLBACK PLAN

### Scenario 1: Build Fails (Phase 7)

**Impact**: None (test build only)

**Action**:

1. Review error messages
2. Fix issues in git
3. Commit fixes
4. Push and retry build

**No Rollback Needed** (no changes to hsb0)

### Scenario 2: Deployment Succeeds, AdGuard Home Stops

**Impact**: 🔴 **CRITICAL** - No DNS/DHCP for network

**Action**:

```bash
# IMMEDIATE (within 10 seconds):
sudo nixos-rebuild switch --rollback

# Verify:
hostname  # Should be back to miniserver99
systemctl is-active adguardhome
nslookup google.com 127.0.0.1

# If still broken:
sudo reboot
# (Previous generation will boot automatically)
```

**Expected Recovery Time**: <1 minute

### Scenario 3: Deployment Succeeds, DNS Broken

**Impact**: 🔴 **HIGH** - Network can't resolve domains

**Symptoms**:

- `nslookup google.com 192.168.1.99` fails
- Devices can't access internet by name
- IP addresses still work

**Action**:

```bash
# IMMEDIATE:
sudo nixos-rebuild switch --rollback

# Test:
hostname  # Back to miniserver99
nslookup google.com 127.0.0.1

# If still broken, check service:
systemctl restart adguardhome
systemctl status adguardhome

# If persistent:
sudo reboot
```

**Expected Recovery Time**: <2 minutes

### Scenario 4: Deployment Succeeds, ZFS Not Mounting

**Impact**: 🔴 **CRITICAL** - System may not boot properly

**Symptoms**:

- ZFS pools not imported
- `/nix/store` missing
- System not bootable

**Root Cause**: `zfs.hostId` was accidentally changed or removed

**Prevention**: Phase 3 verification MUST confirm `zfs.hostId = "dabfdb02"` unchanged

**Action**:

```bash
# If system is responsive:
sudo nixos-rebuild switch --rollback

# If system won't boot:
# 1. Reboot and select previous generation in GRUB
# 2. Once booted, rollback:
sudo nixos-rebuild switch --rollback

# Verify ZFS:
zpool status
zpool list
```

**Expected Recovery Time**: 2-5 minutes

### Scenario 5: Deployment Succeeds, Static Leases Lost

**Impact**: 🟡 **MEDIUM** - DHCP broken for known devices

**Symptoms**:

- New devices can't get IPs
- Known devices may lose static IPs after lease expiry
- DHCP working but without static assignments

**Root Cause**: Secret file rename failed or path incorrect

**Action**:

```bash
# Check if secret file is being loaded:
ls -la /run/agenix/static-leases-hsb0
# Should exist

# Check AdGuard Home logs:
journalctl -u adguardhome -n 50

# If file missing, rollback:
sudo nixos-rebuild switch --rollback

# Verify static leases restored:
curl http://192.168.1.99:3000/control/dhcp/status | jq .static_leases
```

**Expected Recovery Time**: <2 minutes

### Scenario 6: Complete System Failure

**Impact**: 🔴 **CRITICAL** - Server not responding at all

**Symptoms**:

- No SSH response
- No DNS response
- No web UI
- No ping response

**Action**:

```bash
# IMMEDIATE: Physical access required
# 1. Connect monitor and keyboard
# 2. If system is responsive, login and:
sudo nixos-rebuild switch --rollback
# or
sudo reboot

# 3. If system is frozen:
# Hard reset (power cycle)
# Previous generation boots automatically

# 4. If boot fails:
# Select previous generation in GRUB menu
# (Generations listed at boot)
```

**Expected Recovery Time**: 3-5 minutes (physical access required)

---

## 📊 SUCCESS CRITERIA

All criteria must be met to declare migration successful:

### Critical (Must Pass)

- [ ] Hostname changed: `hostname` returns `hsb0`
- [ ] AdGuard Home service active and running
- [ ] DNS resolution working (external domains)
- [ ] DNS resolution working (internal .lan domains)
- [ ] DNS rewrites working (csb0 → cs0.barta.cm)
- [ ] DHCP server active
- [ ] Static leases intact (known devices have correct IPs)
- [ ] Web UI accessible (http://192.168.1.99:3000)
- [ ] SSH access working (via 192.168.1.99)
- [ ] System status: running
- [ ] ZFS pools healthy

### Configuration (Must Verify)

- [ ] `flake.nix` has `hsb0 = mkServerHost "hsb0"`
- [ ] No `miniserver99 = mkServerHost` in flake.nix
- [ ] `hosts/hsb0/configuration.nix` has `hostName = "hsb0"`
- [ ] `zfs.hostId = "dabfdb02"` **UNCHANGED** (critical!)
- [ ] Secret file renamed: `static-leases-hsb0.age`
- [ ] Git repository clean and pushed to main

### Network (Must Verify)

- [ ] Other devices can resolve DNS
- [ ] Internet connectivity working for all devices
- [ ] New DHCP assignments working (if testable)
- [ ] Static leases still correct
- [ ] hsb0.lan resolves to 192.168.1.99

### Documentation (Should Complete)

- [ ] This migration plan marked complete
- [ ] README.md updated with hsb0
- [ ] Changelog updated
- [ ] Lessons learned documented

---

## 🎓 LESSONS FROM hsb8 MIGRATION

### What Worked Well

1. ✅ **Feature Branch Strategy**: Deploy from branch, verify, THEN merge to main
2. ✅ **Test Build on miniserver24**: Caught issues before deployment
3. ✅ **Separate Commits**: Easy to track and rollback individual phases
4. ✅ **Global Search (`rg -n`)**: Found all references that needed updating
5. ✅ **Zero Downtime**: NixOS generation switch is fast (<1 minute)
6. ✅ **Documentation First**: Clear plan made execution smooth
7. ✅ **Keep Migrations Separate**: Hostname separate from hokage migration

### What to Apply Here

1. 🎯 **Same Build Server**: Use miniserver24 (16GB RAM, proven reliable)
2. 🎯 **Same Branch Strategy**: Feature branch → test → deploy → verify → merge
3. 🎯 **Same Commit Strategy**: Separate commits per phase
4. 🎯 **Same Search Strategy**: Use `rg -n miniserver99` to find ALL references
5. 🎯 **Immediate Documentation**: Update docs right after deployment

### Additional Precautions for hsb0

1. ⚠️ **Higher Stakes**: DNS/DHCP is critical infrastructure (hsb8 was test server)
2. ⚠️ **Inform Users**: Brief household members (wasn't needed for hsb8)
3. ⚠️ **Faster Verification**: Must confirm DNS within 30 seconds (hsb8 had 5 minutes)
4. ⚠️ **Physical Access Ready**: Have monitor/keyboard nearby (extra safety)
5. ⚠️ **ZFS hostId**: MUST preserve `dabfdb02` (both hsb8 and hsb0 have ZFS)
6. ⚠️ **Secret File Rename**: More critical (hsb0 manages ALL DHCP leases)
7. ⚠️ **Weekend Deployment**: Lower network usage (hsb8 could be anytime)

---

## 📅 RECOMMENDED EXECUTION SCHEDULE

### Option A: Weekend Afternoon (Recommended) ✅

**When**: Saturday or Sunday, 2-4 PM  
**Duration**: 45-60 minutes  
**Pros**:

- Markus fully available
- Household members around (can inform easily)
- Not during critical work activities
- Daytime (good visibility, alert)
- Can take time to verify thoroughly
- Can fix issues without work pressure

**Cons**:

- Might interrupt weekend activities

### Option B: Weekday Evening

**When**: Tuesday-Thursday, 8-10 PM  
**Duration**: 45-60 minutes  
**Pros**:

- Lower network usage (less streaming)
- Household winding down
- Can inform members in advance

**Cons**:

- Later in day (slightly less alert)
- Next day is work day (less recovery time if issues)

### NOT Recommended

- ❌ **Mornings**: High work activity (video calls, etc.)
- ❌ **During work hours**: Critical for work-from-home
- ❌ **Late night**: Too tired, household asleep (can't inform)
- ❌ **When away from home**: Need physical access as safety net
- ❌ **Monday**: Start of work week (not ideal for potential issues)
- ❌ **Friday evening**: Weekend starts, want to relax

---

## 🚨 PRE-DEPLOYMENT FINAL CHECKLIST

Run this checklist **immediately before** starting Phase 8 (deployment):

### Environment

- [ ] At home (jhw22) with physical access to miniserver99/hsb0
- [ ] Time available: 1-1.5 hours (for deployment + verification + potential issues)
- [ ] Network usage low (no ongoing calls, heavy streaming, etc.)
- [ ] Household members informed
- [ ] Calm and focused (not rushed or stressed)

### Technical

- [ ] Git repository clean: `git status` shows no uncommitted changes
- [ ] Feature branch pushed: `git push -u origin feat/miniserver99-to-hsb0`
- [ ] Test build passed on miniserver24: Phase 7 complete ✅
- [ ] miniserver99 responding: `ping 192.168.1.99` works
- [ ] SSH access confirmed: `ssh mba@192.168.1.99 'echo OK'`
- [ ] AdGuard Home currently active: `ssh mba@192.168.1.99 'systemctl is-active adguardhome'`
- [ ] ZFS healthy: `ssh mba@192.168.1.99 'zpool status'`

### Configuration Verification

- [ ] Hostname in config: `grep 'hostName = "hsb0"' hosts/hsb0/configuration.nix`
- [ ] ZFS hostId preserved: `grep 'zfs.hostId = "dabfdb02"' hosts/hsb0/configuration.nix`
- [ ] Secret file renamed: `ls secrets/static-leases-hsb0.age`
- [ ] flake.nix updated: `grep 'hsb0 = mkServerHost' flake.nix`

### Safety Net

- [ ] Terminal ready for instant rollback command
- [ ] Second device ready to test network connectivity
- [ ] Monitor/keyboard for miniserver99 nearby (physical access)
- [ ] NixOS generations verified: `ssh mba@192.168.1.99 'sudo nixos-rebuild list-generations'`
- [ ] Current generation noted (for rollback reference)

### Mental Preparation

- [ ] Understand rollback procedure
- [ ] Know where physical access equipment is
- [ ] Ready to act quickly if DNS breaks
- [ ] Household members briefed

**If ANY item unchecked**: **DO NOT PROCEED** - Fix the issue first!

---

## 📝 POST-MIGRATION NOTES

**To be filled after migration completes**:

### Execution Date

- **Started**: \_\_\_\_\_\_\_\_\_\_
- **Completed**: \_\_\_\_\_\_\_\_\_\_
- **Duration**: \_\_\_\_\_\_\_\_\_\_

### Issues Encountered

- [ ] None
- [ ] Minor issues (describe):
- [ ] Major issues (describe):

### Rollback Required?

- [ ] No - Migration successful
- [ ] Yes - Rolled back (reason):

### Lessons Learned

_Add any new insights or improvements for future migrations_

### Next Steps

- [ ] Update other servers' /etc/hosts (Phase 10)
- [ ] Begin hokage migration (miniserver99 → hsb0 hokage external consumer)
- [ ] Update workstation SSH configs
- [ ] Document in README.md
- [ ] Share experience with team/documentation

---

## 🔗 RELATED DOCUMENTATION

- [hsb8 Hostname Migration](../hsb8/archive/HOKAGE-MIGRATION-2025-11-21.md) - Previous migration (reference)
- [hsb0 Hokage Migration Plan](./MIGRATION-PLAN-HOKAGE.md) - **NEXT STEP** after hostname migration
- [hsb0 README](./README.md) - Server documentation (to be updated)
- [Hosts Overview](../README.md) - All hosts documentation

---

## 🎯 NEXT MIGRATION

**After this hostname migration completes successfully**, proceed with:

📋 **hokage Migration**: [MIGRATION-PLAN-HOKAGE.md](./MIGRATION-PLAN-HOKAGE.md)

- Migrate from local hokage module to external consumer pattern
- Use lessons learned from hsb8 hokage migration
- Same safety measures (feature branch, test build, gradual deployment)
- Estimated duration: 30-45 minutes

**Recommendation**: Wait 24-48 hours after hostname migration to ensure everything is stable before starting hokage migration.

---

**Status**: 📋 **READY FOR EXECUTION**  
**Next Action**: Review plan with user, get approval to proceed  
**Priority**: **HIGH** - Hostname should be done before hokage migration  
**Created**: November 21, 2025  
**Author**: AI Assistant (with Markus Barta)
