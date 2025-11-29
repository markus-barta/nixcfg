# T06: SSH Remote Access & Security

**Feature ID**: F06  
**Status**: ⏳ Pending

## Overview

Tests that SSH remote access is working correctly and securely configured for server management. csb1 uses port 2222 (not default 22).

## Prerequisites

- Network connectivity to csb1
- SSH client installed
- SSH key configured for mba user

## Manual Test Procedure

### Step 1: Test SSH Connection

```bash
ssh -p 2222 mba@cs1.barta.cm 'echo "SSH connection successful"'
```

**Expected**: Command executes and prints "SSH connection successful"

### Step 2: Test SSH via IP

```bash
ssh -p 2222 mba@152.53.64.166 'echo "SSH via IP works"'
```

**Expected**: Command executes successfully

### Step 3: Test SSH Service Status

```bash
ssh -p 2222 mba@cs1.barta.cm
systemctl status sshd
```

**Expected**: Service is `active (running)`

### Step 4: Verify SSH Port

```bash
nc -zv cs1.barta.cm 2222
```

**Expected**: Port 2222 is open

### Step 5: Test Key-Based Authentication

```bash
ssh -p 2222 -o PasswordAuthentication=no mba@cs1.barta.cm 'whoami'
```

**Expected**: Logs in without password prompt

### Step 6: Verify Passwordless Sudo

```bash
ssh -p 2222 mba@cs1.barta.cm 'sudo -n whoami'
```

**Expected**: Outputs "root" without password prompt

### Step 7: Verify SSH Keys (mba user)

```bash
ssh -p 2222 mba@cs1.barta.cm 'cat ~/.ssh/authorized_keys'
```

**Expected**:

- Your mba@markus key present
- After hokage migration: verify NO omega or yubikey entries

### Step 8: Verify SSH Hardening

```bash
ssh -p 2222 mba@cs1.barta.cm 'sudo grep -E "^PasswordAuthentication|^PermitRootLogin" /etc/ssh/sshd_config'
```

**Expected**:

- `PasswordAuthentication no`
- `PermitRootLogin no`

## Automated Test

Run the automated test script:

```bash
./tests/T06-ssh-access.sh
```

## Success Criteria

- ✅ SSH connection works (port 2222)
- ✅ SSH service running
- ✅ Key-based authentication functional
- ✅ Passwordless sudo enabled
- ✅ Only authorized SSH keys present
- ✅ SSH hardening applied

## Emergency Access

If SSH fails:

1. **VNC Console**: Access via Netcup Server Control Panel
2. **Provider Panel**: https://www.servercontrolpanel.de/SCP
3. **Customer Number**: See 1Password

## Troubleshooting

### SSH Connection Refused

```bash
ping cs1.barta.cm
nc -zv cs1.barta.cm 2222
```

Check network connectivity and firewall.

### Key Authentication Fails

```bash
ssh -p 2222 -vvv mba@cs1.barta.cm
```

Check SSH key configuration and permissions.

### Passwordless Sudo Not Working

```bash
ssh -p 2222 mba@cs1.barta.cm 'groups'
```

Verify user is in wheel group.

### 🚨 External Keys Found (Post-Hokage Migration)

If omega or yubikey keys are found after external hokage migration:

1. This is a CRITICAL SECURITY ISSUE
2. The `lib.mkForce` SSH key override was not applied correctly
3. See `docs/MIGRATION-PLAN-HOKAGE.md` Phase 2.5 for fix
4. DO NOT PROCEED with migration until fixed

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

- SSH port 2222 is used (not default 22)
- Key-based authentication is required
- Password authentication should be disabled
- After hokage migration, verify only authorized keys present
