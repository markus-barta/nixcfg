# CI/CD Pipeline Explained

## 🎯 What Is This About?

This document explains the **automated checks** (CI/CD) that run on GitHub every time you push code to this repository.

---

## 🤖 The Automated Steps

Every time you push code to GitHub, several automated workflows start running. Think of them as robots checking your work before it gets merged.

### 1. **🔎 Flake Check** (`check.yml`)

**What it does:** Validates that all your NixOS host configurations can be evaluated (checked for errors)

**How it works:**

1. Runs a **matrix build** - checks multiple hosts in parallel
2. For each host, tries to evaluate the configuration
3. If ANY host fails, the entire workflow fails

**Hosts being checked:**

- `hsb0`, `hsb1`, `hsb8`
- `gpc0`, `csb0`, `csb1`

**Total:** 6 active hosts

### 2. **🏗️ Build Apps** (`build.yml`)

**What it does:** Builds specific packages (QOwnNotes, Nixbit) and pushes them to your binary cache

**When it runs:** Only on the `main` branch when specific files change

### 3. **🧪 Run Tests** (`tests.yml`)

**What it does:** Runs integration tests for QOwnNotes

**When it runs:** When test files or QOwnNotes package changes

### 4. **📄 Format Check** (`format-check.yml`)

**Status:** Currently disabled (workflow commented out)

**What it did:** Checked if code is properly formatted using pre-commit hooks

**Why disabled:** The `prek` command doesn't exist in the devenv. Local pre-commit hooks handle formatting instead.

---

## 🔍 Understanding the Matrix Build

The flake check workflow uses a **matrix strategy**:

```yaml
strategy:
  matrix:
    host:
      - hsb0
      - hsb1
      - hsb8
      - gpc0
      - csb0
      - csb1
```

This means:

- GitHub creates **parallel jobs** (one per host)
- Each job evaluates that host's configuration
- If **any** job fails, the entire workflow fails
- Currently checking 6 hosts = 6 parallel jobs

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

---

## 🎯 Keeping CI in Sync

When you add or remove hosts from `flake.nix`, remember to update `.github/workflows/check.yml` to match:

1. **Adding a host:** Add it to the `host:` matrix
2. **Removing/archiving a host:** Remove it from the `host:` matrix

**Current active hosts (December 2025):**

| Host   | Role                      |
| ------ | ------------------------- |
| `hsb0` | DNS/DHCP server (home)    |
| `hsb1` | Home automation (home)    |
| `hsb8` | Home automation (parents) |
| `gpc0` | Gaming PC                 |
| `csb0` | Cloud server              |
| `csb1` | Cloud server              |

---

## 💡 Pro Tips

1. **Test workflows locally first** - Use `act` (GitHub Actions locally) or just run the commands manually
2. **Keep workflows in sync** - When you archive a host, remove it from `.github/workflows/check.yml`
3. **Use path filters** - The build and test workflows already do this well
4. **Consider using Cachix** - The workflows use it for faster builds
