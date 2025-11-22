# T06: SSH Remote Access

**Feature ID**: F06  
**Status**: ✅ Implemented  
**Location**: Both jhw22 and ww87

## Overview

Tests that SSH remote access is working correctly for server management.

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

## Automated Test

Run the automated test script:

```bash
./tests/T06-ssh-access.sh
```

## Success Criteria

- ✅ SSH connection works via IP address
- ✅ SSH connection works via hostname
- ✅ SSH service is active
- ✅ Port 22 is accessible
- ✅ Key-based authentication works

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

## Test Log

| Date       | Tester | Location | Result | Notes                       |
| ---------- | ------ | -------- | ------ | --------------------------- |
| 2025-11-22 | AI     | jhw22    | ✅     | Working at testing location |
|            |        |          |        |                             |
