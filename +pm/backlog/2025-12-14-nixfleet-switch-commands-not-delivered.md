# 🔴 URGENT: NixFleet Switch Commands Not Delivered

**Priority:** HIGHEST  
**Date:** 2025-12-14  
**Status:** BLOCKED - needs investigation

## Summary

Switch commands clicked in the NixFleet dashboard UI are not being delivered to agents. Pull commands work correctly, but Switch commands silently fail.

## Current State

All 9 hosts have been updated to use 5s heartbeat interval in their configs, but the changes are NOT active because Switch never ran:

| Host          | Type  | Config Updated | Pull  | Switch      | Agent Status |
| ------------- | ----- | -------------- | ----- | ----------- | ------------ |
| csb0          | NixOS | ✅ 5s interval | ✅ OK | ❌ NOT SENT | inactive     |
| csb1          | NixOS | ✅ 5s interval | ✅ OK | ❌ NOT SENT | inactive     |
| gpc0          | NixOS | ✅ 5s interval | ✅ OK | ❌ NOT SENT | inactive     |
| hsb0          | NixOS | ✅ 5s interval | ✅ OK | ❌ NOT SENT | active       |
| hsb1          | NixOS | ✅ 5s interval | ✅ OK | ❌ NOT SENT | active       |
| hsb8          | NixOS | ✅ 5s interval | -     | -           | offline      |
| imac0         | macOS | ✅ 5s interval | ✅ OK | ❌ NOT SENT | running      |
| mba-imac-work | macOS | ✅ 5s interval | -     | -           | offline      |
| mba-mbp-work  | macOS | ✅ 5s interval | ✅ OK | ❌ NOT SENT | running      |

## Evidence

### Dashboard Logs (csb1 docker)

```
8:53PM INF command status command=pull host=csb0 status=ok
8:53PM INF command status command=pull host=csb1 status=ok
8:54PM INF command status command=pull host=gpc0 status=ok
8:54PM INF command status command=pull host=hsb0 status=ok
8:54PM INF command status command=pull host=hsb1 status=ok
8:54PM INF command status command=pull host=imac0 status=ok
8:54PM INF command status command=pull host=mba-mbp-work status=ok
# NO switch commands logged AT ALL
```

### Agent Logs (hsb1 via journalctl)

```
Dez 14 21:54:09 hsb1 nixfleet-agent: received command command=pull
Dez 14 21:54:10 hsb1 nixfleet-agent: command completed command=pull exit_code=0 status=ok
# NO switch command received
```

### Agent Logs (imac0 local /tmp/nixfleet-agent.err)

```
9:54PM INF received command command=pull
9:54PM INF command completed command=pull exit_code=0 status=ok
# NO switch command received
```

## Root Cause (Suspected)

The Switch button clicks in the browser UI did not result in API calls reaching the backend:

1. The UI shows "switch" badge after clicking (frontend state updated)
2. But the backend never logged receiving a switch command
3. Possible causes:
   - JavaScript error preventing API call
   - CSRF token issue
   - WebSocket disconnection during click
   - API endpoint returning error silently

## What Was Changed (Committed & Pushed)

### nixcfg (commit e50c6d64)

- All 9 hosts: `interval = 30` → `interval = 5` for heartbeat

### nixfleet (commit ab4b0f8)

- Default heartbeat interval: 30s → 10s (for new hosts)
- Dashboard HeartbeatInterval: 5s (matches current host configs)

## To Resume

1. **Investigate why Switch API calls fail:**
   - Check browser console for JavaScript errors
   - Check network tab for failed API requests
   - Look at `/api/hosts/{hostID}/command` endpoint

2. **Manual workaround if needed:**
   - SSH to each host and run switch manually
   - NixOS: `sudo nixos-rebuild switch --flake /path/to/nixcfg#hostname`
   - macOS: `home-manager switch --flake /path/to/nixcfg#hostname`

3. **Verify after fix:**
   - Generation should change from `c52f6c7` to `e50c6d6`
   - Heartbeats should arrive every 5s (not 30s)
   - Last Seen should show small values (0-10s) in gray

## Related Changes Made Today

- CSS: margin-left for progress-badge-mini: 4px → 15px
- Enabled templ generate in Dockerfile (was commented out)
- Static green dots with heartbeat animation only on actual update
- 13px font in table, accurate last-seen with color coding
- 1-second updates for smooth last-seen counting
- Clamped negative time to 0 (clock skew fix)

## Files Modified

- `nixcfg/hosts/*/configuration.nix` or `home.nix` - interval = 5
- `nixfleet/v2/internal/config/config.go` - default 10s
- `nixfleet/v2/internal/dashboard/handlers.go` - HeartbeatInterval: 5
- `nixfleet/v2/internal/templates/base.templ` - CSS fixes
- `nixfleet/v2/internal/templates/dashboard.templ` - JS fixes
- `nixfleet/v2/Dockerfile` - enabled templ generate
