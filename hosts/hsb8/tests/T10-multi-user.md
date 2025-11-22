# T10: Multi-User Access

**Feature ID**: F10  
**Status**: ✅ Implemented  
**Location**: both (testable at jhw22 and ww87)

## Overview

Tests that multiple users (mba and gb) can access the server with their respective permissions.

## Prerequisites

- SSH access configured for both users
- Public keys configured

## Manual Test Procedure

### Step 1: Test MBA User Access

```bash
ssh mba@192.168.1.100 'whoami && id'
```

**Expected**:

- Returns `mba`
- Shows groups: wheel, networkmanager

### Step 2: Test GB User Access

```bash
ssh gb@192.168.1.100 'whoami && id'
```

**Expected**:

- Returns `gb`
- Shows user information

### Step 3: Verify Both Users in System

```bash
ssh mba@192.168.1.100
cat /etc/passwd | grep -E '^(mba|gb):'
```

**Expected**: Both users listed

### Step 4: Test MBA Sudo Access

```bash
ssh mba@192.168.1.100 'sudo -n whoami'
```

**Expected**: Returns `root` (mba has wheel group)

### Step 5: Test GB User Permissions

```bash
ssh gb@192.168.1.100 'ls ~'
```

**Expected**: Can access own home directory

## Automated Test

Run the automated test script:

```bash
./tests/T10-multi-user.sh
```

## Success Criteria

- ✅ MBA user can SSH and has sudo access
- ✅ GB user can SSH
- ✅ Both users exist in system
- ✅ Both users have home directories
- ✅ SSH key authentication works for both

## Troubleshooting

### User Cannot SSH

Check SSH keys:

```bash
ssh mba@192.168.1.100
sudo cat /home/gb/.ssh/authorized_keys
```

### Permission Issues

Check user groups:

```bash
ssh mba@192.168.1.100
groups mba
groups gb
```

## Test Log

| Date       | Tester | Location | Result | Notes         |
| ---------- | ------ | -------- | ------ | ------------- |
| 2025-11-22 | -      | -        | ⏳     | Awaiting test |
|            |        |          |        |               |
