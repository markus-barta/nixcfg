# 2025-12-06 - Scripts Directory Audit

## Description

Analyze the scripts in `scripts/` directory to determine if they are still needed and should be maintained, updated, or removed.

## Scripts to Audit

### `update-qownnotes-release.sh`

- **Purpose**: Updates QOwnNotes package version and hash in `pkgs/qownnotes/package.nix`
- **Dependencies**: `gum`, `curl`, `jq`, `nix-prefetch-url`, `nix hash convert`, `sed`
- **Questions**:
  - [ ] Is this still used for updating QOwnNotes?
  - [ ] Could this be replaced with `nix flake update` or similar?
  - [ ] Should it be a just recipe instead?

### `update-nixbit-release.sh`

- **Purpose**: Updates Nixbit package version and hash in `pkgs/nixbit/package.nix`
- **Dependencies**: `gum`, `curl`, `jq`, `nix flake prefetch`, `sed`
- **Questions**:
  - [ ] Is this still used for updating Nixbit?
  - [ ] Could this be replaced with `nix flake update` or similar?
  - [ ] Should it be a just recipe instead?

### `push-all-to-attic.sh`

- **Purpose**: Pushes all derivations of the current NixOS generation to attic cache (`cicinas2:nix-store`)
- **Dependencies**: `find`, `readlink`, `attic`
- **Questions**:
  - [ ] Is the attic cache `cicinas2:nix-store` still in use?
  - [ ] Is this being run manually or as part of CI/CD?
  - [ ] Should this be integrated into the justfile?

## Scope

Applies to: Repository maintenance

## Acceptance Criteria

- [ ] Document the current usage of each script
- [ ] Determine if each script is actively used
- [ ] For used scripts: update, document, or integrate into justfile
- [ ] For unused scripts: archive or remove
- [ ] Update any related documentation

## Notes

- These scripts use external tools (`gum`, `attic`) that may need to be available
- Consider consolidating functionality into justfile recipes for discoverability
- The `runbook-secrets.sh` script is also in this directory but is newly added (untracked)
