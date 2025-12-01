# 2025-12-01 - Catppuccin Follows Cleanup in flake.nix

## Description

Remove catppuccin follows from flake.nix once all hosts are updated to use Tokyo Night theming via theme-hm.nix.

## Source

- Original: `modules/shared/README.md`
- Note: "Still needed: Keep the catppuccin follows in flake.nix until all hosts are updated"

## Scope

Applies to: flake.nix and all hosts using theming

## Acceptance Criteria

- [ ] Audit which hosts still use catppuccin theming
- [ ] Migrate remaining hosts to Tokyo Night (or confirm they use hokage.catppuccin.enable = false)
- [ ] Remove catppuccin follows from flake.nix
- [ ] Verify all hosts build correctly
- [ ] Update documentation in modules/shared/README.md

## Notes

- Blocked by: All hosts need to be using theme-hm.nix or have catppuccin disabled
- gpc0 already has `hokage.catppuccin.enable = false` set
- External hokage consumers may need this setting explicitly
