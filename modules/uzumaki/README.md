# Uzumaki Module

The "son of hokage" — personalized tooling and theming built on top of hokage's foundation.

While hokage handles system infrastructure (user management, base packages, services), uzumaki adds the personal touch: fish functions, per-host color themes, and system monitoring.

---

## Quick Start

### NixOS Systems

```nix
# In configuration.nix
imports = [ ../../modules/uzumaki ];

uzumaki = {
  enable = true;
  role = "server";  # or "desktop"
  stasysmo.enable = true;  # Optional: system monitoring in prompt
};
```

### macOS (Home Manager)

```nix
# In home.nix
imports = [ ../../modules/uzumaki/home-manager.nix ];

uzumaki = {
  enable = true;
  role = "workstation";
  stasysmo.enable = true;
};
```

---

## Module Options

| Option                     | Type   | Default    | Description                                      |
| -------------------------- | ------ | ---------- | ------------------------------------------------ |
| `uzumaki.enable`           | bool   | `false`    | Enable the uzumaki module                        |
| `uzumaki.role`             | enum   | `"server"` | Host role: `server`, `desktop`, or `workstation` |
| `uzumaki.fish.enable`      | bool   | `true`     | Enable fish functions                            |
| `uzumaki.fish.editor`      | string | `"nano"`   | Default `$EDITOR`                                |
| `uzumaki.fish.functions.*` | bool   | `true`     | Toggle individual functions                      |
| `uzumaki.zellij.enable`    | bool   | `true`     | Install zellij terminal multiplexer              |
| `uzumaki.stasysmo.enable`  | bool   | `false`    | Enable StaSysMo system monitoring                |

### Fish Functions

| Function     | Description                                                                   |
| ------------ | ----------------------------------------------------------------------------- |
| `pingt`      | Timestamped ping with color-coded output (yellow for timeout, red for errors) |
| `sourcefish` | Load `.env` file into current Fish session                                    |
| `stress`     | CPU stress test on all cores                                                  |
| `stasysmod`  | Toggle StaSysMo debug mode                                                    |
| `helpfish`   | Show all custom functions & abbreviations                                     |

---

## File Structure

```text
modules/uzumaki/
├── default.nix          # NixOS entry point (system-level)
├── home-manager.nix     # Home Manager entry point (macOS/user-level)
├── options.nix          # Module option definitions
├── common.nix           # Shared fish function definitions (legacy)
├── server.nix           # Direct import for NixOS servers (legacy)
├── desktop.nix          # Direct import for NixOS desktops (legacy)
├── macos.nix            # Direct import for macOS (legacy)
├── macos-common.nix     # macOS-specific: WezTerm, fonts, packages
├── fish/
│   ├── default.nix      # Fish module exports
│   ├── config.nix       # Aliases & abbreviations
│   └── functions.nix    # Fish function definitions
├── theme/
│   ├── theme-hm.nix           # Home Manager theme module
│   ├── theme-palettes.nix     # Color palette definitions per host
│   ├── starship-template.toml # Template with color placeholders
│   ├── starship.toml          # Legacy starship config
│   └── eza-themes/
│       └── tokyonight-uzumaki.yml  # Tokyo Night Uzumaki eza theme
└── stasysmo/
    ├── README.md              # Detailed StaSysMo documentation
    ├── config.nix             # Centralized configuration
    ├── daemon.sh              # Background metrics daemon
    ├── reader.sh              # Starship custom module reader
    ├── icons.sh               # Nerd Font icons (Python-generated)
    ├── nixos.nix              # NixOS systemd service
    └── home-manager.nix       # Home Manager launchd service
```

### Legacy vs Module Usage

The `server.nix`, `desktop.nix`, and `macos.nix` files are **legacy direct imports** for hosts not yet migrated to the option-based system. New hosts should use the module pattern (`uzumaki.enable = true;`).

---

## ⚠️ Catppuccin Override (Tokyo Night)

### Background

The external hokage module includes Catppuccin theming by default. Uzumaki provides Tokyo Night theming instead for consistent per-host coloring.

### Disabling Catppuccin

Set in host configurations:

```nix
hokage = {
  catppuccin.enable = false;  # Disable Catppuccin, use Tokyo Night
};
```

### What We Override

| Component    | Hokage Default            | Our Override (Tokyo Night) | File                 |
| ------------ | ------------------------- | -------------------------- | -------------------- |
| **Starship** | (disabled via catppuccin) | Per-host gradient colors   | `theme/theme-hm.nix` |
| **Eza**      | (disabled via catppuccin) | Tokyo Night Uzumaki theme  | `theme/theme-hm.nix` |
| **Zellij**   | ⚠️ **NOT disabled**       | Per-host accent colors     | `theme/theme-hm.nix` |
| **WezTerm**  | (not themed by hokage)    | Tokyo Night                | `macos-common.nix`   |
| **Helix**    | (no override needed)      | `tokyonight_storm`         | `common.nix`         |
| **bat**      | (disabled via catppuccin) | `tokyonight_night`         | `theme/theme-hm.nix` |
| **fzf**      | (disabled via catppuccin) | Tokyo Night colors         | `theme/theme-hm.nix` |
| **lazygit**  | (disabled via catppuccin) | Tokyo Night theme          | `theme/theme-hm.nix` |

> **Note**: With `hokage.catppuccin.enable = false`, most workarounds are not needed.
> **Exception: Zellij** - hokage provides zellij config regardless of catppuccin setting,
> so `lib.mkForce` is still required for zellij source.

---

## 🔧 Zellij Configuration

### Hokage Zellij Disabled

We completely disable hokage's zellij module to use our own config:

```nix
programs = {
  zellij = {
    enable = lib.mkForce false;
    settings = lib.mkForce { };
    enableFishIntegration = lib.mkForce false;
    enableBashIntegration = lib.mkForce false;
  };
};
```

Our theme config in `theme/theme-hm.nix` then provides the zellij configuration:

```nix
home.file.".config/zellij" = lib.mkIf config.theme.zellij.enable {
  # lib.mkForce REQUIRED: hokage provides zellij config regardless of catppuccin setting
  source = lib.mkForce (pkgs.writeTextDir "config.kdl" (mkZellijConfig palette hostname));
  recursive = true;
};
```

### ⚠️ Manual Step on First Deploy

When migrating from hokage's zellij to our themed config, you MUST manually remove the old symlinked directory **once**:

```bash
rm -rf ~/.config/zellij
sudo nixos-rebuild switch --flake .#hostname
```

---

## Theme System

### DRY Architecture

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                              DRY Architecture                               │
│                                                                             │
│    hosts/imac0/home.nix                                                     │
│         │                                                                   │
│         │ imports                                                           │
│         ▼                                                                   │
│    modules/uzumaki/theme/theme-hm.nix ──► theme.hostname = "imac0"          │
│         │                                       │                           │
│         │ reads                                 │ lookup                    │
│         ▼                                       ▼                           │
│    ┌────────────────────────┐          hostPalette.imac0 = "warmGray"       │
│    │ starship-template.toml │                   │                           │
│    │ (Unicode glyphs +      │                   │                           │
│    │  color placeholders)   │                   │                           │
│    └────────────────────────┘                   │                           │
│         │                                       │                           │
│         │ builtins.replaceStrings               │                           │
│         ▼                                       ▼                           │
│    theme/theme-palettes.nix ──────────► palettes.lightGray = { ... }        │
│                                                 │                           │
│                                                 ▼                           │
│    ┌─────────────────────────────────────────────────────────────────────┐  │
│    │                    Auto-Generated Configs                           │  │
│    │                                                                     │  │
│    │  ~/.config/starship.toml    (powerline, status, Unicode preserved)  │  │
│    │  ~/.config/zellij/config.kdl (theme, keybindings)                   │  │
│    │  ~/.config/eza/theme.yml    (Tokyo Night Uzumaki)                   │  │
│    └─────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key Points:**

- Unicode characters are preserved because they live in `starship-template.toml`
- Only ASCII color placeholders (`__PRIMARY__`, `__LIGHTEST__`, etc.) are substituted
- One palette definition in `theme-palettes.nix` → three auto-generated configs
- Add a new host: just add one line to `hostPalette` mapping
- **Directory path text is pure white (`#ffffff`)** across all palettes for maximum contrast

### Color Placeholders

| Placeholder            | Source in theme-palettes.nix |
| ---------------------- | ---------------------------- |
| `__LIGHTEST__`         | `palette.gradient.lightest`  |
| `__PRIMARY__`          | `palette.gradient.primary`   |
| `__SECONDARY__`        | `palette.gradient.secondary` |
| `__MIDDARK__`          | `palette.gradient.midDark`   |
| `__DARK__`             | `palette.gradient.dark`      |
| `__DARKER__`           | `palette.gradient.darker`    |
| `__DARKEST__`          | `palette.gradient.darkest`   |
| `__TEXT_ON_LIGHTEST__` | `palette.text.onLightest`    |
| `__TEXT_ON_MEDIUM__`   | `palette.text.onMedium`      |
| `__TEXT_ACCENT__`      | `palette.text.accent`        |
| `__TEXT_MUTED__`       | `palette.text.muted`         |
| `__TEXT_MUTED_LIGHT__` | `palette.text.mutedLight`    |
| `__ROOT_BG__`          | `statusColors.root.bg`       |
| `__ROOT_FG__`          | `statusColors.root.fg`       |
| `__ERROR_BG__`         | `statusColors.error.bg`      |
| `__ERROR_FG__`         | `statusColors.error.fg`      |
| `__SUDO_FG__`          | `statusColors.sudo.fg`       |

---

## Eza Theme (Tokyo Night Uzumaki)

### Design Philosophy

```text
┌─────────────────────────────────────────────────────────────────┐
│  HIGH VISIBILITY (stand out immediately):                       │
│    • Executables    - Bold green         - "Can I run this?"    │
│    • Directories    - Bold blue          - Navigation targets   │
│    • Setuid/Setgid  - Bold warning       - Security concern!    │
│    • Broken links   - Bold red           - Fix this!            │
│    • Large files    - Bold (GB+)         - Disk space awareness │
│                                                                 │
│  MEDIUM VISIBILITY (noticeable when looking):                   │
│    • Symlinks       - Cyan               - Distinct but subtle  │
│    • Git modified   - Yellow/amber       - What changed?        │
│    • Compressed     - Orange             - Archives noticeable  │
│                                                                 │
│  LOW VISIBILITY (background info, not distracting):             │
│    • Permissions    - Subtle colors      - Readable but muted   │
│    • Timestamps     - Very muted         - Reference info       │
│    • User/group     - Muted              - Usually unimportant  │
│    • Small files    - Muted sizes        - Not a concern        │
│    • Temp/compiled  - Dim                - Build artifacts      │
└─────────────────────────────────────────────────────────────────┘
```

Theme file: `theme/eza-themes/tokyonight-uzumaki.yml`

---

## StaSysMo - System Monitoring

StaSysMo displays system metrics (CPU, RAM, Load, Swap) in your Starship prompt with threshold-based coloring.

```text
Prompt: C 5% M 52% L 1.2 S 2%
        (icons render as Nerd Font glyphs)
```

See [stasysmo/README.md](stasysmo/README.md) for detailed documentation.

### Quick Enable

```nix
uzumaki.stasysmo.enable = true;
```

---

## ⚠️ CRITICAL: Editing starship-template.toml

**DO NOT edit with heredocs, echo, or manual typing of Unicode characters!**

The file contains Nerd Font Unicode glyphs that get corrupted easily.

### ✅ Safe Ways to Edit

1. **Use sed for simple ASCII value changes:**

   ```bash
   sed -i '' 's/truncation_length = 3/truncation_length = 0/' starship-template.toml
   ```

2. **Use Python for Unicode-safe edits:**

   ```python
   with open('starship-template.toml', 'r') as f:
       content = f.read()
   content = content.replace('old', 'new')
   with open('starship-template.toml', 'w') as f:
       f.write(content)
   ```

### ❌ DO NOT

- Use `cat << 'EOF'` heredocs (corrupts Unicode)
- Manually type Nerd Font icons (they won't render correctly)
- Copy/paste from web browsers (encoding issues)
- Use `echo` to write the file

---

## Prerequisites

- **Nerd Font** installed (Hack Nerd Font Mono recommended)
- **Terminal** configured to use the Nerd Font (WezTerm, Ghostty, etc.)

### Testing Icons

```bash
python3 -c "
icons = [
    ('\ue0b0', 'Powerline arrow'),
    ('\uf179', 'Apple'),
    ('\uf313', 'NixOS'),
    ('\ue725', 'Git branch'),
    ('\ue73c', 'Python'),
]
for char, name in icons:
    print(f'{char} = {name}')
"
```

---

## macos-common.nix

Provides macOS-specific configuration:

- WezTerm configuration (Tokyo Night theme, Hack Nerd Font)
- Font installation activation script
- Common macOS packages
- Nano configuration

Used by macOS Home Manager configurations.
