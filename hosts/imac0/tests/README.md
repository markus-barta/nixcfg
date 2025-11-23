# imac0 Test Suite

Comprehensive test procedures for validating imac0 configuration.

## Quick Stats

- **Total Tests**: 12 (was 14, removed 2 cosmetic tests + 1 keyboard)
- **Fully Implemented & Passing**: 8
- **Pending Enhancement**: 3
- **Not Yet Created**: 1

## Test List

| Test ID | Feature             | 👇🏻 Manual Last Run | 🤖 Auto Last Run    | Notes                                          |
| ------- | ------------------- | ------------------ | ------------------- | ---------------------------------------------- |
| T00     | Nix Base System     | ⏳ Not yet run     | ⚠️ 2025-11-23 16:47 | 3/4 tests - currentSystem check fails          |
| T01     | Fish Shell          | ⏳ Not yet run     | ✅ 2025-11-23 16:47 | 5/5 tests passed - custom functions working    |
| T02     | Git Dual Identity   | ⏳ Not yet run     | ✅ 2025-11-23 17:15 | 5/5 tests passed - personal/work switching     |
| T03     | Node.js             | ⏳ Not yet run     | ✅ 2025-11-23 17:15 | 3/3 tests passed - v22.21.1 from Nix           |
| T04     | Python              | ⏳ Not yet run     | ✅ 2025-11-23 17:15 | 3/3 tests passed - v3.13.9 from Nix            |
| T05     | direnv + nix-direnv | ⏳ Not yet run     | ✅ 2025-11-23 17:15 | 3/3 tests passed - Fish integration working    |
| T06     | CLI Tools           | ⏳ Not yet run     | ✅ 2025-11-23 17:15 | 8/8 tools - bat, rg, fd, fzf, btop, zoxide, jq |
| T07     | Custom Scripts      | ⏳ Not yet run     | ✅ 2025-11-23 17:15 | 3/3 scripts - flushdns, pingt, stopAmphetamine |
| T08     | Nerd Fonts          | ⏳ Not yet run     | ⏳ Enhancement      | Check in WezTerm, Terminal, Font Book          |
| T09     | GUI Applications    | ⏳ Not yet run     | ⏳ Enhancement      | Verify in Dock and properly launched           |
| T10     | Homebrew Isolation  | ⏳ Not yet run     | ⏳ Enhancement      | No conflicts with Nix, PATH validation         |
| T11     | macOS Preferences   | ⏳ Not yet run     | ⏳ Not created      | NEW: Dock, Finder, system defaults             |

## Notes

- **Removed Tests**: Starship Prompt, WezTerm Terminal, Karabiner (cosmetic/hard to test)
- T00 has a minor issue with `builtins.currentSystem` check
- T02-T07 are fully functional and passing all tests
- T08-T10 need enhancement with more comprehensive checks
- T11 is a new test for macOS system preferences (optional)
- Manual test runs will be updated as tests are executed

## Usage

## Usage

### Running Manual Tests

```bash
# Navigate to tests directory
cd ~/Code/nixcfg/hosts/imac-mba-home/tests

# Follow procedures in individual .md files
# Example: T00-nix-base.md
```

### Running Automated Tests

```bash
# Run individual test
./T00-nix-base.sh

# Run all tests
for test in T*.sh; do ./"$test"; done
```

### Test Status

- **⏳ Pending**: Tests need to be created or executed
- **✅ Pass**: All checks passed
- **❌ Fail**: One or more checks failed

## Test Categories

### Base System (T00)

- Nix installation and configuration
- home-manager functionality
- Flakes support
- Platform detection (macOS)

### Shell & Terminal (T01-T03)

- Fish shell configuration and functions
- Starship prompt customization
- WezTerm terminal emulator

### Development Tools (T04-T07)

- Git dual identity switching
- Node.js global and project-specific
- Python global and project-specific
- direnv automatic environment loading

### User Experience (T08-T10)

- Nerd Font installation and rendering
- CLI tools (bat, ripgrep, fd, etc.)
- Karabiner-Elements keyboard remapping

### Integration (T11-T13)

- macOS GUI apps via Nix
- Custom utility scripts
- Homebrew coexistence validation

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

... (more tests)
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

- **[Main README](../docs/README.md)** - Host documentation
- **[Features](../docs/README.md#features)** - Feature list
- **[Migration Archive](../archive/MIGRATION-2025-11%20[DONE].md)** - Historical context

---

**Last Updated**: November 23, 2025  
**Maintainer**: Markus Barta
