# T06: SSH Remote Access (csb0)

Test SSH access and security hardening.

## Host Information

| Property     | Value         |
| ------------ | ------------- |
| **Host**     | csb0          |
| **IP**       | 85.235.65.226 |
| **SSH Port** | 2222          |
| **User**     | mba           |

## Prerequisites

- [ ] SSH key configured
- [ ] Network access to port 2222

## Automated Tests

Run: `./T06-ssh-access.sh`

## Test Procedures

### Test 1: SSH Connectivity

**Command:** `ssh -p 2222 mba@cs0.barta.cm 'echo success'`

**Expected:** "success"

### Test 2: SSH Service Status

**Command:** `systemctl is-active sshd`

**Expected:** `active`

### Test 3: Key-Based Authentication

**Command:** SSH with `-o PasswordAuthentication=no`

**Expected:** Success (proves key auth works)

### Test 4: Passwordless Sudo

**Command:** `sudo -n whoami`

**Expected:** `root`

### Test 5: SSH Keys Configured

**Command:** `grep -c "^ssh-" ~/.ssh/authorized_keys`

**Expected:** At least 1 key

### Test 6: No External Omega Keys

**Command:** `grep -c "omega" ~/.ssh/authorized_keys`

**Expected:** 0 (external hokage keys removed via mkForce)

### Test 7: Password Auth Disabled

**Command:** Check `/etc/ssh/sshd_config` for `PasswordAuthentication no`

**Expected:** Password auth disabled

### Test 8: Root Login Disabled

**Command:** Check `/etc/ssh/sshd_config` for `PermitRootLogin no`

**Expected:** Root login disabled

## Test Results Summary

| Test | Description       | Status |
| ---- | ----------------- | ------ |
| T1   | SSH Connectivity  | ⏳     |
| T2   | SSH Service       | ⏳     |
| T3   | Key Auth          | ⏳     |
| T4   | Passwordless Sudo | ⏳     |
| T5   | SSH Keys          | ⏳     |
| T6   | No Omega Keys     | ⏳     |
| T7   | Password Auth Off | ⏳     |
| T8   | Root Login Off    | ⏳     |

## Notes

- Recovery password in 1Password: "csb0 csb1 recovery"
- VNC console available via Netcup SCP
- External hokage keys blocked with `lib.mkForce`
