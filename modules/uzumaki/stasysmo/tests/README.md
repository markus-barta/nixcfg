# StaSysMo Test Suite

This directory contains automated tests and manual test checklists for StaSysMo.

## Test Types

### Automated Tests (T00-T03)

These run without human interaction and verify:

- Platform detection and paths
- Daemon process status
- Output file creation
- Reader command availability

### Manual Tests (T04-T05)

These **cannot be automated** because they require:

- Visual inspection in a real terminal
- Starship prompt rendering
- Terminal resizing to test progressive hiding
- Nerd Font icon verification

## Running Tests

### All Automated Tests

```bash
./tests/run-all.sh

# With verbose output
VERBOSE=1 ./tests/run-all.sh
```

### Individual Automated Test

```bash
./tests/T00-platform.sh
./tests/T01-daemon.sh
./tests/T02-output-files.sh
./tests/T03-reader.sh
```

### Manual Test Checklists

```bash
# View and follow the checklist
./tests/T04-width.sh      # Terminal width behavior (documents expected)
./tests/T05-starship.sh   # Complete Starship integration checklist
```

## Test Matrix

| ID  | Test                 | Type      | Linux | macOS | What it tests                            |
| --- | -------------------- | --------- | ----- | ----- | ---------------------------------------- |
| T00 | Platform Detection   | Automated | ✅    | ✅    | OS detection, directory paths            |
| T01 | Daemon Running       | Automated | ✅    | ✅    | systemd (Linux) / launchd (macOS) status |
| T02 | Output Files         | Automated | ✅    | ✅    | Metric files exist in correct directory  |
| T03 | Reader Output        | Automated | ✅    | ✅    | Reader produces formatted output         |
| T04 | Width Behavior       | Manual    | ✅    | ✅    | Progressive hiding at terminal widths    |
| T05 | Starship Integration | Manual    | ✅    | ✅    | Full visual verification checklist       |

## Why Some Tests Are Manual

### Terminal Width (T04)

```
⚠️ Cannot be automated: tput cols queries actual terminal
```

The reader uses `tput cols` to detect terminal width. When run from a script or
CI environment, this returns a default value (usually 80), not a simulated value.
There's no way to fake terminal dimensions without creating a pseudo-terminal.

### Starship Integration (T05)

```
⚠️ Cannot be automated: requires visual verification
```

Starship integration must be tested visually because:

- ANSI escape codes render differently in different terminals
- Nerd Font icons require specific fonts installed
- Powerline segment alignment is visual
- Color thresholds need to be seen
- Artifact detection (gaps, misalignments) is visual

## Manual Test Procedure

When running manual tests, execute the script and follow the checklist:

```bash
./tests/T05-starship.sh
```

Then in a **real terminal with Starship**:

1. Check each `[ ]` item visually
2. Resize terminal to test width behavior
3. Run stress tests to trigger threshold colors
4. Stop daemon to test staleness indication

## Platform Detection

Tests automatically detect the platform:

```bash
if [[ "$(uname)" == "Darwin" ]]; then
    # macOS-specific (launchd, /tmp/stasysmo)
else
    # Linux-specific (systemd, /dev/shm/stasysmo)
fi
```

## Prerequisites

### NixOS (Linux)

```nix
services.stasysmo.enable = true;
```

Then: `nixos-rebuild switch`

### macOS (Home Manager)

```nix
services.stasysmo.enable = true;
```

Then: `home-manager switch`

## Test Output Legend

| Symbol | Meaning                                            |
| ------ | -------------------------------------------------- |
| ✅     | PASS - Test succeeded                              |
| ❌     | FAIL - Test failed, needs fixing                   |
| ⚠️     | WARN - Test passed with warnings                   |
| ⚠️     | MANUAL - Cannot be automated, manual test required |
| ⏭️     | SKIP - Test skipped (e.g., missing prerequisites)  |

## Adding New Tests

1. Create `Txx-feature.sh` (automated script or manual checklist)
2. Add entry to Test Matrix above
3. Mark as "Automated" or "Manual" in the Type column
4. For manual tests: include `⚠️ Cannot be automated` notice
