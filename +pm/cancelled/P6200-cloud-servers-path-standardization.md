# Cloud Servers Path Standardization

## Description

Standardize nixcfg repository path on cloud servers from `~/nixcfg` to `~/Code/nixcfg` for consistency with all other hosts.

## Affected Hosts

| Host | Current    | Target          |
| ---- | ---------- | --------------- |
| csb0 | `~/nixcfg` | `~/Code/nixcfg` |
| csb1 | `~/nixcfg` | `~/Code/nixcfg` |

## Why

All other hosts (hsb0, hsb1, gpc0, imac0) use `~/Code/nixcfg`. This was pbek's original pattern.

## Steps (per host)

```bash
# SSH to host
ssh -p 2222 mba@cs0.barta.cm  # or cs1

# Create Code directory if needed
mkdir -p ~/Code

# Move repo
mv ~/nixcfg ~/Code/nixcfg

# Verify
cd ~/Code/nixcfg && git status
```

## Acceptance Criteria

- [ ] csb0: `~/Code/nixcfg` exists, `~/nixcfg` removed
- [ ] csb1: `~/Code/nixcfg` exists, `~/nixcfg` removed
- [ ] Update `hosts/DEPLOYMENT.md` Quick Commands section

## Priority

Low - cosmetic/consistency, no functional impact.

## Notes

- Do during next maintenance window or alongside other updates
- csb0's hokage migration is pending (do path change first or during)
- csb1's hokage migration is complete, this is a follow-up cleanup
