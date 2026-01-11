# Migrate macOS Hosts to nix-darwin

**Created**: 2025-12-16
**Priority**: P8 (Backlog)
**Effort**: Medium-High
**Hosts**: imac0, mba-mbp-work, mba-imac-work

---

## Problem

Currently macOS hosts use **home-manager only** (not nix-darwin). This was a deliberate choice for simplicity and macOS upgrade safety.

However, this means we can't:

- Declaratively manage Homebrew packages (taps, formulae, casks)
- Manage system-level macOS settings via Nix
- Have a unified rebuild command (`darwin-rebuild switch`)

**Current workaround**: Manual `brew install` for packages like `tw93/tap/mole`.

---

## Proposed Solution

Migrate to nix-darwin while keeping the current home-manager configs as modules.

### Benefits

| Feature               | Current (HM only)             | With nix-darwin         |
| --------------------- | ----------------------------- | ----------------------- |
| Homebrew management   | Manual                        | Declarative             |
| macOS system settings | Manual                        | Declarative             |
| Rebuild command       | `home-manager switch`         | `darwin-rebuild switch` |
| Fish as default shell | Manual `/etc/shells` + `chsh` | Automatic               |

### Example nix-darwin Homebrew config

```nix
homebrew = {
  enable = true;
  onActivation.cleanup = "zap";  # Remove unlisted packages

  taps = [
    "tw93/tap"
  ];

  brews = [
    "mole"
    # Other CLI tools better suited for brew
  ];

  casks = [
    "karabiner-elements"
    "cursor"
    # Other GUI apps
  ];
};
```

---

## Acceptance Criteria

- [ ] Research nix-darwin + existing home-manager integration
- [ ] Test on one Mac first (mba-mbp-work - least critical)
- [ ] Migrate Homebrew packages to declarative config
- [ ] Verify macOS upgrades don't break the setup
- [ ] Update all three Mac hosts
- [ ] Update documentation

---

## Risks

- **macOS upgrades**: nix-darwin touches system files, upgrades might break things
- **Complexity**: More moving parts than pure home-manager
- **Migration effort**: Need to audit all three Macs' Homebrew packages

---

## References

- [nix-darwin](https://github.com/LnL7/nix-darwin)
- [nix-darwin Homebrew module](https://daiderd.com/nix-darwin/manual/index.html#opt-homebrew.enable)
- Current rationale: `hosts/imac0/README.md` → "Why home-manager (not nix-darwin)?"

---

## Notes

Triggered by wanting to install `tw93/tap/mole` declaratively instead of manual `brew install`.

---

## 📌 Relationship to Secrets Management

**Important**: This task is **NOT required** for secrets management.

- **P5950** (workstation secrets) works with home-manager only
- **P8100** (nix-darwin) is separate infrastructure decision
- Secrets architecture is independent of nix-darwin migration

**Recommendation**: Defer P8100 unless you have a specific blocker that requires nix-darwin.
