# T09: SSH Remote Access & Security

**Feature ID**: F09  
**Status**: ✅ Implemented

## Overview

Tests that SSH remote access is working correctly and securely configured for server management. Includes verification of SSH keys, sudo configuration, and password security.

## Prerequisites

- Network connectivity to hsb0
- SSH client installed
- SSH key configured for mba user

## Manual Test Procedure

### Step 1: Test SSH Connection (mba user)

```bash
ssh mba@192.168.1.99 'echo "SSH connection successful"'
```

**Expected**: Command executes and prints "SSH connection successful"

### Step 2: Test SSH via Hostname

```bash
ssh mba@hsb0.lan 'echo "SSH hostname resolution works"'
```

**Expected**: Command executes successfully

### Step 3: Test SSH Service Status

```bash
ssh mba@192.168.1.99
systemctl status sshd
```

**Expected**: Service is `active (running)`

### Step 4: Verify SSH Port

```bash
nc -zv 192.168.1.99 22
```

**Expected**: Port 22 is open

### Step 5: Test Key-Based Authentication

```bash
ssh -o PasswordAuthentication=no mba@192.168.1.99 'whoami'
```

**Expected**: Logs in without password prompt

### Step 6: Verify Passwordless Sudo

```bash
ssh mba@192.168.1.99 'sudo -n whoami'
```

**Expected**: Outputs "root" without password prompt

### Step 7: Check User Password Exists

```bash
ssh mba@192.168.1.99 'sudo getent shadow mba | cut -d: -f2 | cut -c1-5'
```

**Expected**: Shows `$y$j9` or `$6$ab` (yescrypt or SHA-512 hash), NOT `!` or `*`

### Step 8: Verify SSH Keys (mba user)

```bash
ssh mba@192.168.1.99 'cat ~/.ssh/authorized_keys'
```

**Expected**:

- Exactly 1 SSH key (if using local hokage module)
- Your mba@markus key present
- If migrated to external hokage: verify NO omega or yubikey entries

### Step 9: Verify SSH Hardening

```bash
ssh mba@192.168.1.99 'sudo grep -E "^PasswordAuthentication|^PermitRootLogin" /etc/ssh/sshd_config'
```

**Expected**:

- `PasswordAuthentication no`
- `PermitRootLogin no`

## Automated Test

Run the automated test script:

```bash
./tests/T09-ssh-access.sh
```

This script runs 8 tests covering:

- SSH connectivity and hostname resolution
- SSH service status and port accessibility
- Key-based authentication
- Passwordless sudo
- User password security
- SSH key configuration
- SSH hardening (password auth disabled, root login disabled)

## Success Criteria

- ✅ SSH connection works via IP and hostname
- ✅ SSH service running and port accessible
- ✅ Key-based authentication functional
- ✅ Passwordless sudo enabled for wheel group
- ✅ User password set (for emergency console access)
- ✅ Only authorized SSH keys present (no external keys)
- ✅ SSH hardening applied (no password auth, no root login)

## Troubleshooting

### SSH Connection Refused

```bash
ping 192.168.1.99
nc -zv 192.168.1.99 22
```

Check network connectivity and firewall.

### Key Authentication Fails

```bash
ssh -vvv mba@192.168.1.99
```

Check SSH key configuration and permissions.

### Passwordless Sudo Not Working

```bash
ssh mba@192.168.1.99 'groups'
```

Verify user is in wheel group.

### 🚨 External Keys Found (Post-Hokage Migration)

If omega or yubikey keys are found after external hokage migration:

1. This is a CRITICAL SECURITY ISSUE
2. The `lib.mkForce` SSH key override was not applied correctly
3. See `MIGRATION-PLAN-HOKAGE.md` Phase 2.5 for fix
4. DO NOT PROCEED with migration until fixed

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

- SSH is critical for remote management of the DNS/DHCP server
- Key-based authentication is more secure than passwords
- Passwordless sudo simplifies administration (user password still set for emergency console access)
- SSH hardening prevents brute-force attacks
- **Important**: After external hokage migration, verify NO external omega keys are present
