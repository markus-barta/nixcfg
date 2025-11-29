# csb1 Test Suite

This directory contains test procedures and automated scripts to verify that all cloud server features are working correctly.

## Test Format

Each feature has:

- **Test Documentation** (`Txx-feature-name.md`): Detailed manual test procedures
- **Test Script** (`Txx-feature-name.sh`): Automated test script (where applicable)

## Running Tests

### Individual Test

```bash
# Run manual test (follow instructions in markdown file)
cat tests/T01-docker-services.md

# Run automated test
./tests/T01-docker-services.sh
```

### All Automated Tests

```bash
# Run all tests
cd hosts/csb1
for test in tests/T*.sh; do
  echo "Running $test..."
  bash "$test" || echo "❌ Failed: $test"
done
```

## Test Status Legend

- ✅ **Pass**: Feature working as expected
- ⏳ **Pending**: Feature not yet tested
- ❌ **Fail**: Feature not working, requires attention
- N/A: Test type not applicable for this feature

## Prerequisites

- SSH access to csb1 (port 2222)
- Network connectivity to csb1
- For service tests: Docker must be running

## Environment Variables

Tests can be configured using environment variables:

```bash
# Override defaults
export CSB1_HOST="cs1.barta.cm"
export CSB1_USER="mba"
export CSB1_SSH_PORT="2222"

# Run tests
./tests/T00-nixos-base.sh
```

## Test List

### Regular Tests (Run Anytime)

| Test ID | Feature           | 👇🏻 Manual | 🤖 Auto          | Result | Notes                      |
| ------- | ----------------- | --------- | ---------------- | ------ | -------------------------- |
| T00     | NixOS Base System | ⏳        | 2025-11-29 10:45 | ✅     | NixOS 24.11, 4 generations |
| T01     | Docker Services   | ⏳        | 2025-11-29 10:45 | ✅     | 15 containers, 13 volumes  |
| T02     | Grafana           | ⏳        | 2025-11-29 10:45 | ✅     | Healthy, external URL OK   |
| T03     | InfluxDB          | ⏳        | 2025-11-29 10:45 | ✅     | Up 6 months, 0 restarts    |
| T04     | Traefik           | ⏳        | 2025-11-29 10:45 | ✅     | Routes OK, SSL valid       |
| T05     | Backup System     | ⏳        | 2025-11-29 10:45 | ✅     | Restic running             |
| T06     | SSH Access        | ⏳        | 2025-11-29 10:45 | ✅     | No omega keys, hardened    |
| T07     | ZFS Storage       | ⏳        | 2025-11-29 10:45 | ✅     | 2% used, zstd compression  |

### Migration Tests (Before/After Migration)

| Test ID | Feature               | 👇🏻 Manual | 🤖 Auto          | Result | Purpose                      |
| ------- | --------------------- | --------- | ---------------- | ------ | ---------------------------- |
| T08     | Pre-Migration Snap    | N/A       | 2025-11-29 10:45 | ✅     | Baseline snapshot saved      |
| T09     | Post-Migration Verify | N/A       | 2025-11-29 10:45 | ⚠️     | Comparison ready (1 warning) |
| T10     | Rollback Test         | ⏳        | 2025-11-29 10:45 | ✅     | 4 generations available      |
| T11     | Console Access        | ⏳ VNC    | 2025-11-29 10:45 | ✅     | Credentials documented       |
| T12     | Data Integrity        | ⏳        | 2025-11-29 10:45 | ✅     | All data intact              |
| T13     | Service Recovery      | ⏳        | 2025-11-29 10:45 | ⚠️     | 2 warnings (non-critical)    |
| T14     | Firewall & Network    | ⏳        | 2025-11-29 10:45 | ✅     | Ports 80,443,2222 open only  |
| T15     | Netcup API            | ⏳        | ⏳ Setup needed  | ⏳     | Server status via REST API   |

### Legend

- ✅ Pass - All checks successful
- ⚠️ Warning - Passed with minor warnings
- ❌ Fail - Critical issues found
- ⏳ Pending - Not yet run
- N/A - Not applicable (automated only)

## Migration Workflow

Before migrating csb1 to external Hokage, run these tests in order:

```bash
# 1. Pre-migration: Capture current state
./tests/T11-console-access.sh    # Verify emergency access is ready
./tests/T10-rollback-test.sh     # Verify rollback capability
./tests/T08-pre-migration-snapshot.sh  # Save baseline snapshot

# 2. Perform migration (external process)
# ssh -p 2222 mba@cs1.barta.cm
# ... apply new configuration ...

# 3. Post-migration: Verify success
./tests/T09-post-migration-verify.sh   # Compare to baseline
./tests/T00-nixos-base.sh              # Verify NixOS
./tests/T06-ssh-access.sh              # Verify no omega keys!
# ... run all other tests ...
```

## Snapshots Directory

Pre-migration snapshots are stored in `tests/snapshots/`:

```bash
ls -la tests/snapshots/
# pre-migration-2025-11-29-120000.json  <- baseline for comparison
```

## Manual Tests Pending

The following require human verification:

| Test | Manual Step Required | How to Verify                                           |
| ---- | -------------------- | ------------------------------------------------------- |
| T11  | VNC Console Access   | Login to https://servercontrolpanel.de/SCP and test VNC |
| T10  | GRUB Menu            | Verify GRUB shows generations on reboot (optional)      |
| T05  | Backup Restore       | Test actual restore from restic snapshot (optional)     |

## Notes

- csb1 is a cloud server (Netcup VPS) - tests should be run carefully
- SSH uses port 2222 (not default 22)
- VNC console access available via Netcup panel if SSH fails
- All credentials stored in 1Password (not in tests)
- Service-specific credentials redacted - see `secrets/RUNBOOK.md`
- **Before migration**: Verify VNC console access manually!
- **Rollback command**: `sudo nixos-rebuild switch --rollback`

## Last Full Test Run

**Date**: 2025-11-29 10:45 CET  
**Result**: ✅ All 15 tests passed (3 with minor warnings)  
**Runner**: Automated via bash scripts
