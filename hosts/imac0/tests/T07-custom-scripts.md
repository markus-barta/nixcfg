# T07: Custom Scripts

Test custom shell scripts symlinked to ~/Scripts/.

## Prerequisites

- home-manager configured with Scripts symlink
- Scripts directory: `hosts/imac0/scripts/host-user/`

## Scripts Tested

| Script                       | Purpose                            |
| ---------------------------- | ---------------------------------- |
| `flushdns.sh`                | Flush macOS DNS cache              |
| `stopAmphetamineAndSleep.sh` | Stop Amphetamine app and sleep Mac |

**Note:** `pingt` is now a fish function provided by the uzumaki module, not a shell script.

## Manual Test Procedures

### Test 1: Scripts Symlinked

**Steps:**

```bash
ls -la ~/Scripts/
```

**Expected:**

- `flushdns.sh` → symlinked to Nix store
- `stopAmphetamineAndSleep.sh` → symlinked to Nix store

**Status:** ⏳ Pending

### Test 2: Scripts Executable

**Steps:**

```bash
~/Scripts/flushdns.sh
```

**Expected:** DNS cache flushed (may require sudo)

**Status:** ⏳ Pending

## Summary

- Total Tests: 2
- Passed: 0
- Failed: 0
- Pending: 2

## Related

- Feature: [F07 - Custom Scripts](../README.md#features)
- Automated: [T07-custom-scripts.sh](./T07-custom-scripts.sh)
