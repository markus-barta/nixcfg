# gpc0 → External Hokage Consumer Migration Plan

**Host**: gpc0 (Gaming PC 0, formerly mba-gaming-pc)  
**Migration Type**: External Hokage Consumer Pattern  
**Risk Level**: 🟢 **LOW** - Desktop system with GUI access  
**Status**: ✅ **COMPLETE** - All issues resolved including zellij theming  
**Created**: November 29, 2025  
**Updated**: November 30, 2025 (major lessons learned)

---

## 🎯 Migration Overview

### Current State (on host)

| Attribute      | Value                              |
| -------------- | ---------------------------------- |
| **Hostname**   | `mba-gaming-pc` (old!)             |
| **Git**        | `03572ef` (very behind)            |
| **Nix System** | mba-gaming-pc-25.11.20251117       |
| **Needs**      | `git pull && nixos-rebuild switch` |

### Target State (in repo)

| Attribute     | Value                                                    |
| ------------- | -------------------------------------------------------- |
| **Hostname**  | `gpc0`                                                   |
| **Structure** | External hokage from `github:pbek/nixcfg`                |
| **Pattern**   | Explicit module list with commonDesktopModules           |
| **Uzumaki**   | Local `../../modules/uzumaki/desktop.nix` (kept)         |
| **Nixbit**    | Override to `https://github.com/markus-barta/nixcfg.git` |

---

## 📋 Migration Checklist

### Pre-Migration ✅

- [x] Rename host from `mba-gaming-pc` to `gpc0`
- [x] Update `flake.nix` to use external hokage for gpc0
- [x] Update `configuration.nix` to remove local hokage import
- [x] Add `hokage.programs.nixbit.repository` override
- [x] Keep `omega` user definition as-is
- [x] Keep local Uzumaki desktop module
- [x] Run `nix flake check` ✅
- [x] Add catppuccin override (Tokyo Night theming)

### Global Changes (All Hosts) ✅

- [x] Add `nixbit.repository` override to hsb0
- [x] Add `nixbit.repository` override to hsb1
- [x] Add `nixbit.repository` override to hsb8
- [x] Add `nixbit.repository` override to csb0
- [x] Add `nixbit.repository` override to csb1

### Deployment ✅

- [x] SSH to gpc0 or use local terminal
- [x] `cd ~/Code/nixcfg && git pull`
- [x] `sudo nixos-rebuild switch --flake .#gpc0`
- [x] Verify hostname changed: `hostname` shows `gpc0`
- [x] Reboot completed

---

## 🔐 Security Notes

**gpc0 is LOW RISK because:**

1. ✅ **Physical access** - You have GUI/keyboard access
2. ✅ **Local network** - Not exposed to internet
3. ✅ **Gaming PC** - No critical services

**No special security measures needed** - unlike cloud servers where SSH is the only access.

**Omega user (`omega` account = Patrizio Bekerle):**

- Can SSH as `omega@192.168.1.154` when on local network
- No external access (not port-forwarded to internet)
- Keep as-is for when Patrizio visits/helps with the system

---

## 🚀 Deployment Commands

```bash
# Option 1: SSH from imac
ssh mba@192.168.1.154
cd ~/Code/nixcfg  # or wherever it is
git pull
sudo nixos-rebuild switch --flake .#gpc0

# Option 2: Local terminal on gpc0
cd ~/Code/nixcfg
git pull
sudo nixos-rebuild switch --flake .#gpc0

# After switch - verify
hostname  # Should show: gpc0
readlink /run/current-system | sed 's/.*-nixos-system-//'  # Should show: gpc0-...
```

---

## 🔑 Key Differences from Server Migration

| Aspect             | Server (hsb0/hsb8/etc)        | Desktop (gpc0)                 |
| ------------------ | ----------------------------- | ------------------------------ |
| **Base Modules**   | `commonServerModules`         | `commonDesktopModules`         |
| **Plasma Manager** | No                            | Yes (via commonDesktopModules) |
| **Espanso Fix**    | No                            | Yes (via commonDesktopModules) |
| **Gaming**         | No                            | Yes (`hokage.gaming.enable`)   |
| **Role**           | `server-home`/`server-remote` | Desktop (no explicit role)     |
| **Uzumaki Module** | `uzumaki/server.nix`          | `uzumaki/desktop.nix`          |
| **Risk Level**     | 🟡 Medium (SSH only)          | 🟢 Low (GUI access)            |

---

## ⚠️ Important Notes

1. **Omega User**: Keep the `omega` user definition unchanged - Patrizio can still log in (as `omega` user, not `mba`)
2. **Nixbit Repository**: Must point to `markus-barta/nixcfg` for system updates to work
3. **Desktop Modules**: `commonDesktopModules` includes plasma-manager and espanso-fix
4. **Gaming Features**: `hokage.gaming.enable = true` provides Steam, Gamescope, etc.

---

## 📚 Lessons Learned (November 30, 2025)

### Build Time Issues

**Problem**: Initial migration took 6+ hours due to building packages from source.

**Causes**:

1. `nixos-unstable` points to very recent commits without full binary cache coverage
2. Heavy packages (Brave, Plasma, linux-firmware) required source builds
3. `cache.nixos.org` downloads stalled/failed requiring restarts
4. Machine went to sleep during downloads, corrupting partial downloads

**Solutions**:

- Use `systemd-inhibit --what=sleep:idle sudo nixos-rebuild switch` to prevent sleep
- Restart `nix-daemon` if downloads stall: `sudo systemctl restart nix-daemon`
- Consider using `nixos-25.05` (stable) for guaranteed cache coverage
  - ⚠️ BUT: hokage requires unstable-only features like `environment.corePackages`

**Key Finding**: pbek's hokage module requires `nixos-unstable` - stable channels will fail!

---

### Catppuccin/Tokyo Night Theme Conflicts

**Problem**: hokage enables Catppuccin theming by default, we use Tokyo Night.

**Solution**: Set `hokage.catppuccin.enable = false` in host configuration.nix:

```nix
hokage = {
  catppuccin.enable = false;  # We use Tokyo Night via theme-hm.nix
  # ... other options
};
```

**Note**: This option was added by pbek on Nov 30, 2025. Update `nixcfg` input to get it.

---

### Fish Shell Abbreviation Priority

**Problem**: Our fish abbreviations (`nano`, `ping`) were overridden by hokage's.

**Root Cause**: Using `lib.mkDefault` has lowest priority - hokage wins.

**Solution**: Use `lib.mkForce` for abbreviations we want to override:

```nix
shellAbbrs = (lib.mapAttrs (_: v: mkDefault v) sharedFishConfig.fishAbbrs) // {
  nano = lib.mkForce "nano";   # hokage sets nano→micro
  ping = lib.mkForce "pingt";  # hokage sets ping→gping
};
```

---

### Zellij Config Override - THE HARD ONE

**Problem**: Zellij refused to use our Tokyo Night theme despite multiple attempts.

**What DIDN'T Work**:

1. ❌ `home.file.".config/zellij/config.kdl"` with `force = true`
   - Failed because hokage's `programs.zellij` creates a DIRECTORY symlink
2. ❌ `xdg.configFile."zellij/config.kdl"` with `force = true`
   - Same issue - can't put a file inside a symlinked directory
3. ❌ `programs.zellij.enable = lib.mkForce false`
   - Still created the directory symlink somehow
4. ❌ `programs.zellij.settings = lib.mkForce {}`
   - Didn't prevent directory creation

**What WORKED** (Final Solution - after 6+ attempts):

```nix
# In theme-hm.nix - lib.mkForce on source is THE KEY!
home.file.".config/zellij" = lib.mkIf config.theme.zellij.enable {
  source = lib.mkForce (pkgs.writeTextDir "config.kdl" (mkZellijConfig palette hostname));
  recursive = true;
  force = true;
};
```

**Why It Works**:

1. `lib.mkForce` on `source` - Wins the Nix module merge conflict against hokage
2. `pkgs.writeTextDir` - Creates a directory with our config.kdl inside
3. `recursive = true` - Copies the directory structure
4. `force = true` - Replaces symlinks on disk during activation

**Manual Step Required (once per host)**:

```bash
rm -rf ~/.config/zellij
sudo nixos-rebuild switch --flake .#gpc0
```

Home-manager can't backup files inside read-only nix store symlinks. You'll see
`Read-only file system` error. Remove the old symlink first.

**Key Insight**: The conflict error revealed the fix - hokage also sets
`home.file.".config/zellij".source`. Use `lib.mkForce` to win the merge!

---

### Module Loading Order

**Problem**: Our overrides in `common.nix` weren't taking effect.

**Root Cause**: In `flake.nix`, modules are loaded in order. If hokage loads AFTER our `common.nix`, hokage wins.

**Solution**: Ensure hokage loads FIRST, then our overrides:

```nix
modules = [
  inputs.nixcfg.nixosModules.hokage  # External hokage loads FIRST
  ./modules/common.nix               # OUR config loads AFTER to override
  ./hosts/gpc0/configuration.nix
];
```

---

### Starship Missing After Build

**Problem**: Fish couldn't find `starship` command after enabling hokage.

**Root Cause**: We disabled `programs.starship.enable` (to manage config ourselves) but that also removes the binary.

**Solution**: Add starship to `environment.systemPackages`:

```nix
environment.systemPackages = with pkgs; [
  starship  # Binary needed even though we manage config via theme-hm.nix
];
```

---

### Excluding Heavy Packages

**Problem**: OnlyOffice and Brave required long source builds.

**Solution**: Use `hokage.excludePackages`:

```nix
hokage = {
  excludePackages = with pkgs; [
    onlyoffice-desktopeditors
    brave
  ];
};
```

**Note**: Values must be actual packages (with `pkgs.`), not strings.

---

## 🎯 Summary for Future Migrations

1. **Update inputs first**: `nix flake update nixcfg` to get latest hokage
2. **Set `hokage.catppuccin.enable = false`** if using Tokyo Night
3. **Use `lib.mkForce`** for fish abbrs you want to override
4. **Zellij**: Create entire directory with `recursive = true`
5. **Add starship to systemPackages** if disabling `programs.starship`
6. **Use `systemd-inhibit`** during long builds to prevent sleep
7. **Expect unstable**: hokage requires `nixos-unstable`, accept some source builds
