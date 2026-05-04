# mba-imac-work Test Suite

Comprehensive test procedures for validating mba-imac-work configuration.

## Quick Stats

- **Total Tests**: 9
- **Fully Passing**: ✅ 9/9
- **Last Full Run**: 2025-11-28

## Test List

| Test ID | Feature            | 👇🏻 Manual Last Run | 🤖 Auto Last Run | Notes                                                 |
| ------- | ------------------ | ------------------ | ---------------- | ----------------------------------------------------- |
| T00     | Nix Base System    | ✅ 2025-11-28      | ✅ 2025-11-28    | Nix, home-manager, flakes                             |
| T01     | Fish Shell         | ✅ 2025-11-28      | ✅ 2025-11-28    | Shell, functions, aliases                             |
| T02     | Git Dual Identity  | ✅ 2025-11-28      | ✅ 2025-11-28    | Work default, personal for nixcfg                     |
| T03     | Starship Prompt    | ✅ 2025-11-28      | ✅ 2025-11-28    | Prompt config, Git integration                        |
| ~~T04~~ | ~~WezTerm Terminal~~ | REMOVED 2026-05-05 | — | (purged; Ghostty via Homebrew, not Nix) |
| T05     | CLI Tools          | ✅ 2025-11-28      | ✅ 2025-11-28    | bat, rg, fd, fzf, btop, zoxide, jq, just, cloc, watch |
| T06     | direnv + devenv    | ✅ 2025-11-28      | ✅ 2025-11-28    | Auto env loading, devenv shell                        |
| T07     | Karabiner-Elements | ✅ 2025-11-28      | ✅ 2025-11-28    | Caps→Hyper, F-keys                                    |
| T08     | Nerd Fonts         | ✅ 2025-11-28      | ✅ 2025-11-28    | Hack Nerd Font, terminal icons                        |

## Summary

✅ **All 9 tests passing** (2025-11-28)

Run the test suite to validate your configuration:

```bash
cd ~/Code/nixcfg/hosts/mba-imac-work/tests
for test in T*.sh; do ./"$test"; done
```

## Usage

### Running Manual Tests

```bash
# Navigate to tests directory
cd ~/Code/nixcfg/hosts/mba-imac-work/tests

# Follow procedures in individual .md files
# Example: T00-nix-base.md
```

### Running Automated Tests

```bash
# Run individual test
./T00-nix-base.sh

# Run all tests
for test in T*.sh; do ./"$test"; done

# Run all tests with summary
./run-all-tests.sh
```

### Test Status Legend

- **⏳ Pending**: Tests need to be executed
- **✅ Pass**: All checks passed
- **⚠️ Partial**: Some checks passed, minor issues
- **❌ Fail**: One or more checks failed
- **ℹ️ Info**: Informational only (no pass/fail)

## Test Categories

### Base System (T00)

- Nix installation and configuration
- home-manager functionality
- Flakes support
- Platform detection (macOS)

### Shell & Terminal (T01, T03-T04)

- Fish shell configuration and functions
- Starship prompt customization
- ~~WezTerm terminal emulator~~ (purged 2026-05-05; Ghostty via Homebrew now)

### Development Tools (T02, T05-T06)

- Git dual identity switching
- CLI tools (bat, ripgrep, fd, etc.)
- direnv + devenv automatic environment loading

### User Experience (T07-T08)

- Karabiner-Elements keyboard remapping
- Nerd Font installation and rendering

## Adding New Tests

To add a new test:

1. Create `TXX-feature-name.md` (manual procedures)
2. Create `TXX-feature-name.sh` (automated script)
3. Update this README with new entry
4. Run and validate both manual and automated tests

### Test File Format

**Manual Test (.md):**

```markdown
# TXX: Feature Name

Test the Feature Name functionality.

## Prerequisites

- List any requirements

## Manual Test Procedures

### Test 1: Basic Functionality

**Steps:**

1. Step one
2. Step two

**Expected Results:**

- Expected output

**Status:** ⏳ Pending / ✅ Pass / ❌ Fail
```

**Automated Test (.sh):**

```bash
#!/usr/bin/env bash
# Test TXX: Feature Name
set -euo pipefail

echo "Testing Feature Name..."

# Test 1: Basic check
if command -v feature >/dev/null 2>&1; then
  echo "✅ Feature installed"
else
  echo "❌ Feature not found"
  exit 1
fi

echo "✅ All Feature Name tests passed"
```

## Related Documentation

- **[Main README](../README.md)** - Host configuration overview
- **[imac0 Tests](../../imac0/tests/README.md)** - Home iMac test suite (similar)
- **[hsb0 Tests](../../hsb0/tests/README.md)** - Server test suite example

---

**Last Updated**: November 28, 2025
**Maintainer**: Markus Barta
