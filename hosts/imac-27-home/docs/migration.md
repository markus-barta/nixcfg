# Migration Plan - imac-27-home

**Date**: 2025-11-14  
**Status**: ✅ Planning Complete - **Implementation NOT Started**  
**Approach**: Incremental, step-by-step migration  
**Review Process**: Show plan + explain changes, wait for approval, then execute  
**Reality Check**: This is a detailed plan, not completed work. All phases are documented strategies awaiting execution.

**Scope Decision**: This plan includes ~20 packages beyond strict "critical workflows" for **educational purposes** - learning Nix, home-manager, and devenv thoroughly. Comprehensive testing and staged cleanup are documented separately in `testing-and-cleanup.md` to keep this focused on the learning/setup phases.

**Why the extra scope beyond "critical workflows"?**

- **Minimal viable**: Just fish, starship, wezterm, git, node, python (~7 tools)
- **This plan**: +13 nice-to-have tools (bat, ripgrep, fd, fzf, etc.)
- **Reason**: Educational value - learning Nix ecosystem thoroughly, not just solving immediate problem
- **Timeline**: Realistic execution is 1-2 days (compressed) or 1-2 weeks (relaxed learning pace)

## Quick Status

✅ **Planning Complete** (Implementation Pending):

- All **strategic decisions** documented (what tools, what approach, what architecture)
- Configuration **strategies** defined (not yet translated to exact Nix code)
- Migration strategy finalized
- Backup and safety procedures defined
- Template for future imac-27-work machine
- **Note**: Plans are ready, execution has not begun

**Important**: "Planning complete" means architectural decisions are made, NOT that all Nix code is written. Phase 1 includes translating existing configs (starship.toml, wezterm.lua, fish functions) into Nix format - that's implementation work, not planning.

📋 **Migration Progress**:

- ✅ Phase 0: Pre-Migration (Planning & Backup complete - 2025-11-14)
- ✅ Phase 1: Setup Infrastructure (complete - 2025-11-14)
- ⏳ Phase 2: Core Environment (not started)
- ⏳ Phase 3: Scripts & Additional Tools (not started)
- ⏳ Phase 4: Documentation & Template (not started)

📝 **Post-Migration** (see `testing-and-cleanup.md`):

- Testing & Validation procedures
- Staged Homebrew package removal (5 stages)
- Final verification and cleanup

🎬 **Next Action**: Phase 2, Step 6 - Test WezTerm terminal configuration

🎯 **Critical Workflows to Preserve**:

- Terminal + shell functionality
- SSH shortcuts (qc99, qc24, qc0, qc1)
- Cursor/Zed project workflows
- Git dual identity (personal + BYTEPOETS work)

## Executive Summary

This document provides a comprehensive migration plan from Homebrew to Nix/devenv for the macOS development machine `imac-27-home`. The migration will be done incrementally, preserving all functionality while moving towards a **hybrid declarative/imperative configuration**: ~20 core tools and dotfiles managed declaratively in Nix, ~180 packages remaining in Homebrew for flexibility.

**Reality Check**: This is NOT "fully declarative" - it's selective migration of core workflow tools while keeping Homebrew for experimentation and GUI apps. Manual steps (like `setup/setup-macos.sh`) are still required.

**Reproducibility Breakdown**:

- ✅ **Fully automatic**: Dotfiles, packages, scripts, devenv → from `home-manager switch`
- ⚠️ **Semi-automatic**: home-manager install, flake activation → documented commands
- ❌ **Manual/Imperative**: System setup (`setup/setup-macos.sh` with sudo) → must run on each machine
- **Result**: ~90% reproducible from git, 10% documented manual steps

### Why

**Strategic Benefits**: Move from manual Homebrew management to declarative Nix configuration for better reproducibility, version control, and maintainability. This creates a template for future machines (like `imac-27-work`) and enables consistent development environments across all systems.

**Current State**: The existing Homebrew setup works perfectly - there are no problems to solve. This migration is proactive investment in infrastructure that will pay dividends for future machine setups and team collaboration.

**Migration Justification**

The existing Homebrew setup is fully functional. This migration is justified by:

**Success Criteria Beyond Functional Parity:**

1. **Educational Investment**: Deep understanding of Nix, home-manager, devenv, flakes
2. **Reproducibility**: Setup `imac-27-work` in 1 hour (not 1 day of manual config)
3. **Version Control**: Config changes tracked in git, can rollback to any commit
4. **Team Template**: Shareable, documented config other team members can adopt
5. **Future Efficiency**: Next machine setup dramatically faster (clone + switch)
6. **Infrastructure Understanding**: Know exactly how your dev environment works

**The Real Value**: Not solving current problems, but investing in future efficiency and knowledge.

**Key Advantages of This Hybrid Approach**:

- **Semi-reproducible**: ~90% automatic from git + documented manual steps (see below)
- **Version-controlled**: Core configurations tracked in git (dotfiles, packages, scripts)
- **Isolated**: Project-specific dependencies don't conflict
- **Mostly declarative**: Configs as code, with one-time scripted system setup
- **Future-proof**: Template for new machines reduces setup toil significantly

**Reality Check - NOT Fully Automatic**:

- ✅ Declarative: home-manager configs, devenv.nix, scripts → automatic from git
- ❌ Imperative: `setup/setup-macos.sh` must be run manually with sudo (modifies `/etc/shells`, runs `chsh`)
- **Trade-off**: Chose simplicity over full automation (avoided nix-darwin complexity)
- **Result**: Hybrid approach - declarative configs + scripted system setup

**Measurable Benefits**

Beyond preserving functionality, this migration delivers:

- ✅ **Reproducibility**: Can rebuild entire config from git on any machine
- ✅ **Version Control**: All config changes tracked, can rollback to any point
- ✅ **Declarative Core**: Edit `home.nix`, run switch - no manual file copying
- ✅ **Learning**: Deep understanding of Nix, home-manager, devenv, flakes
- ✅ **Template**: Foundation for `imac-27-work` and future machines

**Verification includes**: Nix path checks, declarative rebuild tests, git state validation - not just "does it work?" See `testing-and-cleanup.md` → "Success Criteria" for full list.

### How

**Incremental Migration**: 6-phase approach with extensive testing to minimize risk. Each phase builds on the previous, with Homebrew kept as fallback until Nix versions are proven working.

**Safety First**: Comprehensive backup strategy, staged Homebrew package removal, and multiple rollback scenarios minimize downtime risk. Login shell stays Homebrew fish until everything is verified working.

**Downtime Risk Assessment**

- **Risk Level**: Minimal, but not zero
- **Reality**: Testing can reveal issues; components may break temporarily during validation
- **Mitigation**: Homebrew packages kept as fallbacks during entire testing phase
- **Fallback**: If any Nix component fails, immediate rollback to working Homebrew version
- **Impact**: Brief interruptions possible, but system remains functional via fallbacks

**Technical Approach**:

- **home-manager**: User-level configuration management (safer than nix-darwin for macOS upgrades)
- **Platform Detection**: Single `devenv.nix` works on macOS/Linux automatically
- **Dual Strategy**: Global Node.js/Python baseline + project-specific overrides for maximum flexibility
- **Preserve Everything**: All current functionality maintained during transition

**Timeline**: Flexible - can be completed in 1-2 days (compressed) or 1-2 weeks (relaxed pace)

## Architecture Decision

### Configuration Structure

```text
hosts/imac-27-home/
├── README.md              # Main documentation
├── migration.md           # This document (migration plan)
├── home.nix              # Standalone home-manager configuration (Phase 1)
├── setup/                # Migration setup scripts
│   ├── backup-migration.sh   # Pre-migration backup script (Phase 0)
│   └── setup-macos.sh        # One-time system setup script (Phase 5)
└── scripts/              # User scripts → ~/Scripts/ (managed via home-manager)
    ├── pingt.sh          # Timestamped ping (pure bash, no perl)
    └── ... (30+ personal scripts)

Root level (shared):
├── devenv.nix            # Enhanced with macOS platform detection
└── flake.nix             # Enhanced with homeConfigurations for macOS
```

### Technology Stack

- **Package Management**: Nix (via devenv + home-manager)
- **Shell**: Fish (via home-manager)
- **Terminal**: WezTerm (via home-manager)
- **Prompt**: Starship (via home-manager)
- **System Management**: Standalone home-manager (NOT nix-darwin)

**Why NOT nix-darwin:**

- **macOS Upgrade Safety**: nix-darwin manages system-level files (`/etc/`, system services) that could conflict with major macOS updates (e.g., Sonoma → Sequoia)
- **Lower Risk**: home-manager failures only affect user-level configs, not the entire system
- **Simpler Rollback**: User-level only, no sudo required for daily operations
- **Sufficient for Use Case**: We don't need system-level management (multi-user, system services, macOS preferences)
- **Manual Steps Are Minimal**: Only two commands needed once per machine (`/etc/shells` + `chsh`), scripted in `setup/setup-macos.sh`
- **Future Flexibility**: Can add nix-darwin later if requirements change

## Current State Analysis

### Package Inventory

#### Homebrew Formulae (203 total)

**Migration Strategy**: Selective migration - only core daily-use tools (~20 packages)

**To Migrate to Nix** (~20 packages):

- **Priority 1 (Core Tools)**:
  - fish → Nix/home-manager
  - wezterm → Nix/home-manager
  - starship → Nix/home-manager
  - node → home-manager (global baseline) + devenv (project-specific)
  - python → home-manager (global baseline) + devenv (project-specific)
  - zoxide → devenv
  - bat, btop, ripgrep, fd, fzf → devenv

- **Priority 2 (Development)**:
  - git → home-manager (programs.git with dual identity support)
  - direnv → home-manager (programs.direnv with nix-direnv)
  - prettier → devenv (already added)
  - cloc → devenv

**Keep in Homebrew** (~180 packages):

- All remaining formulae stay in Homebrew
- No migration planned for experimentation/one-off tools
- If tools become daily-use, migrate individually later
- Rationale: Homebrew flexibility for experimentation, Nix for core workflow

**Homebrew Package Management**

- **Scope**: ~180 packages remain in Homebrew for flexibility and experimentation
- **Rationale**: This migration does NOT prevent Homebrew sprawl - that's intentional
- **Trade-off**: Focus is on learning Nix + making core workflow reproducible, not replacing everything
- **Not Version-Controlled**: Homebrew packages deliberately excluded from version control for flexibility
- **Approach**: Declarative core (Nix) + imperative experiments (Homebrew) = practical hybrid for learning

### Going Forward Rule: Nix vs Homebrew

**Use Nix for:**

- ✅ Development tools & CLI utilities (daily use)
- ✅ Project-specific dependencies (per-project devenv.nix)
- ✅ Experiments via `nix-shell -p <package>` (temporary, no installation)
- ✅ Tools that need version pinning or isolation

**Use Homebrew for:**

- ✅ GUI applications (Cursor, Zed, Hammerspoon, etc.)
- ✅ macOS system integrations (osxfuse, etc.)
- ✅ Tools that don't work well in Nix on macOS
- ✅ Quick one-off installations for testing

**Decision Process for New Tools:**

1. Is it a GUI app? → **Homebrew**
2. Is it for daily development work? → **Nix** (add to devenv.nix or home.nix)
3. Just trying it out? → **nix-shell -p** (temporary) or **Homebrew** (if persistent testing)
4. Project-specific? → **Project's devenv.nix** (isolated environment)

**Key Principle**: Declarative for what matters, flexible for exploration.

### Node.js and Python Strategy

**Both Global + Project-Specific** (Option C - Best of both worlds)

**Why both layers?**

1. **Global baseline (home-manager)**: Always available
   - ✅ IDEs (Cursor/Zed) can find interpreters
   - ✅ Scripts with `#!/usr/bin/env node` or `python3` work everywhere
   - ✅ Day-to-day terminal usage (no need to enter devenv shell)
   - ✅ System-wide tools (npm, pip) accessible
   - ✅ Quick prototyping and one-off scripts

2. **Project-specific (devenv.nix)**: Overrides global when needed
   - ✅ Per-project version requirements (e.g., Node 18 for legacy project)
   - ✅ Isolated environments (dependencies don't conflict)
   - ✅ Reproducible builds (exact versions locked in devenv.lock)
   - ✅ Team collaboration (everyone gets same environment)

**How it works:**

```nix
# home.nix - Global baseline (latest stable)
home.packages = with pkgs; [
  nodejs    # Latest Node.js from nixpkgs
  python3   # Latest Python 3 from nixpkgs
];

# project/devenv.nix - Project-specific override
languages = {
  javascript.package = pkgs.nodejs_18;  # Override to Node 18
  python.package = pkgs.python311;      # Override to Python 3.11
};
```

**Precedence:** Project devenv > Global home-manager > Homebrew (removed)

**Example workflows:**

- **In terminal (no project)**: `node --version` → Uses global (home-manager)
- **In devenv shell**: `node --version` → Uses project-specific (devenv.nix)
- **Cursor opens project with devenv.nix**: Uses project-specific interpreter
- **Quick script in ~/Scripts/**: Uses global (home-manager)

**Why NOT just devenv?**

- ❌ IDEs can't find interpreters outside devenv shell
- ❌ Scripts fail when run outside project directories
- ❌ Requires manual `devenv shell` for every terminal session
- ❌ Breaks workflows like "open file in Cursor from Finder"

**Why NOT just global?**

- ❌ Can't handle per-project version requirements
- ❌ Legacy projects that need older Node/Python break
- ❌ No isolation for project dependencies

**Result:** Better control and flexibility, **but with tradeoffs**.

**The Honest Tradeoffs:**

- ✅ **Gain**: Per-project version control, global availability for IDEs/scripts
- ❌ **Cost**: Mental overhead (which version am I using?), PATH precedence complexity, need to understand when you're in devenv shell
- ⚠️ **Reality**: This trades Homebrew's simplicity for Nix's explicit complexity - not "zero compromise," but **intentional complexity for better control**

#### Homebrew Casks (13) - To Keep/Remove

**Keep in Homebrew**:

- cursor, zed, hammerspoon (GUI apps)
- font-hack-nerd-font → Migrate to Nix
- temurin (Java runtime)
- asset-catalog-tinkerer, syntax-highlight, knockknock (specialized tools)
- osxfuse (system integration)

**Remove**:

- qownnotes (as requested)
- mactex-no-gui (as requested)
- wezterm → Migrate to Nix

### Configuration Files to Migrate

#### Fish Configuration

**Current**: `~/.config/fish/config.fish`
**Content**:

- PATH modifications (`/usr/local/sbin`, `/usr/local/opt/node@18/bin` - REMOVE)
- zoxide initialization
- Custom `cd` function
- Custom `sudo` function with `!!` support
- Custom `fish_greeting` function
- `brewall` function
- Aliases: `mc`, `lg`
- Abbreviations: `flushdns`, `qc99`, `qc24`, `qc0`, `qc1`
- Environment variables: `TERM`, `PATH` additions
- Starship and direnv hooks

**Custom Functions**:

- `fish_prompt.fish` → **RENAME** to `fish_prompt.fish.disabled` (conflicts with starship, keep as backup)
- `pingt.fish` → Keep as-is (fish wrapper that calls `~/Scripts/pingt.sh`)
- `sourceenv.fish` → Migrate as-is
- `sourcefish.fish` → Migrate as-is

**Note**: `pingt.fish` and `pingt.sh` work together - the fish function just wraps/calls the bash script.

**Special Handling**:

- pipx PATH (line 54-55) → Remove (no important pipx tools identified)
- ~/Scripts/ → Version-control via home-manager with documentation on adding new scripts
- wezterm_center.json → Remove (doesn't work, can be deleted)

**Migration Target**: `home.nix` → `programs.fish`

#### Starship Configuration

**Current**: `~/.config/starship.toml`
**Key Features**:

- Custom format with username, hostname, directory, git info
- Custom gitcount module (git rev-list --count HEAD)
- Language indicators (python, nodejs, rust, golang)
- Docker and Kubernetes contexts
- Time on right prompt

**Migration Target**: `home.nix` → `programs.starship.settings` + `programs.starship.custom.gitcount`

#### WezTerm Configuration

**Current**: `~/.wezterm.lua`
**Key Features**:

- Font: Hack Nerd Font Mono
- Color scheme: tokyonight_night
- Window settings (opacity, blur, padding)
- Key bindings (CMD+C/V, font size, fullscreen)
- Mouse bindings (CMD+scroll for font size)
- Initial window size: 160x48

**Migration Target**: `home.nix` → `programs.wezterm.extraConfig`

#### Git Configuration

**Current**: `~/.gitconfig` + `~/.gitignore_global`
**Key Features**:

- Dual identity support (personal + work)
- Personal: Markus Barta <markus@barta.com> (default)
- Work: mba <markus.barta@bytepoets.com> (automatic for ~/Code/BYTEPOETS/)
- Global gitignore: `*~`, `.DS_Store`
- OSX Keychain credential helper

**Work Projects Directory**: `~/Code/BYTEPOETS/`

- google-sheets-bp-scripts
- report-view-web
- Future BYTEPOETS projects will automatically use work identity

**Migration Strategy**:

- Use `programs.git.includes` with `gitdir:~/Code/BYTEPOETS/` condition
- Automatic identity switching based on project location
- No manual per-repo configuration needed

**Migration Target**: `home.nix` → `programs.git` with includeIf support

#### Scripts Directory

**Current**: `~/Scripts/` (30+ custom scripts)
**Key Scripts**:

- `pingt.sh` → ✅ Already rewritten (pure bash, no perl), timestamped ping with dark gray formatting
  - Located: `hosts/imac-27-home/scripts/pingt.sh`
  - Paired with: `~/.config/fish/functions/pingt.fish` (wrapper function that calls the script)
- Various automation scripts (backup-all-raspis.sh, analyze_normalized_mp3.sh, etc.)

**Migration Strategy**:

**How pingt Works** (example of script + wrapper pattern):

1. **Implementation**: `hosts/imac-27-home/scripts/pingt.sh` (bash script)
   - ✅ Already rewritten: Pure bash, no perl dependency
   - Adds dark gray timestamps to ping output
   - Symlinked to `~/Scripts/pingt.sh` by home-manager
2. **Wrapper**: `~/.config/fish/functions/pingt.fish` (fish function)
   - Migrated via `home.nix` → `programs.fish`
   - Just calls `/Users/markus/Scripts/pingt.sh $argv`
   - Provides convenient `pingt` command in fish shell
3. **Together**: Type `pingt` in fish → fish function → bash script → timestamped output

**Repository Structure**:

```text
hosts/imac-27-home/
├── scripts/              # Machine-specific scripts → symlink to ~/Scripts/
│   ├── pingt.sh         # ✅ Already done: Pure bash, no perl, dark gray timestamps
│   └── ... (other personal scripts)
└── home.nix             # Includes fish functions (pingt.fish wrapper)

# Future: shared scripts (if needed)
scripts/                  # Shared across all machines
└── common/
    └── ... (shared utilities)
```

**Implementation in home.nix**:

```nix
home.file = {
  # Link entire scripts directory
  "Scripts" = {
    source = ./scripts;
    recursive = true;
  };
};

# Alternative: Individual script management with explicit permissions
home.file = {
  "Scripts/pingt.sh" = {
    source = ./scripts/pingt.sh;
    executable = true;  # Preserves executable bit
  };
  "Scripts/backup-all-raspis.sh" = {
    source = ./scripts/backup-all-raspis.sh;
    executable = true;
  };
  # ... more scripts
};
```

**Permissions Handling**:

- Git stores executable bit for shell scripts
- home-manager preserves permissions when linking
- Can explicitly set `executable = true` in home.nix if needed

**Adding New Scripts Workflow**:

1. Create script in `hosts/imac-27-home/scripts/new-script.sh`
2. Make executable: `chmod +x hosts/imac-27-home/scripts/new-script.sh`
3. Git add: `git add hosts/imac-27-home/scripts/new-script.sh`
4. No home.nix changes needed (if using recursive approach)
5. Apply: `home-manager switch --flake .#markus@imac-27-home`
6. Script appears in `~/Scripts/new-script.sh`

**Machine-Specific vs Shared**:

- **imac-27-home specific**: `hosts/imac-27-home/scripts/`
- **imac-27-work specific**: `hosts/imac-27-work/scripts/` (future)
- **Shared**: `scripts/common/` (if needed later)

**Migration Process**:

1. Create `hosts/imac-27-home/scripts/` directory
2. Copy all scripts from `~/Scripts/` to repo
3. Review each script for sensitive data (passwords, tokens)
4. Add to git with executable permissions preserved
5. Configure home.nix to link them
6. Test that all scripts work from new location

**Special Considerations**:

- This becomes template for imac-27-work
- Easy to share common scripts between machines
- Version history for all automation
- Can .gitignore sensitive scripts if needed

## Migration Plan

### Phase 0: Pre-Migration Safety

#### Phase 0.1: Planning & Documentation ✅

Status: **COMPLETE**

#### Phase 0.2: Backup Execution ✅

Status: **COMPLETE** (2025-11-14)

#### Backup Scope & Destination

**Destination**: `~/migration-backup-YYYYMMDD-HHMMSS/`

- Creates timestamped directory for this specific migration
- Will NOT be in git (add to .gitignore if needed)
- Keep until cleanup complete (days to weeks, based on your pace)

**Files to Backup**:

1. Fish configuration:
   - `~/.config/fish/config.fish` (58 lines)
   - `~/.config/fish/functions/` (all 4 functions)
2. Terminal configuration:
   - `~/.config/starship.toml` (107 lines)
   - `~/.wezterm.lua` (93 lines)
3. Git configuration:
   - `~/.gitconfig` (407 bytes)
   - `~/.gitignore_global` (2 lines)
4. Scripts directory:
   - `~/Scripts/` (all 30+ scripts)
5. System state:
   - Homebrew formulae list → `brew-formulae.txt`
   - Homebrew casks list → `brew-casks.txt`
   - Current PATH → `current-path.txt`
   - Current shell → `current-shell.txt`

**Verification**:

- File count check after backup
- SHA256 checksums of all backed up files → `checksums.txt`
- Verify Time Machine last backup is recent (< 24 hours)

#### Backup Script

**Location**: `hosts/imac-27-home/setup/backup-migration.sh` (version-controlled)

The automated backup script handles:

- All configuration files (fish, starship, wezterm, git)
- `~/Scripts/` directory (30+ scripts)
- System state (Homebrew lists, PATH, shell, tool versions)
- SHA256 checksums for verification
- Auto-generates `RESTORE.md` with recovery instructions
- Checks Time Machine last backup date

**Run the backup:**

```bash
cd ~/Code/nixcfg/hosts/imac-27-home
./setup/backup-migration.sh
```

**Output**: `~/migration-backup-YYYYMMDD-HHMMSS/` with complete backup and restore instructions

#### Backup Execution Checklist

- [x] Backup script created: `hosts/imac-27-home/setup/backup-migration.sh`
- [x] Run backup script from repo directory
- [x] Verify backup completed without errors
- [x] Check file counts match expectations (56 files - exceeds expected ~40-50)
- [x] Verify CHECKSUMS.txt and RESTORE.md created
- [x] Review Time Machine status output (permission issue - not critical)
- [x] Save backup directory path for reference: `~/migration-backup-20251114-165637`

#### Critical: Backup Validation (Don't Skip!)

**Why**: Backups can fail silently. Test BEFORE migrating, not after disaster strikes.

**Validation Steps:**

```bash
BACKUP_DIR=~/migration-backup-YYYYMMDD-HHMMSS  # Your actual backup

# 1. Test restore ONE file (non-destructive)
echo "Testing file restore..."
cp "$BACKUP_DIR/fish/config.fish" /tmp/test-restore.fish
diff ~/.config/fish/config.fish /tmp/test-restore.fish
# Should output nothing (files identical)

# 2. Verify checksums (integrity check)
echo "Verifying checksums..."
cd "$BACKUP_DIR"
shasum -c CHECKSUMS.txt | head -10
# Should all say "OK"

# 3. Count files (completeness check)
echo "Checking file counts..."
echo "Backed up files: $(find . -type f | wc -l)"
echo "Original ~/.config/fish files: $(find ~/.config/fish -type f | wc -l)"
echo "Original ~/Scripts files: $(find ~/Scripts -type f 2>/dev/null | wc -l || echo 0)"

# 4. Verify Time Machine
echo "Checking Time Machine..."
tmutil latestbackup
# Should show a date within last 24 hours

# 5. Test backup is readable
ls -lh "$BACKUP_DIR" > /dev/null && echo "✅ Backup directory accessible"

# 6. Check disk space for future backups
df -h "$BACKUP_DIR"
```

**Validation Checklist:**

- [x] Test restore: File diff shows no differences
- [x] Checksums: All files verify OK
- [x] File counts: Match expectations (56 files - exceeds ~40-50)
- [x] RESTORE.md exists and is readable
- [ ] Time Machine: Last backup < 24 hours (permission issue - skipped)
- [x] Backup directory accessible
- [x] Disk space sufficient (96GB free)

**If ANY validation fails:** Fix it before proceeding. A failed backup is worse than no backup.

**What can go wrong:**

- Backup script had a bug (checksums would fail)
- Permissions not preserved (test restore would fail)
- Time Machine broken (can't rollback system changes)
- Backup drive full (incomplete backup)
- Files corrupted (checksums would fail)

**Point of No Return Warning:**
After Phase 3, you still have Homebrew packages as fallback. After starting Homebrew removal in `testing-and-cleanup.md`, you're committed. Make sure backups work NOW.

#### Pre-Migration File Changes ✅

**Status**: **COMPLETE** (2025-11-14)

- [x] Rename fish_prompt.fish to fish_prompt.fish.disabled
  - Location: `~/.config/fish/functions/fish_prompt.fish`
  - Command: `mv ~/.config/fish/functions/fish_prompt.fish ~/.config/fish/functions/fish_prompt.fish.disabled`
  - Reason: Prevents conflict with starship prompt
  - Result: File renamed successfully before Phase 1 execution

### Phase 1: Setup Infrastructure ✅

Status: **COMPLETE** (2025-11-14)

**Planning** ✅:

- [x] Create host directory structure
- [x] Document current state
- [x] Gather all decisions and answer all questions

**Implementation** ✅:

- [x] Add homeConfigurations to flake.nix for macOS
- [x] Create `home.nix` with comprehensive configuration
  - Fish shell: All functions, aliases, abbreviations
  - Starship: Complete prompt config with custom gitcount module
  - WezTerm: Full terminal configuration
  - Git: Dual identity support (personal + BYTEPOETS)
  - direnv: Nix-direnv integration
  - Global packages: Node.js, Python, zoxide, Hack Nerd Font
  - Scripts management via home.file
- [x] Enhance `devenv.nix` with macOS platform detection
- [x] Install home-manager via flake
- [x] Test initial home-manager activation

**Results**:

- home-manager successfully installed and activated
- All configurations symlinked from Nix store
- Nix versions of all tools installed (in `~/.nix-profile/bin/`)
- Homebrew versions still in use (PATH not yet updated)
- Old configs backed up with `.backup` extension

**Commits**:

- `2198405`: Phase 1 infrastructure setup
- `906a406`, `68f9229`, `59d2bb1`, `eca8290`: Fixes for home-manager compatibility

### Phase 2: Core Environment (Priority 1) ⏳

Status: **IN PROGRESS** (Started 2025-11-14)

**Order of Implementation**:

1. **Global interpreters** → `home.nix` ✅ **TESTED** (2025-11-14)
   - Node.js: Nix v22.20.0 (LTS) vs Homebrew v25.2.0
     - ✅ Basic execution, NPM functional, code execution, scripts work
   - Python3: Nix v3.13.8 vs pyenv v3.10.3
     - ✅ Basic execution, stdlib modules, code execution, scripts work
     - ⚠️ No pip (by design - use Nix for packages)
   - Test result: **PASS** - Both interpreters fully functional
   - Currently: Homebrew/pyenv still active (PATH priority)
   - Rationale: See "Node.js and Python Strategy" section above

2. **Essential CLI tools** → `devenv.nix` (macOS detection) ✅ **TESTED** (2025-11-14)
   - bat v0.25.0, btop v1.4.5, ripgrep v14.1.1, fd v10.3.0, fzf v0.65.2
     - ✅ All tools functional in devenv shell
   - zoxide: Still from Homebrew (will be replaced by Nix home.packages)
   - Node.js v22.19.0 + Python v3.13.7 available in devenv (project override)
   - Test result: **PASS** - All CLI tools working from Nix
   - Test in devenv shell

3. **direnv** → `home.nix` ✅ **TESTED** (2025-11-14)
   - ✅ Installed via home-manager (v2.37.1)
   - ✅ nix-direnv integration enabled
   - ✅ Automatic Fish shell integration configured
   - ⚠️ Full testing requires interactive Fish shell
   - Test result: **PARTIAL PASS** - Configuration correct, works when active

4. **Fish shell** → `home.nix` ✅ **TESTED** (2025-11-14)
   - ✅ Installed via home-manager (Fish v4.1.2 from Nix)
   - ✅ All configuration files symlinked to Nix store
   - ✅ config.fish managed by home-manager
   - ✅ All custom functions symlinked: brewall, cd, sudo, sourceenv, sourcefish, pingt
   - ✅ Aliases configured (mc, lg)
   - ✅ Abbreviations configured (flushdns, qc0, qc1, qc24, qc99)
   - ✅ Environment variables set (TERM, ZOXIDE_CMD)
   - ✅ zoxide integration configured
   - ✅ Custom fish_greeting function
   - ⚠️ Interactive features require Fish shell session to fully test
   - Test result: **PASS** - Configuration complete and deployed correctly

5. **Starship** → `home.nix` ✅ **TESTED** (2025-11-14)
   - ✅ Installed via home-manager (Starship v1.23.0)
   - ✅ Config file symlinked to Nix store (~/.config/starship.toml)
   - ✅ Custom format with username, hostname, directory, git info
   - ✅ Custom gitcount module (git rev-list --count HEAD) - verified working
   - ✅ Language indicators configured (nodejs, python, rust, golang)
   - ✅ Docker and Kubernetes contexts enabled
   - ✅ Time on right prompt configured
   - ✅ Character symbols (success/error) configured
   - ✅ Git status symbols configured
   - ⚠️ Full prompt testing requires interactive Fish shell
   - Test result: **PASS** - Configuration complete and deployed correctly
   - Test prompt displays correctly (fish_prompt.fish already disabled)

6. **WezTerm** → `home.nix`
   - Install wezterm via home-manager
   - Migrate wezterm.lua to extraConfig
   - Test terminal opens with correct settings
   - Verify fonts load correctly

7. **Git** → `home.nix`
   - Enable programs.git
   - Configure dual identity (personal default, work for ~/Code/BYTEPOETS/)
   - Migrate gitignore patterns
   - Test git operations and identity switching

### Phase 3: Scripts & Additional Tools ⏳

Status: **NOT STARTED**

1. **Scripts Management** → `home.nix`
   - Create `hosts/imac-27-home/scripts/` directory
   - Copy all scripts from `~/Scripts/` to repo (30+ files)
   - Review scripts for sensitive data (credentials, tokens)
   - Preserve executable permissions in git
   - Configure home.nix with `home.file."Scripts"` linking
   - Test: Verify all scripts accessible and executable from `~/Scripts/`
   - Document workflow in README.md:
     - How to add new scripts
     - How to handle machine-specific vs shared
     - Permission management

   **Actual home.nix addition**:

   ```nix
   home.file."Scripts" = {
     source = ./scripts;
     recursive = true;  # Links entire directory
   };
   ```

2. **Hack Nerd Font** → `home.nix`
   - Install via home-manager fonts
   - Remove Homebrew cask: font-hack-nerd-font
   - Verify WezTerm uses font correctly

3. **Additional CLI tools** → `devenv.nix`
   - cloc, prettier (already added)
   - Other development utilities as needed

### Post-Migration: Testing & Cleanup

**After completing Phase 3**, you have a working Nix-based system!

**Next steps** are documented in `testing-and-cleanup.md`:

- Testing & validation procedures (hours to weeks - your choice)
- Staged Homebrew package removal (5 stages)
- Final verification and cleanup

**Note**: These are **optional** and can be done at your own pace. The core migration is complete after Phase 3. Testing and cleanup are just for confidence and final polish.

---

### Phase 4: Documentation & Template ⏳

Status: **NOT STARTED**

**Formerly Phase 6** - Moved up since testing/cleanup are now separate

1. **Update README.md** with:

   **a) Complete setup instructions** (hybrid: ~90% automatic + manual steps):

   ```bash
   # 1. Clone repo (automatic)
   git clone <repo-url> ~/Code/nixcfg
   cd ~/Code/nixcfg

   # 2. Install home-manager and activate (semi-automatic)
   home-manager switch --flake .#markus@imac-27-home
   # Declarative configs applied: fish, starship, wezterm, git, scripts

   # 3. One-time system setup (MANUAL - requires sudo)
   ./hosts/imac-27-home/setup/setup-macos.sh
   # Imperative: Adds fish to /etc/shells, runs chsh
   # This step is NOT automatic - must be run manually on each new machine

   # 4. Activate devenv (automatic platform detection)
   devenv shell
   ```

   **Reality**: Steps 1, 2, 4 are (mostly) automatic. Step 3 requires manual execution with sudo.
   **Why**: macOS system files (`/etc/shells`) can't be managed declaratively without nix-darwin.
   **Trade-off**: We chose simplicity over full automation.

   **b) Scripts management workflow**:
   - **Adding new scripts**:

**Commands**:

```bash
brew uninstall zoxide && which zoxide && z --version
brew uninstall direnv && which direnv && direnv version
```

**Critical Test Before Removing Node/Python**:

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

# If all OK, then remove Homebrew versions
brew uninstall node python@3.10
```

---

**Stage 5.3: Terminal & Shell**
**⚠️ HIGH RISK** - These are critical for daily use

- [ ] starship - Verify: Prompt displays correctly, all modules work

  ```bash
  brew uninstall starship
  exec fish  # Reload shell
  # Check: Prompt shows correctly, git info works, custom gitcount works
  ```

- [ ] wezterm - Verify: Terminal opens, fonts render, colors correct

  ```bash
  brew uninstall --cask wezterm
  # Open new WezTerm window from Applications or Spotlight
  # Check: Hack Nerd Font loads, tokyonight theme applies, keybindings work
  ```

- [ ] font-hack-nerd-font - Verify: Font still works in WezTerm
  ```bash
  brew uninstall --cask font-hack-nerd-font
  # Restart WezTerm
  # Check: Font renders correctly, no fallback to different font
  ```

**If WezTerm or fonts break**:

```bash
brew install --cask wezterm font-hack-nerd-font
```

---

**Stage 5.4: Git (After Everything Else Works)**
**⚠️ HIGH RISK** - Git is used everywhere

- [ ] git - Verify dual identity and all operations

  ```bash
  # First, test Nix git extensively
  which git  # Should be from Nix/home-manager
  git --version

  # Test personal repo
  cd ~/Code/nixcfg
  git config user.email  # Should be markus@barta.com
  git status

  # Test work repo
  cd ~/Code/BYTEPOETS/google-sheets-bp-scripts
  git config user.email  # Should be markus.barta@bytepoets.com
  git status

  # If all tests pass, remove Homebrew git
  brew uninstall git
  ```

---

**Stage 5.5: Unwanted Packages** (Safe to remove anytime)

- [ ] qownnotes - `brew uninstall --cask qownnotes`
- [ ] mactex-no-gui - `brew uninstall --cask mactex-no-gui`

---

#### Per-Package Verification Checklist

**Before removing ANY package**:

1. [ ] Verify Nix/home-manager version is working
2. [ ] Check `which <command>` points to Nix path
3. [ ] Test actual functionality, not just version
4. [ ] Keep Homebrew version until Nix version proven working

**After removing each package**:

1. [ ] Command still works: `which <command>`
2. [ ] Version check works: `<command> --version`
3. [ ] Actual use case works (open file, run command, etc.)
4. [ ] No error messages in shell startup
5. [ ] PATH doesn't show old Homebrew paths

**If any issues**:

```bash
# Immediately reinstall
brew install <package>  # or --cask for GUI apps

# Debug
which <command>
echo $PATH
# Check if Nix version is in PATH
```

2. **Finalize login shell transition**:

   ```bash
   # Run the one-time system setup script (see Technical Implementation Details)
   cd ~/Code/nixcfg/hosts/imac-27-home
   ./setup/setup-macos.sh

   # After successful completion:
   # - Restart terminal and verify fish is the login shell
   # - Test login/logout cycle
   # - Only then: brew uninstall fish
   ```

3. **Final verification checklist**:
   - ✅ Terminal opens correctly
   - ✅ Shell prompt works (starship with custom gitcount)
   - ✅ All commands available in devenv shell
   - ✅ Fonts render correctly (Hack Nerd Font)
   - ✅ Custom functions work (sourceenv, sourcefish, pingt)
   - ✅ Aliases work (mc, lg)
   - ✅ Abbreviations work (flushdns, qc99, qc24, qc0, qc1)
   - ✅ SSH shortcuts connect properly
   - ✅ Git dual identity switches correctly
   - ✅ direnv auto-loads environments
   - ✅ Node.js projects work
   - ✅ Python projects work

---

2. **Prepare for imac-27-work** (future):
   - This setup serves as template
   - Copy structure: `cp -r hosts/imac-27-home hosts/imac-27-work`
   - Customize scripts directory for work-specific automation
   - Same dual identity setup (personal vs BYTEPOETS)
   - Document any work-specific differences

---

## Technical Implementation Details

### Home-Manager Installation

**Approach**: Flake-based installation for maximum reproducibility

```bash
# Clone repo
git clone <repo-url> ~/Code/nixcfg
cd ~/Code/nixcfg

   # Install home-manager and activate
   nix run home-manager/master -- init --switch
   home-manager switch --flake .#markus@imac-27-home

   # Activate devenv (automatic platform detection)
   devenv shell
```

**b) Scripts management workflow**:

- **Adding new scripts**:

  ```bash
  # 1. Create script in repo
  vim hosts/imac-27-home/scripts/my-new-script.sh

  # 2. Make executable
  chmod +x hosts/imac-27-home/scripts/my-new-script.sh

  # 3. Add to git
  git add hosts/imac-27-home/scripts/my-new-script.sh
  git commit -m "Add my-new-script"

  # 4. Apply (script auto-links to ~/Scripts/)
  home-manager switch --flake .#markus@imac-27-home

  # 5. Use it
  ~/Scripts/my-new-script.sh
  ```

- **Editing existing scripts**:

  ```bash
  # 1. Edit in repo (NOT in ~/Scripts/ - those are symlinks!)
  vim hosts/imac-27-home/scripts/pingt.sh

  # 2. Commit changes
  git add hosts/imac-27-home/scripts/pingt.sh
  git commit -m "Update pingt script"

  # 3. Changes immediately visible (symlinked)
  # No home-manager switch needed for content changes
  ```

- **Machine-specific vs shared**:
  - Machine-specific: `hosts/<hostname>/scripts/`
  - Shared (future): `scripts/common/`

**c) Git dual identity setup**:

- Personal (default): Markus Barta <markus@barta.com>
- Work (automatic): mba <markus.barta@bytepoets.com>
- Trigger: Any git repo in `~/Code/BYTEPOETS/`
- Implementation: `programs.git.includes` with `gitdir:` condition

**d) Node.js and Python - Global + Project-specific**:

- **Global baseline** (home-manager): Always available everywhere (IDEs, scripts, terminal)
- **Project overrides** (devenv.nix): Specify different versions when needed
- **nixcfg repo**: Uses latest Node/Python from nixpkgs (via devenv.nix)
- **Other projects**: Create `devenv.nix` with specific versions
- Example override: `languages.javascript.package = pkgs.nodejs_18;`
- See "Node.js and Python Strategy" section for full details

**e) Troubleshooting guide**:

- Scripts not executable: Check git permissions, use `git ls-files -s`
- Git identity wrong: Check `git config user.email` in repo
- Node/Python not found: Check `which node` and `which python3` (should be in PATH globally)
- Wrong Node/Python version: Are you in correct devenv shell for project override?
- Starship not showing: Is `fish_prompt.fish` disabled?
- devenv tools not found: Are you in `devenv shell` for nixcfg repo?

2. **Prepare for imac-27-work** (future):
   - This setup serves as template
   - Copy structure: `cp -r hosts/imac-27-home hosts/imac-27-work`
   - Customize scripts directory for work-specific automation
   - Same dual identity setup (personal vs BYTEPOETS)
   - Document any work-specific differences

## Technical Implementation Details

### Home-Manager Installation

**Approach**: Flake-based installation for maximum reproducibility

```bash
# 1. Add to flake.nix outputs (after nixosConfigurations)
homeConfigurations."markus@imac-27-home" = home-manager.lib.homeManagerConfiguration {
  pkgs = nixpkgs.legacyPackages.x86_64-darwin;
  modules = [ ./hosts/imac-27-home/home.nix ];
  extraSpecialArgs = self.commonArgs // { inherit inputs; };
};

# 2. Create hosts/imac-27-home/home.nix (see Configuration Structure below)

# 3. Initial activation (directly from flake)
nix run home-manager/master -- switch --flake .#markus@imac-27-home

# 4. Subsequent switches (home-manager will be in PATH after first activation)
home-manager switch --flake .#markus@imac-27-home
```

**Why flake-based?**

- ✅ Version-locked with flake.lock
- ✅ Consistent with NixOS configurations
- ✅ Mostly reproducible from git (configs automatic, system setup manual)
- ✅ Single source of truth for declarative configs

### Devenv Platform Detection

**Approach**: Platform detection in single `devenv.nix`

```nix
# devenv.nix with automatic platform detection
{ pkgs, lib, ... }:
let
  isDarwin = pkgs.stdenv.isDarwin;
  isLinux = pkgs.stdenv.isLinux;

  commonPackages = with pkgs; [ git gum prettier ];
  darwinPackages = with pkgs; [ bat btop ripgrep fd fzf zoxide cloc ];
  linuxPackages = with pkgs; [ ];
in
{
  packages = commonPackages
    ++ lib.optionals isDarwin darwinPackages
    ++ lib.optionals isLinux linuxPackages;

  # Languages (project-specific for nixcfg repo)
  # Note: Global Node/Python available via home-manager
  # These override globals when in devenv shell for this repo
  languages = lib.optionalAttrs isDarwin {
    javascript.enable = true;  # Latest Node.js from nixpkgs
    python.enable = true;      # Latest Python 3 from nixpkgs
  };

  enterShell = if isDarwin
    then "echo '\uf313 nixcfg \ue711 macOS'"
    else "echo '\uf313 nixcfg \ue712 Linux'";
}
```

**Why platform detection?**

- ✅ **Automatic conditional execution** - single file runs appropriate code per platform
- ✅ Git-friendly - no separate platform-specific files
- ✅ Standard Nix pattern
- ✅ Maintains shared configuration

**Reality Check**: "Automatic" means the conditionals execute automatically, NOT that you avoid writing conditionals. You still manually maintain separate package lists and platform-specific logic - it just lives in one file instead of multiple files.

### Home-Manager Configuration Structure

```nix
# home.nix structure with all key configurations
{ config, pkgs, ... }:
{
  home.username = "markus";
  home.homeDirectory = "/Users/markus";
  home.stateVersion = "24.11";

  # Shell & Terminal
  programs.fish = {
    enable = true;
    # All config.fish content (functions, aliases, abbreviations)
    # Custom functions: sourceenv, sourcefish, pingt
    # Remove: fish_prompt (conflicts with starship), node@18 PATH, pipx PATH
  };

  programs.starship = {
    enable = true;
    settings = { ... };  # Migrate starship.toml
    # Custom gitcount module
  };

  programs.wezterm = {
    enable = true;
    extraConfig = '' ... '';  # Migrate wezterm.lua
  };

  # Development Tools
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;  # Better Nix integration
    # Fish integration automatic
  };

  programs.git = {
    enable = true;
    userName = "Markus Barta";
    userEmail = "markus@barta.com";  # Personal (default)
    ignores = [ "*~" ".DS_Store" ];
    extraConfig.credential.helper = "osxkeychain";

    # Dual identity: automatic work identity for BYTEPOETS projects
    includes = [{
      condition = "gitdir:~/Code/BYTEPOETS/";
      contents.user = {
        name = "mba";
        email = "markus.barta@bytepoets.com";
      };
    }];
  };

  # Global Packages
  home.packages = with pkgs; [
    # Interpreters (global baseline - always available)
    nodejs    # Latest Node.js - for IDEs, scripts, terminal
    python3   # Latest Python 3 - for IDEs, scripts, terminal

    # Fonts
    (nerdfonts.override { fonts = [ "Hack" ]; })
  ];

  fonts.fontconfig.enable = true;

  # Scripts Management
  home.file."Scripts" = {
    source = ./scripts;  # Points to hosts/imac-27-home/scripts/
    recursive = true;     # Links all files in directory
    # Preserves executable permissions from git
  };

  # Alternative: Individual script control
  # home.file."Scripts/pingt.sh" = {
  #   source = ./scripts/pingt.sh;
  #   executable = true;
  # };
}
```

### System Setup Script (setup-macos.sh)

**Location**: `hosts/imac-27-home/setup/setup-macos.sh` (version-controlled)

**Purpose**: One-time system-level configuration after home-manager activation

**Why a script instead of nix-darwin:**

- **macOS Upgrade Safety**: Doesn't interfere with system-level files that Apple updates
- **Simpler**: Only two commands needed, documented in version control
- **Well-documented**: Same script works for `imac-27-work` (still requires manual execution)
- **Lower Risk**: Failures don't affect existing system configuration

**Reality Check - NOT Fully Declarative:**

- This script is **imperative**, not declarative
- Requires **manual execution** with sudo password
- Modifies **system state** outside Nix control (`/etc/shells`)
- One-time setup per machine, not automatic from git
- Trade-off: Simplicity & safety vs full automation

**What it does:**

- Adds `~/.nix-profile/bin/fish` to `/etc/shells` (requires sudo)
- Changes default shell via `chsh`
- Verifies Nix fish exists before proceeding
- Checks if already configured (idempotent)

**Usage:**

```bash
# Run AFTER home-manager is activated and working
cd ~/Code/nixcfg/hosts/imac-27-home
./setup/setup-macos.sh

# Verify
exec fish
echo $SHELL    # Should show ~/.nix-profile/bin/fish
which fish     # Should show ~/.nix-profile/bin/fish
```

**For imac-27-work:** Copy script to `hosts/imac-27-work/`, run once after home-manager activation

## Risk Assessment

### Critical Risk: Backup Failure

**THE BIGGEST RISK** - Everything else depends on working backups

**Risk**: Backup fails, corrupts, or is inaccessible when needed

- Backup script has bugs (doesn't copy everything)
- Time Machine broken or outdated
- Backup directory deleted or corrupted
- Checksums calculated but files actually corrupted
- Can't access backup when disaster strikes

**Impact**: **Unrecoverable** - Can't rollback, lose configurations permanently

- Hours/days of manual recovery
- Potential data loss
- System rebuild from scratch

**Mitigation**:

- ✅ **Validate backup BEFORE migrating** (Phase 0.2 validation checklist)
- ✅ Test restore of ONE file to verify process works
- ✅ Verify checksums to detect corruption
- ✅ Confirm Time Machine has recent backup
- ✅ Keep Homebrew packages until Phase 3 complete (fallback layer)
- ✅ Take Time Machine snapshot before starting Phase 5 cleanup

**Rollback if backups fail**:

- If discovered BEFORE removing Homebrew packages: Abort migration, keep Homebrew
- If discovered AFTER removing Homebrew packages: Manual recovery required
  1. Reinstall Homebrew from scratch
  2. Reinstall all packages from memory
  3. Restore from older Time Machine backup (lose recent work)
  4. Or: Start over from scratch

**Reality Check**: This is why Phase 0.2 validation is NOT optional. A failed backup discovered too late means you're rebuilding everything manually.

---

### Testing Timeline Reality

**Testing Timeline Clarification**

The "1-2 weeks" testing guideline is aspirational, not a requirement.

**Reality**:

- Most people won't test for weeks
- You'll test for hours/days, then proceed when confident
- As long as Homebrew packages exist as fallbacks, risk is low

**Actual Implementation Timeline**:

- **Compressed**: Complete entire migration in 1-2 days
- **Standard**: Phase 0-3 in a few days, test/cleanup as you go
- **Relaxed**: 1-2 weeks for educational/thorough approach

**The Key**: Homebrew packages stay until YOU decide to remove them. Test as much or as little as you want.

**See `testing-and-cleanup.md`** for detailed testing procedures, but remember: the timeline is entirely your choice.

---

### High Risk Areas

**1. Fish shell migration** - Core tool, must work perfectly

- **Risk**: Shell doesn't start, lose access to terminal
- **Impact**: Can't use terminal at all
- **Mitigation**:
  - Keep Homebrew fish as login shell during testing
  - Test Nix fish extensively before making login shell
  - Verify extensively before removing
- **Rollback**: Homebrew fish still login shell, just `exec /usr/local/bin/fish`

**2. Starship configuration** - Complex custom config with gitcount module

- **Risk**: Prompt broken, missing git info, custom modules fail
- **Impact**: Annoying but not blocking
- **Mitigation**:
  - Migrate all settings declaratively
  - Test custom gitcount module specifically
  - Verify before removing
- **Rollback**: `brew install starship`, restore starship.toml from backup

**3. WezTerm + Fonts** - Terminal and font rendering

- **Risk**: Terminal won't open, fonts missing/ugly, colors wrong
- **Impact**: Can use another terminal temporarily (iTerm2, Terminal.app)
- **Mitigation**:
  - Test WezTerm opens with correct font before removing
  - Stage 5.3 removal: Remove wezterm and font separately
- **Rollback**: `brew install --cask wezterm font-hack-nerd-font`

**4. Git with dual identity** - Used everywhere, complex setup

- **Risk**: Git breaks, wrong identity used, commits with wrong email
- **Impact**: Could commit with wrong identity to repos
- **Mitigation**:
  - Test both identities extensively before removal
  - Verify in personal and BYTEPOETS repos
  - Stage 5.4 removal: Last to remove, after everything else proven
- **Rollback**: `brew install git`, restore ~/.gitconfig from backup

### Medium Risk Areas

**1. Development tools (Node.js, Python)** - Used in devenv shell

- **Risk**: Projects don't work, version mismatches
- **Impact**: Can't work on projects until fixed
- **Mitigation**:
  - Test in devenv shell before removing Homebrew versions
  - Stage 5.2 removal: Test with actual projects first
- **Rollback**: `brew install node python@3.10`

**2. direnv** - Auto-loads project environments

- **Risk**: .envrc files don't load, manual activation needed
- **Impact**: Annoying but not blocking
- **Mitigation**:
  - home-manager handles fish integration automatically
  - Test with projects that have .envrc
  - Stage 5.2 removal: Early, easy to reinstall
- **Rollback**: `brew install direnv`, add hook back to fish config

**3. zoxide** - Directory jumping (z command)

- **Risk**: `z` command doesn't work
- **Impact**: Annoying but can use `cd`
- **Mitigation**:
  - home-manager should handle fish integration
  - Test directory jumping before removal
  - Stage 5.2 removal: Test 1 day
- **Rollback**: `brew install zoxide`

### Low Risk Areas

**1. CLI tools (bat, btop, ripgrep, fd, fzf, cloc)** - Nice-to-have utilities

- **Risk**: Commands not found or don't work
- **Impact**: Minimal, alternative commands available
- **Mitigation**:
  - Stage 5.1 removal: First to remove, easiest
  - Remove one by one with immediate verification
- **Rollback**: `brew install <package>` - quick and easy

**2. Scripts directory** - Custom automation

- **Risk**: Scripts missing or not executable
- **Impact**: Automation broken, but can fix individual scripts
- **Mitigation**:
  - Git preserves permissions
  - Test each critical script after migration
- **Rollback**: Restore from backup, scripts still work from old location

### Risk Mitigation Strategy

**Staged removal approach** (Phase 5):

1. **Stage 5.1** (Low risk): CLI tools - 6 packages
2. **Stage 5.2** (Medium risk): Dev tools - 4 packages
3. **Stage 5.3** (High risk): Terminal/Shell - 3 packages
4. **Stage 5.4** (High risk): Git - 1 package
5. **Stage 5.5** (No risk): Unwanted - 2 packages

**Testing periods**:

- Stage 5.1: 1 day between removals
- Stage 5.2: 1 day between removals
- Stage 5.3: Verify each removal (critical!)
- Stage 5.4: Test thoroughly (after everything else stable)

**Per-package verification**: Every package has specific test commands and rollback procedure

**Result**: If ANY package fails, only that package needs reinstalling, not everything

## Rollback & Recovery

**If anything goes wrong**, see **`testing-and-cleanup.md`** → "Rollback & Recovery Procedures" for:

- ✅ **3 Rollback Scenarios**: Early failure, late failure (after Homebrew removal), partial rollback
- ✅ **Dirty Git State Recovery**: Handles uncommitted changes and partial migrations
- ✅ **Staged Rollback Points**: Git commits at each phase for easy reversion
- ✅ **Complete Verification Checklist**: Ensures full system restoration
- ✅ **Emergency Resources**: Time Machine, shell recovery, Homebrew reinstall

**Key Principle**: Better to rollback early and retry than push through problems.

**Quick Emergency Rollback**:

```bash
# 1. Restore from backup
BACKUP_DIR=~/migration-backup-YYYYMMDD-HHMMSS
cp -r "$BACKUP_DIR/fish" ~/.config/ && cp "$BACKUP_DIR/starship.toml" ~/.config/

# 2. Revert system shell
chsh -s /usr/local/bin/fish

# 3. Reinstall Homebrew packages (if removed)
cd "$BACKUP_DIR/system-state" && xargs brew install < brew-formulae.txt

# See testing-and-cleanup.md for complete procedures
```

---

## Key Decisions Summary

✅ **Devenv strategy**: Platform detection in single `devenv.nix` (using `pkgs.stdenv.isDarwin`)  
✅ **Fish config**: Home-manager with all functionality preserved  
✅ **Starship config**: Home-manager, migrate custom toml  
✅ **WezTerm config**: Home-manager extraConfig  
✅ **Node.js & Python**: **Both global (home-manager) + project-specific (devenv)**

- Global via home-manager: Always available for IDEs, scripts, terminal
- Project-specific via devenv: Overrides for per-project version requirements
- Rationale: See "Node.js and Python Strategy" section - maximum flexibility, zero compromise
  ✅ **pingt script**: Bash implementation (`pingt.sh` - ✅ already rewritten, pure bash, no perl) + Fish wrapper (`pingt.fish` - calls the script)  
  ✅ **nix-darwin**: NOT using - standalone home-manager safer for macOS upgrades  
  ✅ **System setup**: `setup/setup-macos.sh` script for `/etc/shells` and `chsh` (one-time, **MANUAL**, imperative)
- NOT fully declarative - requires manual execution with sudo on each machine
- Trade-off: Simplicity & macOS upgrade safety vs full automation (nix-darwin)  
  ✅ **direnv**: Migrate to home-manager (programs.direnv)  
  ✅ **Timeline**: Flexible - 1-2 days (compressed) or 1-2 weeks (relaxed learning pace)
- No fixed testing periods - test as long as YOU need
- Homebrew packages stay as fallback until you're confident
- Testing/cleanup (`testing-and-cleanup.md`) is at your own pace

## Next Steps

**Planning Phase**: ✅ Complete

**Ready to execute when approved:**

1. **Phase 0.2**: Run `setup/backup-migration.sh` to create pre-migration backup

2. **Phase 1**: Create `home.nix`, enhance `devenv.nix` and `flake.nix` with platform detection

3. **Phase 2-4**: Execute incremental migration (CLI tools → environment → shell transition)

4. **Phase 5**: Run `setup/setup-macos.sh`, finalize shell transition, staged Homebrew cleanup

5. **Phase 6**: Document final setup in README.md for `imac-27-work` template

## Implementation Notes

**Review & Approval Process**:

- Show the plan and explain what will be done
- Wait for explicit approval before executing
- Rather ask one more time than one less time

**Safety First**:

- All changes will be made incrementally
- Each step will be tested before proceeding
- Homebrew packages kept as fallback during testing, removed immediately after
- Original configs backed up before any changes
- Login shell stays Homebrew fish until everything verified, then transitioned to Nix

**Timeline**:

- Flexible execution: 1-2 days (compressed) or 1-2 weeks (relaxed learning)
- Phase 0-3: Core setup and migration
- Phase 4-5: Testing and cleanup (at your pace - see `testing-and-cleanup.md`)
- Phase 6: Documentation for reproducibility and `imac-27-work` template

**Special Considerations**:

- Everything works fine currently - no issues to fix (migration is educational investment, not problem-solving)
- This will serve as template for imac-27-work later
- Focus is on learning Nix + building reproducible infrastructure, not fixing problems
- Success measured by knowledge gained and future efficiency, not just "works the same"
