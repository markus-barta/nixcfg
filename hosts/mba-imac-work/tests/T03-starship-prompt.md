# T03: Starship Prompt

Test Starship prompt configuration.

## Prerequisites

- Starship installed via Nix
- Fish shell integration enabled

## Manual Test Procedures

### Test 1: Starship Installation

**Steps:**

1. Verify Starship is installed from Nix

```bash
which starship
starship --version
```

**Expected Results:**

- Shows `/Users/markus/.nix-profile/bin/starship`
- Version displayed

**Status:** ⏳ Pending

### Test 2: Config File Exists

**Steps:**

1. Check Starship config exists

```bash
ls -la ~/.config/starship.toml
```

**Expected Results:**

- File exists (symlink to shared config)

**Status:** ⏳ Pending

### Test 3: Fish Integration

**Steps:**

1. Verify Starship is initialized in Fish

```bash
grep -i starship ~/.config/fish/config.fish
```

**Expected Results:**

- Shows `starship init fish` or similar

**Status:** ⏳ Pending

### Test 4: Prompt Displays

**Steps:**

1. Open a new terminal
2. Observe the prompt

**Expected Results:**

- Custom prompt with username, hostname, directory
- Git branch/status when in a git repo
- Time in right prompt

**Status:** ⏳ Pending

### Test 5: Git Status in Prompt

**Steps:**

1. Navigate to a git repository

```bash
cd ~/Code/nixcfg
# Make a change (don't commit)
echo "test" >> /tmp/test
```

2. Observe prompt

**Expected Results:**

- Shows branch name (e.g., `main`)
- Shows commit hash
- Shows status indicators if dirty

**Status:** ⏳ Pending

## Summary

- Total Tests: 5
- Passed: 0
- Failed: 0
- Pending: 5

## Related

- Feature: [F03 - Starship Prompt](../README.md#features)
- Automated: [T03-starship-prompt.sh](./T03-starship-prompt.sh)
