# Starship $fill Module Broken on hsb1

## Status: RESOLVED

## Resolution

**Root cause:** The `printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l'` mouse tracking reset in fish shellInit was interfering with Starship's terminal width detection.

**Fix:** Removed the printf command from `modules/common.nix` and `modules/uzumaki/macos-common.nix` (commit 5f36669).

---

## Original Problem (Archived)

## Problem Statement

The Starship prompt's `$fill` module does not work correctly on hsb1. The right side of the prompt (StaSysMo metrics, time, nix_shell indicator) appears in the **middle** of the terminal instead of at the **right edge**.

### Visual Comparison

| Host  | Behavior                               | Git Version                         |
| ----- | -------------------------------------- | ----------------------------------- |
| hsb0  | ✅ Right side at right edge            | `a06e1181` (old, pre-COLUMNS fixes) |
| hsb1  | ❌ Right side in middle (~60-90 chars) | `54ae8aa4` (latest)                 |
| imac0 | ⚠️ Trailing space issue                | Latest                              |

### Terminal Width Test

Using `echo 12345678901234567890...` pattern confirmed:

- Terminal width: 158 characters (both hosts)
- hsb0: Right side ends at position ~158 ✅
- hsb1: Right side ends at position ~67-92 ❌

---

## Root Cause Analysis

### Confirmed Facts

1. **Identical software versions:**
   - Starship 1.24.1 (same Nix store path)
   - Zellij 0.43.1
   - Fish 4.2.1
   - Same locale settings

2. **Identical Starship configuration** (only colors differ due to theme)

3. **StaSysMo Debug output identical:**

   ```
   WIDTH: COLUMNS=unset /dev/tty=158 → using 158
   SLOTS: hideAll=60 show1=80 show2=100 show3=130 → max_metrics=4
   OUTPUT: metrics_shown=3 visible_chars=26-27 budget=45
   FORMAT: output_empty=no output_len=67-68
   ```

4. **Key difference: Git commit version**
   - hsb0: `a06e1181` - before any COLUMNS/STARSHIP_TERM_WIDTH changes
   - hsb1: `54ae8aa4` - after multiple fix attempts

### Fish Config Difference

**hsb0 `/etc/fish/config.fish`:**

```fish
set -e LANGUAGE
set -e LANGUAGE
# (no additional code)
```

**hsb1 `/etc/fish/config.fish`:**

```fish
set -e LANGUAGE
set -e LANGUAGE

# Reset mouse tracking (prevents garbled escape sequences from crashed apps)
printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l'

# NOTE: Do NOT set STARSHIP_TERM_WIDTH...
```

### Suspect: Mouse Tracking Reset

The `printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l'` command was added in a recent commit. While it should be harmless (just resets mouse tracking modes), it may be interfering with Starship's terminal width detection.

---

## Attempted Fixes (All Failed on hsb1)

### 1. Remove COLUMNS recursion (commit 38e92ab)

- **Issue:** `__sync_term_width` function caused infinite loop
- **Fix:** Removed `set -gx COLUMNS $COLUMNS`
- **Result:** Fixed infinite loop, but $fill still broken

### 2. Remove STARSHIP_TERM_WIDTH entirely (commit 54ae8aa)

- **Issue:** Suspected STARSHIP_TERM_WIDTH was interfering
- **Fix:** Removed entire `__sync_term_width` function
- **Result:** $fill still broken

### 3. Tested new Zellij session

- Created fresh session `hsb1new`
- **Result:** $fill still broken (not Zellij session cache issue)

### 4. Verified ANSI codes theory

- Compared `output_len` vs `visible_chars`
- Both hosts have ~41 bytes of ANSI codes
- **Result:** ANSI codes NOT the cause (hsb0 works with same codes)

---

## Solution Approach

### Next Step: Remove printf mouse tracking reset

The `printf '\e[?1000l...'` is the only executable code difference between hsb0 and hsb1's fish config. Test by removing it.

**File:** `modules/common.nix`

**Current:**

```nix
shellInit = ''
  set -e LANGUAGE
  printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l'
  # NOTE: Do NOT set STARSHIP_TERM_WIDTH...
'';
```

**Proposed:**

```nix
shellInit = ''
  set -e LANGUAGE
  # NOTE: Do NOT set STARSHIP_TERM_WIDTH...
'';
```

### Fallback: Revert to pre-COLUMNS state

If removing printf doesn't help, revert all COLUMNS-related changes to match hsb0's working state.

---

## Commits in Question

```
54ae8aa fix(fish): remove STARSHIP_TERM_WIDTH - breaks Starship $fill
38e92ab fix(fish): remove COLUMNS recursion causing infinite loop on hsb1
1852682 fix(mqtt): update MQTT_HOST to localhost after hostname migration
47bae52 fix(starship): export STARSHIP_TERM_WIDTH for $fill module
4a16590 fix(fish): export COLUMNS immediately and on resize
97095e3 fix(fish): export COLUMNS on every prompt for Starship width detection
05cb74c fix(fish): reset mouse tracking on shell init  <-- SUSPECT
```

---

## Test Plan

1. Remove `printf '\e[?1000l...'` from `modules/common.nix`
2. Commit and push
3. On hsb1: `git pull && just switch && exec fish`
4. Test in multiple directories (home, ~/Code/nixcfg)
5. If fixed: Document and close
6. If not fixed: Revert more changes or investigate further

---

## Related Issues

- **Trailing space on imac0:** Separate issue, lower priority
- **Enhancement 9 in sysmon backlog:** Documents trailing space after nix_shell

---

## Notes

- hsb0 is the "safe base" - do NOT update until problem is resolved
- Problem manifests in all directories, but more visually obvious when left side is longer (e.g., in git repos with branch info)
