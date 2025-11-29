# Shared Modules

This directory contains configuration files shared across all systems (NixOS servers and macOS workstations).

## Files

| File                     | Purpose                                                  | Used By                        |
| ------------------------ | -------------------------------------------------------- | ------------------------------ |
| `fish-config.nix`        | Fish shell aliases, abbreviations, `sourcefish` function | `common.nix`, `imac0/home.nix` |
| `macos-common.nix`       | macOS-specific: WezTerm, fonts, packages                 | `imac0`, `imac-mba-work`       |
| `starship.toml`          | Tokyo Night prompt theme (legacy)                        | Systems not using theme-hm.nix |
| `theme-palettes.nix`     | Color palette definitions per host                       | `theme-hm.nix`                 |
| `theme-hm.nix`           | Home Manager theme module (auto-applies palettes)        | `imac0`, etc.                  |
| `starship-template.toml` | Template with Unicode glyphs + color placeholders        | `theme-hm.nix`                 |

---

## theme-hm.nix & starship-template.toml

### How the Template System Works

The theme module uses a **template-based approach** to preserve Unicode/Nerd Font characters:

1. `starship-template.toml` contains the full starship config with:
   - All Unicode/Nerd Font glyphs intact (✦, ❯, ✗, , , etc.)
   - Color placeholders like `__PRIMARY__`, `__LIGHTEST__`, `__TEXT_ACCENT__`

2. `theme-hm.nix` reads the template and uses `builtins.replaceStrings` to substitute
   ONLY the ASCII color placeholders with actual hex values from the palette.

3. This preserves all Unicode because we never write them in Nix strings.

### DRY Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              DRY Architecture                               │
│                                                                             │
│    hosts/imac0/home.nix                                                     │
│         │                                                                   │
│         │ imports                                                           │
│         ▼                                                                   │
│    modules/shared/theme-hm.nix ──────► theme.hostname = "imac0"             │
│         │                                       │                           │
│         │ reads                                 │ lookup                    │
│         ▼                                       ▼                           │
│    ┌────────────────────────┐          hostPalette.imac0 = "lightGray"      │
│    │ starship-template.toml │                   │                           │
│    │ (Unicode glyphs +      │                   │                           │
│    │  color placeholders)   │                   │                           │
│    └────────────────────────┘                   │                           │
│         │                                       │                           │
│         │ builtins.replaceStrings               │                           │
│         ▼                                       ▼                           │
│    modules/shared/theme-palettes.nix ──► palettes.lightGray = { ... }       │
│                                                 │                           │
│                                                 │                           │
│                                                 ▼                           │
│    ┌─────────────────────────────────────────────────────────────────────┐  │
│    │                    Auto-Generated Configs                           │  │
│    │                                                                     │  │
│    │  ~/.config/starship.toml    (powerline, status, Unicode preserved)  │  │
│    │  ~/.config/zellij/config.kdl (theme, keybindings)                   │  │
│    │  ~/.config/eza/theme.yml    (sysop-focused colors)                  │  │
│    └─────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Key Points:**

- Unicode characters are preserved because they live in `starship-template.toml`
- Only ASCII color placeholders (`__PRIMARY__`, `__LIGHTEST__`, etc.) are substituted
- One palette definition in `theme-palettes.nix` → three auto-generated configs
- Add a new host: just add one line to `hostPalette` mapping
- Eza colors are universal (same polished theme for all hosts)
- **Directory path text is pure white (`#ffffff`)** across all palettes for maximum contrast

### ⚠️ CRITICAL: Editing starship-template.toml

**The same rules as starship.toml apply here!**

- ✅ Use Python for Unicode character edits
- ✅ Use sed for simple ASCII value changes
- ❌ DO NOT use heredocs or echo
- ❌ DO NOT manually type Nerd Font icons

### Color Placeholders in Template

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

## Eza Theme (Tokyo Night + Sysop)

Eza uses a **theme file** at `~/.config/eza/theme.yml` instead of the `EZA_COLORS` variable.

### Base Theme

Based on [Tokyo Night from eza-themes](https://github.com/eza-community/eza-themes/blob/main/themes/tokyonight.yml)
with sysop-focused modifications.

### Source File

`modules/shared/eza-themes/sysop.yml`

### Design Philosophy

```
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

### Key Modifications from Tokyo Night

| Item              | Tokyo Night | Sysop Override  | Reason                   |
| ----------------- | ----------- | --------------- | ------------------------ |
| Executables       | Green       | **Bold** green  | Critical for sysops      |
| Directories       | Blue        | **Bold** blue   | Navigation targets       |
| User execute perm | Green       | **Bold** green  | "x" bit must stand out   |
| GB+ file sizes    | Orange      | **Bold** orange | Disk space awareness     |
| Broken symlinks   | Pink        | **Bold** pink   | Errors need attention    |
| Setuid files      | Pink        | **Bold** pink   | Security concern         |
| Git modified      | Purple      | Yellow/amber    | Match git conventions    |
| Dates             | Orange      | Muted gray      | Less important           |
| Byte sizes        | Gray        | Very muted      | Small files don't matter |

### Testing

```bash
ll                          # Should show Tokyo Night colors
ll -la /usr/bin             # Check bold executables
cat ~/.config/eza/theme.yml # View theme file
```

---

## starship.toml (Legacy)

### ⚠️ CRITICAL: Editing Rules

**DO NOT edit this file with heredocs, echo, or manual typing of Unicode characters!**

The file contains Nerd Font Unicode glyphs that get corrupted easily.

### ✅ Safe Ways to Edit

1. **Use the official preset as base:**

   ```bash
   starship preset tokyo-night -o ~/.config/starship.toml
   ```

2. **Make surgical edits with sed (simple values only):**

   ```bash
   sed -i '' 's/truncation_length = 3/truncation_length = 0/' ~/.config/starship.toml
   ```

3. **Use Python for Unicode-safe edits:**

   ```python
   with open('starship.toml', 'r') as f:
       content = f.read()
   content = content.replace('old', 'new')
   with open('starship.toml', 'w') as f:
       f.write(content)
   ```

4. **Add new sections by appending (with Python for symbols):**
   ```python
   new_section = '''
   [python]
   symbol = "\ue73c"
   '''
   content += new_section
   ```

### ❌ DO NOT

- Use `cat << 'EOF'` heredocs (corrupts Unicode)
- Manually type Nerd Font icons (they won't render correctly)
- Copy/paste from web browsers (encoding issues)
- Use `echo` to write the file

### Features

| Feature         | Description                                       |
| --------------- | ------------------------------------------------- |
| Dynamic OS icon | Shows on Mac, on NixOS, on Linux                  |
| Full path       | No truncation, always shows complete path         |
| Git info        | Branch, status, commit count (#2329)              |
| Languages       | Node.js, Python, Rust, Go, PHP                    |
| Docker          | Shows context when in Docker project              |
| Time            | **Always right-aligned**, with seconds (19:14:20) |
| Nix shell       | Subtle segment after time (❄ impure/pure)        |

### Layout

```
Left side                              $fill                    Right side
░▒▓ [OS] [path] [git] [langs]  ←────────────────────→  [time] [❄ nix]
#a3aed2  #769ff0 #394260 #212736                         #1d2230  #13161f
brightest ────────────────────────────────────────────────────► darkest
```

- Uses `$fill` to push time to the right edge
- Nix shell is a subtle, darker segment (muted gray text `#5a6070`)

### Prerequisites

- **Nerd Font** installed (Hack Nerd Font Mono recommended)
- **WezTerm** configured to use the Nerd Font
- No conflicting plain Hack fonts in `~/Library/Fonts/`

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

## fish-config.nix

Provides:

- `sourcefish` function - Load .env files into fish session
- `EDITOR=nano` - Default editor
- Common aliases and abbreviations

Used via `programs.fish.interactiveShellInit` in `common.nix`.

---

## macos-common.nix

Provides:

- WezTerm configuration (Tokyo Night theme, Hack Nerd Font)
- Font installation activation script
- Common macOS packages
- Nano configuration

Used by macOS Home Manager configurations.
