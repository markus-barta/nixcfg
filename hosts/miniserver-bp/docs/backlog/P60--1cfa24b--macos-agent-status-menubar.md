# macos-agent-status-menubar

**Host**: miniserver-bp
**Priority**: P60
**Status**: Backlog
**Created**: 2026-02-16

---

## Problem

No visibility into Percy's status from macOS without SSH-ing or opening Telegram. Can't tell at a glance if he's alive, busy, or stuck. Docker logs only show errors — successful activity is invisible from the server side.

## Solution

macOS menubar app that shows agent health at a glance. Options:

1. **Minimal**: Poll `/health` endpoint, show green/red dot in menubar
2. **Medium**: Also show last activity timestamp, current session count (if Control UI API exposes this)
3. **Full**: Show recent conversation snippets, error count, active tasks

### Pre-requisites to investigate

- What does `http://10.17.1.40:18789/health` actually return?
- Does the Control UI have an API we can poll for session/activity data?
- Does OpenClaw expose a WebSocket we can subscribe to for real-time updates?
- Network: only works from office network (or via Tailscale)

### Tech options

- **SwiftUI menubar app** — native, lightweight, low power
- **xbar/SwiftBar plugin** — shell script that runs periodically, shows output in menubar (zero code)
- **Hammerspoon script** — Lua-based, flexible, already common in dev setups

## Implementation

- [ ] Test `/health` endpoint response format
- [ ] Check Control UI for API endpoints (sessions, activity)
- [ ] Choose approach (native app vs xbar vs Hammerspoon)
- [ ] Implement polling + display
- [ ] Handle network unavailability gracefully (office-only)

## Acceptance Criteria

- [ ] Green/red indicator visible in macOS menubar
- [ ] Shows Percy's alive/dead status within 30s of change
- [ ] Works from office network (mba-imac-work, mba-mbp-work)
- [ ] Graceful when offline / host unreachable

## Notes

- Control UI: `http://10.17.1.40:18789`
- Health: `http://10.17.1.40:18789/health`
- xbar (https://xbarapp.com) might be quickest MVP — just a shell script
- Could later extend to Merlin (hsb0) status too
- Related: P40 agent-to-agent-comms backlog item
