# TODO: Homebrew Cleanup - Stage 4+

**Last Updated**: 2025-11-15  
**Current State**: 167 formulae, 10 casks remaining after Stage 1-3 cleanup

---

## Overview

This document provides a **package-by-package analysis** of all remaining Homebrew packages with recommendations for migration, removal, or retention.

**Categories**:

1. **Migrate to Nix** - CLI tools that benefit from declarative management
2. **macOS Built-in Overrides** - Tools macOS provides but outdated/limited
3. **Remove if Unused** - Question if actually needed
4. **Keep in Homebrew** - System integration, complex dependencies, GUI apps
5. **Auto-Dependencies** - Libraries installed as dependencies (review after cleanup)

---

## Category 1: Migrate to Nix ✅

### CLI Development Tools

- [ ] **`gh`** - GitHub CLI
  - Used for: GitHub operations from terminal
  - Nix package: `pkgs.gh`
  - Action: Add to `home.packages`

- [ ] **`jq`** - JSON processor
  - Used for: JSON parsing in scripts
  - Nix package: `pkgs.jq`
  - Action: Add to `home.packages`

- [ ] **`just`** - Command runner (already in devenv.nix for nixcfg)
  - Used for: Task automation
  - Nix package: `pkgs.just`
  - Action: Add to `home.packages` for global use

- [ ] **`lazygit`** - Terminal UI for git (already in devenv.nix for nixcfg)
  - Used for: Git TUI
  - Nix package: `pkgs.lazygit`
  - Action: Add to `home.packages` for global use

### File Management & Utilities

- [ ] **`tree`** - Directory tree viewer
  - Used for: Visualizing directory structures
  - Nix package: `pkgs.tree`
  - Action: Add to `home.packages`

- [ ] **`pv`** - Pipe viewer (progress for pipes)
  - Used for: Monitoring data through pipes
  - Nix package: `pkgs.pv`
  - Action: Add to `home.packages`

- [ ] **`tldr`** - Simplified man pages
  - Used for: Quick command examples
  - Nix package: `pkgs.tealdeer` (or `pkgs.tldr`)
  - Action: Add to `home.packages`

- [ ] **`fswatch`** - File system watcher
  - Used for: Monitoring file changes
  - Nix package: `pkgs.fswatch`
  - Action: Add to `home.packages` or project devenv

### Terminal Multiplexers (Pick ONE)

- [x] **`tmux`** - Terminal multiplexer
  - Used for: nothing any more
  - Action: ❌ **REMOVE**

- [x] **`zellij`** - Modern terminal multiplexer
  - Used for: all interaction with hosts
  - Nix package: `pkgs.zellij`
  - Action: ✅ **MIGRATE TO NIX**

### Networking Tools

- [ ] **`netcat`** - Network utility
  - Used for: Network debugging
  - Nix package: `pkgs.netcat`
  - Action: Add to `home.packages` if used

- [ ] **`telnet`** - Telnet client
  - Used for: Testing network services
  - Nix package: `pkgs.inetutils` (includes telnet)
  - Action: Add to `home.packages` if used

- [ ] **`websocat`** - WebSocket client
  - Used for: WebSocket testing
  - Nix package: `pkgs.websocat`
  - Action: Add to `home.packages` if used

### Text Processing

- [ ] **`lynx`** - Text-based web browser
  - Used for: Viewing HTML in terminal
  - Nix package: `pkgs.lynx`
  - Action: Add to `home.packages` if used

- [ ] **`html2text`** - HTML to text converter
  - Used for: Converting HTML to plain text
  - Nix package: `pkgs.html2text`
  - Action: Add to `home.packages` if used

### Backup & Archive

- [ ] **`restic`** - Backup program
  - Used for: Backups
  - Nix package: `pkgs.restic`
  - Action: Add to `home.packages`

- [ ] **`rage`** - Age encryption (Rust implementation)
  - Used for: File encryption (secrets management)
  - Nix package: `pkgs.rage`
  - Note: **`age`** already installed via Homebrew
  - Action: Migrate to Nix, remove Homebrew version

### Development Languages (if needed globally)

- [ ] **`lua`** - Lua language
  - Used for: nothing
  - Nix package: `pkgs.lua`
  - Action: Remove!

- [ ] **`luarocks`** - Lua package manager
  - Used for: Lua packages
  - Nix package: `pkgs.luarocks`
  - Action: Remove

---

## Category 2: macOS Built-in Overrides 🍎

**These tools exist in macOS but are outdated or limited. Nix provides modern versions.**

- [ ] **`rsync`** - File synchronization
  - macOS version: 2.6.9 (from 2006!)
  - Nix version: 3.3.0+ (modern)
  - Nix package: `pkgs.rsync`
  - Action: Add to `home.packages`, prepend to PATH (already done via Nix)

- [ ] **`wget`** - File downloader
  - macOS: Not included
  - Nix package: `pkgs.wget`
  - Action: Add to `home.packages`

- [ ] **`diffutils`** - diff, cmp, etc.
  - macOS version: BSD variants (limited features)
  - Nix version: GNU diffutils (full-featured)
  - Nix package: `pkgs.diffutils`
  - Action: Add to `home.packages` if GNU features needed

- [ ] **`ncurses`** - Terminal handling library
  - macOS version: Outdated
  - Nix package: `pkgs.ncurses`
  - Note: May be auto-dependency for other tools
  - Action: Keep in Homebrew as dependency

**Note**: Unlike `nano` (already migrated), these should be evaluated case-by-case. Only migrate if you specifically need the newer versions.

---

## Category 3: Remove if Unused ❓

**Review usage before removing. These might be experiments or old installations.**

### Specialized/Unknown Usage

- [ ] **`go-jira`** - Jira CLI
  - Question: Do you actively use Jira from CLI?
  - Action: Remove

- [ ] **`magic-wormhole`** - Secure file transfer
  - Question: When was this last used?
  - Action: Remove

- [ ] **`wakeonlan`** - Wake-on-LAN utility
  - Question: Do you use Wake-on-LAN?
  - Action: Remove

- [ ] **`tuist@4.104.6`** - Xcode project generation
  - Question: iOS/macOS development tool - still relevant?
  - Action: Remove

- [ ] **`topgrade`** - Update all tools
  - Question: Still useful with Nix/Homebrew split?
  - Action: Remove

- [ ] **`f3`** - Flash drive testing tool
  - Question: When was this last used?
  - Action: keep, is occasionally used

### Duplicate Tools

- [ ] **`defaultbrowser`** vs **`defbro`**
  - Both set default browser
  - Action: Keep `defaultbrowser`

### Python Tools (Potential Leftover Dependencies)

- [ ] **`pipx`** - Python app installer
  - Question: Still used after Python migration to Nix?
  - Action: remove

- [ ] **`certifi`** - Python SSL certificates
  - Likely a dependency for removed Python packages
  - Action: keep

- [ ] **`python-*`** packages (charset-normalizer, cryptography, idna, requests, urllib3)
  - Question: Dependencies for removed Python tools?
  - Action: Run `brew autoremove` to clean orphaned dependencies

### Old Python Packages

- [ ] **`pycparser`**, **`python-cryptography`**, **`python-idna`**, etc.
  - These look like leftover dependencies from removed Python packages
  - Action: `brew autoremove` should clean these up

---

## Category 4: Keep in Homebrew 🍺

### GUI Applications (Casks) - Keep

- ✅ **`cursor`** - AI code editor
- ✅ **`zed`** - Modern code editor
- ✅ **`hammerspoon`** - macOS automation
- ✅ **`karabiner-elements`** - Keyboard remapping (config in Nix)
- ✅ **`temurin`** - Java JDK
- ✅ **`asset-catalog-tinkerer`** - Asset catalog viewer
- ✅ **`syntax-highlight`** - Syntax highlighting tool
- ✅ **`knockknock`** - Launch at login scanner
- ✅ **`osxfuse`** - Filesystem in userspace
- ✅ **`rar`** - RAR archive support

**Reason**: GUI apps, system integrations, not available in Nix or better in Homebrew

### System Integration Tools - Keep

- ❌ **`evcc`** - Electric vehicle charging control
  - Was: Test only, no longer needed
  - Action: Remove

- ✅ **`mosquitto`** - MQTT broker
  - Reason: System-level service for IoT/home automation
  - Note: used as a client for development sometimes

- ✅ **`ext4fuse`** - Linux filesystem support
  - Reason: macOS kernel extension

### Complex Multimedia - Keep

- ✅ **`ffmpeg`** - Video/audio processing
  - Reason: Complex with many codec dependencies
  - Note: Has 50+ dependencies (all the lib\* packages)
  - Action: Keep in Homebrew to avoid Nix dependency hell

- ✅ **`imagemagick`** - Image processing
  - Reason: Complex with many format dependencies
  - Note: Depends on many lib\* packages
  - Action: Keep in Homebrew

- ✅ **`ghostscript`** - PostScript/PDF interpreter
  - Reason: Complex document processing
  - Action: Keep in Homebrew

- ✅ **`tesseract`** - OCR engine
  - Reason: Large with language data
  - Action: Keep in Homebrew

### Java - Keep

- ✅ **`openjdk`** - Java Development Kit (Homebrew formula)
  - Action: remove
- ✅ **`temurin`** - Java runtime (cask)
  - Reason: System-level Java installation
  - Action: Keep

### Terminal Tools (Personal Preference)

- ✅ **`midnight-commander`** - File manager
  - Reason: Personal workflow tool
  - Action: ✅ **MIGRATE TO NIX**

---

## Category 5: Auto-Dependencies 📦

**These are libraries installed as dependencies. They'll be cleaned up automatically when parent packages are removed.**

### Codec Libraries (ffmpeg dependencies)

- `aom`, `dav1d`, `rav1e`, `svt-av1` - AV1 codecs
- `x264`, `x265`, `xvid` - Video codecs
- `opus`, `vorbis`, `flac`, `lame`, `speex` - Audio codecs
- `libvpx`, `libtheora`, `opencore-amr` - Other codecs

### Image Libraries (imagemagick dependencies)

- `libpng`, `libjpeg-turbo`, `libtiff`, `libwebp`, `giflib`
- `jpeg-xl`, `libheif`, `libraw`, `openjpeg`, `openjph`
- `little-cms2`, `libde265`

### System Libraries

- `gettext`, `glib`, `gmp`, `gnutls`, `icu4c@77`
- `readline`, `sqlite`, `openssl@3`, `ca-certificates`
- `brotli`, `lz4`, `lzo`, `xz`, `zstd`, `snappy`, `xxhash`

### Graphics Libraries

- `cairo`, `pango`, `harfbuzz`, `fontconfig`, `freetype`, `pixman`
- `graphite2`, `fribidi`

### X11 Libraries (for some tools)

- `libx11`, `libxau`, `libxcb`, `libxdmcp`, `libxext`, `libxrender`
- `xorgproto`

### Other Dependencies

- `libevent`, `libuv`, `libssh`, `libssh2`, `libnghttp2`
- `libarchive`, `libzip`, `libtool`, `pcre2`, `oniguruma`
- `mpdecimal` (Python dependency)

**Action**: Leave these alone. They'll be removed automatically by `brew autoremove` when parent packages are gone.

---

## Execution Plan

### Phase 1: Gather Information

- [ ] Review usage of "Remove if Unused" packages
  - [ ] `go-jira` - Check last use
  - [ ] `magic-wormhole` - Check last use
  - [ ] `wakeonlan` - Check last use
  - [ ] `tuist` - Still doing iOS dev?
  - [ ] `topgrade` - Conflicts with Nix?
  - [ ] `f3` - Check last use
  - [ ] `pipx` - List installed apps: `pipx list`

- [ ] Decide: `tmux` or `zellij`?
- [ ] Decide: `defaultbrowser` or `defbro`?
- [ ] Check Java: Do you need both `openjdk` and `temurin`?

### Phase 2: Migrate to Nix

- [ ] Add to `home.nix` → `home.packages`:

  ```nix
  # CLI Development Tools
  gh          # GitHub CLI
  jq          # JSON processor
  just        # Command runner (already in devenv, add globally)
  lazygit     # Git TUI (already in devenv, add globally)

  # File Management & Utilities
  tree        # Directory tree
  pv          # Pipe viewer
  tealdeer    # tldr (simplified man pages)
  fswatch     # File watcher
  mc          # midnight-commander (file manager)

  # Terminal Multiplexer
  zellij      # Modern terminal multiplexer

  # Networking Tools
  netcat      # Network utility
  inetutils   # Includes telnet
  websocat    # WebSocket client

  # Text Processing
  lynx        # Text browser
  html2text   # HTML converter

  # Backup & Archive
  restic      # Backup
  rage        # Age encryption (replaces Homebrew age)

  # macOS Built-in Overrides
  rsync       # Modern rsync
  wget        # File downloader
  ```

- [ ] Apply changes:

  ```bash
  cd ~/Code/nixcfg
  home-manager switch --flake ".#markus@imac-27-home"
  ```

- [ ] Verify all commands work from Nix:
  ```bash
  which gh jq tree pv tldr rsync wget rage
  # All should point to ~/.nix-profile/bin/
  ```

### Phase 3: Remove from Homebrew

- [ ] Remove migrated packages:

  ```bash
  # Remove migrated packages
  brew uninstall gh jq just lazygit tree pv tldr fswatch mc \
    netcat telnet websocat lynx html2text restic rage age \
    rsync wget zellij

  # Remove unused/old packages
  brew uninstall go-jira magic-wormhole wakeonlan tuist topgrade \
    lua luarocks evcc openjdk tmux defbro pipx
  ```

- [ ] Clean up Python dependencies:

  ```bash
  brew uninstall pipx
  brew autoremove
  ```

- [ ] Final cleanup:
  ```bash
  brew cleanup --prune=all
  ```

### Phase 4: Verification

- [ ] Test all migrated tools work
- [ ] Check remaining packages:
  ```bash
  brew list --formula | wc -l  # Should be significantly lower
  brew list --cask | wc -l     # Should be ~10
  ```
- [ ] Update this document with final state

---

## Expected Outcome

**Before Stage 4**: 167 formulae, 10 casks  
**After Stage 4**: ~120 formulae (mostly dependencies), 9-10 casks

**Migrated to Nix**: ~20-25 CLI tools  
**Removed as Unused**: ~10-15 packages  
**Remaining in Homebrew**: System integration, GUI apps, complex multimedia with dependencies

---

## Notes

- **Don't rush**: Test each migration before removing from Homebrew
- **Dependencies cleanup automatically**: `brew autoremove` handles lib\* packages
- **GUI apps stay**: No benefit moving casks to Nix on macOS
- **Multimedia complexity**: ffmpeg/imagemagick are better in Homebrew due to codecs
- **Java**: Clarify which Java installation is actually needed
