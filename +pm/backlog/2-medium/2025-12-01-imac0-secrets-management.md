# 2025-12-01 - imac0 Age-based Secrets Management

## Description

Implement Age-based secrets management for ~/Secrets directory on imac0 (macOS).

## Source

- Original: `hosts/imac0/docs/todo-secrets-management.md`
- Status at extraction: Full TODO plan documented

## Scope

Applies to: imac0 (macOS workstation)

## Acceptance Criteria

- [ ] Review the detailed plan in `hosts/imac0/docs/todo-secrets-management.md`
- [ ] Set up agenix for macOS/nix-darwin
- [ ] Create age secrets for sensitive files in ~/Secrets
- [ ] Configure home-manager to decrypt secrets
- [ ] Test secrets are accessible after nix-darwin rebuild
- [ ] Document the setup for future reference

## Notes

- This is for a macOS host using nix-darwin + home-manager
- May require different approach than NixOS agenix setup
- See detailed plan in the source document
