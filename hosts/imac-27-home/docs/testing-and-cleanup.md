# Testing & Cleanup Guide - imac-27-home

**Purpose**: Post-migration testing and Homebrew package cleanup procedures  
**When to use**: After completing Phases 0-3 of the main migration  
**Reference**: See `migration.md` for the main migration plan

---

## Overview

After completing the main migration (Phases 0-3), you'll have:

- ✅ home-manager configured and activated
- ✅ Core tools and dotfiles migrated to Nix
- ✅ Shell, terminal, git, and dev tools working

**This document covers:**

1. Testing & validation procedures (formerly Phase 4)
2. Staged Homebrew package removal (formerly Phase 5)
3. Final system cleanup and verification

**Note**: These phases are **optional and can be done gradually**. The main migration is complete after Phase 3. This is just cleanup.

---

## ✅ Switch to Nix Complete (2025-11-14)

**Status**: Successfully switched to Nix as primary tool source

### What Was Done

1. **Ran `setup-macos.sh`** - Added Nix fish to `/etc/shells` and set as default shell
2. **Fixed PATH Priority Issue** - Initial switch didn't prioritize Nix paths
   - **Root cause**: PATH was inherited from parent environment, Homebrew paths came first
   - **Solution**: Added `loginShellInit` to Fish configuration in `home.nix`
   - **Bonus**: Also configured Zsh for consistency across shells
3. **Verified Switch** - All commands now resolve to Nix versions:
   ```bash
   echo $SHELL      # /Users/markus/.nix-profile/bin/fish
   which fish       # /Users/markus/.nix-profile/bin/fish
   which node       # /Users/markus/.nix-profile/bin/node
   which python3    # /Users/markus/.nix-profile/bin/python3
   ```

### Key Configuration Changes

**Fish Shell (`home.nix`):**

```nix
loginShellInit = ''
  # Ensure Nix paths are prioritized
  fish_add_path --prepend --move ~/.nix-profile/bin
  fish_add_path --prepend --move /nix/var/nix/profiles/default/bin
'';
```

**Zsh Shell (`home.nix`):**

```nix
programs.zsh = {
  enable = true;
  initExtra = ''
    export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
  '';
};
```

### Verification Checklist

- ✅ Default shell is Nix fish
- ✅ PATH prioritizes Nix over Homebrew
- ✅ Node.js from Nix (v22.20.0)
- ✅ Python from Nix (v3.13.0)
- ✅ Fish from Nix (v4.1.2)
- ✅ Zsh also configured for consistency

You're now ready to proceed with daily usage testing below.

---

## Phase 4: Testing & Validation

**Timeline**: Flexible - hours to days, based on your confidence level

**Goal**: Verify Nix versions work before removing Homebrew fallbacks

**Reality Check**: The "1-2 weeks" recommendation is aspirational. In practice:

- **Compressed timeline**: Test for a few hours, proceed if confident
- **Standard timeline**: 2-3 days of daily use
- **Paranoid timeline**: 1-2 weeks
- **Your call**: As long as Homebrew packages exist as fallback, risk is low

### Daily Usage Testing

Use your system normally with all Nix/home-manager tools. Keep Homebrew packages installed as fallbacks during this phase.

**Test Checklist:**

- [ ] Terminal opens and works smoothly
- [ ] SSH shortcuts work (qc99, qc24, qc0, qc1)
- [ ] Open Cursor/Zed with projects
- [ ] Git operations with correct identity switching
  - [ ] Personal repos show markus@barta.com
  - [ ] BYTEPOETS repos show markus.barta@bytepoets.com
- [ ] Node.js works globally and in projects
- [ ] Python works globally and in projects
- [ ] WezTerm renders Hack Nerd Font correctly
- [ ] Starship prompt displays all modules
- [ ] All abbreviations work (flushdns, qc99, qc24, etc.)
- [ ] All aliases work (mc, lg)
- [ ] Custom functions work (pingt, sourceenv, sourcefish)
- [ ] Scripts in `~/Scripts/` are executable and work
- [ ] direnv auto-loads when entering project directories

### Critical Workflow Validation

Test your actual daily workflows, not just individual commands:

**Morning Routine:**

1. Open terminal
2. SSH to servers
3. Check git repos
4. Open projects in Cursor

**Development Work:**

1. Create new Node.js script
2. Run existing Python scripts
3. Git commit and push
4. Use custom scripts from `~/Scripts/`

**If anything doesn't work:**

- Document the issue
- Use Homebrew fallback temporarily
- Fix the Nix config
- Test again

**When to proceed to Phase 5:**

- ✅ All critical workflows tested
- ✅ No unexpected issues encountered
- ✅ Comfortable that Nix versions work identically to Homebrew versions
- ✅ At least 3-5 days of daily use (or longer if you prefer)

---

## Phase 5: Homebrew Package Cleanup

**Goal**: Remove Homebrew packages now that Nix versions are proven working

**Important Principles:**

1. **Remove in stages** - Not all at once
2. **Test after each stage** - Verify everything still works
3. **Easy rollback** - Can reinstall immediately if needed
4. **No rush** - Take your time between stages

---

### Stage 5.1: Low-Risk CLI Tools

**Timeline**: Test for a few hours (or proceed immediately if confident)

**Packages to remove:**

- [ ] bat
- [ ] btop
- [ ] ripgrep
- [ ] fd
- [ ] fzf
- [ ] cloc

**Removal process:**

```bash
# Remove one by one with immediate verification
brew uninstall bat && which bat && bat --version
brew uninstall btop && which btop && btop --help
brew uninstall ripgrep && which rg && rg --version
brew uninstall fd && which fd && fd --version
brew uninstall fzf && which fzf && fzf --version
brew uninstall cloc && which cloc && cloc --version
```

**Verification:**

- [ ] Each command still works after removal
- [ ] `which <command>` points to Nix path (not /usr/local/bin/)
- [ ] Actual usage works (not just --version)

**If any fails:** `brew install <package>` to restore immediately

---

### Stage 5.2: Development Tools

**Timeline**: Test immediately - verify Node/Python work globally and in projects

**Packages to remove:**

- [ ] zoxide
- [ ] direnv
- [ ] node (AFTER extensive testing)
- [ ] python@3.10 (AFTER extensive testing)

**Removal process:**

```bash
# Safe removals first
brew uninstall zoxide && which zoxide && z --version
brew uninstall direnv && which direnv && direnv version
```

**Critical Test Before Removing Node/Python:**

```bash
# Test GLOBALLY first (home-manager provides these)
node --version        # Should work in any directory
python3 --version     # Should work in any directory
npm --version         # Should work globally
pip3 --version        # Should work globally

# Test in nixcfg devenv shell (project override)
cd ~/Code/nixcfg
devenv shell
node --version        # Should show devenv version
python3 --version     # Should show devenv version
exit

# Test Cursor can find interpreters
# Open a .js or .py file in Cursor, verify LSP works

# Test actual projects
cd ~/path/to/node/project
node your-script.js
npm install  # If you use npm

cd ~/path/to/python/project
python3 your-script.py

# If ALL tests pass, then remove Homebrew versions
brew uninstall node python@3.10
```

**Verification:**

- [ ] Node/Python work globally (outside any project)
- [ ] Node/Python work in devenv shell
- [ ] IDEs (Cursor/Zed) can find interpreters
- [ ] Actual project scripts run successfully
- [ ] npm/pip commands work globally

---

### Stage 5.3: Terminal & Shell (HIGH RISK)

**Timeline**: Test thoroughly - these are critical for daily use

**⚠️ WARNING**: Remove carefully, verify each before proceeding.

**Remove in this order:**

#### 1. Starship

```bash
brew uninstall starship
exec fish  # Reload shell

# Verify:
# - Prompt displays correctly
# - Git info shows
# - Custom gitcount module works
# - All prompt modules display
```

#### 2. WezTerm

```bash
brew uninstall --cask wezterm

# Open new WezTerm from Applications or Spotlight

# Verify:
# - Terminal opens
# - Hack Nerd Font renders correctly
# - Colors/theme correct
# - Keybindings work
```

#### 3. Hack Nerd Font

```bash
brew uninstall --cask font-hack-nerd-font

# Restart WezTerm

# Verify:
# - Font still renders correctly
# - No fallback to different font
# - Nerd Font icons display (snowflake, Apple logo, etc.)
```

**Emergency Rollback:**

```bash
brew install --cask wezterm font-hack-nerd-font
brew install starship
```

---

### Stage 5.4: Git (AFTER Everything Else Works)

**Timeline**: Test thoroughly before removing

**⚠️ CRITICAL**: Git is used everywhere. Test extensively before removing.

**Pre-removal testing:**

```bash
# Verify Nix git is working
which git  # Should show Nix path
git --version

# Test personal repo
cd ~/Code/nixcfg
git config user.email  # Should be markus@barta.com
git status
git log --oneline -5

# Test work repo
cd ~/Code/BYTEPOETS/google-sheets-bp-scripts
git config user.email  # Should be markus.barta@bytepoets.com
git status
git log --oneline -5

# Test actual git operations
git add -A
git commit -m "test commit"
git push  # or git pull

# If ALL tests pass:
brew uninstall git
```

**Verification after removal:**

- [ ] Git still works globally
- [ ] Dual identity switching works correctly
- [ ] Can commit and push
- [ ] GitHub/GitLab authentication works
- [ ] gitignore patterns applied correctly

---

### Stage 5.5: Unwanted Packages (Anytime)

**Safe to remove whenever:**

```bash
brew uninstall --cask qownnotes
brew uninstall --cask mactex-no-gui
```

---

## Per-Package Verification Checklist

**Before removing ANY package:**

1. [ ] Nix/home-manager version is working
2. [ ] `which <command>` points to Nix path
3. [ ] Test actual functionality, not just `--version`
4. [ ] Keep Homebrew version until Nix proven working

**After removing each package:**

1. [ ] Command still works: `which <command>`
2. [ ] Version check: `<command> --version`
3. [ ] Actual use case works
4. [ ] No error messages in shell startup
5. [ ] PATH doesn't show old Homebrew paths

**If any issues:**

```bash
# Immediately reinstall
brew install <package>  # or --cask for GUI apps

# Debug
which <command>
echo $PATH
# Check if Nix version is in PATH
```

---

## Final System Cleanup

### Finalize Login Shell Transition

After all packages removed and tested:

```bash
# Run the one-time system setup script
cd ~/Code/nixcfg/hosts/imac-27-home
./setup/setup-macos.sh

# This script:
# - Adds ~/.nix-profile/bin/fish to /etc/shells
# - Changes default shell via chsh

# After completion:
# - Restart terminal
# - Verify fish is the login shell
# - Test login/logout cycle

# Only AFTER verification:
brew uninstall fish
```

### Final Verification Checklist

Before declaring migration complete:

**Functional Parity (same as before migration):**

- [ ] Terminal opens correctly
- [ ] Shell prompt works (starship with custom gitcount)
- [ ] All commands available
- [ ] Fonts render correctly (Hack Nerd Font)
- [ ] Custom functions work (sourceenv, sourcefish, pingt)
- [ ] Aliases work (mc, lg)
- [ ] Abbreviations work (flushdns, qc99, qc24, qc0, qc1)
- [ ] SSH shortcuts connect properly
- [ ] Git dual identity switches correctly
- [ ] direnv auto-loads environments
- [ ] Node.js projects work
- [ ] Python projects work
- [ ] Cursor/Zed open projects correctly

**Nix-Specific Verification (proving migration benefits):**

- [ ] Commands come from Nix paths:
  ```bash
  which fish      # Should show ~/.nix-profile/bin/fish
  which starship  # Should show Nix path
  which git       # Should show Nix path
  which node      # Should show Nix path
  which python3   # Should show Nix path
  ```
- [ ] No Homebrew packages for migrated tools: `brew list | grep -E "^(fish|starship|git|node)$"` returns nothing
- [ ] Nix paths in PATH: `echo $PATH | grep nix` shows Nix directories first
- [ ] Configs are version-controlled:
  ```bash
  cd ~/Code/nixcfg
  git status  # home.nix, flake.nix, devenv.nix should be committed
  ```
- [ ] home-manager works: `home-manager switch --flake .#markus@imac-27-home` succeeds
- [ ] Declarative rebuild: Can rebuild configs from git on a fresh machine
- [ ] Rollback tested: Verified rollback procedure works (or documented why skipped)

---

## Timeline Summary

**Realistic Timeline (Your Pace):**

- Phase 4 (Testing): Hours to days - as long as YOU need
- Stage 5.1-5.5: Remove and verify - can be done in one session if confident
- Final cleanup: Minutes to hours

**Total**: Highly variable - from same-day to weeks

**Compressed Timeline (1-2 days total):**

- Day 1: Phases 0-3 (setup and migration)
- Day 2: Quick testing + Stage 5 cleanup (remove Homebrew packages)
- **Key**: Homebrew packages stay until you're ready to remove them

**Relaxed Timeline (1-2 weeks):**

- Week 1: Phases 0-3 + daily usage testing
- Week 2: Staged cleanup when confident

**Your Choice**: The timeline is entirely up to your confidence level and risk tolerance.

---

## Rollback & Recovery Procedures

### When to Rollback

**Rollback immediately if:**

- Terminal becomes unusable
- Shell won't start
- Critical tools broken (git, node, python)
- System feels unstable
- You're not comfortable with the changes

**Remember**: Better to rollback early and retry than to push through problems.

---

### Full Rollback Scenarios

#### Scenario 1: Early Failure (Before Removing Homebrew Packages)

**When**: Phases 0-4, Homebrew packages still installed

**Steps**:

```bash
# 1. Restore all dotfiles from backup
BACKUP_DIR=~/migration-backup-YYYYMMDD-HHMMSS  # Use your actual backup dir
cp -r "$BACKUP_DIR/fish" ~/.config/
cp "$BACKUP_DIR/starship.toml" ~/.config/
cp "$BACKUP_DIR/wezterm.lua" ~/
cp "$BACKUP_DIR/gitconfig" ~/.gitconfig
cp "$BACKUP_DIR/gitignore_global" ~/.gitignore_global
cp -r "$BACKUP_DIR/Scripts" ~/

# 2. Verify restoration with checksums
cd "$BACKUP_DIR"
shasum -c checksums.txt

# 3. Revert system-level shell changes (if setup/setup-macos.sh was run)
ORIGINAL_SHELL=$(cat "$BACKUP_DIR/system-state/current-shell.txt")
if [ "$SHELL" != "$ORIGINAL_SHELL" ]; then
  echo "Reverting login shell to: $ORIGINAL_SHELL"
  chsh -s "$ORIGINAL_SHELL"
fi

# Remove Nix fish from /etc/shells (requires sudo)
NIX_FISH="$HOME/.nix-profile/bin/fish"
if grep -q "$NIX_FISH" /etc/shells; then
  echo "Removing Nix fish from /etc/shells (requires sudo)"
  sudo sed -i.backup "/$(echo $NIX_FISH | sed 's/\//\\\//g')/d" /etc/shells
fi

# 4. Revert git repository changes
cd ~/Code/nixcfg
git checkout -- flake.nix devenv.nix
rm -f hosts/imac-27-home/home.nix  # Remove if created

# 5. Deactivate home-manager (if installed)
home-manager uninstall  # Removes home-manager activation

# 6. Clean up Nix profiles (if any)
nix profile list
# Remove any newly added profiles if needed

# 7. Restart shell to reload original configs
exec "$ORIGINAL_SHELL"
```

**Result**: System back to 100% Homebrew state, including system-level shell settings

---

#### Scenario 2: Late Failure (After Removing Homebrew Packages)

**When**: Phase 5+, some/all Homebrew packages removed

**Steps**:

```bash
# 1. Restore all dotfiles (same as Scenario 1)
BACKUP_DIR=~/migration-backup-YYYYMMDD-HHMMSS
cp -r "$BACKUP_DIR/fish" ~/.config/
cp "$BACKUP_DIR/starship.toml" ~/.config/
cp "$BACKUP_DIR/wezterm.lua" ~/
cp "$BACKUP_DIR/gitconfig" ~/.gitconfig
cp "$BACKUP_DIR/gitignore_global" ~/.gitignore_global

# 2. Reinstall Homebrew packages from backup
cd "$BACKUP_DIR/system-state"
xargs brew install < brew-formulae.txt
xargs brew install --cask < brew-casks.txt

# 3. Revert system-level shell changes
ORIGINAL_SHELL=$(cat current-shell.txt)
echo "Reverting login shell to: $ORIGINAL_SHELL"
chsh -s "$ORIGINAL_SHELL"

# Remove Nix fish from /etc/shells (requires sudo)
NIX_FISH="$HOME/.nix-profile/bin/fish"
if grep -q "$NIX_FISH" /etc/shells; then
  echo "Removing Nix fish from /etc/shells (requires sudo)"
  sudo sed -i.backup "/$(echo $NIX_FISH | sed 's/\//\\\//g')/d" /etc/shells
fi

# 4. Verify critical tools work
fish --version
starship --version
wezterm --version
git --version
node --version

# 5. Revert git repository changes
cd ~/Code/nixcfg
git checkout -- flake.nix devenv.nix
rm -f hosts/imac-27-home/home.nix

# 6. Deactivate home-manager
home-manager uninstall

# 7. Restart shell with original shell
exec "$ORIGINAL_SHELL"
```

**Result**: System fully restored to pre-migration state, including system-level shell settings

---

#### Scenario 3: Partial Rollback (Keep Some Changes)

**When**: Most things work, but need to revert specific components

**Example: Revert just Fish, keep everything else**:

```bash
# 1. Restore Fish only
BACKUP_DIR=~/migration-backup-YYYYMMDD-HHMMSS
cp -r "$BACKUP_DIR/fish" ~/.config/

# 2. Reinstall Homebrew fish
brew install fish

# 3. Revert system-level shell changes
chsh -s /usr/local/bin/fish

# Remove Nix fish from /etc/shells (requires sudo)
NIX_FISH="$HOME/.nix-profile/bin/fish"
if grep -q "$NIX_FISH" /etc/shells; then
  echo "Removing Nix fish from /etc/shells (requires sudo)"
  sudo sed -i.backup "/$(echo $NIX_FISH | sed 's/\//\\\//g')/d" /etc/shells
fi

# 4. Update home.nix to disable programs.fish
# (Edit home.nix: set programs.fish.enable = false)
home-manager switch --flake .#markus@imac-27-home

# 5. Restart shell
exec /usr/local/bin/fish
```

---

### Rollback Testing (Before Migration)

**Test the rollback procedure BEFORE starting**:

```bash
# 1. After creating backup, try restoring one file
cp "$BACKUP_DIR/fish/config.fish" /tmp/test-restore.fish
diff ~/.config/fish/config.fish /tmp/test-restore.fish
# Should show no differences

# 2. Verify brew lists are valid
cat "$BACKUP_DIR/brew-formulae.txt" | wc -l
# Should show 203 lines

# 3. Verify checksums work
cd "$BACKUP_DIR"
shasum -c checksums.txt | grep -c OK
# Should match file count
```

---

### Prevention: Staged Rollback Points

**Create git commits at each phase** for easy rollback:

```bash
# After Phase 1
git add flake.nix hosts/imac-27-home/home.nix
git commit -m "Phase 1: Infrastructure setup"

# After Phase 2
git add devenv.nix hosts/imac-27-home/home.nix
git commit -m "Phase 2: Core environment complete"

# etc...
```

**Result**: Can rollback to any phase with `git checkout <commit>`

**Dirty Git State and Partial Failures**

The standard rollback procedures assume clean git operations, but Phase 1-5 implementations create uncommitted changes that require special handling.

**What Actually Happens:**

- You create `home.nix` (new file, untracked)
- You modify `flake.nix` and `devenv.nix` (uncommitted changes)
- You activate home-manager (creates symlinks in `~/.config/`)
- Something breaks midway...

**Dirty State Rollback**:

```bash
# 1. Force revert ALL git changes (including uncommitted)
cd ~/Code/nixcfg
git reset --hard HEAD  # Reverts tracked files
git clean -fd          # Removes untracked files

# 2. Remove home-manager symlinks
home-manager uninstall || true

# 3. Restore dotfiles from backup (as in Scenario 1)
BACKUP_DIR=~/migration-backup-YYYYMMDD-HHMMSS
cp -r "$BACKUP_DIR/fish" ~/.config/
cp "$BACKUP_DIR/starship.toml" ~/.config/
# ... etc

# 4. Verify no Nix artifacts remain
ls -la ~/.config/ | grep -- '->'  # Check for symlinks
echo $PATH | grep nix              # Check PATH

# 5. Restart shell
exec /usr/local/bin/fish
```

**Lesson**: This is why git commits at each phase (staged rollback points) are important - you can rollback to a known-good state rather than forcing a hard reset.

---

### Rollback Checklist

Before declaring rollback complete, verify:

- [ ] All backed up files restored and checksums match
- [ ] Homebrew packages reinstalled (compare with brew-formulae.txt)
- [ ] Login shell restored to original: `echo $SHELL` matches backup
- [ ] Nix fish removed from /etc/shells: `grep ~/.nix-profile/bin/fish /etc/shells` returns nothing
- [ ] System shell properly set: `dscl . -read ~/ UserShell` shows correct shell
- [ ] Terminal opens and works (fish, starship, wezterm)
- [ ] Git operations work with correct identity
- [ ] SSH shortcuts work (qc99, qc24, etc.)
- [ ] Custom functions work (pingt, sourceenv, etc.)
- [ ] Cursor/Zed open projects correctly
- [ ] Node.js and Python work (if applicable)
- [ ] No Nix/home-manager artifacts in shell PATH
- [ ] Git repo clean (no uncommitted Nix changes)

---

## Emergency Contacts & Resources

### If Rollback Fails

1. **Time Machine**: Use macOS Time Machine to restore to pre-migration state
   - System Preferences → Time Machine → Enter Time Machine
   - Navigate to backup before migration started
   - Restore entire home directory or specific files

2. **Homebrew reinstall** (if brew itself breaks):

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

3. **Shell recovery** (if can't login due to broken shell):
   - Boot to Recovery Mode (Cmd+R)
   - Terminal → Utilities → Terminal
   - Reset shell: `chsh -s /bin/bash <username>`
   - Clean up /etc/shells: `sudo sed -i.backup '/\.nix-profile/d' /etc/shells`
   - Reboot and fix from bash, then switch back to working shell

4. **Git repository recovery**:
   ```bash
   cd ~/Code/nixcfg
   git reflog  # Find commit before migration
   git reset --hard <commit-hash>
   ```

### Help Resources

If something goes wrong:

1. **Homebrew reinstall**: `brew install <package>`
2. **Nix community**: https://discourse.nixos.org
3. **devenv documentation**: https://devenv.sh
4. **home-manager manual**: https://nix-community.github.io/home-manager/

---

## Success Criteria

**Beyond Functional Parity**

Migration is successful when it delivers measurable benefits beyond just maintaining existing functionality:

**Functional Parity:**

- ✅ All critical workflows work perfectly
- ✅ System feels identical to pre-migration (or better)

**Nix-Specific Benefits (The Actual Improvements):**

- ✅ **Reproducible**: Configs in git, can rebuild from scratch via `home-manager switch`
- ✅ **Declarative**: Core tools and dotfiles managed in `home.nix`, not manual file edits
- ✅ **Version-controlled**: All changes tracked in git with meaningful commits
- ✅ **Rollback tested**: Rollback procedure verified (or documented rationale for skip)
- ✅ **Path verified**: Commands come from Nix, not Homebrew
- ✅ **Template ready**: Can replicate to `imac-27-work` from git
- ✅ **Understanding**: You know what you built and can maintain it

**Learning Goals (Educational Purpose):**

- ✅ Understand Nix package management
- ✅ Understand home-manager for user configs
- ✅ Understand devenv for project environments
- ✅ Understand flakes for reproducible builds
- ✅ Experience hybrid declarative/imperative approach

**Most importantly**: The migration **improved** the system beyond maintaining what worked before.
