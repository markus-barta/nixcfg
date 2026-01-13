# P9000: Migrate miniserver-bp to NixOS (Fresh Start)

**Status**: IN PROGRESS  
**Priority**: P9 (Validation Phase)  
**Created**: 2026-01-13  
**Updated**: 2026-01-13

---

## 🎯 Objective

Migrate `miniserver-bp` (Mac Mini 2009, Ubuntu 24.04) to NixOS for declarative configuration management.

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

- [ ] OS version and kernel
- [ ] Current disk layout
- [ ] SSH host keys present
- [ ] Network configuration (IP, interface, gateway)
- [ ] Any running services that need preservation

**Status**: ⏳ Not yet verified

---

### 1.2 Installation Source (mba-imac-work)

**Check**: Can we run nixos-anywhere from the office iMac?

```bash
# On mba-imac-work (10.17.1.7):
ssh mba@10.17.1.7
```

**Information needed**:

- [ ] Is nixos-anywhere available? (`which nixos-anywhere`)
- [ ] Is nixcfg repository present? (`ls ~/Code/nixcfg`)
- [ ] Network connectivity to miniserver-bp (`ping 10.17.1.40`)
- [ ] Current working directory for installation

**Status**: ⏳ Not yet verified

---

### 1.3 Network Reachability

**Check**: Can we reach miniserver-bp from the installation machine?

**Tests**:

- [ ] Ping from mba-imac-work to miniserver-bp
- [ ] SSH connectivity (password or key-based)
- [ ] WireGuard VPN status (if needed for remote installation)

**Status**: ⏳ Not yet verified

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

**Status**: ⏳ Need to verify what exists vs. what needs extraction

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

- [ ] Static IP: `10.17.1.40/16`
- [ ] Gateway: `10.17.1.1`
- [ ] DNS: `1.1.1.1`, `10.17.1.1`
- [ ] Interface: `enp0s10`

**WireGuard**:

- [ ] Local IP: `10.100.0.51/32`
- [ ] Peer public key: `TZHbPPkIaxlpLKP2frzJl8PmOjYaRnfz/MqwCS7JDUQ=`
- [ ] Endpoint: `vpn.bytepoets.net:51820`
- [ ] Private key file path in config

**SSH**:

- [ ] Host keys configured to preserve
- [ ] Password auth enabled for initial setup
- [ ] Authorized keys for mba user

**User**:

- [ ] mba user with UID 1000
- [ ] Fish shell
- [ ] Wheel group for sudo
- [ ] SSH authorized keys

**Uzumaki**:

- [ ] Module enabled
- [ ] Role: server
- [ ] Fish editor: vim
- [ ] Stasysmo enabled

**Hokage**:

- [ ] External module imported
- [ ] Catppuccin disabled (Tokyo Night theme)
- [ ] Hostname configured
- [ ] User login configured

**Status**: ⏳ Need to review all configuration files

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
nix run github:nix-community/nixos-anywhere -- \
  --flake .#miniserver-bp \
  --build-on-remote \
  --extra-files hosts/miniserver-bp/secrets \
  --chown /secrets 0:0 \
  mba@<IP>
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

**What I need from you**:

1. **Confirm current state**: Are you at home or office?
2. **SSH access**: Can you SSH to miniserver-bp from where you are?
3. **Installation machine**: Are you on mba-imac-work or another machine?
4. **nixos-anywhere**: Is it installed on your current machine?

**Once you confirm, I will**:

- Validate the first item on the checklist
- Report findings
- Wait for your approval before proceeding to next step

## 🔍 Step-by-Step Validation Plan

### Step 1: Environment Validation

- [ ] Verify current Ubuntu state on miniserver-bp
- [ ] Check disk layout and available space
- [ ] Verify SSH connectivity from installation machine
- [ ] Confirm network configuration matches expectations

### Step 2: Secrets Validation

- [ ] Extract missing `wireguard-private.key` from Ubuntu
- [ ] Extract missing `id_rsa` from Ubuntu
- [ ] Verify all secrets are in correct location with proper permissions
- [ ] Fix WireGuard private key path in configuration.nix

### Step 3: Configuration Validation

- [ ] Review and fix WireGuard private key path
- [ ] Verify hokage module integration
- [ ] Check uzumaki module configuration
- [ ] Validate network settings match current Ubuntu config

### Step 4: Dry Run Preparation

- [ ] Test nixos-anywhere command syntax
- [ ] Verify flake.nix integration
- [ ] Check disko configuration

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

(None yet - this is a fresh start)

---

## ❌ Previous Failures (P8000)

**Attempt 1**: Home via VPN

- Status: Failed
- Reason: Unknown

**Attempt 2**: Office network

- Status: Failed
- Reason: Unknown

**Learning**: Need to diagnose failures before retrying.

---

**Next**: Wait for user confirmation on Phase 1 checks.
