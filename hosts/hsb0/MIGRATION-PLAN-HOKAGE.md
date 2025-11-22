# hsb0 → External Hokage Consumer Migration Plan

**Server**: hsb0 (formerly miniserver99) - DNS/DHCP Infrastructure Server  
**Migration Type**: External Hokage Consumer Pattern  
**Risk Level**: 🔴 **HIGH** - Critical network infrastructure (DNS/DHCP for entire network)  
**Status**: ✅ **COMPLETE** - External hokage migration successful!  
**Created**: November 21, 2025  
**Last Updated**: November 22, 2025  
**Completed**: November 22, 2025 16:45 CET

---

## ✅ PREREQUISITE COMPLETE: Hostname Migration Done

**GOOD NEWS**: The server has been **successfully renamed** from `miniserver99` to `hsb0`.

**Verification** (November 22, 2025):

- ✅ Server responds as `hsb0` via SSH
- ✅ Running NixOS 25.11.20251117.89c2b23 (Xantusia)
- ✅ AdGuard Home service is active
- ✅ All critical services operational

📋 **See**: [MIGRATION-PLAN-HOSTNAME [DONE].md](./archive/MIGRATION-PLAN-HOSTNAME%20%5BDONE%5D.md) - Completed migration

**Why Hostname Was Migrated First?**

1. ✅ **Isolate risks**: Hostname change is MORE disruptive than hokage migration for DNS/DHCP
2. ✅ **Test thoroughly**: Can verify hostname change for 24-48 hours before hokage migration
3. ✅ **Easier rollback**: If hostname breaks, rollback without hokage complications
4. ✅ **Clear documentation**: Two separate migration reports
5. ✅ **Follow proven pattern**: hsb8 did hostname first (msww87 → hsb8), then hokage external consumer

**Status**: ✅ Hostname migration completed successfully, server stable

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
   - Web UI: <http://192.168.1.99:3000>
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

## 📚 OFFICIAL HOKAGE CONSUMER REFERENCE

**Source**: Patrizio's canonical examples at `github:pbek/nixcfg/examples/hokage-consumer`

### Reference Links

- **Example Flake**: [hokage-consumer/flake.nix](https://github.com/pbek/nixcfg/blob/main/examples/hokage-consumer/flake.nix)
- **Server Config**: [hokage-consumer/server/configuration.nix](https://github.com/pbek/nixcfg/blob/main/examples/hokage-consumer/server/configuration.nix)
- **Desktop Config**: [hokage-consumer/desktop/configuration.nix](https://github.com/pbek/nixcfg/blob/main/examples/hokage-consumer/desktop/configuration.nix)
- **README**: [hokage-consumer/README.md](https://github.com/pbek/nixcfg/blob/main/examples/hokage-consumer/README.md)
- **Quick Start**: [hokage-consumer/QUICK_START.md](https://github.com/pbek/nixcfg/blob/main/examples/hokage-consumer/QUICK_START.md)
- **Documentation**: [HOKAGE_MODULE_EXPORT.md](https://github.com/pbek/nixcfg/blob/main/examples/HOKAGE_MODULE_EXPORT.md)

### Critical Requirements from Official Examples

#### 1. Required Flake Inputs

The hokage module **requires** these dependencies (from official example):

```nix
inputs = {
  nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  nixcfg.url = "github:pbek/nixcfg";
  agenix.url = "github:ryantm/agenix";              # ← REQUIRED by hokage
  home-manager.url = "github:nix-community/home-manager";  # ← REQUIRED by hokage
  plasma-manager.url = "github:nix-community/plasma-manager";  # ← Desktop only

  # Follow nixpkgs to avoid version conflicts
  nixcfg.inputs.nixpkgs.follows = "nixpkgs";
  agenix.inputs.nixpkgs.follows = "nixpkgs";
  home-manager.inputs.nixpkgs.follows = "nixpkgs";
};
```

**Status in Your Flake**: ✅ All inputs already present!

#### 2. Required Module Imports

The hokage consumer **must** import these modules (from official example):

```nix
modules = [
  nixcfg.nixosModules.hokage        # ← External hokage module
  agenix.nixosModules.age           # ← CRITICAL: Required by hokage!
  home-manager.nixosModules.home-manager  # ← CRITICAL: Required by hokage!

  # For desktop only (not needed for hsb0):
  # { home-manager.sharedModules = [ plasma-manager.homeModules.plasma-manager ]; }

  ./configuration.nix
  disko.nixosModules.disko
];
```

**Status in Your Plan**: ⚠️ **MISSING** `agenix` and `home-manager` module imports!

#### 3. Required specialArgs

From official example:

```nix
specialArgs = {
  inherit inputs;
  lib-utils = nixcfg.commonArgs.lib-utils;  # ← Correct approach!
};
```

**Status in Your Plan**: ✅ Already correct!

#### 4. Hokage Configuration Options

From official server example:

```nix
hokage = {
  hostName = "example-server";
  userLogin = "john";                      # ← Should be explicit!
  userNameLong = "John Doe";               # ← Optional
  userNameShort = "John";                  # ← Optional
  userEmail = "john@example.com";          # ← Optional
  useInternalInfrastructure = false;       # ← Should set explicitly!
  useSecrets = false;                      # ← Should set (true for hsb0)
  useSharedKey = false;                    # ← Should set explicitly!
  programs.git.enableUrlRewriting = false; # ← Optional
  zfs.enable = false;                      # ← Should be true for hsb0
  role = "server-remote"; # Options: "desktop", "server-home", "server-remote", "ally"
};
```

**Current hsb0 Config** (uses mixin pattern):

```nix
hokage = {
  hostName = "hsb0";
  zfs.hostId = "dabfdb02";
  audio.enable = false;
  serverMba.enable = true;  # ← Mixin pattern (local hokage)
};
```

**Target hsb0 Config** (external hokage pattern):

```nix
hokage = {
  hostName = "hsb0";
  userLogin = "mba";                 # ← ADD: Explicit user
  role = "server-home";              # ← ADD: Explicit role (instead of serverMba mixin)
  useInternalInfrastructure = false; # ← ADD: Not using pbek's infrastructure
  useSecrets = true;                 # ← ADD: Using agenix for DHCP leases
  useSharedKey = false;              # ← ADD: Not using shared SSH keys
  zfs.enable = true;                 # ← ADD: Enable ZFS support
  zfs.hostId = "dabfdb02";           # ← KEEP: ZFS host ID
  audio.enable = false;              # ← KEEP: No audio on server
  programs.git.enableUrlRewriting = false;  # ← ADD: No internal git rewrites
};
```

### Key Differences: Local vs External Hokage

| Aspect            | Local Hokage (Current)  | External Hokage (Target)              |
| ----------------- | ----------------------- | ------------------------------------- |
| **Import Source** | `../../modules/hokage`  | `inputs.nixcfg.nixosModules.hokage`   |
| **Mixins**        | Uses `serverMba.enable` | Use explicit `role = "server-home"`   |
| **Dependencies**  | Bundled                 | Must import `agenix` + `home-manager` |
| **Configuration** | Implicit via mixins     | Explicit options                      |
| **lib-utils**     | Auto-available          | Must pass via `specialArgs`           |

### Comparison to hsb8 Implementation

**hsb8 flake.nix** (already migrated):

```nix
hsb8 = nixpkgs.lib.nixosSystem {
  inherit system;
  modules = commonServerModules ++ [
    inputs.nixcfg.nixosModules.hokage  # External hokage module
    ./hosts/hsb8/configuration.nix
    disko.nixosModules.disko
  ];
  specialArgs = self.commonArgs // {
    inherit inputs;
    # lib-utils already provided by self.commonArgs
  };
};
```

**hsb8 configuration.nix** (already migrated):

```nix
hokage = {
  hostName = "hsb8";
  location = "jhw22";  # Test mode (will be ww87 in production)
  userLogin = "mba";
  role = "server-home";
  useInternalInfrastructure = false;
  useSecrets = false;  # Not using secrets yet
  useSharedKey = false;
  zfs.enable = true;
  zfs.hostId = "0ee2ca55";
  audio.enable = false;
  programs.adguardhome.enable = false;  # Disabled for now
};
```

**Observation**: hsb8 successfully works **without** explicit `agenix` and `home-manager` module imports!

**Why?**: `commonServerModules` likely already includes them!

### ✅ Verification Complete: Dependencies Already Included

Checked `commonServerModules` in flake.nix (lines 71-79):

```nix
commonServerModules = [
  home-manager.nixosModules.home-manager  # ✅ Already included!
  { }
  (_: {
    nixpkgs.overlays = allOverlays;
  })
  agenix.nixosModules.age  # ✅ Already included!
];
```

**GOOD NEWS**: ✅ Both `agenix` and `home-manager` are **already included** via `commonServerModules`!

This means **hsb0 migration will work exactly like hsb8** - no additional module imports needed!

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
- [ ] AdGuard Home web UI accessible: <http://192.168.1.99:3000>
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

### Phase 2.5: Update Hokage Configuration (Switch from Mixin to Explicit Options)

**Status**: ⏸️ Not Started  
**Duration**: 5 minutes  
**Risk**: 🔴 **HIGH** - SSH key security CRITICAL (see hsb8 lockout incident below)

**🚨 CRITICAL LESSON FROM hsb8 MIGRATION (Nov 22, 2025)**:

During hsb8 migration, switching from `serverMba.enable = true` mixin to explicit hokage options caused **complete SSH lockout** after reboot. The hokage `server-home.nix` module auto-injects Patrizio's SSH keys (omega@yubikey, omega@rsa, omega@tuvb, omega@semaphore) into ALL users. The mixin was providing the `mba` user's SSH key, which was lost during the switch, leaving only external omega keys.

**Impact**: Complete SSH lockout requiring physical console access to recover.

**Fix Required**: Use `lib.mkForce` to **explicitly override** SSH keys for ALL users BEFORE deployment.

**Security Policy**: Only `mba` (Markus) SSH key on hsb0. NO external keys (omega/yubikey) allowed.

**Rationale**:

The local hokage module uses **mixin pattern** (`serverMba.enable = true`), but external hokage module requires **explicit role-based configuration** AND **explicit SSH key management**.

**File**: `hosts/hsb0/configuration.nix` (lines 275-280)

**Current** (mixin pattern):

```nix
hokage = {
  hostName = "hsb0";
  zfs.hostId = "dabfdb02";
  audio.enable = false;
  serverMba.enable = true;  # ← MIXIN (local hokage)
};
```

**Target** (explicit external hokage pattern + SSH security - based on official examples + hsb8 lessons):

```nix
hokage = {
  hostName = "hsb0";
  userLogin = "mba";                 # ADD: Explicit user (required)
  userNameLong = "Markus Barta";     # ADD: Explicit name (prevents "Patrizio Bekerle" default)
  userNameShort = "Markus";          # ADD: Explicit short name
  userEmail = "markus@barta.com";    # ADD: Explicit email
  role = "server-home";              # ADD: Explicit role (replaces serverMba mixin)
  useInternalInfrastructure = false; # ADD: Not using pbek's infrastructure
  useSecrets = true;                 # ADD: Using agenix for DHCP leases
  useSharedKey = false;              # ADD: Not using shared SSH keys
  zfs.enable = true;                 # ADD: Enable ZFS support
  zfs.hostId = "dabfdb02";           # KEEP: ZFS host ID (required)
  audio.enable = false;              # KEEP: No audio on server
  programs.git.enableUrlRewriting = false;  # ADD: No internal git rewrites
};

# ============================================================================
# 🚨 FISH SHELL CONFIGURATION - Lost when removing serverMba mixin
# ============================================================================
programs.fish.interactiveShellInit = ''
  function sourcefish --description 'Load env vars from a .env file into current Fish session'
    set file "$argv[1]"
    if test -z "$file"
      echo "Usage: sourcefish PATH_TO_ENV_FILE"
      return 1
    end
    if test -f "$file"
      for line in (cat "$file" | grep -v '^[[:space:]]*#' | grep .)
        set key (echo $line | cut -d= -f1)
        set val (echo $line | cut -d= -f2-)
        set -gx $key "$val"
      end
    else
      echo "File not found: $file"
      return 1
    end
  end
  export EDITOR=nano
'';

# ============================================================================
# 🚨 SSH KEY SECURITY - CRITICAL FIX FROM hsb8 INCIDENT
# ============================================================================
# The hokage server-home module auto-injects external SSH keys (omega@*).
# We use lib.mkForce to REPLACE (not append) with our own keys only.
#
# Security Policy:
# - hsb0: Only mba (Markus) key
# - NO external access (omega/Yubikey) on personal/family servers
# ============================================================================

users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    # Markus' SSH key ONLY
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt" # mba@markus
  ];
};

# ============================================================================
# 🚨 PASSWORDLESS SUDO - Also lost when removing serverMba mixin
# ============================================================================
# The serverMba mixin provided passwordless sudo, which is also lost.
# Re-enable it explicitly to prevent sudo failures.
# ============================================================================

security.sudo-rs.wheelNeedsPassword = false;
```

**Actions**:

```bash
cd ~/Code/nixcfg
nano hosts/hsb0/configuration.nix

# Step 1: Navigate to hokage section (around line 275)
# Replace serverMba.enable with explicit options
# ⚠️ IMPORTANT: Include userNameLong, userEmail, etc. to avoid defaults
# ⚠️ IMPORTANT: Add programs.fish.interactiveShellInit block (sourcefish)

# Step 2: 🚨 CRITICAL - Add SSH key override AFTER hokage section
# Add the users.users.mba section with lib.mkForce
# This prevents external omega keys from being injected!

# Step 3: 🚨 CRITICAL - Add passwordless sudo
# Add security.sudo-rs.wheelNeedsPassword = false
# This was also provided by serverMba mixin and is now lost

# Verify changes:
grep -A 18 "hokage = {" hosts/hsb0/configuration.nix
grep -A 5 "users.users.mba" hosts/hsb0/configuration.nix
grep "wheelNeedsPassword" hosts/hsb0/configuration.nix
grep "sourcefish" hosts/hsb0/configuration.nix

# Should show:
# - All explicit hokage options, no serverMba.enable
# - users.users.mba with lib.mkForce and ONLY mba@markus key
# - security.sudo-rs.wheelNeedsPassword = false
# - programs.fish.interactiveShellInit with sourcefish defined

# Commit:
git add hosts/hsb0/configuration.nix
git commit -m "refactor(hsb0): explicit hokage + SSH/sudo security fixes

- Replace serverMba.enable with explicit hokage options
- Add lib.mkForce SSH key override (prevent omega key injection)
- Add passwordless sudo (lost when removing serverMba mixin)
- Restore fish shell config (sourcefish, EDITOR)
- Applies lessons from hsb8 SSH lockout incident (Nov 22, 2025)"
```

**Verification**:

- [ ] No `serverMba.enable` present
- [ ] `userLogin = "mba"` added
- [ ] `userNameLong`, `userNameShort`, `userEmail` added correctly
- [ ] `role = "server-home"` added
- [ ] `useInternalInfrastructure = false` added
- [ ] `useSecrets = true` added
- [ ] `useSharedKey = false` added
- [ ] `zfs.enable = true` added
- [ ] `zfs.hostId` still present
- [ ] `audio.enable = false` still present
- [ ] `programs.git.enableUrlRewriting = false` added
- [ ] `programs.fish.interactiveShellInit` added (restores `sourcefish`)
- [ ] 🚨 **CRITICAL**: `users.users.mba` section added with `lib.mkForce`
- [ ] 🚨 **CRITICAL**: Only `mba@markus` SSH key present in the override
- [ ] 🚨 **CRITICAL**: No `omega@*` keys in the configuration
- [ ] 🚨 **CRITICAL**: `security.sudo-rs.wheelNeedsPassword = false` added
- [ ] Git commit successful

**Why This Matters**: Without the `lib.mkForce` SSH key override, hsb0 will be **locked out after deployment**, requiring physical console access to recover. This happened on hsb8 and must not be repeated! The passwordless sudo is also critical for smooth operation.

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
- [ ] Web UI: <http://192.168.1.99:3000> accessible
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

# 5. Verify environment
echo "=== Environment Verification ==="
echo "Checking Git user config (should be Markus Barta):"
git config --get user.name || echo "NOT SET"
git config --get user.email || echo "NOT SET"

echo "Checking Fish functions (should find sourcefish):"
type sourcefish || echo "sourcefish NOT FOUND"

# 6. 🚨 CRITICAL: Verify SSH key security (lesson from hsb8)
echo "=== SSH Key Security ==="
echo "Checking authorized SSH keys for mba user:"
cat ~/.ssh/authorized_keys

echo ""
echo "⚠️ SECURITY CHECK: Should show ONLY mba@markus key"
echo "⚠️ If you see omega@yubikey, omega@rsa, or omega@* keys: LOCKOUT RISK!"
echo "⚠️ If only mba@markus key present: ✅ SECURE"

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
open <http://192.168.1.99:3000>
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
- [ ] Git user config correct (Markus Barta)
- [ ] Fish `sourcefish` function available
- [ ] 🚨 **CRITICAL**: SSH keys verified - ONLY `mba@markus` key present
- [ ] 🚨 **CRITICAL**: NO `omega@*` keys in authorized_keys
- [ ] No errors in `journalctl -xe`

**🚨 If omega keys are found**: You have a security issue! External keys were injected. This indicates the `lib.mkForce` override in Phase 2.5 was not applied correctly. DO NOT PROCEED - fix the configuration immediately!

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
- [ ] Web UI accessible (<http://192.168.1.99:3000>)
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

### Execution Date

- **Started**: November 22, 2025 16:44 CET
- **Completed**: November 22, 2025 16:45 CET
- **Duration**: ~1 minute (deployment only, ~45 minutes total with all phases)

### Issues Encountered

- [x] None - Migration was flawless!
- Minor git issue on server (.shared folder conflict) - quickly resolved

### Rollback Required?

- [x] No - Migration successful on first attempt

### Verification Results

✅ **All Critical Services Working**:

- AdGuard Home: Active and running
- DNS resolution: Working (local and remote)
- DNS rewrites: Working (csb0 → cs0.barta.cm)
- DHCP: Active
- Internet connectivity: Verified
- System health: Running
- SSH access: Working
- SSH security: ✅ **SECURE** - Only mba@markus key present (no omega keys!)
- Passwordless sudo: ✅ Working
- External hokage: ✅ Confirmed active

### Lessons Learned

1. ✅ **Git conflicts on server**: `.shared` folder needed cleanup before pull
2. ✅ **SSH key security worked perfectly**: `lib.mkForce` prevented omega key injection
3. ✅ **Zero downtime achieved**: DNS/DHCP never stopped during switch
4. ✅ **Test build on miniserver24**: Caught no issues (good practice)
5. ✅ **Fish functions**: Require user to log out/in to reload (home-manager service doesn't exist on servers)

### Success Factors

1. Comprehensive migration plan based on hsb8 experience
2. Critical SSH security fixes applied proactively
3. Test build on miniserver24 before deployment
4. Clean git commits per phase for easy rollback
5. Following proven pattern from hsb8 migration

### Next Steps

- [x] Document in hsb0/README.md
- [x] Update main hosts/README.md
- [x] Archive this migration plan
- [ ] Consider migrating miniserver24 (hsb1) next
- [x] hsb8 and hsb0 now both using external hokage successfully!

---

## 🔗 RELATED DOCUMENTATION

- [hsb8 Hokage Migration Report](../hsb8/archive/HOKAGE-MIGRATION-2025-11-21.md) - Completed migration (reference)
- [hsb8 Backlog](../hsb8/BACKLOG.md) - Lessons learned from hsb8
- **[hsb0 Hostname Migration Plan](./MIGRATION-PLAN-HOSTNAME.md)** - **PREREQUISITE** (must complete first!)
- [hsb0 README](./README.md) - Server documentation
- [Hokage Options](../../docs/hokage-options.md) - Module reference

---

**Status**: ✅ **MIGRATION COMPLETE** - All phases executed successfully  
**Result**: Zero downtime, all services operational, external hokage active  
**Created**: November 21, 2025  
**Completed**: November 22, 2025 16:45 CET  
**Author**: AI Assistant (with Markus Barta)

---

## 📑 APPENDIX: BOILERPLATE FOR OTHER SERVERS

**Purpose**: This section provides reusable templates for migrating other servers to external hokage consumer pattern.

### Template: flake.nix Entry

Based on hsb8 and official examples:

```nix
# <DESCRIPTION> - <SERVER_NAME>
# Using external hokage consumer pattern
<hostname> = nixpkgs.lib.nixosSystem {
  inherit system;
  modules = commonServerModules ++ [
    inputs.nixcfg.nixosModules.hokage  # External hokage module
    ./hosts/<hostname>/configuration.nix
    disko.nixosModules.disko  # If using disko
  ];
  specialArgs = self.commonArgs // {
    inherit inputs;
    # lib-utils already provided by self.commonArgs
  };
};
```

**Example for miniserver24 (hsb1)**:

```nix
# Home Automation Server + MQTT - Home Server Barta 1
# Using external hokage consumer pattern
hsb1 = nixpkgs.lib.nixosSystem {
  inherit system;
  modules = commonServerModules ++ [
    inputs.nixcfg.nixosModules.hokage
    ./hosts/hsb1/configuration.nix
    disko.nixosModules.disko
  ];
  specialArgs = self.commonArgs // {
    inherit inputs;
  };
};
```

### Template: configuration.nix Hokage Section

For **servers** (based on official hokage-consumer/server/configuration.nix):

```nix
hokage = {
  hostName = "<hostname>";
  userLogin = "mba";                 # Or appropriate user
  role = "server-home";              # For home servers
  # role = "server-remote";          # For remote/cloud servers (csb0, csb1)
  useInternalInfrastructure = false; # Set true only for pbek's infrastructure
  useSecrets = true;                 # If using agenix secrets
  useSharedKey = false;              # If using shared SSH keys
  zfs.enable = true;                 # If using ZFS
  zfs.hostId = "<hostid>";           # Required for ZFS
  audio.enable = false;              # Typically false for servers
  programs.git.enableUrlRewriting = false;  # Set true only for pbek's infrastructure
};
```

For **desktops** (based on official hokage-consumer/desktop/configuration.nix):

```nix
hokage = {
  hostName = "<hostname>";
  userLogin = "mba";
  role = "desktop";                  # For desktops/laptops
  useInternalInfrastructure = false;
  useSecrets = false;
  useSharedKey = false;
  programs.espanso.enable = false;   # Enable if needed
  programs.git.enableUrlRewriting = false;
  waylandSupport = true;             # true for Wayland, false for X11
  useGraphicalSystem = true;         # Enable graphical environment
};
```

### Migration Checklist Template

Use this for migrating other servers:

- [ ] **Phase 1**: Verify `nixcfg.url` input exists in flake.nix
- [ ] **Phase 2**: Remove `../../modules/hokage` from configuration.nix imports
- [ ] **Phase 2.5**: Update hokage section (remove mixin, add explicit options)
- [ ] **Phase 3**: Update flake.nix entry (replace `mkServerHost` with `nixosSystem`)
- [ ] **Phase 4**: Test build on miniserver24 or another test machine
- [ ] **Phase 5**: Deploy to target server
- [ ] **Phase 6**: Verify external hokage is active
- [ ] **Phase 7**: Update documentation

### Common Configurations by Server Type

#### Home Servers (hsb\*)

```nix
role = "server-home";
useInternalInfrastructure = false;
useSecrets = true;  # Most use agenix
```

#### Cloud Servers (csb*, netcup*)

```nix
role = "server-remote";
useInternalInfrastructure = false;
useSecrets = true;
```

#### Workstations (imac*, pcg*)

```nix
role = "desktop";
useInternalInfrastructure = false;
useGraphicalSystem = true;
```

### Required Dependencies (Already in Your Flake)

✅ All required inputs are already present:

```nix
inputs = {
  nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  nixcfg.url = "github:pbek/nixcfg";
  agenix.url = "github:ryantm/agenix";
  home-manager.url = "github:nix-community/home-manager";
  plasma-manager.url = "github:nix-community/plasma-manager";
  # ... follows declarations ...
};
```

✅ All required modules are in `commonServerModules`:

```nix
commonServerModules = [
  home-manager.nixosModules.home-manager
  agenix.nixosModules.age
];
```

### Next Servers to Migrate

**Priority Order** (based on risk and dependencies):

1. ✅ **hsb8** (msww87) - **COMPLETE** - Nov 21, 2025
2. 🎯 **hsb0** (miniserver99) - **IN PROGRESS** - This migration
3. 🔜 **hsb1** (miniserver24) - Home automation + MQTT (medium risk)
4. 🔜 **csb0** - Cloud server (high uptime, but external, medium risk)
5. 🔜 **csb1** - Cloud server (high uptime, but external, medium risk)
6. 🔜 **mba-gaming-pc** (pcg0) - Gaming PC (low risk, can rebuild)
7. 🔜 **Other workstations** - Low risk

### Reference Implementation: hsb8

See completed migration: `hosts/hsb8/archive/MIGRATION-PLAN [DONE].md`

**What worked well on hsb8**:

- Zero downtime deployment
- Test build on miniserver24 before deployment
- Separate commits per phase
- Immediate documentation updates
- Clear rollback plan

**Apply these lessons to all future migrations!**

---

## 🚨 CRITICAL LESSONS FROM hsb8 MIGRATION (November 22, 2025)

### Incident: Complete SSH Lockout After Deployment

**What Happened**:

On November 22, 2025, hsb8 suffered a complete SSH lockout after switching from local hokage module to external hokage consumer pattern. Physical console access was required to recover the system.

**Root Cause**:

1. The local hokage `serverMba.enable = true` mixin was providing the `mba` user's SSH key
2. When switching to explicit hokage options, the mixin was removed
3. The external hokage `server-home.nix` module auto-injected Patrizio's SSH keys (omega@yubikey, omega@rsa, omega@tuvb, omega@semaphore) into ALL users
4. Result: Only external omega keys were present, no `mba` key → complete lockout

**Impact**:

- Complete loss of SSH access to hsb8
- Required physical console access (HDMI + keyboard)
- System had to be recovered manually via physical console
- Approximately 2 hours of troubleshooting and recovery

**The Fix (Applied to hsb8, MUST apply to hsb0)**:

```nix
# In configuration.nix, AFTER hokage configuration:
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3..." # mba@markus ONLY
  ];
};
```

**Why `lib.mkForce` is Critical**:

- Without `lib.mkForce`: NixOS **merges** SSH keys (hokage keys + your keys)
- With `lib.mkForce`: NixOS **replaces** SSH keys (only your keys, no hokage keys)
- The hokage module's omega keys are deeply nested in the module system
- Only `lib.mkForce` can override them completely

**Secondary Issue: Passwordless Sudo**:

The `serverMba.enable` mixin also provided passwordless sudo (`security.sudo-rs.wheelNeedsPassword = false`). This was also lost during migration, causing sudo commands to fail after SSH was restored. Solution: explicitly add this to `configuration.nix`.

**Security Policy Established**:

- ✅ **hsb0**: Only `mba` (Markus) SSH key
- ✅ **hsb8**: Only `mba` (Markus) + `gb` (Gerhard/father) SSH keys
- ❌ **NO external keys** (omega@yubikey, omega@rsa, etc.) on personal/family servers
- 🔒 **ALL hokage external consumer configurations** MUST use `lib.mkForce` for SSH keys

**Testing Added**:

After the hsb8 incident, comprehensive SSH security testing was added:

- Test T09: SSH Access & Security (11 automated tests)
  - SSH key verification (only authorized keys present)
  - No external omega keys
  - Passwordless sudo enabled
  - SSH hardening (password auth disabled, root login disabled)

**Documentation Created**:

1. `hosts/hsb0/SSH-KEY-SECURITY-NOTE.md` - Warning for hsb0 migration
2. `hosts/hsb8/archive/MIGRATION-PLAN [DONE].md` - Updated with lockout addendum
3. Enhanced T09 test suite with security validation

**Lessons for hsb0 Migration**:

1. ✅ **Phase 2.5 is CRITICAL**: Must include `lib.mkForce` SSH key override
2. ✅ **Verify BEFORE deployment**: Check configuration has SSH override
3. ✅ **Verify AFTER deployment**: Check authorized_keys file (Phase 6)
4. ✅ **Physical access ready**: Have HDMI + keyboard ready just in case
5. ✅ **Passwordless sudo**: Add `security.sudo-rs.wheelNeedsPassword = false`
6. ✅ **Test thoroughly**: Don't skip Phase 4 (test build on miniserver24)

**Why This Matters for hsb0**:

hsb0 is a **CRITICAL DNS/DHCP server**. Unlike hsb8 (a test server), losing access to hsb0 would:

- Break DNS for the entire network (all devices)
- Require emergency physical access during potential family time
- Risk extended network downtime if recovery is complex

**Prevention is CRITICAL**: The `lib.mkForce` SSH override in Phase 2.5 is **non-negotiable** for hsb0.

---
