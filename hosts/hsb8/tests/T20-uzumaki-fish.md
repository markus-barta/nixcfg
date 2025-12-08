# T20: Uzumaki Fish Functions (hsb8)

Test fish shell functions provided by the Uzumaki module.

## Host Information

| Property     | Value           |
| ------------ | --------------- |
| **Host**     | hsb8            |
| **Role**     | Parents' Server |
| **IP**       | 192.168.1.100   |
| **Location** | ww87            |

## Prerequisites

- [ ] Uzumaki module deployed to hsb8
- [ ] NixOS configuration applied: `sudo nixos-rebuild switch --flake .#hsb8`
- [ ] Fish shell is the default shell

## Automated Tests

Run: `./T20-uzumaki-fish.sh`

## Manual Test Procedures

### Test 1: Fish Shell Available

**Steps:**

1. Check fish is installed: `fish --version`

**Expected Results:**

- Fish version displayed (e.g., "fish, version 3.x.x")

**Status:** ⏳ Pending

### Test 2: Uzumaki Functions Exist

**Steps:**

1. Check functions in fish config:
   ```bash
   grep "function pingt" /etc/fish/config.fish
   grep "function helpfish" /etc/fish/config.fish
   ```

**Expected Results:**

- Functions defined: `pingt`, `sourcefish`, `stress`, `helpfish`

**Status:** ⏳ Pending

### Test 3: pingt Function Works

**Steps:**

1. Run pingt: `pingt -c 1 127.0.0.1`

**Expected Results:**

- Ping output includes timestamp prefix (HH:MM:SS format)
- Color-coded latency output

**Status:** ⏳ Pending

### Test 4: helpfish Function

**Steps:**

1. Run: `helpfish`

**Expected Results:**

- Shows "Functions" section
- Lists available uzumaki functions (pingt, etc.)
- Shows abbreviations

**Status:** ⏳ Pending

### Test 5: Abbreviations

**Steps:**

1. Check abbreviations: `abbr --show`

**Expected Results:**

- `ping` → `pingt` abbreviation exists
- `tmux` → `zellij` abbreviation exists

**Status:** ⏳ Pending

### Test 6: Zellij Available

**Steps:**

1. Check zellij: `zellij --version`

**Expected Results:**

- Zellij version displayed

**Status:** ⏳ Pending

## Test Results Summary

| Test | Description      | Status |
| ---- | ---------------- | ------ |
| T1   | Fish Shell       | ⏳     |
| T2   | Functions Exist  | ⏳     |
| T3   | pingt Works      | ⏳     |
| T4   | helpfish Output  | ⏳     |
| T5   | Abbreviations    | ⏳     |
| T6   | Zellij Available | ⏳     |

## Notes

- Functions defined in `modules/uzumaki/common.nix`
- Exported via `modules/uzumaki/server.nix`
- Fish functions use `interactiveShellInit` so may not work in non-interactive shells
