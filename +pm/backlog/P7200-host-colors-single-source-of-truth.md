# P7200 - Host Colors: Single Source of Truth

**Priority**: P7200 (Low - Infrastructure Polish)  
**Status**: Backlog  
**Effort**: Phase 1: Low (1-2h) | Phase 2: High (8-16h)

---

## Summary

Consolidate host color management so:

1. **Single source of truth**: `theme-palettes.nix` defines all colors
2. **Auto-propagation**: Colors flow to starship, zellij, AND nixfleet dashboard
3. **Dashboard-editable** (future): Change colors via NixFleet UI → writes to nixcfg

---

## Current Architecture (What Works)

```
theme-palettes.nix
    │
    │ hostPalette.hsb0 = "yellow"
    │ palettes.yellow.gradient.primary = "#d4c060"
    │
    ▼
theme-hm.nix (auto-detects hostname, looks up palette)
    │
    ├──► starship.toml (yellow prompt segments) ✅
    ├──► zellij/config.kdl (yellow frame) ✅
    └──► eza theme ✅
```

**This works perfectly.** Each host has its distinct color in terminal.

---

## Current Gap (What's Broken)

```
theme-palettes.nix
    │
    │ (NO CONNECTION)
    │
    ▼
services.nixfleet-agent.themeColor = "" (not set!)
    │
    ▼
Agent fallback (hub.go:573-579):
    - NixOS → #7aa2f7 (blue)
    - macOS → #bb9af7 (purple)
    │
    ▼
Dashboard shows ALL NixOS hosts as blue, ALL macOS as purple ❌
```

**The nixfleet-agent config exists** (`themeColor` option in shared.nix), but **no host sets it**, and **uzumaki doesn't wire it**.

---

## Phase 1: Auto-Wire Colors (Immediate Fix)

### Goal

Wire `palette.gradient.primary` → `services.nixfleet-agent.themeColor` automatically.

### Implementation Options

**Option A: In theme-hm.nix (Home Manager only)**

```nix
# In theme-hm.nix config section:
services.nixfleet-agent.themeColor = lib.mkIf
  (config.services.nixfleet-agent.enable or false)
  palette.gradient.primary;
```

**Pros**: DRY, automatic for all Home Manager hosts  
**Cons**: Only works for macOS/Linux Home Manager, not NixOS system-level

**Option B: In a shared uzumaki module (NixOS + HM)**

Create a small module that wires the color for both NixOS and Home Manager.

**Option C: In each host config (manual, not recommended)**

```nix
services.nixfleet-agent = {
  themeColor = "#d4c060";  # Must match theme-palettes.nix manually
};
```

**Cons**: Violates single source of truth, error-prone

### Recommended Approach

**Option A** for now (Home Manager covers all macOS + gpc0).  
Add NixOS module later if needed for server colors.

### Acceptance Criteria (Phase 1)

- [ ] `theme-hm.nix` auto-populates `themeColor` from palette
- [ ] Dashboard shows distinct colors per host
- [ ] No manual `themeColor` setting required in host configs
- [ ] Hosts without uzumaki still work (use fallback colors)

---

## Phase 2: Dashboard-Editable Colors (Future Feature)

### Goal

Allow changing host colors via NixFleet dashboard UI, with changes persisted to nixcfg.

### User Flow

```
1. User opens NixFleet dashboard
2. Clicks host row → Settings → "Theme Color"
3. Picks new color from palette or color picker
4. Clicks "Apply"
5. NixFleet creates PR / commits to nixcfg
6. User merges / auto-deploys
7. Next rebuild: prompt, zellij, AND dashboard use new color
```

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     NixFleet Dashboard                          │
│  ┌──────────────┐                                               │
│  │ Color Picker │ ──► API: POST /hosts/{name}/settings         │
│  └──────────────┘                                               │
└────────────────────────────────────────────────────────────────-┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                    NixFleet Backend                             │
│  1. Clone nixcfg repo (if not already)                          │
│  2. Parse theme-palettes.nix                                    │
│  3. Update hostPalette.{hostname} = "newPalette"               │
│     OR create new palette if custom color                       │
│  4. Commit with message: "theme(hsb0): change color to blue"   │
│  5. Push to branch / create PR                                  │
└─────────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                      GitHub / nixcfg                            │
│  PR: "theme(hsb0): change color to blue"                       │
│  Modified: modules/uzumaki/theme/theme-palettes.nix            │
└─────────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                      On Next Rebuild                            │
│  - Starship uses new color                                      │
│  - Zellij uses new color                                        │
│  - Agent reports new color                                      │
│  - Dashboard shows new color                                    │
└─────────────────────────────────────────────────────────────────┘
```

### Design Decisions

| Question                      | Decision                                                                      |
| ----------------------------- | ----------------------------------------------------------------------------- |
| How to pick colors?           | **Full color picker** + existing palette presets                              |
| Where to store custom colors? | New palette entry in theme-palettes.nix (auto-generate gradient from primary) |
| How to modify nixcfg?         | NixFleet already has repo access (isolated clone), can commit                 |
| PR or direct push?            | **Both supported**, controlled by `ColorCommitMode` setting                   |
| How to name custom palettes?  | `custom-{hostname}` (e.g., `custom-hsb0`)                                     |

### Settings (Code-Only for Now)

```go
// In settings or config (not exposed in UI yet)
type ColorSettings struct {
    // "pr" = create pull request, "push" = direct push to main
    ColorCommitMode string `json:"colorCommitMode" default:"pr"`
}
```

Future P6400 (Settings Page) will expose this in UI.

### Color Picker UI

```
┌─────────────────────────────────────────────────┐
│  Host Theme Color                               │
├─────────────────────────────────────────────────┤
│                                                 │
│  Presets:                                       │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐    │
│  │ 🟡 │ │ 🟢 │ │ 🟠 │ │ 🔵 │ │ 🟣 │ │ 🩷 │    │
│  └────┘ └────┘ └────┘ └────┘ └────┘ └────┘    │
│  Yellow  Green Orange  Blue  Purple  Pink      │
│                                                 │
│  Custom:  ┌────────────────────┐               │
│           │ #d4c060            │ [🎨]          │
│           └────────────────────┘               │
│                                                 │
│  Preview: ░▒▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░▒▓     │
│                                                 │
│  [ Cancel ]                    [ Apply Color ]  │
└─────────────────────────────────────────────────┘
```

### Gradient Generation from Primary Color

When user picks a custom hex color, auto-generate the full gradient:

```nix
# Generated in theme-palettes.nix for custom colors
custom-hsb0 = {
  name = "Custom (hsb0)";
  category = "custom";
  description = "User-defined color for hsb0";

  gradient = {
    # Auto-calculated from primary (#ff6b6b example):
    lightest  = "#ffb3b3";  # primary + 30% lightness
    primary   = "#ff6b6b";  # USER INPUT
    secondary = "#cc5656";  # primary - 15% lightness
    midDark   = "#662b2b";  # primary - 50% lightness
    dark      = "#401b1b";  # primary - 65% lightness
    darker    = "#2d1313";  # primary - 75% lightness
    darkest   = "#1a0c0c";  # primary - 85% lightness
  };

  # Auto-calculated text colors
  text = {
    onLightest = "#1a0c0c";
    onMedium = "#000000";
    accent = "#ff8a8a";
    muted = "#401b1b";
    mutedLight = "#cc8080";
  };

  # Auto-calculated zellij colors
  zellij = { ... };
};

### Challenges

1. **Parsing Nix**: Need to parse/modify theme-palettes.nix (Nix syntax is non-trivial)
   - Option: Use `nix eval` to read, template to write
   - Option: Store colors in JSON, generate Nix from it

2. **Atomic updates**: What if multiple color changes conflict?
   - Use git branches, let user merge

3. **Validation**: Must generate valid Nix syntax
   - Test by evaluating before commit

### Acceptance Criteria (Phase 2)

- [ ] Dashboard shows **full color picker** + palette presets per host
- [ ] `ColorCommitMode` setting controls PR vs direct push (code-only for now)
- [ ] Custom colors auto-generate full gradient palette
- [ ] Selecting color creates commit/PR to nixcfg (based on setting)
- [ ] New `custom-{hostname}` palette created for custom colors
- [ ] Existing palette name used for preset colors
- [ ] Changes validate (`nix eval` succeeds) before commit
- [ ] Preview shows how gradient will look
- [ ] Rebuild propagates color to all consumers (starship, zellij, dashboard)

---

## Files Involved

| File | Role |
|------|------|
| `modules/uzumaki/theme/theme-palettes.nix` | **Source of truth** for palettes |
| `modules/uzumaki/theme/theme-hm.nix` | Wires palette → starship/zellij/eza |
| `nixfleet/modules/shared.nix` | Defines `themeColor` option |
| `nixfleet/v2/internal/dashboard/hub.go` | Fallback color logic |
| `hosts/*/home.nix` or `configuration.nix` | Host-specific overrides (if any) |

---

## Related Tasks

- **P2900** (nixfleet): Dashboard host theme colors display
- **P5200** (nixfleet): Declarative secrets (similar pattern: dashboard → nixcfg)
- **P6400** (nixfleet): Settings page (will expose `ColorCommitMode` setting)

---

## Notes

### Why Not Store Colors in NixFleet DB?

Colors need to be consistent across:
- Terminal prompt (starship)
- Terminal multiplexer (zellij)
- File listings (eza)
- SSH banners
- Dashboard

If dashboard stored colors separately, they'd drift from terminal colors. By writing to nixcfg, we ensure one source of truth for everything.

### Immediate Win

Phase 1 can ship independently and immediately fixes dashboard showing all hosts same color. Phase 2 is a nice-to-have for the future.
```
