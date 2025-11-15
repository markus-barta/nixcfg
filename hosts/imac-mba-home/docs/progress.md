# Migration Progress & History - imac-mba-home

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

- ✅ Migrated 25 CLI tools to Nix (gh, jq, just, lazygit, tree, pv, tealdeer, fswatch, mc, zellij, netcat, telnet, websocat, lynx, html2text, restic, rage, rsync, wget, and core tools)
- ✅ Removed 42 total packages (21 migrated + 13 unused/old + 8 auto-dependencies)
- ✅ Freed ~700MB from Homebrew (~460MB net after Nix additions)
- ✅ **Final state: 127 formulae (down from 167), 10 casks**
- ✅ All remaining packages kept for valid reasons (GUI apps, system integration, complex multimedia with dependencies)

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

- ✅ All core tools migrated to Nix (~45 packages)
- ✅ Homebrew cleanup complete (127 formulae, 10 casks)
- ✅ Git dual identity verified and working
- ✅ System running 100% on Nix for daily workflows

**Optional Future Work**:

- Continue daily usage and testing
- Template preparation for `imac-27-work`
- Secrets management exploration (see `docs/todo-secrets-management.md`)

---

## Migration Journey

### Pre-Migration Safety ✅ (2025-11-14)

**Planning & Documentation** ✅

- Comprehensive migration plan created
- Architecture decisions documented
- Risk assessment completed
- Backup strategy defined

**Backup Execution** ✅

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

### Infrastructure Setup ✅ (2025-11-14)

**Created**:

- `hosts/imac-mba-home/home.nix` - Comprehensive user configuration
- Enhanced `flake.nix` with `homeConfigurations."markus@imac-mba-home"`
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

### Core Environment Testing ✅ (2025-11-14)

Tested each component step-by-step to verify Nix versions work correctly.

**Global Interpreters** ✅

- Node.js: Nix v22.20.0 (LTS) - All tests passed (execution, NPM, scripts)
- Python: Nix v3.13.8 - All tests passed (execution, stdlib, scripts)
- ⚠️ No pip (by design - use Nix for packages)

**Essential CLI Tools** ✅

- bat, btop, ripgrep, fd, fzf - All functional in devenv shell
- devenv's macOS platform detection working correctly

**direnv** ✅

- Installed via home-manager (v2.37.1)
- nix-direnv integration enabled
- Automatic Fish shell integration configured

**Fish Shell** ✅

- Fish v4.1.2 from Nix
- All configuration files symlinked
- Custom functions: brewall, cd, sudo, sourceenv, sourcefish, pingt
- Aliases: mc, lg
- Abbreviations: flushdns, qc0, qc1, qc24, qc99

**Starship** ✅

- Starship v1.23.0
- Custom gitcount module verified working
- Language indicators (nodejs, python, rust, golang) configured
- Docker and Kubernetes contexts enabled

**WezTerm** ✅

- WezTerm v0-unstable-2025-10-14 (newer than Homebrew)
- Config symlinked to `~/.config/wezterm/wezterm.lua`
- Hack Nerd Font installed and recognized
- All settings verified (font, colors, keybindings)

**Git Dual Identity** ✅

- Git v2.51.1
- Personal identity: Markus Barta / markus@barta.com (default)
- Work identity: mba / markus.barta@bytepoets.com (for ~/Code/BYTEPOETS/)
- Directory-based switching working correctly
- Global gitignore, credential helper, Sourcetree tools configured

---

### Scripts & Additional Tools ✅ (2025-11-14)

**Scripts Management** ✅

- Created `hosts/imac-mba-home/scripts/` directory
- Added 3 essential scripts to repo:
  - `flushdns.sh` - DNS cache flush utility
  - `pingt.sh` - Timestamped ping (pure bash, no perl)
  - `stopAmphetamineAndSleep.sh` - System sleep control
- All other scripts remain only in local `~/Scripts/` backup (not in git)
- Configured `home.file."Scripts"` to link scripts to `~/Scripts/`

**Hack Nerd Font** ✅

- Already installed in Infrastructure Setup
- Verified WezTerm uses font correctly in Core Environment Testing
- Later: Added symlinks to `~/Library/Fonts/` for Terminal.app

**Additional CLI Tools** ✅

- cloc, prettier already added in Infrastructure Setup
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

## Homebrew Cleanup ✅ (2025-11-15)

### Final State

**Before Cleanup**: 167 formulae, 10 casks  
**After Cleanup**: 127 formulae, 10 casks  
**Total Removed**: 42 packages (~700MB)

### What Was Migrated to Nix (25 packages)

**CLI Development Tools**:

- `gh`, `jq`, `just`, `lazygit`

**File Management & Utilities**:

- `tree`, `pv`, `tealdeer`, `fswatch`, `mc` (midnight-commander)

**Terminal Multiplexer**:

- `zellij` (removed `tmux`)

**Networking Tools**:

- `netcat`, `inetutils` (telnet), `websocat`, `lynx`, `html2text`

**Backup & Archive**:

- `restic`, `rage` (removed `age`)

**macOS Built-in Overrides**:

- `rsync`, `wget`

**Core Tools** (migrated earlier):

- `fish`, `node`, `python`, `bat`, `btop`, `ripgrep`, `fd`, `fzf`, `zoxide`, `direnv`, `starship`, `git`, `prettier`, `esptool`, `nmap`, `nano`

### What Was Removed as Unused (17 packages)

- `go-jira`, `magic-wormhole`, `wakeonlan`, `tuist`, `topgrade`
- `lua`, `luarocks`, `tmux`, `pipx`, `defbro`
- `evcc` (test only), `openjdk` (kept `temurin`), `age` (using `rage`)
- `qownnotes`, `mactex-no-gui` (GUI apps no longer needed)

### Auto-Removed Dependencies (8 packages)

- `ncurses`, `utf8proc`, `xxhash`, `diffutils`, `libssh2`, `oniguruma`, `popt`, `s-lang`

### What Remains in Homebrew (137 total)

**GUI Applications (10 casks)**:

- `cursor`, `zed`, `hammerspoon`, `karabiner-elements`, `temurin`, `asset-catalog-tinkerer`, `syntax-highlight`, `knockknock`, `osxfuse`, `rar`

**System Integration (4 formulae)**:

- `mosquitto` (MQTT), `ext4fuse` (Linux FS), `defaultbrowser`, `f3`

**Complex Multimedia (4 formulae)**:

- `ffmpeg`, `imagemagick`, `ghostscript`, `tesseract`

**Auto-Dependencies (~115 formulae)**:

- All `lib*` packages (codecs, image libraries, system libraries)

**Rationale**: GUI apps better in Homebrew for macOS integration; complex multimedia avoids Nix dependency hell; auto-dependencies will clean up if parent packages removed.

### Verification ✅

```bash
$ which gh jq tree mc zellij restic rage rsync wget
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
hosts/imac-mba-home/
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
2. Apply config: `home-manager switch --flake .#markus@imac-mba-home`
3. Run setup: `./hosts/imac-mba-home/scripts/setup/setup-macos.sh`
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
