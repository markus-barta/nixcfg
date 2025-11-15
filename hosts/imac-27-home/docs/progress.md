# Migration Progress & History - imac-27-home

**Last Updated**: 2025-11-15  
**Status**: 🎉 **MIGRATION 100% COMPLETE** 🎉

---

## Current State (2025-11-15)

### 🎉 **MIGRATION 100% COMPLETE** 🎉

### ✅ Completed

**Core Migration** (Phases 0-3):

- ✅ All configurations declaratively managed via Nix
- ✅ Shell (Fish), Terminal (WezTerm), Prompt (Starship), Git dual identity
- ✅ Global interpreters (Node.js, Python) via home-manager
- ✅ Essential CLI tools (bat, btop, ripgrep, fd, fzf, etc.)
- ✅ Scripts management (3 essential scripts in git)
- ✅ Fonts (Hack Nerd Font) for both WezTerm and macOS Terminal.app
- ✅ macOS GUI apps (WezTerm) linked to ~/Applications/
- ✅ Karabiner-Elements configuration declarative (JSON in git)

**System Integration**:

- ✅ Nix fish as default login shell
- ✅ PATH properly prioritizes Nix over Homebrew
- ✅ Zsh configured for consistency
- ✅ direnv with nix-direnv enabled
- ✅ Nano with syntax highlighting

**Homebrew Cleanup**:

- ✅ Stage 1 complete: Removed 10 packages (~62MB freed)
- ✅ Stage 2 complete: Removed unwanted GUI apps (qownnotes, mactex-no-gui - already removed)
- ✅ Stage 3 complete: Removed git (using Nix v2.51.0)
- ✅ Core dependencies migrated to Nix (prettier, esptool, nmap)
- ✅ Auto-removed unused dependencies and cleaned cache (45MB freed)
- ✅ **ALL MIGRATED PACKAGES REMOVED FROM HOMEBREW**
- ✅ **Total freed: ~110MB**

**Special Configurations**:

- ✅ Terminal.app Nerd Fonts (manual setup documented)
- ✅ Karabiner-Elements (Caps Lock → Hyper, F1-F12 in terminals)
- ✅ macOS GUI app linking elegant solution

### 🔧 Current Setup

**Shell & Tools** (All from Nix):

```bash
$ which fish git node python3 starship wezterm
/Users/markus/.nix-profile/bin/fish (v4.1.2)
/Users/markus/.nix-profile/bin/git (v2.51.0)
/Users/markus/.nix-profile/bin/node (v22.20.0)
/Users/markus/.nix-profile/bin/python3 (v3.13.8)
/Users/markus/.nix-profile/bin/starship
/Users/markus/.nix-profile/bin/wezterm
```

**Configuration Management**:

- `home.nix`: User-level configurations
- `flake.nix`: Nix flake with home-manager integration
- `devenv.nix`: Development environment with macOS platform detection

### ⏭️ Next Steps

**Migration Complete** ✅:

- ✅ All core tools migrated to Nix
- ✅ All Homebrew duplicates removed
- ✅ Git dual identity verified and working
- ✅ System running 100% on Nix for daily workflows

**Optional Future Work**:

- Continue daily usage and testing
- Template preparation for `imac-27-work`
- Remaining Homebrew packages: 167 formulae, 10 casks (experiments/GUI apps - keep as-is)

---

## Migration Journey

### Phase 0: Pre-Migration Safety ✅

**Phase 0.1: Planning & Documentation** ✅ (2025-11-14)

- Comprehensive migration plan created
- Architecture decisions documented
- Risk assessment completed
- Backup strategy defined

**Phase 0.2: Backup Execution** ✅ (2025-11-14)

- Created backup script: `setup/backup-migration.sh`
- Executed full backup to `~/migration-backup-20251114-165637/`
- Verified 56 files backed up with SHA256 checksums
- Renamed `fish_prompt.fish` to `fish_prompt.fish.disabled` (prevent Starship conflict)

**Backup Validation** ✅:

- File diff test passed (no differences)
- Checksums verified (all OK)
- File counts match expectations (56 files)
- RESTORE.md and CHECKSUMS.txt created
- Backup directory accessible, 96GB free space

---

### Phase 1: Setup Infrastructure ✅ (2025-11-14)

**Created**:

- `hosts/imac-27-home/home.nix` - Comprehensive user configuration
- Enhanced `flake.nix` with `homeConfigurations."markus@imac-27-home"`
- Enhanced `devenv.nix` with macOS platform detection

**Configured in home.nix**:

- **Fish**: All functions, aliases, abbreviations, PATH configuration
- **Starship**: Complete prompt config with custom gitcount module
- **WezTerm**: Full terminal configuration with Hack Nerd Font
- **Git**: Dual identity support (personal + BYTEPOETS work)
- **direnv**: Nix-direnv integration
- **Global packages**: Node.js, Python, zoxide, Hack Nerd Font, CLI tools

**Results**:

- home-manager successfully installed and activated
- All configurations symlinked from Nix store
- Nix versions of all tools installed (in `~/.nix-profile/bin/`)
- Homebrew versions still active (PATH priority not yet fixed)
- Old configs backed up with `.backup` extension

**Commits**:

- Initial infrastructure setup with fixes for home-manager compatibility
- Fixed deprecated Git settings, Nerd Font package name, Fish function issues

---

### Phase 2: Core Environment Testing ✅ (2025-11-14)

Tested each component step-by-step to verify Nix versions work correctly.

**2.1 Global Interpreters** ✅

- Node.js: Nix v22.20.0 (LTS) - All tests passed (execution, NPM, scripts)
- Python: Nix v3.13.8 - All tests passed (execution, stdlib, scripts)
- ⚠️ No pip (by design - use Nix for packages)

**2.2 Essential CLI Tools** ✅

- bat, btop, ripgrep, fd, fzf - All functional in devenv shell
- devenv's macOS platform detection working correctly

**2.3 direnv** ✅

- Installed via home-manager (v2.37.1)
- nix-direnv integration enabled
- Automatic Fish shell integration configured

**2.4 Fish Shell** ✅

- Fish v4.1.2 from Nix
- All configuration files symlinked
- Custom functions: brewall, cd, sudo, sourceenv, sourcefish, pingt
- Aliases: mc, lg
- Abbreviations: flushdns, qc0, qc1, qc24, qc99

**2.5 Starship** ✅

- Starship v1.23.0
- Custom gitcount module verified working
- Language indicators (nodejs, python, rust, golang) configured
- Docker and Kubernetes contexts enabled

**2.6 WezTerm** ✅

- WezTerm v0-unstable-2025-10-14 (newer than Homebrew)
- Config symlinked to `~/.config/wezterm/wezterm.lua`
- Hack Nerd Font installed and recognized
- All settings verified (font, colors, keybindings)

**2.7 Git Dual Identity** ✅

- Git v2.51.1
- Personal identity: Markus Barta / markus@barta.com (default)
- Work identity: mba / markus.barta@bytepoets.com (for ~/Code/BYTEPOETS/)
- Directory-based switching working correctly
- Global gitignore, credential helper, Sourcetree tools configured

---

### Phase 3: Scripts & Additional Tools ✅ (2025-11-14)

**3.1 Scripts Management** ✅

- Created `hosts/imac-27-home/scripts/` directory
- Added 3 essential scripts to repo:
  - `flushdns.sh` - DNS cache flush utility
  - `pingt.sh` - Timestamped ping (pure bash, no perl)
  - `stopAmphetamineAndSleep.sh` - System sleep control
- All other scripts remain only in local `~/Scripts/` backup (not in git)
- Configured `home.file."Scripts"` to link scripts to `~/Scripts/`

**3.2 Hack Nerd Font** ✅

- Already installed in Phase 1
- Verified WezTerm uses font correctly in Phase 2
- Later: Added symlinks to `~/Library/Fonts/` for Terminal.app

**3.3 Additional CLI Tools** ✅

- cloc, prettier already added in Phase 1
- All development utilities configured

---

### Post-Migration: Switch to Nix ✅ (2025-11-14)

**Initial Issue**: After home-manager switch, commands still resolved to Homebrew versions.

**Root Cause**: PATH inherited from parent environment, Homebrew paths came first.

**Solution**:

1. **Fixed Fish PATH** - Added `loginShellInit` to prepend Nix paths:

   ```nix
   loginShellInit = ''
     fish_add_path --prepend --move ~/.nix-profile/bin
     fish_add_path --prepend --move /nix/var/nix/profiles/default/bin
   '';
   ```

2. **Configured Zsh** - Added PATH configuration for consistency:

   ```nix
   programs.zsh = {
     enable = true;
     initExtra = ''
       export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
     '';
   };
   ```

3. **Ran setup-macos.sh** - Added Nix fish to `/etc/shells` and set as default shell

**Verification** ✅:

```bash
$ echo $SHELL      # /Users/markus/.nix-profile/bin/fish
$ which fish node python3
/Users/markus/.nix-profile/bin/fish
/Users/markus/.nix-profile/bin/node
/Users/markus/.nix-profile/bin/python3
```

---

## Testing & Validation

### Reboot Test ✅ (2025-11-14)

Performed full system reboot to verify persistence.

**Results**:

- ✅ Nix fish loads correctly
- ✅ PATH prioritizes Nix
- ✅ direnv auto-loads environments
- ✅ Core tools work (fish, bat, btop, ripgrep, fd, zoxide)

**Initial Issue**: Nerd Font icons missing in Starship prompt

**Root Cause**: Starship's `settings` in `home.nix` losing Unicode escape sequences during Nix conversion.

**Solution**: Switched from `programs.starship.settings` to direct file linking:

```nix
home.file.".config/starship.toml".source = ./config/starship.toml;
```

**Result**: ✅ All Nerd Font icons rendering correctly

---

### devenv Lock File ✅ (2025-11-14)

**Warning**: `devenv 1.10.1 is newer than devenv input (1.10) in devenv.lock`

**Solution**: Ran `devenv update` to sync `devenv.lock` with latest version.

**Result**: ✅ Warning resolved, lock file updated and committed

---

## Homebrew Cleanup

### Stage 1: Core Tools ✅ (2025-11-14)

**Removed 10 packages** (~62MB freed):

- fish, bat, btop, ripgrep, fd, zoxide, direnv, starship

**Auto-removed dependencies**:

- libgit2, bash

### Stage 2: Unwanted GUI Apps ✅ (2025-11-15)

**Removed**:

- qownnotes (cask) - Note-taking app (no longer needed)
- mactex-no-gui (cask) - LaTeX distribution (no longer needed)

### Stage 3: Git ✅ (2025-11-15)

**Removed 8 packages** (~62MB freed):

- fish, bat, btop, ripgrep, fd, zoxide, direnv, starship

**Auto-removed dependencies**:

- libgit2, bash

**Blocked by dependencies**:

- `node` → Required by `prettier`
- `python@3.13` → Required by `esptool`, `evernote-backup`, `nmap`

**Migration to Nix**:

- ✅ Added missing packages to `home.nix`: bat, btop, ripgrep, fd, fzf
- ✅ Migrated `prettier`, `esptool`, `nmap` to Nix
- ⚠️ `evernote-backup` not in nixpkgs (kept in Homebrew)
- ✅ Force-removed `node` and `python@3.13` with `--ignore-dependencies`
- ✅ Cleaned Homebrew cache with `brew cleanup --prune=all`

**Verification** ✅:

```bash
$ which bat btop rg fd fzf prettier esptool nmap
# All point to ~/.nix-profile/bin/
```

---

### Nano Configuration ✅ (2025-11-14)

**Goal**: Use latest nano (not macOS pico) with syntax highlighting

**Solution**:

- Added `nano` to `home.packages`
- Created `~/.nanorc` via `home.file.".nanorc".text`
- Included syntax highlighting files from Nix nano package
- Removed unsupported options (`set smooth`, `set suspend`)

**Result**: ✅ Nano 8.6 with full syntax highlighting for nix, yaml, md, etc.

---

### Terminal.app Nerd Fonts ✅ (2025-11-15)

**Goal**: Make Nerd Fonts work in macOS Terminal.app (not just WezTerm)

**Issue**: Fonts installed in Nix store but not visible to macOS native apps

**Solution**: Added `home.activation.installMacOSFonts` to symlink fonts:

```nix
home.activation.installMacOSFonts = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  # Symlink all Hack Nerd Font files to ~/Library/Fonts/
'';
```

**Additional Step**: `killall fontd` to refresh font cache

**Result**: ✅ All 12 Hack Nerd Font variants available in Terminal.app font picker

**Documentation**: Manual setup steps in `docs/manual-setup/terminal-app-fonts.md`

---

### macOS GUI Apps Linking ✅ (2025-11-15)

**Goal**: Elegant solution for GUI apps (WezTerm) in Dock and Spotlight

**Issue**: After uninstalling WezTerm via Homebrew, Dock icon broke

**Solution**: Added `home.activation.linkMacOSApps` to symlink apps:

```nix
home.activation.linkMacOSApps = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  # Symlink from ~/Applications/Home Manager Apps/ to ~/Applications/
'';
```

**Benefits**:

- ✅ Apps appear in Spotlight (⌘+Space)
- ✅ Can pin to Dock
- ✅ Appear in ~/Applications/ like regular apps
- ✅ Fully managed by home-manager

**Documentation**: `docs/reference/macos-gui-apps.md`

---

### Karabiner-Elements Configuration ✅ (2025-11-15)

**Goal**: Declarative keyboard remapping (Caps Lock → Hyper, F1-F12 in terminals)

**Approach**: Hybrid solution

- **App**: Homebrew (`brew install --cask karabiner-elements`)
- **Config**: Nix/home-manager (JSON file in git)

**Solution**:

```nix
home.file.".config/karabiner/karabiner.json".source = ./config/karabiner.json;
```

**Configuration**:

- Caps Lock → Hyper (Cmd+Ctrl+Opt+Shift)
- F1-F12 as regular function keys in terminals
- Device-specific settings (ignore keyboard vendor: 1133, product: 50475)

**Documentation**:

- `docs/manual-setup/karabiner-setup.md` - Installation & usage
- `docs/reference/karabiner-elements.md` - Technical details

---

## Success Metrics

### Functional Parity ✅

- ✅ All critical workflows work perfectly
- ✅ System feels identical to pre-migration (or better)
- ✅ Terminal, shell, git, dev tools all functional
- ✅ SSH shortcuts, custom functions, scripts all working

### Nix-Specific Benefits ✅

- ✅ **Reproducible**: Configs in git, can rebuild via `home-manager switch`
- ✅ **Declarative**: Core tools and dotfiles managed in `home.nix`
- ✅ **Version-controlled**: All changes tracked in git with meaningful commits
- ✅ **Path verified**: Commands come from Nix (`~/.nix-profile/bin/`)
- ✅ **Template ready**: Can replicate to `imac-27-work` from git
- ✅ **Understanding**: Deep knowledge of Nix, home-manager, devenv, flakes

### Learning Goals ✅

- ✅ Understand Nix package management
- ✅ Understand home-manager for user configs
- ✅ Understand devenv for project environments
- ✅ Understand flakes for reproducible builds
- ✅ Experience hybrid declarative/imperative approach (manual Karabiner app install, etc.)

---

## Key Decisions Made

### Architecture

- ✅ **home-manager only** (NOT nix-darwin) - macOS upgrade safety
- ✅ **Flake-based** - version-locked, reproducible
- ✅ **Platform detection** - single `devenv.nix` for macOS/Linux
- ✅ **Manual system setup** - `setup/setup-macos.sh` for `/etc/shells` + `chsh`

### Tool Strategy

- ✅ **Node.js & Python**: Both global (home-manager) + project-specific (devenv)
- ✅ **Starship config**: Direct file linking (preserves Unicode characters)
- ✅ **Scripts**: 3 essential in git, rest local only
- ✅ **Nerd Fonts**: Nix + symlinks to `~/Library/Fonts/` for macOS
- ✅ **GUI Apps**: Symlink to `~/Applications/` for Dock/Spotlight integration
- ✅ **Karabiner**: Hybrid (Homebrew app + Nix config)

### Homebrew Strategy

- ✅ **Keep in Homebrew**: GUI apps (Cursor, Zed, Hammerspoon), specialized tools
- ✅ **Migrate to Nix**: CLI tools, dev tools, shell, terminal, fonts
- ✅ **Rule**: Declarative for daily-use, flexible for experiments

---

## File Structure

```
hosts/imac-27-home/
├── config/
│   ├── starship.toml
│   └── karabiner.json
├── docs/
│   ├── progress.md                  # This file (consolidated history)
│   ├── manual-setup/
│   │   ├── karabiner-setup.md       # Manual Karabiner app install
│   │   └── terminal-app-fonts.md    # Terminal.app font setup
│   └── reference/
│       ├── karabiner-elements.md    # Technical details
│       ├── macos-gui-apps.md        # GUI app management
│       └── hardware-info.md         # System specs
└── scripts/
    ├── setup/
    │   ├── backup-migration.sh      # Pre-migration backup
    │   └── setup-macos.sh           # One-time system setup
    └── host-user/
        ├── flushdns.sh              # User utilities
        ├── pingt.sh
        └── stopAmphetamineAndSleep.sh
```

---

## Rollback & Recovery

**If anything goes wrong**, see archived migration documentation for:

- Full rollback procedures (3 scenarios)
- Dirty git state recovery
- Emergency resources (Time Machine, shell recovery)

**Quick Emergency Rollback**:

```bash
# 1. Restore from backup
BACKUP_DIR=~/migration-backup-20251114-165637
cp -r "$BACKUP_DIR/fish" ~/.config/
cp "$BACKUP_DIR/starship.toml" ~/.config/

# 2. Revert system shell
chsh -s /usr/local/bin/fish

# 3. Reinstall Homebrew packages (if removed)
cd "$BACKUP_DIR/system-state"
xargs brew install < brew-formulae.txt
```

---

## Next Steps

### Immediate

- ✅ All done! System is production-ready

### Optional

- Stage 2+ Homebrew cleanup (see Homebrew Cleanup Analysis)
- Template preparation for `imac-27-work`
- Documentation refinement

### Future Machines

1. Clone repo: `git clone <repo-url> ~/Code/nixcfg`
2. Apply config: `home-manager switch --flake .#markus@imac-27-home`
3. Run setup: `./hosts/imac-27-home/scripts/setup/setup-macos.sh`
4. Install Karabiner: `brew install --cask karabiner-elements`
5. Done! (~1 hour vs 1 day manual setup)

---

## Lessons Learned

1. **PATH is critical** - loginShellInit needed to ensure Nix paths come first
2. **Unicode in Nix configs** - Direct file linking better for configs with special characters
3. **Activation scripts are powerful** - Used for fonts and GUI app linking
4. **Hybrid approaches work** - Homebrew app + Nix config (Karabiner) is elegant
5. **Documentation matters** - Manual steps clearly documented for reproducibility
6. **Git history is valuable** - Using `git mv` preserves file history
7. **Test after reboot** - Catches issues with persistence and initialization
8. **Backup early, validate backups** - Safety net for entire migration

---

**Migration Status**: ✅ **COMPLETE** - Production-ready system, fully declarative core, 100% functional.
