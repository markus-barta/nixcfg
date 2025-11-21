# hsb0 → External Hokage Consumer Migration Plan

**Server**: hsb0 (formerly miniserver99) - DNS/DHCP Infrastructure Server  
**Migration Type**: External Hokage Consumer Pattern  
**Risk Level**: 🔴 **HIGH** - Critical network infrastructure (DNS/DHCP for entire network)  
**Status**: ⏸️ **BLOCKED** - Waiting for hostname migration to complete first  
**Created**: November 21, 2025  
**Last Updated**: November 21, 2025

---

## ⚠️ PREREQUISITE: HOSTNAME MIGRATION MUST COMPLETE FIRST

**CRITICAL**: This hokage migration plan assumes the server has **already been renamed** from `miniserver99` to `hsb0`.

📋 **See**: [MIGRATION-PLAN-HOSTNAME.md](./MIGRATION-PLAN-HOSTNAME.md) - Must complete first!

**Why Separate?**

1. ✅ **Isolate risks**: Hostname change is MORE disruptive than hokage migration for DNS/DHCP
2. ✅ **Test thoroughly**: Can verify hostname change for 24-48 hours before hokage migration
3. ✅ **Easier rollback**: If hostname breaks, rollback without hokage complications
4. ✅ **Clear documentation**: Two separate migration reports
5. ✅ **Follow proven pattern**: hsb8 did hostname first (msww87 → hsb8), then hokage external consumer

**Recommended Wait Time**: 24-48 hours after hostname migration completes successfully

---

## 🎯 MIGRATION OBJECTIVE

Migrate hsb0 (formerly miniserver99) from **local hokage module** (`../../modules/hokage`) to **external hokage consumer pattern** using `inputs.nixcfg.nixosModules.hokage` from `github:pbek/nixcfg`.

**Key Constraint**: **ZERO DOWNTIME** - This server provides DNS/DHCP for the entire network!

---

## 📊 CURRENT STATE ANALYSIS

### Server Information

| Attribute         | Value                                                |
| ----------------- | ---------------------------------------------------- |
| **Hostname**      | `hsb0` (formerly `miniserver99`)                     |
| **Role**          | DNS/DHCP server (AdGuard Home)                       |
| **Criticality**   | 🔴 **CRITICAL** - Network infrastructure             |
| **IP Address**    | `192.168.1.99` (static)                              |
| **Uptime**        | 8+ days (at time of planning)                        |
| **NixOS Version** | 25.11.20251117.89c2b23 (Xantusia)                    |
| **Services**      | AdGuard Home, SSH, NetworkManager                    |
| **Note**          | Hostname migration complete (miniserver99 → hsb0) ✅ |

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

### Current Configuration (After Hostname Migration)

**File**: `hosts/hsb0/configuration.nix`

```nix
imports = [
  ./hardware-configuration.nix
  ../../modules/hokage          # ← LOCAL hokage module (TO BE CHANGED)
  ./disk-config.zfs.nix
];
```

**File**: `flake.nix` (line ~211)

```nix
hsb0 = mkServerHost "hsb0" [ disko.nixosModules.disko ];
# ↑ Uses mkServerHost which imports LOCAL hokage
```

**Hokage Configuration**: Uses defaults via `serverMba.enable` (no explicit hokage options)

### Dependencies

- **Other Servers**: hsb8, miniserver24, mba-gaming-pc rely on hsb0 for DNS/DHCP
- **Workstations**: All home network devices use hsb0 as DNS server
- **Static Leases**: Manages IP assignments for infrastructure servers

---

## 🔍 COMPARISON TO hsb8 MIGRATION

### Similarities

| Aspect                 | hsb8                      | hsb0 (formerly miniserver99)    |
| ---------------------- | ------------------------- | ------------------------------- |
| **Current State**      | Local hokage module       | Local hokage module             |
| **Target State**       | External hokage consumer  | External hokage consumer        |
| **flake.nix Pattern**  | Uses `mkServerHost`       | Uses `mkServerHost`             |
| **NixOS Version**      | 25.11                     | 25.11                           |
| **Hardware**           | Mac mini 2011             | Mac mini 2011                   |
| **Storage**            | ZFS                       | ZFS                             |
| **Hokage Config**      | Uses defaults             | Uses defaults                   |
| **Migration Steps**    | 6 phases                  | 6 phases (same)                 |
| **Test Build Server**  | miniserver24              | miniserver24                    |
| **Zero Downtime Goal** | ✅ Achieved               | 🎯 Required                     |
| **Hostname Migrated**  | ✅ Complete (msww87→hsb8) | ✅ Complete (miniserver99→hsb0) |

### Critical Differences

| Aspect                 | hsb8                         | hsb0 (formerly miniserver99)                                                |
| ---------------------- | ---------------------------- | --------------------------------------------------------------------------- |
| **Risk Level**         | 🟡 **MEDIUM** (test server)  | 🔴 **HIGH** (critical DNS/DHCP)                                             |
| **Service Type**       | Home automation (future)     | **DNS/DHCP** (network infrastructure)                                       |
| **Downtime Impact**    | Low (not in production)      | **CRITICAL** (entire network loses DNS)                                     |
| **Rollback Urgency**   | Can wait hours               | **Must be instant** (<1 min)                                                |
| **Testing Strategy**   | Deploy, then verify          | **Extensive pre-deployment testing required**                               |
| **Location**           | Currently at jhw22 (testing) | **Production at jhw22** (serves entire network)                             |
| **Physical Access**    | Easy (at your home)          | Easy (at your home) ✅                                                      |
| **Backup DNS**         | Can use Cloudflare (1.1.1.1) | **Network devices need reconfiguration** if it fails                        |
| **Deployment Window**  | Anytime                      | **Evening/weekend preferred** (when network usage is lower)                 |
| **Verification Time**  | 5 minutes acceptable         | **Must verify within 30 seconds** (DNS failures noticed immediately)        |
| **Users Affected**     | None (pre-production)        | **All household members** (Markus, Mailina, guests)                         |
| **Service Count**      | Minimal (SSH, basic tools)   | **Critical services** (DNS, DHCP, SSH)                                      |
| **Complexity**         | Simple server config         | **Complex**: AdGuard Home with DHCP, static leases, DNS rewrites            |
| **Configuration**      | ~400 lines, location-based   | **~280 lines**, AdGuard-centric                                             |
| **Hostname Migration** | Done before hokage ✅        | **Done before hokage ✅** (miniserver99 → hsb0)                             |
| **Lessons Learned**    | N/A (first hokage migration) | **Can apply hsb8 experience** (lib-utils fix, testing on miniserver24, etc) |

### What We Learned from hsb8

1. ✅ **lib-utils**: External nixcfg doesn't export `lib-utils` - use local one from `self.commonArgs`
2. ✅ **Test Build**: miniserver24 is the right choice (16GB RAM, fast)
3. ✅ **Verification**: Check configuration files, not just nix-store references
4. ✅ **Documentation**: Update ASAP to avoid confusion
5. ✅ **Zero Downtime**: NixOS generation switch is fast and reliable
6. ✅ **Commit Strategy**: Separate commits per phase for easy rollback

---

## 📋 MIGRATION PLAN

### Pre-Migration Checklist

#### 1. Risk Assessment ✅

- [x] Criticality level: 🔴 **HIGH** (DNS/DHCP infrastructure)
- [x] Downtime tolerance: **ZERO** (network breaks without DNS)
- [x] Physical access: ✅ Available (at jhw22)
- [x] Backup DNS: ❌ Not configured (would require device reconfiguration)
- [x] Rollback method: NixOS generations (instant)
- [x] Testing server: miniserver24 available ✅

#### 2. Network Impact Assessment

- [x] Affected devices: **All network devices** (~10-15 devices)
- [x] Affected users: **All household members**
- [x] Affected services: DNS resolution, DHCP assignments, static leases
- [x] DNS fallback: Devices may have Cloudflare (1.1.1.1) as secondary
- [x] DHCP impact: Existing leases continue during migration (no immediate impact)

#### 3. Timing Considerations

**Best Time**:

- 🌙 Evening (8-10 PM) when network usage is low
- 📅 Weekend afternoon (2-4 PM) when Markus is available
- ⚠️ **Avoid**: During work hours, video calls, streaming

**Estimated Duration**: 30-45 minutes (including verification)

#### 4. Backup Strategy

- [x] **NixOS Generations**: Automatic rollback available
- [x] **Git History**: All changes committed separately
- [x] **Configuration Backup**: Current config in git
- [x] **Service State**: AdGuard Home settings in git (declarative)
- [x] **DHCP Leases**: Encrypted in `static-leases-miniserver99.age`

#### 5. Communication Plan

- [ ] **Inform household members**: "DNS server maintenance in progress"
- [ ] **Expected duration**: "5-10 minutes, internet may be briefly affected"
- [ ] **What to do if issues**: "Tell Markus immediately"

#### 6. Verification Checklist

Essential checks (must pass before declaring success):

- [ ] DNS resolution works: `nslookup google.com 192.168.1.99`
- [ ] DHCP server active: `systemctl is-active adguardhome`
- [ ] AdGuard Home web UI accessible: http://192.168.1.99:3000
- [ ] Static leases intact: Check known devices
- [ ] DNS rewrites working: `nslookup csb0` returns `cs0.barta.cm`
- [ ] External DNS works: `ping google.com` from another device
- [ ] SSH access works: `ssh mba@miniserver99.lan`

---

## 🚀 EXECUTION PHASES

### Phase 1: Add External Hokage Input to flake.nix

**Status**: ⏸️ Not Started  
**Duration**: 2 minutes  
**Risk**: 🟢 **LOW** (no impact on running system)

**Actions**:

```bash
cd ~/Code/nixcfg

# Input already added during hsb8 migration! ✅
# Verify it exists:
grep "nixcfg.url" flake.nix

# Expected output:
# nixcfg.url = "github:pbek/nixcfg";
```

**Verification**:

- [ ] `nixcfg.url` exists in flake.nix
- [ ] `flake.lock` has nixcfg entry
- [ ] Git clean (from hsb8 migration)

**Rollback**: N/A (no changes to miniserver99)

---

### Phase 2: Remove Local Hokage Import from configuration.nix

**Status**: ⏸️ Not Started  
**Duration**: 1 minute  
**Risk**: 🟢 **LOW** (local change only, not deployed yet)

**File**: `hosts/hsb0/configuration.nix`

**Current** (line 11-15):

```nix
imports = [
  ./hardware-configuration.nix
  ../../modules/hokage          # ← REMOVE THIS LINE
  ./disk-config.zfs.nix
];
```

**Target**:

```nix
imports = [
  ./hardware-configuration.nix
  ./disk-config.zfs.nix
];
```

**Actions**:

```bash
cd ~/Code/nixcfg
nano hosts/hsb0/configuration.nix

# Remove line 13: ../../modules/hokage

# Verify:
grep -n "modules/hokage" hosts/hsb0/configuration.nix
# Should return nothing

# Commit:
git add hosts/hsb0/configuration.nix
git commit -m "refactor(hsb0): remove local hokage import (will use external)"
```

**Verification**:

- [ ] No `../../modules/hokage` import in configuration.nix
- [ ] File still has `./hardware-configuration.nix` and `./disk-config.zfs.nix`
- [ ] Git commit successful

**Rollback**: `git revert HEAD`

---

### Phase 3: Update flake.nix hsb0 Definition

**Status**: ⏸️ Not Started  
**Duration**: 2 minutes  
**Risk**: 🟢 **LOW** (local change only, not deployed yet)

**File**: `flake.nix` (line ~211)

**Current**:

```nix
hsb0 = mkServerHost "hsb0" [ disko.nixosModules.disko ];
```

**Target**:

```nix
# DNS/DHCP Server (AdGuard Home) - Home Server Barta 0
# Using external hokage consumer pattern
hsb0 = nixpkgs.lib.nixosSystem {
  inherit system;
  modules = commonServerModules ++ [
    inputs.nixcfg.nixosModules.hokage  # External hokage module
    ./hosts/hsb0/configuration.nix
    disko.nixosModules.disko
  ];
  specialArgs = self.commonArgs // {
    inherit inputs;
    # lib-utils already provided by self.commonArgs
  };
};
```

**Actions**:

```bash
cd ~/Code/nixcfg
nano flake.nix

# Find hsb0 definition (line ~211)
# Replace mkServerHost with nixosSystem definition

# Verify:
grep -A 10 "hsb0 = " flake.nix

# Commit:
git add flake.nix
git commit -m "refactor(hsb0): migrate to external hokage consumer pattern"
```

**Verification**:

- [ ] `inputs.nixcfg.nixosModules.hokage` present
- [ ] `commonServerModules` included
- [ ] `disko.nixosModules.disko` included
- [ ] `specialArgs` uses `self.commonArgs`
- [ ] Git commit successful

**Rollback**: `git revert HEAD`

---

### Phase 4: Test Build on miniserver24

**Status**: ⏸️ Not Started  
**Duration**: 5 minutes  
**Risk**: 🟢 **LOW** (test build only, no deployment)

**Rationale**: Test on miniserver24 (not your Mac) to:

- ✅ Native Linux build (no macOS cross-platform issues)
- ✅ Catches Linux-specific problems
- ✅ 16GB RAM (2x more than miniserver99's 8GB)
- ✅ Proven reliable from hsb8 migration

**Actions**:

```bash
# Push changes to main
cd ~/Code/nixcfg
git push

# SSH to miniserver24 (test build server)
ssh mba@miniserver24.lan

# On miniserver24:
cd ~/Code/nixcfg
git pull

echo "=== Testing miniserver99 build ==="
nixos-rebuild build --flake .#miniserver99 --show-trace

# If build fails:
# 1. Check error messages carefully
# 2. Verify external hokage is found
# 3. Verify lib-utils is available
# 4. Check AdGuard Home configuration compatibility

echo "✓ Build successful!"

# Exit back to Mac
exit
```

**Expected Result**: Build should succeed (similar to hsb8)

**Common Issues** (from hsb8 experience):

- ❌ `lib-utils` not found → Already fixed (use `self.commonArgs`)
- ❌ Module evaluation errors → Check hokage compatibility
- ❌ Service definition changes → Verify AdGuard Home config

**Verification**:

- [ ] Build completes without errors
- [ ] No warnings about missing attributes
- [ ] Result path created: `/nix/store/...-nixos-system-hsb0-...`

**Rollback**: N/A (no changes to hsb0)

---

### Phase 5: Deploy to hsb0 (CRITICAL PHASE)

**Status**: ⏸️ Not Started  
**Duration**: 5-10 minutes  
**Risk**: 🔴 **HIGH** - This is the critical deployment!

**⚠️ CRITICAL SAFETY MEASURES**:

1. **Inform household members** (brief DNS interruption possible)
2. **Have physical access** to hsb0 ready
3. **Keep terminal open** for instant rollback if needed
4. **Monitor network connectivity** from another device

**Pre-Deployment Checks**:

```bash
# On hsb0 (via SSH):
ssh mba@192.168.1.99  # Or: ssh mba@hsb0.lan

# 1. Verify current state
hostname  # Should be: hsb0 (after hostname migration)
systemctl is-active adguardhome  # Should be: active
nixos-version  # Note current version

# 2. Check Git repository
cd ~/Code/nixcfg
git status  # Should be clean
git pull    # Get latest changes

# 3. Verify changes
grep -c "modules/hokage" hosts/hsb0/configuration.nix
# Should be: 0

grep "inputs.nixcfg.nixosModules.hokage" flake.nix
# Should find the line

# 4. Pre-deployment test (dry-build)
nixos-rebuild dry-build --flake .#hsb0
# Should succeed
```

**Deployment Execution**:

```bash
# Still on hsb0:

echo "=== DEPLOYING EXTERNAL HOKAGE CONSUMER PATTERN ==="
echo "Starting at: $(date)"

# Deploy!
sudo nixos-rebuild switch --flake .#hsb0

# This will:
# - Build new configuration
# - Switch system to new generation
# - Restart affected services (hopefully none!)
# - Should take 30-60 seconds

echo "Deployment completed at: $(date)"
```

**Immediate Verification** (within 30 seconds):

```bash
# 1. Check AdGuard Home
systemctl status adguardhome
# Should be: active (running)

# 2. Test DNS locally
nslookup google.com 127.0.0.1
# Should resolve

# 3. Check web UI
curl -I http://192.168.1.99:3000
# Should return HTTP 200

# 4. Verify system
hostname && nixos-version
systemctl is-system-running
```

**Test from Another Device** (immediately):

```bash
# From your Mac:

# 1. DNS resolution
nslookup google.com 192.168.1.99
# Should resolve

# 2. DNS rewrite (csb0 test)
nslookup csb0 192.168.1.99
# Should return cs0.barta.cm

# 3. Internet connectivity
ping -c 3 google.com
# Should work

# 4. SSH still works
ssh mba@miniserver99.lan 'echo "SSH OK"'
```

**Verification**:

- [ ] AdGuard Home: active and running
- [ ] DNS resolution: working locally (127.0.0.1)
- [ ] DNS resolution: working from network (192.168.1.99)
- [ ] DNS rewrites: csb0 → cs0.barta.cm working
- [ ] DHCP: systemctl status shows DHCP active
- [ ] Web UI: http://192.168.1.99:3000 accessible
- [ ] SSH: Access working
- [ ] System: `systemctl is-system-running` returns "running"
- [ ] Internet: Other devices can access internet
- [ ] Static leases: Known devices still have correct IPs

**If ANY check fails**:

```bash
# IMMEDIATE ROLLBACK!
sudo nixos-rebuild switch --rollback

# Verify rollback worked:
systemctl is-active adguardhome
nslookup google.com 127.0.0.1

# If still broken, reboot:
sudo reboot
# (Will boot to previous generation automatically)
```

**Rollback**: `sudo nixos-rebuild switch --rollback` or reboot

---

### Phase 6: Verify External Hokage is Active

**Status**: ⏸️ Not Started  
**Duration**: 3 minutes  
**Risk**: 🟢 **LOW** (verification only)

**Actions**:

```bash
# On hsb0:
ssh mba@192.168.1.99  # Or: ssh mba@hsb0.lan

echo "=== Configuration Verification ==="

# 1. Verify configuration files
cd ~/Code/nixcfg

echo "Local hokage import (should be 0):"
grep -c "modules/hokage" hosts/hsb0/configuration.nix || echo "0 ✓"

echo "External hokage in flake.nix (should find it):"
grep "inputs.nixcfg.nixosModules.hokage" flake.nix

# 2. Verify system health
echo "=== System Health ==="
hostname
nixos-version
uptime
systemctl is-system-running

# 3. Verify critical services
echo "=== Critical Services ==="
systemctl is-active adguardhome
systemctl is-active NetworkManager
systemctl is-active sshd

# 4. Verify hokage tools
echo "=== Hokage Features ==="
which fish
which zellij
which git

echo "✅ All verifications complete!"
```

**Extended Verification** (from Mac):

```bash
# Test all DNS functionality:
nslookup google.com 192.168.1.99          # External DNS
nslookup miniserver24.lan 192.168.1.99   # Internal hostname
nslookup csb0 192.168.1.99               # DNS rewrite

# Test DHCP (if possible):
# - Connect a test device
# - Verify it gets IP in range 192.168.1.201-254
# - Verify DNS is set to 192.168.1.99

# Test AdGuard Home UI:
open http://192.168.1.99:3000
# Login with admin credentials
# Check dashboard shows active queries
# Verify DHCP leases tab shows devices
```

**Verification**:

- [ ] Configuration files confirmed (no local hokage)
- [ ] System running normally
- [ ] All critical services active
- [ ] DNS working (external, internal, rewrites)
- [ ] DHCP working (existing leases, new assignments)
- [ ] AdGuard Home UI accessible
- [ ] Hokage tools available (fish, zellij, git)
- [ ] No errors in `journalctl -xe`

**Rollback**: N/A (verification only)

---

### Phase 7: Update Documentation

**Status**: ⏸️ Not Started  
**Duration**: 5 minutes  
**Risk**: 🟢 **LOW** (documentation only)

**Files to Update**:

1. **`hosts/hsb0/MIGRATION-PLAN-HOKAGE.md`** (this file)
   - Mark status as ✅ COMPLETE
   - Add completion date
   - Note any issues encountered

2. **`hosts/hsb0/README.md`**
   - Update "Current Status" section
   - Add external hokage note
   - Update changelog

3. **`hosts/README.md`** (if needed)
   - Note hsb0 hokage migration complete

**Actions**:

```bash
cd ~/Code/nixcfg

# Update documentation
# (Detailed edits based on actual migration results)

git add hosts/hsb0/*.md hosts/README.md
git commit -m "docs(hsb0): external hokage migration complete ✅"
git push
```

**Verification**:

- [ ] This file marked as COMPLETE
- [ ] README.md updated
- [ ] Changelog updated
- [ ] All documentation committed and pushed

**Rollback**: N/A (documentation only)

---

## 🛡️ COMPREHENSIVE ROLLBACK PLAN

### Scenario 1: Build Fails (Phase 4)

**Impact**: None (test build only)

**Action**:

1. Review error messages
2. Fix issues in local git
3. Retry build
4. If persistent, investigate external hokage compatibility

**No Rollback Needed** (no changes to hsb0)

### Scenario 2: Deployment Succeeds, AdGuard Home Stops

**Impact**: 🔴 **CRITICAL** - No DNS/DHCP for network

**Action**:

```bash
# IMMEDIATE (within 10 seconds):
sudo nixos-rebuild switch --rollback

# Verify:
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
nslookup google.com 127.0.0.1

# If still broken, check service:
systemctl restart adguardhome
systemctl status adguardhome

# If persistent:
sudo reboot
```

**Expected Recovery Time**: <2 minutes

### Scenario 4: Deployment Succeeds, DHCP Broken

**Impact**: 🟡 **MEDIUM** - Existing devices keep IPs, new devices can't connect

**Symptoms**:

- Existing devices work fine
- New devices can't get IP addresses
- Static leases missing

**Action**:

```bash
# Not as urgent (existing devices work)
sudo nixos-rebuild switch --rollback

# Verify:
systemctl status adguardhome | grep -i dhcp

# Check web UI:
curl http://192.168.1.99:3000
```

**Expected Recovery Time**: <2 minutes

### Scenario 5: Deployment Succeeds, SSH Broken

**Impact**: 🟡 **MEDIUM** - Can't remotely manage, but services work

**Symptoms**:

- Can't SSH to miniserver99
- DNS/DHCP still working
- Web UI accessible

**Action**:

```bash
# Option A: Physical access (if at home)
# 1. Connect monitor and keyboard
# 2. Login as mba
# 3. sudo nixos-rebuild switch --rollback

# Option B: Reboot via web interface (if available)
# 1. Access router/switch
# 2. Power cycle miniserver99
# 3. Previous generation boots automatically

# Option C: Wait (if services working)
# - DNS/DHCP continue working
# - Fix at next physical access
```

**Expected Recovery Time**: Varies (not urgent if services work)

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

- [ ] AdGuard Home service active and running
- [ ] DNS resolution working (external domains)
- [ ] DNS resolution working (internal .lan domains)
- [ ] DNS rewrites working (csb0 → cs0.barta.cm)
- [ ] DHCP server active
- [ ] Static leases intact (known devices have correct IPs)
- [ ] Web UI accessible (http://192.168.1.99:3000)
- [ ] SSH access working
- [ ] System status: running

### Configuration (Must Verify)

- [ ] No local `../../modules/hokage` import in configuration.nix
- [ ] External hokage in flake.nix (`inputs.nixcfg.nixosModules.hokage`)
- [ ] flake.lock has nixcfg entry
- [ ] Git repository clean and pushed

### Network (Must Verify)

- [ ] Other devices can resolve DNS
- [ ] Internet connectivity working for all devices
- [ ] New DHCP assignments working (if testable)
- [ ] Static leases still correct

### Documentation (Should Complete)

- [ ] This migration plan marked complete
- [ ] README.md updated
- [ ] Changelog updated
- [ ] Lessons learned documented

---

## 🎓 LESSONS FROM hsb8 MIGRATION

### What Worked Well

1. ✅ **Test Build on miniserver24**: Caught issues before deployment
2. ✅ **lib-utils from self.commonArgs**: Correct approach (external nixcfg doesn't export it)
3. ✅ **Separate Commits**: Easy to track and rollback individual phases
4. ✅ **Zero Downtime**: NixOS generation switch is fast (<1 minute)
5. ✅ **Documentation First**: Clear plan made execution smooth

### What to Apply Here

1. 🎯 **Same Build Server**: Use miniserver24 (16GB RAM, proven reliable)
2. 🎯 **Same lib-utils Fix**: Don't try to use `inputs.nixcfg.lib-utils`
3. 🎯 **Same Commit Strategy**: Separate commits per phase
4. 🎯 **Same Verification**: Check config files, not just nix-store
5. 🎯 **Immediate Documentation**: Update docs right after deployment

### Additional Precautions for miniserver99

1. ⚠️ **Higher Stakes**: DNS/DHCP is critical infrastructure (hsb8 was test server)
2. ⚠️ **Inform Users**: Brief household members (wasn't needed for hsb8)
3. ⚠️ **Faster Verification**: Must confirm DNS within 30 seconds (hsb8 had 5 minutes)
4. ⚠️ **Physical Access Ready**: Have monitor/keyboard nearby (extra safety)
5. ⚠️ **Evening Deployment**: Lower network usage (hsb8 could be anytime)

---

## 📅 RECOMMENDED EXECUTION SCHEDULE

### Option A: Weekend Afternoon (Recommended)

**When**: Saturday or Sunday, 2-4 PM  
**Duration**: 30-45 minutes  
**Pros**:

- Markus fully available
- Household members around (can inform easily)
- Not during critical work activities
- Daytime (good visibility, alert)
- Can take time to verify thoroughly

**Cons**:

- Might interrupt weekend activities

### Option B: Weekday Evening

**When**: Tuesday-Thursday, 8-10 PM  
**Duration**: 30-45 minutes  
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

---

## 🚨 PRE-DEPLOYMENT FINAL CHECKLIST

Run this checklist **immediately before** starting Phase 5 (deployment):

### Environment

- [ ] At home (jhw22) with physical access to miniserver99
- [ ] Time available: 1 hour (for deployment + verification + potential issues)
- [ ] Network usage low (no ongoing calls, heavy streaming, etc.)
- [ ] Household members informed

### Technical

- [ ] Git repository clean: `git status` shows no uncommitted changes
- [ ] Latest changes pulled on Mac: `git pull`
- [ ] Latest changes pulled on miniserver99: `ssh mba@192.168.1.99 'cd ~/Code/nixcfg && git pull'`
- [ ] Test build passed on miniserver24: Phase 4 complete ✅
- [ ] hsb0 responding: `ping 192.168.1.99` works
- [ ] SSH access confirmed: `ssh mba@hsb0.lan 'echo OK'` (or via IP: `ssh mba@192.168.1.99 'echo OK'`)
- [ ] AdGuard Home currently active: `ssh mba@hsb0.lan 'systemctl is-active adguardhome'`

### Safety Net

- [ ] Terminal ready for instant rollback command
- [ ] Second device ready to test network connectivity
- [ ] Monitor/keyboard for miniserver99 nearby (physical access)
- [ ] NixOS generations verified: `sudo nixos-rebuild list-generations` (on hsb0)
- [ ] Current generation noted (for rollback reference)

### Mental Preparation

- [ ] Understand rollback procedure
- [ ] Know where physical access equipment is
- [ ] Ready to act quickly if DNS breaks
- [ ] Calm and focused (not rushed or stressed)

**If ANY item unchecked**: **DO NOT PROCEED** - Fix the issue first!

---

## 📝 POST-MIGRATION NOTES

**To be filled after migration completes**:

### Execution Date

- **Started**: \***\*\_\_\_\*\***
- **Completed**: \***\*\_\_\_\*\***
- **Duration**: \***\*\_\_\_\*\***

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

- [ ] Document in hsb0/README.md
- [ ] Update main hosts/README.md
- [ ] Archive this migration plan (similar to hsb8)
- [ ] Consider migrating miniserver24 next
- [ ] Share experience/lessons learned

---

## 🔗 RELATED DOCUMENTATION

- [hsb8 Hokage Migration Report](../hsb8/archive/HOKAGE-MIGRATION-2025-11-21.md) - Completed migration (reference)
- [hsb8 Backlog](../hsb8/BACKLOG.md) - Lessons learned from hsb8
- **[hsb0 Hostname Migration Plan](./MIGRATION-PLAN-HOSTNAME.md)** - **PREREQUISITE** (must complete first!)
- [hsb0 README](./README.md) - Server documentation
- [Hokage Options](../../docs/hokage-options.md) - Module reference

---

**Status**: ⏸️ **BLOCKED** - Waiting for hostname migration (miniserver99 → hsb0) to complete  
**Next Action**: Complete hostname migration first, wait 24-48 hours for stability, then proceed with this hokage migration  
**Created**: November 21, 2025  
**Author**: AI Assistant (with Markus Barta)
