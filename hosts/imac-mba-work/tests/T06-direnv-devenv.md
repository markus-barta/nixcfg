# T06: direnv + devenv

Test direnv and devenv functionality for automatic environment loading.

## Prerequisites

- direnv installed via Nix
- devenv installed via Nix profile
- Fish shell integration enabled

## Manual Test Procedures

### Test 1: direnv Installation

**Steps:**

```bash
which direnv
direnv version
```

**Expected Results:**

- direnv from Nix profile
- Version displayed

**Status:** ⏳ Pending

### Test 2: devenv Installation

**Steps:**

```bash
which devenv
devenv version
```

**Expected Results:**

- devenv in PATH
- Version displayed

**Status:** ⏳ Pending

### Test 3: Fish Integration

**Steps:**

```bash
grep -i direnv ~/.config/fish/config.fish
```

**Expected Results:**

- direnv hook command present

**Status:** ⏳ Pending

### Test 4: nixcfg Environment Loading

**Steps:**

1. Navigate to nixcfg directory

```bash
cd ~/Code/nixcfg
```

2. Observe direnv loading

**Expected Results:**

- `direnv: loading .envrc` message
- `direnv: using devenv` message
- Environment variables exported

**Status:** ⏳ Pending

### Test 5: .shared/common.just Created

**Steps:**

```bash
ls -la ~/Code/nixcfg/.shared/
```

**Expected Results:**

- `common.just` symlink exists (points to nix store)

**Status:** ⏳ Pending

### Test 6: just Commands Available

**Steps:**

```bash
cd ~/Code/nixcfg
just --list | head -10
```

**Expected Results:**

- List of available recipes displayed
- Includes `switch`, `build`, etc.

**Status:** ⏳ Pending

## Troubleshooting

### "devenv: command not found"

Install devenv:

```bash
nix profile install "nixpkgs#devenv"
```

### "Failed to set up binary caches"

Add yourself to trusted-users:

```bash
sudo nano /etc/nix/nix.conf
# Add: trusted-users = root markus
sudo launchctl kickstart -k system/org.nixos.nix-daemon
```

### "Conflicting file .shared/common.just"

Remove manual file:

```bash
rm -rf ~/Code/nixcfg/.shared
cd ~/Code/nixcfg
devenv shell -- echo "Recreated"
```

## Summary

- Total Tests: 6
- Passed: 0
- Failed: 0
- Pending: 6

## Related

- Feature: [F06 - direnv + devenv](../README.md#features)
- Automated: [T06-direnv-devenv.sh](./T06-direnv-devenv.sh)
