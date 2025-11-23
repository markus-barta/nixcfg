# imac-mba-home Test Suite

Comprehensive test procedures for validating imac-mba-home configuration.

## Test Overview

| ID  | Feature             | Manual Test | Automated Test | Status |
| --- | ------------------- | ----------- | -------------- | ------ |
| T00 | Nix Base System     | ✅          | ✅             | ⏳     |
| T01 | Fish Shell          | ✅          | ✅             | ⏳     |
| T02 | Starship Prompt     | ✅          | ✅             | ⏳     |
| T03 | WezTerm Terminal    | ✅          | ✅             | ⏳     |
| T04 | Git Dual Identity   | ✅          | ✅             | ⏳     |
| T05 | Node.js             | ✅          | ✅             | ⏳     |
| T06 | Python              | ✅          | ✅             | ⏳     |
| T07 | direnv + nix-direnv | ✅          | ✅             | ⏳     |
| T08 | Nerd Fonts          | ✅          | ✅             | ⏳     |
| T09 | CLI Tools           | ✅          | ✅             | ⏳     |
| T10 | Karabiner-Elements  | ✅          | ⏳             | ⏳     |
| T11 | GUI Apps            | ✅          | ✅             | ⏳     |
| T12 | Custom Scripts      | ✅          | ✅             | ⏳     |
| T13 | Homebrew Validation | ✅          | ✅             | ⏳     |

**Legend:**

- ✅ = Available
- ⏳ = Pending creation
- ❌ = Not applicable

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
