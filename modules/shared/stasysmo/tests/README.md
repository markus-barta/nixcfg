# StaSysMo Test Suite

This directory contains test procedures and automated scripts to verify StaSysMo functionality.

## Test Format

Each feature has:

- **Test Documentation** (`Txx-feature-name.md`): Manual test procedures for humans and AI
- **Test Script** (`Txx-feature-name.sh`): Automated test script

## Running Tests

### Individual Test

```bash
# Run manual test (follow instructions in markdown file)
cat tests/T01-daemon.md

# Run automated test
./tests/T01-daemon.sh
```

### All Automated Tests

```bash
# Run all tests for current platform
./tests/run-all.sh

# Run with verbose output
VERBOSE=1 ./tests/run-all.sh
```

## Platform Detection

Tests automatically detect the platform (Linux/macOS) and run appropriate checks:

```bash
# The test scripts use this pattern:
if [[ "$(uname)" == "Darwin" ]]; then
    # macOS-specific tests
else
    # Linux-specific tests
fi
```

## Test Status Legend

- ✅ **Pass**: Feature working as expected
- ⏳ **Pending**: Feature not yet tested
- ❌ **Fail**: Feature not working, requires attention
- N/A: Test not applicable for this platform

## Test List

| Test ID | Feature             | Linux | macOS | Notes                             |
| ------- | ------------------- | ----- | ----- | --------------------------------- |
| T00     | Platform Detection  | ✅    | ✅    | Detects OS and sets paths         |
| T01     | Daemon Running      | ✅    | ✅    | systemd (Linux) / launchd (macOS) |
| T02     | Output Files        | ✅    | ✅    | Metrics written to correct dir    |
| T03     | Reader Output       | ✅    | ✅    | Formatted output with icons       |
| T04     | Staleness Detection | ✅    | ✅    | Shows "?" when data stale         |
| T05     | Threshold Colors    | ✅    | ✅    | Color changes at thresholds       |

## Prerequisites

### NixOS

- StaSysMo enabled: `services.stasysmo.enable = true`
- System rebuilt: `nixos-rebuild switch`

### macOS

- StaSysMo enabled: `services.stasysmo.enable = true`
- Home Manager applied: `home-manager switch`

## Notes

- Tests are designed to be non-destructive
- Some tests may require waiting for daemon to produce output
- Platform-specific tests are clearly marked
