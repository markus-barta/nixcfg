# 2025-12-01 - Create Standalone pingt Package

## Description

Create a standalone Nix package for the `pingt` fish function (timestamped ping with color-coded output).

## Source

- Original: Memory/backlog item
- Currently defined in: `modules/uzumaki/fish/functions.nix` (previously `modules/uzumaki/common.nix`)
- Used by: `modules/uzumaki/default.nix` (via `fish/default.nix`)

## Scope

Applies to: Package could be shared or upstreamed

## Acceptance Criteria

- [ ] Create package definition in `pkgs/pingt/`
- [ ] Package provides `pingt` command
- [ ] Maintains current functionality (timestamped ping with color-coded output)
- [ ] Update uzumaki modules to use the package instead of inline definition
- [ ] Test on both server and desktop hosts
- [ ] Document the package

## Notes

- Currently implemented as a fish function
- Should work as a standalone command callable from any shell
- Consider if it should be a fish-specific package or a general script
