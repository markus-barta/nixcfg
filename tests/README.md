# Tests

This directory contains tests for the nixcfg repository.

## Test Types in This Repository

### 1. NixOS VM Tests (Nix-based)

**Location:** `tests/*.nix`, `tests/common/`

These are NixOS integration tests that run in a VM using the NixOS test framework. Originally from pbek's repository for testing packages like QOwnNotes.

```bash
# Run a NixOS VM test
nix build .#checks.x86_64-linux.qownnotes
```

### 2. Host-Specific Tests (Shell scripts)

**Location:** `hosts/<hostname>/tests/`

Shell scripts that verify ongoing functionality a host must provide (DNS, DHCP, services, security). These are permanent tests that should pass after any rebuild.

Example: `hosts/hsb0/tests/T01-system-health.sh`

```bash
# Run host tests
bash hosts/hsb0/tests/T01-system-health.sh
```

### 3. General/Structural Tests (Shell scripts)

**Location:** `tests/T*.sh`

Shell scripts for repository-wide verification:

- Repository structure conventions
- Cross-host consistency
- Migration verification
- Security checks (no plain secrets, etc.)

```bash
# Run all general tests
for t in tests/T*.sh; do bash "$t"; done
```

## Test Philosophy

### When Tests Live Where

| Test Type              | Location                  | Purpose                            |
| ---------------------- | ------------------------- | ---------------------------------- |
| **NixOS VM tests**     | `tests/*.nix`             | Package/integration testing in VMs |
| **Host-specific**      | `hosts/<hostname>/tests/` | Ongoing functionality verification |
| **General/structural** | `tests/T*.sh`             | Repository-wide checks             |
| **PM task-specific**   | Inline in task file       | One-time verification for changes  |

### PM Task Test Requirements

Every PM task that moves through `review/` to `done/` **must** have:

| Test Type          | Description                                     | Required |
| ------------------ | ----------------------------------------------- | -------- |
| **Manual Test**    | Human verification steps documented in the task | ✅ Yes   |
| **Automated Test** | Script that can verify the change               | ✅ Yes   |

## Shell Test Naming Convention

```
T##-descriptive-name.sh
```

Examples:

- `T01-repo-structure.sh` — Verify expected folder structure
- `T02-no-plain-secrets.sh` — Ensure no unencrypted secrets in repo
- `T03-hostname-consistency.sh` — Check old hostnames aren't referenced

## Writing Shell Tests

### Template

```bash
#!/usr/bin/env bash
# T##-test-name.sh
# Description: What this test verifies
# Related PM task: .pm/done/YYYY-MM-DD-task-name.md (if applicable)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0

pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((PASSED++))
}

fail() {
    echo -e "${RED}✗${NC} $1"
    ((FAILED++))
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# ============================================================================
# TESTS
# ============================================================================

echo "=== T##: Test Name ==="
echo ""

# Test 1: Description
if [[ some_condition ]]; then
    pass "Test 1 passed"
else
    fail "Test 1 failed: reason"
fi

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo "=== Summary ==="
echo -e "Passed: ${GREEN}${PASSED}${NC}"
echo -e "Failed: ${RED}${FAILED}${NC}"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
```

## Running Tests

```bash
# Run all shell tests
for t in tests/T*.sh; do bash "$t"; done

# Run specific shell test
bash tests/T01-repo-structure.sh

# Run host-specific tests
bash hosts/hsb0/tests/T01-system-health.sh

# Run NixOS VM test
nix build .#checks.x86_64-linux.qownnotes
```

## Related Documentation

- [PM Workflow](../.pm/README.md) — How tests fit into the review process
- [hsb0 Tests](../hosts/hsb0/tests/) — Example host-specific test suite
