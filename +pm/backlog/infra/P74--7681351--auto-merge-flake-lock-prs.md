# Auto-Merge flake.lock Update PRs

**Priority**: P7 (Low)  
**Status**: DONE  
**Created**: 2025-12-28  
**Completed**: 2025-12-28

## Problem

The `update-flake-lock.yml` workflow creates a PR every Sunday for flake.lock updates, but requires manual merging. This leads to:

- PRs piling up and getting stale (PR #3 was 2 weeks old)
- Merge conflicts with other automated commits (e.g., nixfleet bumps)
- User friction ("I'm not proficient in Git, it has to work automatically")

## Current State

| Workflow            | Creates PR? | Auto-commits? | User action needed? |
| ------------------- | ----------- | ------------- | ------------------- |
| `update-nixfleet`   | No          | ✅ Yes        | None                |
| `update-flake-lock` | ✅ Yes      | No            | Manual merge        |

## What Happened (2025-12-28)

1. PR #3 was open since 2025-12-14 (flake.lock updates)
2. Multiple `nixfleet` auto-commits happened in parallel
3. PR #3 had merge conflicts in `flake.lock`
4. Manually resolved by:
   - Checked out PR branch
   - Ran `nix flake update` to get latest everything
   - Committed merge resolution
   - Merged PR

Git history shows the pattern:

```
91aacf07 Merge pull request #3 from markus-barta/update_flake_lock_action
660d5f7c flake: update all inputs to latest (resolve merge conflict)
176e721a chore: bump nixfleet to v3.1.1 (213f261)
1fb434c8 chore: bump nixfleet to v3.1.1 (b55ec20)
514a28a1 chore: bump nixfleet to v3.1.0 (0661d09)
...
```

## Solution Options

### Option A: Enable GitHub Auto-Merge (Recommended)

Add to `update-flake-lock.yml`:

```yaml
- name: Enable auto-merge
  run: gh pr merge --auto --merge
  env:
    GH_TOKEN: ${{ secrets.GH_TOKEN_FOR_UPDATES }}
```

**Pros**: Uses GitHub's native feature, respects branch protection  
**Cons**: Requires branch protection rules with required checks

### Option B: Direct Commit (Like nixfleet)

Change workflow to commit directly to main instead of creating PR.

**Pros**: No manual intervention ever  
**Cons**: No review opportunity, could break builds

### Option C: Merge Immediately After PR Creation

Add merge step right after PR creation in same workflow.

**Pros**: Simple, no branch protection needed  
**Cons**: No CI check before merge

## Acceptance Criteria

- [x] flake.lock updates merge automatically without user intervention
- [ ] Build checks still run (ideally before merge) — skipped for simplicity
- [x] No merge conflicts with other automated commits (immediate merge prevents conflicts)

## NixFleet Note

This is managed by GitHub Actions in nixcfg. NixFleet triggers `update-nixfleet.yml` via repository_dispatch after each Docker build, which already auto-commits. The issue is only with the weekly `update-flake-lock.yml` PR workflow.

## Related

- Workflow: `.github/workflows/update-flake-lock.yml`
- Action: [DeterminateSystems/update-flake-lock](https://github.com/DeterminateSystems/update-flake-lock)
