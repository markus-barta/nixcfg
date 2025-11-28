# T05: CLI Development Tools

Test CLI development tools installation.

## Prerequisites

- CLI tools installed via Nix home-manager

## Manual Test Procedures

### Test 1: bat (better cat)

**Steps:**

```bash
which bat
bat --version
echo "Hello" | bat
```

**Expected Results:**

- bat from Nix profile
- Syntax highlighting works

**Status:** ⏳ Pending

### Test 2: ripgrep (rg)

**Steps:**

```bash
which rg
rg --version
```

**Expected Results:**

- rg from Nix profile
- Version displayed

**Status:** ⏳ Pending

### Test 3: fd (better find)

**Steps:**

```bash
which fd
fd --version
```

**Expected Results:**

- fd from Nix profile
- Version displayed

**Status:** ⏳ Pending

### Test 4: fzf (fuzzy finder)

**Steps:**

```bash
which fzf
fzf --version
```

**Expected Results:**

- fzf from Nix profile
- Version displayed

**Status:** ⏳ Pending

### Test 5: btop (better top)

**Steps:**

```bash
which btop
btop --version
```

**Expected Results:**

- btop from Nix profile
- Version displayed

**Status:** ⏳ Pending

### Test 6: zoxide (smart cd)

**Steps:**

```bash
which zoxide
zoxide --version
```

**Expected Results:**

- zoxide from Nix profile
- Version displayed

**Status:** ⏳ Pending

### Test 7: jq (JSON processor)

**Steps:**

```bash
which jq
jq --version
echo '{"test": 123}' | jq .
```

**Expected Results:**

- jq from Nix profile
- JSON parsing works

**Status:** ⏳ Pending

### Test 8: just (command runner)

**Steps:**

```bash
which just
just --version
```

**Expected Results:**

- just from Nix profile
- Version displayed

**Status:** ⏳ Pending

## Summary

- Total Tests: 8
- Passed: 0
- Failed: 0
- Pending: 8

## Related

- Feature: [F05 - CLI Development Tools](../README.md#features)
- Automated: [T05-cli-tools.sh](./T05-cli-tools.sh)
