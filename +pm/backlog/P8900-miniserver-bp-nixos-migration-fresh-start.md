# P8900: Migrate miniserver-bp to NixOS (Fresh Start)

**Status**: READY FOR INSTALLATION  
**Priority**: P8 (Installation Ready)  
**Created**: 2026-01-13  
**Updated**: 2026-01-15

---

## 🎯 Objective

Migrate `miniserver-bp` (Mac Mini 2009, Ubuntu 24.04) to NixOS for declarative configuration management. It will be a testmachine and serve as a (wireguard) jump host additionally.

**Critical Requirements**:

- Hostname: `miniserver-bp` (MUST NOT CHANGE)
- Primary IP: `10.17.1.40/16` (MUST NOT CHANGE)
- WireGuard: Disabled initially (enable manually post-install)
- User: `mba` (UID 1000)
- Shell: `fish` (via uzumaki module)
- SSH: Same authorized keys as csb0/csb1
- Role: Test server + future jump host

---

## 📋 Phase 1: Environment Validation

**Goal**: Verify the installation environment is ready before attempting nixos-anywhere.

### 1.1 Current Server State (Ubuntu)

**Check**: What is currently running on miniserver-bp?

```bash
# From any machine with SSH access:
ssh mba@miniserver-bp.local  # or 10.17.1.40
```

**Information needed**:

- [x] OS version and kernel: Ubuntu 24.04.2 LTS, Linux 6.8.0-90-generic
- [x] Current disk layout: 489G total, 426G free, ext4 (no ZFS)
- [x] SSH host keys present: ed25519, rsa, ecdsa keys verified
- [x] Network configuration: enp0s10 with 10.17.1.40/16 (DHCP)
- [x] Running services: WireGuard VPN active and configured

**Status**: ✅ **COMPLETED** - All components validated

---

### 1.2 Installation Source (mba-imac-work)

**Check**: Can we run nixos-anywhere from the office iMac?

```bash
# On mba-imac-work (10.17.1.7):
ssh mba@10.17.1.7
```

**Information needed**:

- [x] Is nixos-anywhere available? ✅ (nix run github:nix-community/nixos-anywhere)
- [x] Is nixcfg repository present? ✅ (/Users/markus/Code/nixcfg)
- [x] Network connectivity to miniserver-bp ✅ (ping successful)
- [x] Current working directory ✅ (ready for installation)

**Status**: ✅ **COMPLETED** - Installation source ready

---

### 1.3 Network Reachability

**Check**: Can we reach miniserver-bp from the installation machine?

**Tests**:

- [x] Ping from mba-imac-work to miniserver-bp ✅ (5.269ms response)
- [x] SSH connectivity ✅ (passwordless access working)
- [x] WireGuard VPN status ✅ (active service, verified config)

**Status**: ✅ **COMPLETED** - Full network connectivity confirmed

---

## 📋 Phase 2: Secrets Inventory

**Goal**: Ensure all required secrets are extracted and available.

### 2.1 Required Secrets

**DECISION**: No secrets needed for initial installation.

**Rationale**:

- SSH host keys: NixOS generates fresh keys (clients will see warning - acceptable)
- SSH authorized keys: Embedded in configuration.nix (same as csb0/csb1)
- WireGuard: Disabled initially (commented out in config)
- Emergency password: Hashed password in configuration.nix

**WireGuard Re-enablement** (post-install):

1. Extract `wireguard-private.key` from Ubuntu backup
2. Copy to `/etc/nixos/secrets/wireguard-private.key` on NixOS
3. Uncomment WireGuard config in configuration.nix
4. `nixos-rebuild switch`

**Status**: ✅ **NO SECRETS NEEDED** - Clean installation approach

---

## 📋 Phase 3: Configuration Validation

**Goal**: Verify NixOS configuration files are complete and correct.

### 3.1 Configuration Files

- [ ] `hosts/miniserver-bp/configuration.nix` - Main config
- [ ] `hosts/miniserver-bp/disk-config.zfs.nix` - Disk layout
- [ ] `hosts/miniserver-bp/hardware-configuration.nix` - Hardware (placeholder)
- [ ] `flake.nix` - Integration

### 3.2 Key Configuration Elements

**Network**:

- [x] Static IP: `10.17.1.40/16` ✅ Matches Ubuntu
- [x] Gateway: `10.17.1.1` ✅ Correct
- [x] DNS: `1.1.1.1`, `10.17.1.1` ✅ Configured
- [x] Interface: `enp0s10` ✅ Matches Ubuntu

**WireGuard**:

- [x] Config commented out in configuration.nix ✅ Safe initial state
- [x] Can be enabled post-install manually ✅ Documented in runbook
- [x] Private key will be copied from Ubuntu backup later ✅ Planned

**SSH**:

- [x] Host keys: Fresh generation (Ubuntu keys discarded) ✅ Acceptable
- [x] Password auth enabled ✅ Emergency fallback
- [x] Authorized keys: Same as csb0/csb1 ✅ lib.mkForce pattern
- [x] Recovery password: Matches csb0/csb1 ✅ Hashed in config

**User**:

- [x] mba user with UID 1000 ✅ Configured
- [x] Fish shell ✅ Managed by uzumaki
- [x] Wheel group for sudo ✅ Configured
- [x] SSH authorized keys ✅ Public key present

**Uzumaki**:

- [x] Module enabled ✅ Imported
- [x] Role: server ✅ Configured
- [x] Fish editor: vim ✅ Set
- [x] Stasysmo enabled ✅ Configured

**Hokage**:

- [x] External module imported ✅ In flake.nix
- [x] Catppuccin disabled (Tokyo Night theme) ✅ Configured
- [x] Hostname configured ✅ miniserver-bp
- [x] User login configured ✅ mba user

**Status**: ✅ **COMPLETED** - All configuration elements validated

---

## 📋 Phase 4: Installation Method

**Goal**: Determine the best installation approach.

### 4.1 Options

**Option A: nixos-anywhere from office network**

- Pros: Direct access, no VPN complexity
- Cons: Requires physical/office presence

**Option B: nixos-anywhere via WireGuard VPN**

- Pros: Can be done from home
- Cons: VPN must be working

**Option C: USB stick installation**

- Pros: Most reliable, direct hardware access
- Cons: Requires physical access

### 4.2 nixos-anywhere Command

**Installation Approach**: USB stick minimal NixOS → nixos-anywhere

**Prerequisites**:

1. Boot miniserver-bp from minimal NixOS USB
2. User: `nixos`, Password: `1234` (temp)
3. Verify network: `ip addr show` (should get DHCP)
4. Get IP address for nixos-anywhere target

**Validated Command** (2026-01-15):

```bash
# From mba-imac-work (or any office machine)
cd ~/Code/nixcfg

# Run nixos-anywhere (no secrets, no extra files)
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver-bp \
  --build-on-remote \
  nixos@10.17.1.40
```

**Flags Explained**:

- `--flake .#miniserver-bp`: Use local flake config
- `--build-on-remote`: Build on target (Mac Mini, not iMac)
- `nixos@10.17.1.40`: Target user@IP (USB stick user)

**No flags needed**:

- ~~`--extra-files`~~: No secrets to copy
- ~~`--copy-host-keys`~~: Fresh keys acceptable
- ~~`--disk-encryption-keys`~~: No encryption

**Expected Outcome**:

- Full disk format (ZFS)
- NixOS installed with mba user
- SSH accessible via password or key
- WireGuard disabled (manual enable later)

---

## 📋 Phase 5: Rollback Plan

**Goal**: Ensure we can recover if installation fails.

### 5.1 Fallback Options

- [ ] Ubuntu remains bootable until final reboot
- [ ] Can restore from backup if needed
- [ ] Network configuration won't break existing setup

### 5.2 Pre-Installation Backup

**Optional**: Backup current Ubuntu state

```bash
# On miniserver-bp:
sudo tar -czf /tmp/ubuntu-backup.tar.gz /etc/ssh /home/mba /var/lib
# Copy to safe location
```

**Status**: ⏳ Not yet decided if needed

---

## 📋 Phase 6: Post-Installation Verification

**Goal**: Confirm NixOS is working correctly.

**Status**: ✅ **COMPLETED** (2026-01-15 12:40 CET)

### 6.1 Basic Checks

- [x] ✅ SSH access works (port 2222)
- [x] ✅ Hostname: miniserver-bp
- [x] ✅ IP address: 10.17.1.40/16
- [x] ✅ Fish shell: v4.3.3
- [x] ✅ User: mba (UID 1000)
- [x] ✅ NixOS version: 26.05 (Yarara)
- [x] ✅ Kernel: 6.18.4

### 6.2 Uzumaki Components

- [x] ✅ zellij installed and working
- [x] ✅ starship installed and working
- [x] ✅ eza installed and working
- [x] ✅ bat installed and working
- [x] ✅ fish shell set as default
- [x] ✅ StaSysMo: N/A (needs terminal for metrics)

### 6.3 Network Tests

- [x] ✅ Static IP configured: 10.17.1.40/16
- [x] ✅ Office network reachable
- [x] ✅ Internet connectivity: Working
- [ ] ⏳ WireGuard VPN: Deferred to Phase 7

### 6.4 Storage

- [x] ✅ ZFS pool: zroot (healthy)
- [x] ✅ Disk usage: 1% (467GB available)
- [x] ✅ Boot: EFI working

### 6.5 Documentation

- [x] ✅ README.md created
- [x] ✅ RUNBOOK.md created (with Phase 7 WireGuard guide)

---

## 📋 Phase 7: WireGuard Setup (Post-Install)

**Goal**: Enable WireGuard VPN for jump host functionality.

**Status**: ⏳ AFTER PHASE 6

### 7.1 Extract WireGuard Key from Ubuntu

**Before wiping Ubuntu**, backup the WireGuard key:

```bash
# On Ubuntu miniserver-bp (if still accessible):
ssh mba@miniserver-bp.local
sudo cat /etc/wireguard/wg0.conf
# Copy the PrivateKey value
```

**Alternative**: If Ubuntu already wiped, regenerate:

1. Generate new key: `wg genkey | tee privatekey | wg pubkey > publickey`
2. Update BYTEPOETS VPN server with new public key
3. Use new private key

### 7.2 Configure WireGuard on NixOS

```bash
# On NixOS miniserver-bp:
ssh mba@10.17.1.40

# Create secrets directory
sudo mkdir -p /etc/nixos/secrets
sudo chmod 700 /etc/nixos/secrets

# Create WireGuard private key file
# Paste the private key from Ubuntu backup
sudo nano /etc/nixos/secrets/wireguard-private.key
sudo chmod 600 /etc/nixos/secrets/wireguard-private.key
```

### 7.3 Enable WireGuard in Configuration

```bash
# On mba-imac-work:
cd ~/Code/nixcfg

# Edit configuration.nix - uncomment WireGuard section (lines 78-93)
# Then rebuild:
just switch-remote miniserver-bp
```

### 7.4 Test VPN

```bash
# On miniserver-bp:
sudo wg show
# Should show wg0 interface with peer

# From home (via VPN):
ping 10.100.0.51
ssh mba@10.100.0.51
```

---

## 🎯 Next Action

**Status**: ✅ **INSTALLATION COMPLETE** (2026-01-15 12:30 CET)

**Used command**:

```bash
cd ~/Code/nixcfg

nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver-bp \
  --build-on-remote \
  nixos@10.17.1.40
```

**Prerequisites**:

1. ✅ Boot miniserver-bp from minimal NixOS USB
2. ✅ User: `nixos`, Password: `1234`
3. ✅ Network: DHCP → 10.17.1.40
4. ✅ Run from: mba-imac-work (office network)

**What happens**:

1. Formats disk with ZFS (disko)
2. Builds NixOS on target (--build-on-remote)
3. Installs with mba user (UID 1000)
4. Configures SSH (fresh host keys)
5. Applies uzumaki module (fish, zellij, stasysmo)
6. Reboots into NixOS

**Post-install**:

- SSH: `ssh mba@10.17.1.40` (password auth enabled)
- WireGuard: Disabled (enable manually later)
- Recovery password: Same as csb0/csb1

**Risk level**: 🟢 LOW (minimal config, no secrets)

**Result**: ✅ **SUCCESS** - System installed and verified

**Next phase**: Phase 7 (WireGuard setup) - See RUNBOOK.md

## 🔍 Step-by-Step Validation Plan

### Step 1: Environment Validation

- [x] ✅ Verify current Ubuntu state on miniserver-bp
- [x] ✅ Check disk layout and available space (426G free)
- [x] ✅ Verify SSH connectivity from installation machine (working)
- [x] ✅ Confirm network configuration matches expectations (matches)

### Step 2: Secrets Validation

- [x] ✅ Extract missing `wireguard-private.key` from Ubuntu (already present)
- [x] ✅ Extract missing `id_rsa` from Ubuntu (present in secrets)
- [x] ✅ Verify all secrets are in correct location with proper permissions
- [x] ✅ Fix WireGuard private key path in configuration.nix (correct)

### Step 3: Configuration Validation

- [x] ✅ Review and fix WireGuard private key path (correct)
- [x] ✅ Verify hokage module integration (imported)
- [x] ✅ Check uzumaki module configuration (configured)
- [x] ✅ Validate network settings match current Ubuntu config (matches)

### Step 4: Dry Run Preparation

- [x] ✅ Test nixos-anywhere command syntax (ready)
- [x] ✅ Verify flake.nix integration (miniserver-bp defined)
- [x] ✅ Check disko configuration (ZFS layout ready)

### Step 5: Installation Execution

- [ ] Run nixos-anywhere with proper flags
- [ ] Monitor installation progress
- [ ] Handle any errors methodically

### Step 6: Post-Installation Verification

- [ ] Test SSH access (no host key warnings)
- [ ] Verify WireGuard VPN connectivity
- [ ] Test jump host functionality
- [ ] Confirm uzumaki/hokage features work

---

## 📝 Notes

**Lessons from P8000 failures**:

- Missing secrets likely caused installation failures
- No pre-installation validation was performed
- Configuration issues (WireGuard path) not caught early
- No clear error diagnosis before retrying

**New approach**:

- Validate every component before installation
- Fix all configuration issues first
- Methodical step-by-step with user confirmation
- Clear error diagnosis if anything fails

---

## ✅ Completed Steps

**Phase 1: Environment Validation** ✅

- Current Ubuntu state verified (Ubuntu 24.04.2 LTS)
- Disk layout confirmed (489G total, 426G free)
- SSH connectivity tested (passwordless access working)
- Network configuration validated (10.17.1.40/16 on enp0s10)
- WireGuard service confirmed active and configured

**Phase 2: Secrets Strategy** ✅

- No secrets needed for initial install ✅
- SSH keys embedded in configuration.nix ✅
- WireGuard deferred to Phase 7 (post-install) ✅
- Emergency password hashed in configuration.nix ✅

**Phase 3: Configuration Validation** ✅

- Network settings: 10.17.1.40/16 static IP ✅
- WireGuard: Commented out (Phase 7) ✅
- SSH: lib.mkForce pattern (csb0/csb1 compatible) ✅
- User: mba (UID 1000), fish shell ✅
- Uzumaki: server role, vim editor, stasysmo ✅
- Hokage: server-remote role, Tokyo Night theme ✅

**Phase 4: Installation Preparation** ✅

- nixos-anywhere command syntax validated ✅
- Flake.nix integration confirmed (miniserver-bp defined) ✅
- Disko configuration ready (ZFS layout) ✅
- All preflight checks passed ✅

---

## ❌ Previous Failures (P8000)

**Attempt 1**: Home via VPN

- Status: Failed
- Reason: connection interrupted

**Attempt 2**: Office network

- Status: Failed
- Reason: never finished - command hung locally?

**Learning**: Need to diagnose failures before retrying.

---

## ✅ Installation Complete (2026-01-15)

**Timeline**:

- 12:30 CET: nixos-anywhere installation started
- 12:30 CET: System booted successfully
- 12:40 CET: Verification completed

**Verified Components**:

| Component | Status  | Details                              |
| --------- | ------- | ------------------------------------ |
| OS        | ✅ Pass | NixOS 26.05 (Yarara), kernel 6.18.4  |
| SSH       | ✅ Pass | Port 2222, password + key auth       |
| Network   | ✅ Pass | 10.17.1.40/16 static IP              |
| User      | ✅ Pass | mba (UID 1000), fish shell           |
| Storage   | ✅ Pass | ZFS pool healthy, 467GB free         |
| Uzumaki   | ✅ Pass | zellij, starship, eza, bat installed |
| Hokage    | ✅ Pass | External module working              |
| Docs      | ✅ Pass | README.md + RUNBOOK.md created       |

**Known Items**:

- ✅ Font warning on console: Normal for headless server (ignored)
- ✅ SSH port 2222: Correct (hokage server-remote pattern)
- ⏳ WireGuard: Intentionally disabled (Phase 7 manual setup)

**Lessons Learned**:

1. ✅ No secrets in --extra-files = simpler install
2. ✅ Fresh SSH keys = acceptable for test server
3. ✅ Password auth fallback = prevented lockout
4. ✅ Port 2222 from hokage = expected behavior

**Next Actions**:

1. ⏳ **Optional**: Enable WireGuard (see RUNBOOK.md Phase 7)
2. ✅ **Done**: Document installation (this file + README + RUNBOOK)
3. ⏳ **Future**: Clone nixcfg repo to server for local rebuilds

---

**Installation validated successfully. System ready for use.**
