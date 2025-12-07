# 2025-12-01 - CI/CD Pipeline Improvements (Optional)

## Description

Optional improvements for the CI/CD pipeline after the urgent hostname fix.

## What Was Already Fixed ✅

- [x] Updated `check.yml` with correct hostnames (hsb0, hsb1, hsb8, gpc0, csb0, csb1)
- [x] Disabled broken `format-check.yml` (uses non-existent `prek` command)

See `.pm/done/2025-12-01-cicd-hostname-fix.md` for details.

## Optional Improvements (Low Priority)

- [ ] Make host list dynamic (auto-detect from flake.nix)
- [ ] Re-enable format check with proper pre-commit setup
- [ ] Add path filters to reduce unnecessary CI runs
- [ ] Update `docs/CI-CD-PIPELINE.md` with current state

## Notes

- **Priority**: Low - urgent issues fixed, these are nice-to-haves
- Local pre-commit hooks already handle formatting
- Dynamic host list would prevent future hostname drift
