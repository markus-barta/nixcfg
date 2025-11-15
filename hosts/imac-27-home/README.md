# imac-27-home - macOS Development Machine

Personal macOS development machine with Nix package management.

## Migration Status

**Phase 0: Pre-Migration** ✅ **COMPLETE** (2025-11-14)

- ✅ Phase 0.1: Planning & Documentation complete
- ✅ Phase 0.2: Backup execution complete
  - Backup location: `~/migration-backup-20251114-165637`
  - 56 files backed up (configs, scripts, system state)
  - All validations passed

**Phase 1: Setup Infrastructure** ✅ **COMPLETE** (2025-11-14)

- ✅ Created comprehensive `home.nix` with all configurations
- ✅ Added homeConfigurations to `flake.nix` for macOS
- ✅ Enhanced `devenv.nix` with macOS platform detection
- ✅ Installed and activated home-manager
- ✅ All configs symlinked from Nix store
- ✅ Nix versions installed (fish, starship, wezterm, git, direnv, node, python, zoxide)

**Phase 2: Core Environment** ✅ **COMPLETE** (2025-11-14)

- ✅ All 7 components tested and verified working
- ✅ Global interpreters (Node.js, Python), Essential CLI tools, direnv, Fish shell, Starship, WezTerm, Git
- ✅ Dual Git identity working correctly (personal/work)
- ✅ All configurations deployed from Nix store

**Phase 3: Scripts & Additional Tools** ✅ **COMPLETE** (2025-11-14)

- ✅ 3 essential scripts added to Nix management (flushdns, pingt, stopAmphetamineAndSleep)
- ✅ Hack Nerd Font installed and verified
- ✅ Additional CLI tools configured (cloc, prettier)

**Switch to Nix** ✅ **COMPLETE** (2025-11-14)

- ✅ Ran `setup-macos.sh` - Set Nix fish as default login shell
- ✅ Fixed PATH priority - Nix paths now take precedence over Homebrew
  - Added `loginShellInit` to Fish configuration
  - Added `initExtra` to Zsh configuration
- ✅ Verified switch: `$SHELL`, `which fish/node/python3` all point to Nix
- ✅ System now running entirely on Nix versions

**Homebrew Cleanup - Stage 1** ✅ **COMPLETE** (2025-11-15)

- ✅ Removed Stage 1 packages: fish, bat, btop, ripgrep, fd, zoxide, direnv, starship
- ✅ Added missing global packages to Nix: bat, btop, ripgrep, fd, fzf
- ✅ Migrated remaining dependencies: prettier, esptool, nmap
- ✅ Removed node, python@3.13 from Homebrew (using Nix versions)
- ✅ Cleaned Homebrew cache (freed disk space)

**Terminal.app Fonts** ✅ **COMPLETE** (2025-11-15)

- ✅ Configured `home.activation.installMacOSFonts` to symlink Nerd Fonts to ~/Library/Fonts/
- ✅ All 12 Hack Nerd Font variants now available in macOS Font Book
- ✅ Fonts work in both WezTerm (via fontconfig) and Terminal.app (via ~/Library/Fonts/)
- ✅ Font daemon restarted to refresh font cache

**Karabiner-Elements** ✅ **CONFIGURATION DECLARATIVE** (2025-11-15)

- ✅ Configuration fully managed via Nix (config/karabiner.json)
- ✅ Version-controlled in git
- ✅ Key mappings: Caps Lock → Hyper, F1-F12 in terminals
- ⚠️ **App installation**: Manual via Homebrew (see setup/karabiner-setup.md)
  ```bash
  brew install --cask karabiner-elements
  ```

**Current State**: **ACTIVELY USING NIX** ✅

All core tools running from Nix. Stage 1 Homebrew cleanup complete. System stable.

**Next**: Continue daily usage, proceed with Stage 2+ cleanup when ready (see `docs/testing-and-cleanup.md`)

See [docs/migration.md](docs/migration.md) for detailed migration plan.

## Current System Analysis

### System Information

- **OS**: macOS 15.7.2 (24G325)
- **Architecture**: x86_64 (Intel)
- **Shell**: Fish 4.1.2 (from Nix: ~/.nix-profile/bin/fish) ✅
- **Default Browser**: Helium (net.imput.helium)

### Package Managers

#### Nix (Package Manager)

- Status: Active
- Profile: `/Users/markus/.nix-profile`
- Installed via nix profile: 5 packages
- Installed via nix-env: 0 packages
- Primary package: devenv 1.10.1

#### Homebrew

- Status: Active
- Location: `/usr/local` (Intel)
- Formulae count: 203
- Casks count: 13

### Installed Packages

#### Homebrew Formulae (203 total)

**Sample of key packages:**

- age, bat, btop, cloc, defaultbrowser, fish, fzf, git
- hammerspoon (cask), mactex-no-gui (cask), wezterm (cask), zed (cask)
- Languages: node (25.2.0), python@3.10
- Build tools: autoconf, cmake, gcc, llvm
- Utilities: zoxide, zsh-syntax-highlighting, ripgrep, fd

**Full list saved to:** `/tmp/brew-formulae.txt`

#### Homebrew Casks (13 total)

- asset-catalog-tinkerer, cursor, font-hack-nerd-font
- hammerspoon, knockknock, mactex-no-gui
- osxfuse, qownnotes, rar, syntax-highlight
- temurin, wezterm, zed

**Full list saved to:** `/tmp/brew-casks.txt`

#### Nix Packages (5 total)

- devenv 1.10.1 (from cachix/devenv flake)
- No packages installed via nix-env

**Profile list saved to:** `/tmp/nix-profile.txt`

### Shell Environment

#### Fish Shell

- **Configuration location**: `~/.config/fish/`
- **Version**: 4.1.2 (from Homebrew)
- **Config file**: `~/.config/fish/config.fish`
- **Custom functions**: fish_prompt.fish, pingt.fish, sourceenv.fish, sourcefish.fish
- **Environment setup**:
  - Adds `/usr/local/sbin` to PATH
  - Adds `/usr/local/opt/node@18/bin` to PATH
  - zoxide integration with `z` command
  - Custom `cd` function using zoxide
  - Sudo with `!!` support

#### Terminal/Editor

- **WezTerm**: Version 20240203-110809-5046fc22
- **WezTerm config**: `~/.wezterm.lua`
- **Settings**:
  - Font: Hack Nerd Font Mono (fallback to Hack Nerd Font, Apple Color Emoji)
  - Font size: 12, Line height: 1.1
  - Color scheme: tokyonight_night
  - Custom centering script: `~/Scripts/wezterm_center.json` (BetterTouchTool preset)
- **Default browser**: Helium (net.imput.helium)
- **Other tools**: Cursor, Zed editors

#### Languages & Runtimes

- **Node.js**: v22.20.0 (Nix) ✅
- **Python**: v3.13.8 (Nix) ✅
- **Java**: Temurin (Homebrew cask)
- **Other languages**: LaTeX (MacTeX, Homebrew)

#### Development Tools

- **Git**: Available via Homebrew (version and config to be migrated to Nix)
- **Editors**: Cursor, Zed (both via Homebrew casks - staying in Homebrew)
- **Build tools**: autoconf, cmake, gcc, llvm (Homebrew - may migrate to Nix)
- **Utilities**: bat, btop, cloc, ripgrep, fd, fzf (Homebrew - migrating to devenv)
- **Shell tools**: zoxide (Homebrew - migrating to devenv), zsh-syntax-highlighting (Homebrew - not needed for fish)

### System Integration

#### macOS Preferences

- Default applications
- Keyboard shortcuts
- Dock configuration
- System preferences

#### Services & Daemons

- Background services
- Launch agents

## Migration Plan

### Phase 1: Analysis & Planning

- [ ] Complete system inventory
- [ ] Identify Homebrew vs Nix packages
- [ ] Determine migration priorities

### Phase 2: Core Environment

- [ ] **Fish shell** → Move from Homebrew to Nix (fish + config)
- [ ] **WezTerm** → Move from Homebrew cask to Nix (+ config migration)
- [ ] **Default browser** → Helium settings (may stay manual)
- [ ] **Essential CLI tools** → Move to devenv: bat, btop, ripgrep, fd, fzf, zoxide
- [ ] **Fonts** → Hack Nerd Font via Nix instead of Homebrew cask

### Phase 3: Development Tools

- [ ] Language runtimes → Nix/devenv
- [ ] Development tools → Nix/devenv
- [ ] Build tools → Nix/devenv

### Phase 4: System Integration

- [ ] macOS preferences → Declarative config (if possible)
- [ ] Launch agents → Nix
- [ ] Services migration

### Phase 5: Cleanup

- [ ] Remove redundant Homebrew packages
- [ ] Verify all functionality
- [ ] Document remaining manual configurations

## Declarative Configuration Goals

### Nix Environment (Primary)

- **Fish shell** with custom config, functions, and PATH setup
- **WezTerm** with lua configuration and color schemes
- **Development tools in devenv**: bat, btop, ripgrep, fd, fzf, zoxide, prettier, etc.
- **Languages**: Node.js, Python via Nix instead of Homebrew
- **Fonts**: Hack Nerd Font via Nix
- **System packages** via nix-darwin (future consideration)

### Homebrew (Minimal - Keep Only)

- **GUI Applications**: Hammerspoon, QOwnNotes, Cursor, Zed (not available in Nix or prefer native macOS versions)
- **macOS-specific tools**: defaultbrowser (for setting default browser)
- **Specialized software**: MacTeX, asset-catalog-tinkerer, syntax-highlight
- **System integration tools**: knockknock, BetterTouchTool integration

### Manual/Configuration Files

- **Dotfiles management**: Fish config, WezTerm lua config
- **macOS preferences**: Default browser (Helium), system settings
- **Scripts**: Custom scripts like wezterm_center.json

## Questions & Decisions

> **📝 See [docs/migration.md](docs/migration.md) for the complete migration plan and Q&A reference.**

### Package Migration Strategy

- **Move to Nix/devenv**: fish, wezterm, bat, btop, ripgrep, fd, fzf, zoxide, prettier, node, python
- **Keep in Homebrew**: GUI apps (cursor, zed, hammerspoon), MacTeX, specialized tools
- **Fonts**: Hack Nerd Font → Migrate to Nix (see [docs/migration.md](docs/migration.md))

### Configuration Management

- **Fish config**: Migrate to home-manager declaratively (see [docs/migration.md](docs/migration.md))
- **WezTerm config**: Migrate to home-manager with extraConfig (see [docs/migration.md](docs/migration.md))
- **Default browser**: Keep manual (Helium) - ignored per decision
- **macOS settings**: Defer system-level management (Karabiner/BetterTouchTool stay manual)

### Development Workflow

- **Devenv strategy**: Separate macOS profile (`devenv.macos.nix`) - see [docs/migration.md](docs/migration.md)
- **Shell integration**: PATH modifications managed in Nix/devenv (see [docs/migration.md](docs/migration.md))

## Commands Reference

### Analysis Commands

```bash
# Homebrew inventory
brew list --formula > brew-formulae.txt
brew list --cask > brew-casks.txt

# Nix inventory
nix profile list > nix-profile.txt
nix-env -q > nix-env-packages.txt

# System info
sw_vers
uname -a
```

### Migration Commands

```bash
# Test nix-darwin (future)
# nix run nix-darwin -- switch --flake .#imac-27-home

# Update devenv
devenv update
```

## Notes

- Current setup uses Nix primarily as package manager alongside Homebrew
- Goal is to move towards more declarative configuration
- Focus on development environment consistency
- Consider nix-darwin for future system management
