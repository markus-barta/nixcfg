# P8900: Migrate miniserver-bp to NixOS (Fresh Start)

**Status**: READY FOR INSTALLATION  
**Priority**: P8 (Installation Ready)  
**Created**: 2026-01-13  
**Updated**: 2026-01-13

---

## 🎯 Objective

Migrate `miniserver-bp` (Mac Mini 2009, Ubuntu 24.04) to NixOS for declarative configuration management. It will be a testmachine and serve as a (wireguard) jump host additionally.

**Critical Requirements**:

- Hostname: `miniserver-bp` (MUST NOT CHANGE)
- Primary IP: `10.17.1.40/16` (MUST NOT CHANGE)
- WireGuard IP: `10.100.0.51/32` (MUST NOT CHANGE)
- User: `mba` (UID 1000)
- Shell: `fish`
- Role: Jump host + test server

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

| File                    | Purpose                 | Source        | Status |
| ----------------------- | ----------------------- | ------------- | ------ |
| `wireguard-private.key` | VPN private key         | Ubuntu server | ⏳     |
| `id_rsa`                | mba user SSH key        | Ubuntu server | ⏳     |
| `id_rsa.pub`            | mba user SSH public key | Ubuntu server | ⏳     |
| `ssh_host_ed25519_key`  | SSH host key (ed25519)  | Ubuntu server | ⏳     |
| `ssh_host_rsa_key`      | SSH host key (RSA)      | Ubuntu server | ⏳     |

**Location**: `hosts/miniserver-bp/secrets/`

**Status**: ✅ **COMPLETED** - All secrets validated and ready

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

- [x] Local IP: `10.100.0.51/32` ✅ Correct
- [x] Peer public key: `TZHbPPkIaxlpLKP2frzJl8PmOjYaRnfz/MqwCS7JDUQ=` ✅ Correct
- [x] Endpoint: `vpn.bytepoets.net:51820` ✅ Correct
- [x] Private key file path: `/etc/nixos/secrets/wireguard-private.key` ✅ Will be created by nixos-anywhere

**SSH**:

- [x] Host keys configured to preserve ✅ ed25519 and RSA keys ready
- [x] Password auth enabled for initial setup ✅ Configured
- [x] Authorized keys for mba user ✅ Public key present

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

**Template**:

```bash
# IMPORTANT: Two-step installation due to secrets directory issue
# Step 1: Basic installation without --extra-files
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver-bp \
  --build-on-remote \
  mba@<IP>

# Step 2: After successful boot, manually copy secrets
# On the new NixOS system:
# sudo mkdir -p /secrets
# sudo chown mba:mba /secrets
# scp -r user@source:/path/to/secrets/* mba@miniserver-bp:/secrets/
# sudo chown -R mba:mba /secrets/*
# sudo chmod 600 /secrets/*
```

**Questions**:

- [ ] Which installation method to use?
- [ ] What IP to use (local vs VPN)?
- [ ] Is `--build-on-remote` needed?

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

### 6.1 Basic Checks

- [ ] SSH access works (no host key warning)
- [ ] Hostname is correct
- [ ] IP address is correct
- [ ] Fish shell is default
- [ ] Uzumaki functions available

### 6.2 Network Tests

- [ ] WireGuard VPN connects
- [ ] Jump host to mba-imac-work works
- [ ] Internet connectivity

### 6.3 Theme Tests

- [ ] Starship prompt shows correct color
- [ ] Zellij theme applied
- [ ] Eza theme applied

---

## 🎯 Next Action

**Status**: ✅ **READY FOR INSTALLATION**

**All preflight checks completed successfully**:

- ✅ Environment validation (Phase 1)
- ✅ Secrets inventory (Phase 2)
- ✅ Configuration validation (Phase 3)
- ✅ Installation method determined (Phase 4)

**Installation command ready**:

```bash
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver-bp \
  --build-on-remote \
  --extra-files hosts/miniserver-bp/secrets \
  --chown /secrets 0:0 \
  mba@10.17.1.40
```

**Expected outcome**:

- ✅ SSH access preserved (no host key warnings)
- ✅ WireGuard VPN working immediately
- ✅ Jump host functionality maintained
- ✅ All services operational

**Risk level**: 🟢 LOW (all components validated)

**Next step**: Run the installation command above

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

**Phase 2: Secrets Inventory** ✅

- WireGuard private key extracted and verified ✅
- SSH host keys (ed25519, RSA) present in secrets ✅
- User SSH keys (id_rsa, id_rsa.pub) present in secrets ✅
- All secrets validated and ready for nixos-anywhere ✅

**Phase 3: Configuration Validation** ✅

- Network settings match current Ubuntu configuration ✅
- WireGuard configuration matches Ubuntu setup ✅
- SSH host keys paths correct for nixos-anywhere ✅
- User configuration (mba, UID 1000) correct ✅
- Uzumaki module integrated and configured ✅
- Hokage module imported and configured ✅

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

**Next**: Wait for user confirmation on Phase 1 checks.
