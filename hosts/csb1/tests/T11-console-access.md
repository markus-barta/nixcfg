# T11: Console Access Verification

**Feature ID**: F11  
**Status**: ⏳ Pending  
**Purpose**: Verify emergency console access is available and documented

## Overview

Verifies that all emergency access methods are documented and accessible. This is critical for migration - if SSH breaks, you need alternative access.

## Access Methods (Priority Order)

### 1. Primary: SSH with Key

```bash
ssh -p 2222 mba@cs1.barta.cm
```

### 2. Backup: SSH with Password

```bash
ssh -p 2222 mba@cs1.barta.cm
# Password in secrets/RUNBOOK.md
```

### 3. Emergency: Netcup VNC Console

**URL**: https://www.servercontrolpanel.de/SCP

**Steps**:

1. Login with customer number (see secrets/RUNBOOK.md)
2. Complete 2FA authentication
3. Navigate to server csb1
4. Click "VNC Console" or "Console"
5. Login as `mba` with password

### 4. Recovery: Netcup Rescue Mode

Via Netcup Server Control Panel:

1. Select server
2. Choose "Rescue System" or "Recovery Mode"
3. Boot into rescue environment
4. Mount ZFS pools
5. Repair configuration

## Pre-Migration Verification Checklist

### Credentials Available

- [ ] SSH key configured and working
- [ ] mba user password documented in secrets/RUNBOOK.md
- [ ] Root password documented in secrets/RUNBOOK.md
- [ ] Netcup customer number documented
- [ ] Netcup 2FA device available

### Access Tested

- [ ] SSH with key works
- [ ] SSH with password works (test before migration!)
- [ ] Can login to Netcup SCP
- [ ] Can access VNC console (test it!)
- [ ] Know how to use GRUB menu for rollback

### Emergency Commands Saved

- [ ] Rollback command documented
- [ ] Root emergency access command documented
- [ ] Recovery procedure documented

## Manual Test Procedure

### Step 1: Verify SSH Key Access

```bash
ssh -p 2222 -o PasswordAuthentication=no mba@cs1.barta.cm 'echo "Key auth OK"'
```

### Step 2: Verify Password Access

```bash
# Temporarily allow password auth for this test
ssh -p 2222 -o PreferredAuthentications=password mba@cs1.barta.cm 'echo "Password auth OK"'
# Enter password from secrets/RUNBOOK.md
```

### Step 3: Verify Netcup Access

1. Open https://www.servercontrolpanel.de/SCP
2. Login with customer number
3. Complete 2FA
4. Verify server csb1 is listed
5. Verify VNC console button is available

### Step 4: Test VNC Console (Optional but Recommended)

1. Click VNC Console
2. Wait for console to load
3. Press Enter to see login prompt
4. Login as mba (or just verify you see the prompt)
5. Exit

## Automated Test

```bash
./tests/T11-console-access.sh
```

Note: Cannot fully automate Netcup VNC access - requires manual verification.

## Success Criteria

- ✅ SSH key authentication works
- ✅ Password for mba user documented
- ✅ Password for root user documented (emergency)
- ✅ Netcup credentials documented
- ✅ Netcup 2FA available
- ✅ VNC console accessible (manually verified)

## Critical Information Location

All emergency access info should be in:

```
hosts/csb1/secrets/RUNBOOK.md
```

This file is gitignored and contains:

- IP addresses
- SSH connection details
- User passwords
- Netcup customer number
- Recovery procedures

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |

## Notes

**Before every migration**:

1. Verify Netcup login works
2. Verify VNC console loads
3. Have RUNBOOK.md open in another window
4. Have phone ready for 2FA
