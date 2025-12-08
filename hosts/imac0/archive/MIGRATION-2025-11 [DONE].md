# imac-mba-home Migration to Nix [COMPLETED]

**Migration Period**: November 14-15, 2025  
**Status**: ✅ 100% COMPLETE - Production Ready  
**Last Updated**: November 23, 2025

---

## Executive Summary

Successfully migrated `imac-mba-home` from imperative Homebrew/manual configuration to declarative Nix/home-manager management in approximately 24 hours with zero data loss.

**Key Achievements:**

- ✅ 45+ packages migrated to Nix (shell, dev tools, CLI utilities)
- ✅ Homebrew reduced from 167 → 127 formulae (~700MB freed)
- ✅ All dotfiles declaratively managed via home-manager
- ✅ System 100% functional with improved reproducibility
- ✅ Template ready for future machines (imac-27-work)

**System:**

- **Machine**: iMac 27" 2019 (iMac19,1)
- **CPU**: Intel Core i9 8-core @ 3.6GHz
- **RAM**: 16 GB
- **Display**: Retina 5K (5120x2880)
- **OS**: macOS Sequoia 15.7.2
- **Architecture**: x86_64-darwin (Intel)

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
- Custom functions: brewall, cd, sudo, sourcefish, pingt
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

## Technical Details

### System Hardware

**Hardware Overview:**

- **Model Name:** iMac
- **Model Identifier:** iMac19,1
- **Processor Name:** 8-Core Intel Core i9
- **Processor Speed:** 3.6 GHz
- **Number of Processors:** 1
- **Total Number of Cores:** 8
- **L2 Cache (per Core):** 256 KB
- **L3 Cache:** 16 MB
- **Hyper-Threading Technology:** Enabled
- **Memory:** 16 GB
- **Architecture:** x86_64 (Intel)

**Graphics & Display:**

- **Graphics Card:** Radeon Pro Vega 48
- **VRAM:** 8 GB
- **Display:** Built-In Retina LCD
- **Resolution:** Retina 5K (5120 x 2880)
- **Color Depth:** 30-Bit Color (ARGB2101010)
- **Display Size:** 27-inch

**Storage:**

- **Drive Type:** Apple SSD SM1024L
- **Capacity:** ~796 GB (1 TB physical)
- **Protocol:** PCI-Express
- **File System:** APFS
- **Note:** Separate APFS volume for `/nix` store (disk1s7)

**Operating System:**

- **macOS Version:** 15.7.2 (Sequoia)
- **Build Version:** 24G325
- **Architecture:** x86_64-darwin

---

### Special Configurations Implemented

#### Karabiner-Elements (Keyboard Remapping)

**The Elegant Hybrid Approach**:

- Install Karabiner-Elements via **Homebrew** (GUI app + system driver)
- Manage configuration **declaratively via Nix** (home-manager)

**Why Homebrew?**

- Karabiner-Elements requires kernel extensions/system permissions
- Not available in nixpkgs (macOS-specific, complex installation)
- GUI app management is better suited for Homebrew cask

**Declarative Configuration**:

The configuration file is managed via Nix:

```nix
home.file.".config/karabiner/karabiner.json".source = ./config/karabiner.json;
```

**Benefits**:

✅ **Configuration version-controlled** - All key mappings in git  
✅ **Reproducible** - Same keyboard setup on all machines  
✅ **Declarative** - Edit home.nix, run switch, done  
✅ **Safe** - Can rollback to previous configurations  
✅ **Documented** - Your key mappings are self-documenting in Nix

---

#### macOS GUI Applications

**The Elegant Nix Solution:**

home-manager automatically manages macOS GUI applications through a declarative approach:

**How It Works:**

1. **Automatic App Linking**: When you enable a GUI program in `home.nix`, home-manager automatically:
   - Detects `.app` bundles in the Nix package
   - Creates symlinks in `~/Applications/Home Manager Apps/`
   - Makes them available to Spotlight, Launchpad, and Finder

2. **Declarative Configuration**: Simply enable the program in your `home.nix`:

```nix
programs.wezterm = {
  enable = true;
  # ... your config
};
```

3. **Automatic Updates**: When you `home-manager switch`:
   - Old symlinks are removed
   - New symlinks point to updated app versions
   - No manual intervention needed

**Making Nix Apps Easily Accessible:**

**Option 1: Use Spotlight (⌘+Space)** (Recommended)

- **Instant**: Type "WezTerm" in Spotlight
- **Works immediately**: Spotlight indexes `~/Applications/Home Manager Apps/`
- **Recommendation**: This is the macOS-native way

**Option 2: Symlink to Main Applications Folder**

For apps you want directly in `~/Applications/`, use activation scripts:

```nix
home.activation.linkMacOSApps = lib.hm.dag.entryAfter ["writeBoundary"] ''
  # Link important apps to main Applications folder
'';
```

**Advantages Over Homebrew Cask:**

✅ **Declarative**: Apps defined in `home.nix`, not imperative `brew install`  
✅ **Version-controlled**: App versions locked in `flake.lock`  
✅ **Reproducible**: Same apps on every machine from git  
✅ **Automatic updates**: `home-manager switch` updates everything  
✅ **Rollback**: `home-manager generations` lets you rollback apps  
✅ **No manual linking**: home-manager handles all symlinks automatically

---

#### macOS Network Tools Fix

**Issue Date**: 2025-11-16  
**Status**: Documented & Resolved

**Problem:**

The Nix `inetutils` package (which provides Linux network utilities like `ping`, `telnet`, etc.) has a critical bug when running on macOS:

**Symptoms:**

```bash
$ ping 192.168.1.223
PING 192.168.1.223 (192.168.1.223): 56 data bytes
56 bytes from 192.168.1.145: icmp_seq=0 ttl=64 time=-1084818903855532605440.000 ms
56 bytes from 192.168.1.89: icmp_seq=0 ttl=255 time=-1084818903855532605440.000 ms (DUP!)
```

**Root Cause:**

- **Linux ping on macOS**: The `inetutils` package provides the Linux version of `ping`
- **Timestamp calculation bug**: When running on Darwin (macOS), the timestamp arithmetic overflows
- **Integer overflow**: Results in astronomically large negative numbers (-10^21 ms)
- **Duplicate packets**: All responses are marked as duplicates due to the timestamp corruption

**Solution:**

**1. Package Configuration**

Removed `inetutils` from `home.nix`

**2. Shell Aliases**

Added explicit aliases to use macOS native network tools:

```nix
shellAliases = {
  # Force macOS native ping (inetutils ping has bugs on Darwin)
  ping = "/sbin/ping";

  # Other macOS network tools for reference
  traceroute = "/usr/sbin/traceroute";
  netstat = "/usr/sbin/netstat";
};
```

**3. Verification**

```bash
$ which ping
ping: aliased to /sbin/ping

$ ping -c 3 192.168.1.223
PING 192.168.1.223 (192.168.1.223): 56 data bytes
64 bytes from 192.168.1.223: icmp_seq=0 ttl=64 time=0.649 ms
64 bytes from 192.168.1.223: icmp_seq=1 ttl=64 time=0.617 ms
64 bytes from 192.168.1.223: icmp_seq=2 ttl=64 time=0.587 ms
```

**macOS Native Network Tools:**

macOS includes high-quality BSD network utilities that should be preferred:

| Tool         | Path                   | Purpose                         |
| ------------ | ---------------------- | ------------------------------- |
| `ping`       | `/sbin/ping`           | ICMP echo requests              |
| `traceroute` | `/usr/sbin/traceroute` | Network path tracing            |
| `netstat`    | `/usr/sbin/netstat`    | Network statistics              |
| `ifconfig`   | `/sbin/ifconfig`       | Network interface configuration |
| `arp`        | `/usr/sbin/arp`        | ARP table management            |
| `route`      | `/sbin/route`          | Routing table management        |

**Lesson Learned:**

**When on macOS, prefer native tools for low-level system utilities:**

- ✅ Use macOS native: `ping`, `traceroute`, `netstat`, `ifconfig`
- ✅ Use Nix for: Modern CLI tools (`bat`, `ripgrep`, `fd`, etc.)
- ⚠️ Avoid: Linux-specific system utilities on Darwin

---

### Homebrew Cleanup Analysis

**Before Cleanup**: 167 formulae, 10 casks  
**After Cleanup**: 127 formulae, 10 casks  
**Total Removed**: 42 packages (~700MB)  
**Net Space Savings**: ~460MB after accounting for Nix additions

**Migration Strategy:**

1. **Migrated to Nix (25 packages)**: CLI development tools, file utilities, networking tools
2. **Removed as Unused (17 packages)**: Old experiments, redundant tools
3. **Auto-Removed (8 packages)**: Dependencies no longer needed
4. **Kept in Homebrew (137 packages)**: GUI apps, complex multimedia, system integration

**Rationale for Keeping in Homebrew:**

- **GUI Applications**: Better macOS integration (Cursor, Zed, Hammerspoon, Karabiner)
- **Complex Multimedia**: Avoid Nix dependency hell (ffmpeg, imagemagick)
- **System Integration**: Native system tools (mosquitto, ext4fuse)
- **Auto-Dependencies**: Will be cleaned up if parent packages removed

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

## File Structure

```
hosts/imac-mba-home/
├── config/
│   ├── starship.toml
│   └── karabiner.json
├── docs/
│   ├── README.md                  # Documentation index
│   ├── archive/
│   │   └── MIGRATION-2025-11 [DONE].md  # This file
│   ├── manual-setup/
│   │   ├── karabiner-setup.md       # Manual Karabiner app install
│   │   └── terminal-app-fonts.md    # Terminal.app font setup
│   └── reference/
│       └── (no longer needed - info consolidated here)
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

**If anything goes wrong**, the backup is available at `~/migration-backup-20251114-165637/`

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

- Stage 2+ Homebrew cleanup (evaluate remaining 127 formulae)
- Template preparation for `imac-27-work`
- Documentation refinement

### Future Machines

1. Clone repo: `git clone <repo-url> ~/Code/nixcfg`
2. Apply config: `home-manager switch --flake .#markus@imac-mba-home`
3. Run setup: `./hosts/imac-mba-home/scripts/setup/setup-macos.sh`
4. Install Karabiner: `brew install --cask karabiner-elements`
5. Done! (~1 hour vs 1 day manual setup)

---

## Reference: Secrets Management Architecture

**Status**: Documented but NOT YET IMPLEMENTED  
**Purpose**: Design document for future work, not part of this migration

### Overview

Automated, multi-machine secrets management using `rage` (age encryption) with SSH key-based encryption and directory watching for zero-friction workflow.

### Architecture Decisions

**Repository Structure:**

- `~/Secrets/personal/` - Personal secrets (all machines)
- `~/Secrets/work/` - Work secrets (work machines only)

**Key Management Strategy:** SSH keys (no dedicated age keys)

- Encryption: `rage -R ~/.ssh/id_rsa.pub -o file.age file.txt`
- Decryption: `rage -d -i ~/.ssh/id_rsa file.age > file.txt`

**Automation Level:** Auto-stage (not auto-commit)

- Watchman detects file changes in `decrypted/`
- Auto-encrypts to `encrypted/` within 1-2 seconds
- Auto-stages encrypted files in git
- User writes commit message and commits manually

**Rationale:** Balance automation with control. No noisy commit history, can batch changes, meaningful commit messages.

### Core Features

1. **Automated Encryption**: Watchman monitors `decrypted/` and auto-encrypts on save
2. **Multi-Machine Sync**: Pull latest + decrypt with single command
3. **Safety Mechanisms**: Pre-commit hook, integrity verification, auto-backup
4. **Selective Decryption**: Can decrypt everything or single files

### Implementation Phases

1. **Canonical Scripts** - Create in `nixcfg/.shared/secrets-scripts/`
2. **Personal Repo** - Setup `~/Secrets/personal/` with GitHub repo
3. **Work Repo** - Setup `~/Secrets/work/` (optional, later)
4. **Migration** - Find and migrate existing secrets
5. **Deploy** - Setup on servers and work machines

**Note**: This is a planned feature for future implementation, not a completed migration task.

---

## Files Archived

This document consolidates the following files from the original migration:

- `progress.md` (613 lines) - Main migration history and journey
- `hardware-info.md` (63 lines) - System specs
- `karabiner-elements.md` (132 lines) - Karabiner technical details
- `macos-gui-apps.md` (163 lines) - GUI app management patterns
- `macos-network-tools.md` (153 lines) - Ping bug investigation
- `secrets-management.md` (250 lines) - Architecture for secrets (approved but not implemented)
- `todo-homebrew-cleanup.md` (460 lines) - Detailed homebrew cleanup tracking

All information preserved, just organized into one comprehensive document for easier reference and consistency with other host archives (hsb8, hsb0).

---

**Migration Status**: ✅ **COMPLETE** - Production-ready system, fully declarative core, 100% functional.

**Last Updated**: November 23, 2025  
**Maintainer**: Markus Barta  
**Repository**: https://github.com/markus-barta/nixcfg
