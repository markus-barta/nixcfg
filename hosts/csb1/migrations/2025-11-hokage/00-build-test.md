# 00: Pre-Migration Build Test

Build the new NixOS configuration **without applying it**. This validates the configuration will work before committing to the switch.

## Purpose

- Verify flake syntax is correct
- Verify all dependencies resolve
- Verify configuration compiles
- See what packages would change
- Catch errors **before** potentially breaking SSH access

## Prerequisites

- SSH access to csb1 working
- nixcfg repository on server up to date
- New configuration ready in flake

## Automated Test

```bash
./00-build-test.sh
```

### What It Does

1. Verifies SSH access
2. Checks repository is up to date
3. Records current generation number
4. Runs `nixos-rebuild build --flake .#csb1`
5. Shows what would change
6. Reports success/failure

### Expected Output

```
=== 00: Pre-Migration Build Test ===
Step 1: Verifying SSH access... ✅ OK
Step 2: Checking nixcfg repository... ✅ Up to date
Step 3: Recording current generation... Generation 4
Step 4: Building new configuration...
✅ BUILD SUCCESSFUL (45s)

═══════════════════════════════════════════════════════════
  ✅ BUILD TEST PASSED
  Ready to migrate:
    sudo nixos-rebuild switch --flake .#csb1
═══════════════════════════════════════════════════════════
```

## Manual Test

If you prefer to run manually:

```bash
# SSH to server
ssh -p 2222 mba@cs1.barta.cm

# Update repository
cd ~/Code/nixcfg
git pull

# Build without switching
sudo nixos-rebuild build --flake .#csb1

# Check what would change
sudo nix store diff-closures /run/current-system /nix/var/nix/profiles/system
```

## If Build Fails

1. Read the error messages carefully
2. Common issues:
   - Syntax errors in Nix files
   - Missing flake inputs
   - Undefined variables
   - Incompatible module options
3. Fix issues in configuration
4. Commit and push
5. Pull on server and retry

## After Success

Once the build passes, proceed with migration:

```bash
# Apply the new configuration
sudo nixos-rebuild switch --flake .#csb1

# Then run post-migration verification
./02-post-verify.sh
```
