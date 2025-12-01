# 2025-12-01 - CI/CD Pipeline Fixes

## Description

Fix issues in the CI/CD pipeline as documented in docs/CI-CD-PIPELINE.md.

## Source

- Original: `docs/CI-CD-PIPELINE.md`
- Status at extraction: Multiple phases of fixes listed

## Scope

Applies to: Repository CI/CD workflows

## Acceptance Criteria

- [ ] Fix format command (prek → pre-commit typo if applicable)
- [ ] Update check workflow to only check active hosts (exclude archived)
- [ ] Review and implement other phases listed in CI-CD-PIPELINE.md
- [ ] Verify pipeline runs successfully
- [ ] Update documentation with current state

## Notes

- Check the CI-CD-PIPELINE.md for full list of planned improvements
- May involve updates to .github/workflows/ files
- Consider which hosts should be included in CI checks
