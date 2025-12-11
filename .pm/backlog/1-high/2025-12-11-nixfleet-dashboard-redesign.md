# NixFleet Dashboard Redesign + Metrics

**Created**: 2025-12-11
**Priority**: High
**Status**: In Progress

## Overview

Comprehensive NixFleet dashboard update:

1. Ripple status indicator (✅ done)
2. Location & Type columns
3. Per-host theme colors
4. StaSysMo metrics integration

All changes combined into one agent/backend/dashboard update.

---

## Changes

### 1. Ripple → Status Column ✅

- [x] Move ripple from "Last Seen" to "Status" column
- [x] Ripple replaces status dot (not additional)
- [x] Online = green ripple (animated)
- [x] Offline = static gray dot (no ripple)
- [x] Countdown seconds visible on row hover (next to ripple)
- [x] Error state shows only in Comment column (orange text)

### 2. Split Device → Location + Type ✅

- [x] New "Location" column: Cloud, Home, Work
- [x] New "Type" column: server, desktop, laptop, gaming
- [x] Add agent config fields: `location`, `device_type`
- [x] Update NixOS module with new options
- [x] Update Home Manager module with new options
- [x] Update all host configs with specific values

### 3. Theme Color per Host ✅

- [x] Agent sends `theme_color` hex from config
- [x] Host column (OS icon + hostname) uses theme color
- [x] Add `themeColor` option to agent modules
- [x] Update all host configs with theme colors

### 4. StaSysMo Metrics (Optional) ✅

- [x] Agent reads StaSysMo files if they exist
- [x] Include metrics in heartbeat: `cpu`, `ram`, `swap`, `load`
- [x] Backend stores metrics in host data
- [x] Dashboard shows metrics (compact CPU/RAM %)
- [x] Graceful fallback if StaSysMo not installed

---

## Agent Payload (Combined)

```json
{
  "hostname": "hsb1",
  "host_type": "nixos",
  "location": "home",
  "device_type": "server",
  "theme_color": "#68c878",
  "metrics": {
    "cpu": 12,
    "ram": 45,
    "swap": 0,
    "load": 1.23
  }
}
```

**Note**: `metrics` is optional - only sent if StaSysMo files exist.

---

## Dashboard Layout

```
| Host (themed) | Loc | Type | Status | Metrics | Version | Last Seen | Comment | Actions |
```

- **Host**: OS icon + hostname in theme color
- **Loc**: Cloud ☁️ / Home 🏠 / Work 🏢 icons
- **Type**: server/desktop/laptop/gaming icons
- **Metrics**: CPU/RAM bars or `—` if unavailable

---

## Files to Modify

| Component    | Files                                           |
| ------------ | ----------------------------------------------- |
| Frontend     | `pkgs/nixfleet/app/templates/dashboard.html`    |
| Backend      | `pkgs/nixfleet/app/main.py`                     |
| Agent        | `pkgs/nixfleet/agent/nixfleet-agent.sh`         |
| NixOS Module | `modules/nixfleet-agent.nix`                    |
| HM Module    | `modules/home/nixfleet-agent.nix`               |
| Host Configs | `hosts/*/configuration.nix`, `hosts/*/home.nix` |

---

## Theme Colors Reference

| Host          | Palette   | Primary Color |
| ------------- | --------- | ------------- |
| csb0          | iceBlue   | `#98b8d8`     |
| csb1          | blue      | `#769ff0`     |
| hsb0          | yellow    | `#d4c060`     |
| hsb1          | green     | `#68c878`     |
| hsb8          | orange    | `#e09050`     |
| gpc0          | purple    | `#9868d0`     |
| imac0         | warmGray  | `#a8a098`     |
| mba-imac-work | darkGray  | `#686c70`     |
| mba-mbp-work  | lightGray | `#a8aeb8`     |

---

## StaSysMo Integration

Agent checks for metrics files:

- **Linux**: `/dev/shm/stasysmo/{cpu,ram,swap,load}`
- **macOS**: `/tmp/stasysmo/{cpu,ram,swap,load}`

If files exist and are fresh (< 30s old), include in payload.

---

## Acceptance Criteria

- [x] Ripple in Status column, countdown on hover
- [x] Location and Type as separate columns with icons
- [x] Hostname colored per theme palette
- [x] Metrics displayed (compact %) when available
- [x] `—` shown for hosts without StaSysMo
- [x] Agent modules updated with new config options
- [x] Comment column shows ✓/✗ icons for success/error
- [x] Last Seen compact (relative only, full date on hover)
- [x] All host configs updated (gpc0/hsb8/mba-imac-work offline, will deploy on next boot)
