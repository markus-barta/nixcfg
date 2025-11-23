# T11: macOS Preferences

Test macOS system preferences and defaults.

## Prerequisites

- macOS system
- `defaults` command available

## Manual Test Procedures

### Test 1: Dock Settings

**Steps:**

1. Open System Preferences → Dock
2. Check settings

**Expected Results:**

- Note current Dock settings (autohide, position, size)

**Status:** ⏳ Pending

### Test 2: Screenshot Settings

**Steps:**

1. Check screenshot location: `defaults read com.apple.screencapture location`

**Expected Results:**

- Screenshot location is set (or defaults to ~/Desktop)

**Status:** ⏳ Pending

### Test 3: Finder Preferences

**Steps:**

1. Open Finder → Preferences
2. Check "Show hidden files" setting

**Expected Results:**

- Hidden files setting is configured

**Status:** ⏳ Pending

### Test 4: Keyboard Repeat Settings

**Steps:**

1. Check keyboard repeat: `defaults read NSGlobalDomain KeyRepeat`
2. Check initial delay: `defaults read NSGlobalDomain InitialKeyRepeat`

**Expected Results:**

- Keyboard settings configured for fast typing

**Status:** ⏳ Pending

## Notes

- This test is informational - documents current system state
- Helps with reproducibility on new machines
- Optional: Can add more preferences as needed
