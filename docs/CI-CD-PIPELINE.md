# CI/CD Pipeline Explained

## 🎯 What Is This About?

This document explains the **automated checks** (CI/CD) that run on GitHub every time you push code to this repository. You're seeing failures in GitHub Actions, and this explains what they do, why they fail, and how to fix them.

---

## 🤖 The Automated Steps (What Should Work)

Every time you push code to GitHub, several automated workflows start running. Think of them as robots checking your work before it gets merged.

### 1. **📄 Format Check** (`format-check.yml`)

**What it does:** Checks if your code is properly formatted (clean, consistent style)

**How it works:**

1. GitHub checks out your code
2. Installs Nix (the package manager)
3. Installs `devenv` (development environment tool)
4. Runs `just format` command

**The command chain:**

```
just format → prek run --all-files
```

### 2. **🔎 Flake Check** (`check.yml`)

**What it does:** Validates that all your NixOS host configurations can be evaluated (checked for errors)

**How it works:**

1. Runs a **matrix build** - checks multiple hosts in parallel
2. For each host, tries to evaluate the configuration
3. If ANY host fails, the entire workflow fails

**Hosts being checked:**

- `gaia`, `venus`, `rhea`, `hyperion`
- `ally2`, `astra`, `caliban`, `mercury`
- `sinope`, `netcup01`, `netcup02`, `home01`
- `moobox01`, `jupiter`, `ally`, `pluto`
- `mba-gaming-pc`, `dp01`-`dp08`

**Total:** 28 hosts (!)

### 3. **🏗️ Build Apps** (`build.yml`)

**What it does:** Builds specific packages (QOwnNotes, Nixbit) and pushes them to your binary cache

**When it runs:** Only on the `main` branch when specific files change

### 4. **🧪 Run Tests** (`tests.yml`)

**What it does:** Runs integration tests for QOwnNotes

**When it runs:** When test files or QOwnNotes package changes

---

## 💥 Why Do The Builds Fail?

### Problem 1: Format Check Fails

**Error:** `just format` command fails

**Likely reasons:**

1. **Missing `prek` tool** - The format command calls `prek` (pre-commit hook runner), but it may not be installed in the devenv
2. **Typo in command** - The `.shared/common.just` file has:

   ```just
   format args='':
       prek run --all-files {{ args }}
   ```

   Notice: `prek` instead of `pre-commit`? This might be an alias or typo.

3. **No `.pre-commit-config.yaml`** - The pre-commit tool needs a configuration file to know what to check

**Quick test locally:**

```bash
devenv shell "just format"
```

If this fails on your machine too, you'll see the exact error.

### Problem 2: Flake Check Fails

**Error:** "Some jobs were not successful"

**Likely reasons:**

1. **Archived hosts in workflow** - The workflow checks 28 hosts, but many are in `hosts/archived/`:
   - `gaia`, `venus`, `rhea`, `hyperion`
   - `ally2`, `astra`, `caliban`, `mercury`
   - `sinope`, `netcup01`, `netcup02`, `home01`
   - `moobox01`, `jupiter`, `ally`, `pluto`
   - `eris`, `dp01`-`dp09`

2. **Missing host configurations** - Some hosts don't have `configuration.nix` files anymore (they're archived)

3. **Outdated nixpkgs** - Some old configurations might reference packages that no longer exist

4. **Module errors** - Old hosts might use the old `mixins` structure instead of the new `hokage` module pattern

**What happens:**

```
GitHub tries: nix eval .#nixosConfigurations.venus.config.system.build.toplevel.drvPath
Result: ERROR (host doesn't exist in active flake.nix)
```

### Problem 3: Workflow Configuration Out of Sync

**Root cause:** The workflow file (`.github/workflows/check.yml`) lists hosts that:

- No longer exist in `flake.nix`
- Are archived and not maintained
- Were removed from active configurations

**Current situation:**

- **Workflow checks:** 28 hosts
- **Active hosts in flake.nix:** ~10 hosts (hsb0, hsb8, miniserver24, mba-gaming-pc, etc.)
- **Mismatch:** ~18 hosts that don't exist anymore!

---

## 🔍 Detailed Analysis

### Format Check Workflow Problem

```yaml
- name: 🔧 Install devenv.sh
  run: nix profile add nixpkgs#devenv
- name: 🌳 Format code
  run: devenv shell "just format"
```

The workflow assumes:

1. `devenv` can create a development environment
2. Inside that environment, `just` is available
3. Inside that environment, `prek` (or `pre-commit`) is available

**Missing pieces:**

- Check `devenv.nix` - does it include `just` and `pre-commit`/`prek`?
- Check if there's a `.pre-commit-config.yaml` file
- The command might be calling a tool that doesn't exist

### Flake Check Workflow Problem

The workflow has a hardcoded list from when you had many more machines:

```yaml
strategy:
  matrix:
    host:
      - gaia # ❌ Archived
      - venus # ❌ Archived
      - rhea # ❌ Archived
      # ... many more archived hosts
      - mba-gaming-pc # ✅ Active
      - dp01-dp08 # ❌ Archived
```

**What should happen:** The workflow should only check **active** hosts from `flake.nix`:

- `miniserver24`
- `hsb0`
- `hsb8`
- `mba-gaming-pc`
- (any other non-archived hosts)

---

## ✅ How To Fix It

### Fix 1: Format Check

**Option A - Fix the command:**

```just
# In .shared/common.just
format args='':
    pre-commit run --all-files {{ args }}
```

Change `prek` → `pre-commit`

**Option B - Add prek alias:**
Make sure `devenv.nix` has:

```nix
{
  packages = [
    pkgs.just
    pkgs.pre-commit
  ];
  scripts.prek.exec = "${pkgs.pre-commit}/bin/pre-commit $@";
}
```

**Option C - Remove the workflow temporarily:**
If you don't need format checking right now, you can:

1. Remove or disable `format-check.yml`
2. Fix it later when you have time

### Fix 2: Flake Check

**Option A - Update the workflow to only check active hosts:**

```yaml
strategy:
  matrix:
    host:
      - miniserver24
      - hsb0
      - hsb8
      - mba-gaming-pc
      # Only include hosts that actually exist in flake.nix
```

**Option B - Make the workflow dynamic:**
Generate the host list from `flake.nix` automatically:

```yaml
- name: Get host list
  id: hosts
  run: |
    hosts=$(nix eval --json .#nixosConfigurations --apply 'builtins.attrNames' | jq -r '.[]')
    echo "hosts=$hosts" >> $GITHUB_OUTPUT
```

**Option C - Temporarily disable the workflow:**
Comment out or delete `.github/workflows/check.yml` until you're ready to fix it

### Fix 3: Keep Only What You Need

Since you have:

- **4 active workflows:** format-check, check, build, tests
- **Multiple inactive hosts** being checked

**Quick win:**

1. Update `check.yml` to only check your 3-4 active machines
2. Fix the format command (`prek` → `pre-commit`)
3. Let the build and test workflows run only when needed (they already have `paths:` filters)

---

## 🎯 Recommended Action Plan

### Phase 1: Quick Fixes (10 minutes)

1. **Fix format command** - Change `prek` to `pre-commit` in `.shared/common.just`
2. **Update check workflow** - Replace the host matrix with only your active hosts:
   ```yaml
   host:
     - hsb0
     - hsb8
     - miniserver24
     - mba-gaming-pc
   ```

### Phase 2: Verification (5 minutes)

1. Test locally: `just format`
2. Test locally: `just check-all`
3. Push changes
4. Watch GitHub Actions turn green ✅

### Phase 3: Optional Improvements (later)

1. Add a dynamic host list generator
2. Set up proper pre-commit hooks locally
3. Add more comprehensive tests

---

## 🤓 Understanding the Matrix Build

The flake check workflow uses a **matrix strategy**:

```yaml
strategy:
  matrix:
    host: [host1, host2, host3]
```

This means:

- GitHub creates **parallel jobs** (one per host)
- Each job evaluates that host's configuration
- If **any** job fails, the entire workflow fails
- Currently checking 28 hosts = 28 parallel jobs = expensive and mostly useless (because they're archived)

**By updating to check only 4 active hosts:**

- Faster builds ⚡
- Lower costs 💰
- Actually useful results ✅

---

## 📚 Quick Reference

### Check what hosts exist in flake.nix:

```bash
nix eval .#nixosConfigurations --apply 'builtins.attrNames'
```

### Check a specific host:

```bash
just check-host hsb8
```

### Check all hosts (locally):

```bash
just check-all
```

### Run format check:

```bash
just format
```

---

## 🎬 Summary

**TL;DR:**

1. **Format check fails** because `prek` command doesn't exist (should be `pre-commit`)
2. **Flake check fails** because it's checking 18+ archived hosts that don't exist anymore
3. **Fix:** Update the workflow to check only active hosts and fix the format command
4. **Result:** Fast, reliable CI that actually helps you ✨

**The workflows are trying to do a good job, but they're checking machines that don't exist anymore!**

---

## 💡 Pro Tips

1. **Test workflows locally first** - Use `act` (GitHub Actions locally) or just run the commands manually
2. **Keep workflows in sync** - When you archive a host, remove it from `.github/workflows/check.yml`
3. **Use path filters** - The build and test workflows already do this well
4. **Consider using Cachix** - The format workflow already uses it for faster builds
5. **Fail fast** - The check workflow correctly has `continue-on-error: false` (commented out)

---

## ❓ Still Having Issues?

If the fixes above don't work:

1. **Check the actual error logs** in GitHub Actions
2. **Run the commands locally** to see detailed error messages
3. **Check if devenv.nix includes all needed tools**
4. **Make sure .pre-commit-config.yaml exists** (if using pre-commit)

The good news: These are all simple configuration issues, not fundamental problems! 🎉
