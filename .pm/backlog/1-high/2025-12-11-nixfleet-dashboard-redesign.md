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

### 2. Split Device → Location + Type

- [ ] New "Location" column: Cloud, Home, Work
- [ ] New "Type" column: server, desktop, laptop, gaming
- [ ] Add agent config fields: `location`, `device_type`
- [ ] Update NixOS module with new options
- [ ] Update Home Manager module with new options
- [ ] Update all host configs

### 3. Theme Color per Host

- [ ] Agent sends `theme_color` hex from config
- [ ] Host column (OS icon + hostname) uses theme color
- [ ] Add `themeColor` option to agent modules

### 4. StaSysMo Metrics (Optional)

- [ ] Agent reads StaSysMo files if they exist
- [ ] Include metrics in heartbeat: `cpu`, `ram`, `swap`, `load`
- [ ] Backend stores metrics in host data
- [ ] Dashboard shows metrics (compact bars or values)
- [ ] Graceful fallback if StaSysMo not installed

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
- [ ] Location and Type as separate columns with icons
- [ ] Hostname colored per theme palette
- [ ] Metrics displayed (bars or values) when available
- [ ] `—` shown for hosts without StaSysMo
- [ ] All agents updated with new config options
- [ ] All hosts deployed with location/type/color config
