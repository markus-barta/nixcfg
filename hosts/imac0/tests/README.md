# imac0 Test Suite

Comprehensive test procedures for validating imac0 configuration.

## Quick Stats

- **Total Tests**: 12 (streamlined from 14)
- **Fully Passing**: 11/12 (92%)
- **Partial/Info**: 1 (T00 - minor issue)

## Test List

| Test ID | Feature             | 👇🏻 Manual Last Run | 🤖 Auto Last Run    | Notes                                           |
| ------- | ------------------- | ------------------ | ------------------- | ----------------------------------------------- |
| T00     | Nix Base System     | ⏳ Not yet run     | ⚠️ 2025-11-23 16:47 | 3/4 tests - currentSystem check fails           |
| T01     | Fish Shell          | ⏳ Not yet run     | ✅ 2025-11-23 16:47 | 5/5 tests passed - custom functions working     |
| T02     | Git Dual Identity   | ⏳ Not yet run     | ✅ 2025-11-23 17:15 | 5/5 tests passed - personal/work switching      |
| T03     | Node.js             | ⏳ Not yet run     | ✅ 2025-11-23 17:15 | 3/3 tests passed - v22.21.1 from Nix            |
| T04     | Python              | ⏳ Not yet run     | ✅ 2025-11-23 17:15 | 3/3 tests passed - v3.13.9 from Nix             |
| T05     | direnv + nix-direnv | ⏳ Not yet run     | ✅ 2025-11-23 17:15 | 3/3 tests passed - Fish integration working     |
| T06     | CLI Tools           | ⏳ Not yet run     | ✅ 2025-11-23 17:15 | 8/8 tools - bat, rg, fd, fzf, btop, zoxide, jq  |
| T07     | Custom Scripts      | ⏳ Not yet run     | ✅ 2025-11-23 17:15 | 3/3 scripts - flushdns, pingt, stopAmphetamine  |
| T08     | Nerd Fonts          | ⏳ Not yet run     | ✅ 2025-11-23 17:20 | 3/3 tests (Test 4 was WezTerm-specific, removed 2026-05-05) |
| ~~T09~~ | ~~GUI Applications~~ | REMOVED 2026-05-05 | — | (was WezTerm install + symlink check; purged) |
| T10     | Homebrew Isolation  | ⏳ Not yet run     | ✅ 2025-11-23 17:22 | 4/4 tests - no conflicts, PATH correct          |
| T11     | macOS Preferences   | ⏳ Not yet run     | ℹ️ 2025-11-23 17:23 | 5/5 checks - informational, system state logged |

## Summary

✅ **11/12 tests fully passing (92%)**

### Test Results by Category:

**Base System (T00-T01):**

- T00: ⚠️ Minor issue (currentSystem check)
- T01: ✅ Full pass

**Development (T02-T07):**

- All ✅ passing - Git, Node, Python, direnv, CLI tools, scripts

**User Experience (T08-T09):**

- All ✅ passing - Fonts, GUI apps

**System Integration (T10-T11):**

- T10: ✅ Homebrew isolation verified
- T11: ℹ️ System preferences documented

## Notes

- **Removed Tests**: Starship Prompt, ~~WezTerm Terminal~~ (purged 2026-05-05), Karabiner (cosmetic/hard to test)
- T00 has a minor issue with `builtins.currentSystem` check (doesn't affect functionality)
- T11 is informational - documents system state for reproducibility
- All core functionality verified and working

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
- ~~WezTerm terminal emulator~~ (purged 2026-05-05; Ghostty via Homebrew now)

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
