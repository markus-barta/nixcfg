# P8500: Attic Cache Script - Cleanup and Adaptation

**Created**: 2026-01-08  
**Priority**: P8500 (Low - Backlog)  
**Status**: Backlog  
**Depends on**: None

---

## Problem

The script `scripts/push-all-to-attic.sh` exists but:

1. May not be adapted to current infrastructure
2. Needs cleanup or verification it works correctly
3. Attic cache configuration may need updating

Current script pushes derivations from `/run/current-system/sw/bin` and `/sbin` to `cicinas2:nix-store`.

---

## Solution

Review and either:

1. **Clean up**: Remove if deprecated/no longer needed
2. **Adapt**: Update for current infra and document usage
3. **Integrate**: Add to deployment workflow or CI/CD

---

## Acceptance Criteria

- [ ] Script reviewed for current relevance
- [ ] Either cleaned up OR adapted with documentation
- [ ] If kept: tested and verified working
- [ ] If removed: documented why in commit message

---

## Investigation Tasks

### 1. Determine Current State

- [ ] Check if `attic` command is available on hosts
- [ ] Verify `cicinas2` cache still exists/accessible
- [ ] Check if script is referenced anywhere in codebase
- [ ] Review git history for last usage

### 2. Evaluate Need

- [ ] Is Attic still used for binary caching?
- [ ] What's the current binary cache strategy?
- [ ] Are there better alternatives (nixos-binary-cache, cachix, etc.)?

### 3. Action Based on Findings

**Option A: Keep and Adapt**

- Update cache name if needed
- Add to deployment checklist
- Document when/how to run
- Test on a host

**Option B: Remove**

- Delete script
- Update any docs referencing it
- Add note to README about cache strategy

---

## Test Plan

### If Keeping:

```bash
# Test on gpc0 or hsb0
cd ~/Code/nixcfg
./scripts/push-all-to-attic.sh
# Verify packages appear in attic cache
```

### If Removing:

```bash
# Verify no references
grep -r "push-all-to-attic" .
grep -r "attic push" .
```

---

## Related

- **Infrastructure**: Binary caching strategy
- **Deployment**: Could be part of post-deploy checklist
- **Performance**: Affects build times on other hosts
