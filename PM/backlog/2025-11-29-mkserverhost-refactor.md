# 2025-11-29 - Refactor mkServerHost Helper (Optional)

## Description

Consider refactoring the mkServerHost helper to support external hokage consumer pattern directly, or deprecate it as hosts migrate.

## Source

- Original: `hosts/hsb8/docs/📋 BACKLOG.md` (Low Priority - Optional)

## Scope

Applies to: flake.nix, all hosts using mkServerHost

## Acceptance Criteria

- [ ] Audit which hosts still use mkServerHost
- [ ] Decide: Enhance mkServerHost or deprecate entirely
- [ ] If enhancing: Update to support external hokage pattern
- [ ] If deprecating: Migrate remaining hosts to explicit nixosSystem
- [ ] Update documentation

## Notes

- Low priority - Optional refactor
- May become irrelevant as hosts migrate to explicit external hokage pattern
- Currently: hsb0, hsb8, gpc0, csb1 use explicit pattern; others may still use mkServerHost
- Consider maintaining mkServerHost for future new hosts if pattern is useful
