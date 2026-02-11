# zsh-dotdir-deprecation

**Host**: imac0
**Priority**: P91
**Status**: Backlog
**Created**: 2026-01-13

---

## Problem

Home Manager showing deprecation warning for `programs.zsh.dotDir`. Warning appears twice during `home-manager switch` for imac0.

## Solution

Explicitly set `programs.zsh.dotDir` to either keep legacy behavior (home directory) or adopt new XDG behavior (config directory).

## Implementation

- [ ] Evaluate options:
  - Option A: Keep legacy - `programs.zsh.dotDir = config.home.homeDirectory;`
  - Option B: Adopt XDG - `programs.zsh.dotDir = "${config.xdg.configHome}/zsh";`
- [ ] Decide which option (recommendation: keep legacy for now)
- [ ] Update imac0 home-manager configuration with explicit setting
- [ ] Run `just switch` and verify warning gone
- [ ] Test zsh functionality unchanged

## Acceptance Criteria

- [ ] Decision made on legacy vs XDG
- [ ] Configuration updated with explicit `programs.zsh.dotDir`
- [ ] Warning no longer appears during home-manager switch
- [ ] Zsh configuration functions normally

## Notes

- Warning message: `programs.zsh.dotDir` default will change in future
- Current: Using legacy default (home directory) due to `home.stateVersion` < "26.05"
- Priority: 🟢 Low (cosmetic warning, no functional impact)
