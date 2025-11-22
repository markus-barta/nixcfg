# T09: SSH Remote Access & Security

**Feature ID**: F09  
**Status**: ✅ Implemented  
**Location**: Both jhw22 and ww87

## Overview

Tests that SSH remote access is working correctly and securely configured for server management. Includes verification of SSH keys, sudo configuration, and password security.

## Prerequisites

- Network connectivity to hsb8
- SSH client installed
- SSH key or password authentication configured

## Manual Test Procedure

### Step 1: Test SSH Connection (mba user)

```bash
ssh mba@192.168.1.100 'echo "SSH connection successful"'
```

**Expected**: Command executes and prints "SSH connection successful"

### Step 2: Test SSH via Hostname

```bash
ssh mba@hsb8.lan 'echo "SSH hostname resolution works"'
```

**Expected**: Command executes successfully

### Step 3: Test SSH Service Status

```bash
ssh mba@192.168.1.100
systemctl status sshd
```

**Expected**: Service is `active (running)`

### Step 4: Verify SSH Port

```bash
nc -zv 192.168.1.100 22
```

**Expected**: Port 22 is open

### Step 5: Test Key-Based Authentication

```bash
ssh -o PasswordAuthentication=no mba@192.168.1.100 'whoami'
```

**Expected**: Logs in without password prompt

### Step 6: Verify Passwordless Sudo

```bash
ssh mba@192.168.1.100 'sudo -n whoami'
```

**Expected**: Outputs "root" without password prompt

### Step 7: Check User Password Exists

```bash
ssh mba@192.168.1.100 'sudo getent shadow mba | cut -d: -f2 | cut -c1-5'
```

**Expected**: Shows `$y$j9` or `$6$ab` (yescrypt or SHA-512 hash), NOT `!` or `*`

### Step 8: Verify SSH Keys (mba user)

```bash
ssh mba@192.168.1.100 'sudo cat /etc/ssh/authorized_keys.d/mba'
```

**Expected**:

- Exactly 1 SSH key
- Your mba@markus key present
- NO omega or yubikey entries

### Step 9: Verify SSH Keys (gb user)

```bash
ssh mba@192.168.1.100 'sudo cat /etc/ssh/authorized_keys.d/gb'
```

**Expected**:

- Exactly 1 SSH key
- gb@gerhard key present
- NO omega or yubikey entries

### Step 10: Verify SSH Hardening

```bash
ssh mba@192.168.1.100 'sudo grep -E "^PasswordAuthentication|^PermitRootLogin" /etc/ssh/sshd_config'
```

**Expected**:

- `PasswordAuthentication no`
- `PermitRootLogin no`

## Automated Test

Run the automated test script:

```bash
./tests/T09-ssh-access.sh
```

This script runs 11 tests covering:

1. SSH connection via IP
2. SSH connection via hostname
3. SSH service status
4. Port accessibility
5. Command execution
6. Passwordless sudo
7. User password configured
8. SSH key security (mba)
9. SSH key security (gb)
10. SSH password auth disabled
11. Root SSH login disabled

## Success Criteria

**SSH Functionality:**

- ✅ SSH connection works via IP address
- ✅ SSH connection works via hostname
- ✅ SSH service is active
- ✅ Port 22 is accessible
- ✅ Key-based authentication works

**Security Configuration:**

- ✅ Passwordless sudo enabled
- ✅ User password exists (for recovery)
- ✅ Only authorized keys present (mba + gb)
- ✅ No external keys (omega/yubikey blocked)
- ✅ SSH password authentication disabled
- ✅ Root SSH login disabled

## Troubleshooting

### Connection Refused

```bash
ping 192.168.1.100
```

Check if server is reachable.

### Permission Denied

Check SSH keys:

```bash
ssh -v mba@192.168.1.100
```

Look for key authentication attempts in verbose output.

### Security Alert: External Keys Found

If the test detects omega or yubikey entries:

```bash
# Check configuration
ssh mba@192.168.1.100 'sudo cat /etc/ssh/authorized_keys.d/mba'

# Should only show mba@markus key
# If external keys present, verify configuration.nix has lib.mkForce
```

The `lib.mkForce` in `configuration.nix` ensures only your keys are used:

```nix
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3..." # mba@markus only
  ];
};
```

## Related Documentation

- `hosts/hsb8/configuration.nix` - SSH key overrides with `lib.mkForce`
- `hosts/hsb8/README.md` - SSH Key Security Policy section
- `hosts/hsb0/SSH-KEY-SECURITY-NOTE.md` - Background on hokage module key injection

## Test Log

| Date       | Tester | Location | Result | Notes                                     |
| ---------- | ------ | -------- | ------ | ----------------------------------------- |
| 2025-11-22 | AI     | jhw22    | ✅     | All 11 tests pass (SSH + security checks) |
| 2025-11-22 | AI     | jhw22    | ✅     | Security verified: keys, sudo, password   |
|            |        |          |        |                                           |
