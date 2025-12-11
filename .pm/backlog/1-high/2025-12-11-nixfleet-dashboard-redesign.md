# NixFleet Dashboard Redesign

**Created**: 2025-12-11
**Priority**: High
**Status**: In Progress

## Overview

Redesign the NixFleet dashboard with improved visual hierarchy, per-host theming, and refined column structure.

## Changes

### 1. Ripple → Status Column

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

- [ ] Agent sends `theme_color` hex from Starship palette
- [ ] Host column (OS icon + hostname) uses theme color
- [ ] Update agent to read from theme-palettes.nix or config

## Files to Modify

| Component    | Files                                           |
| ------------ | ----------------------------------------------- |
| Frontend     | `pkgs/nixfleet/app/templates/dashboard.html`    |
| Backend      | `pkgs/nixfleet/app/main.py`                     |
| Agent        | `pkgs/nixfleet/agent/nixfleet-agent.sh`         |
| NixOS Module | `modules/nixfleet-agent.nix`                    |
| HM Module    | `modules/home/nixfleet-agent.nix`               |
| Host Configs | `hosts/*/configuration.nix`, `hosts/*/home.nix` |

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

## Acceptance Criteria

- [ ] Ripple in Status column, countdown on hover
- [ ] Location and Type as separate columns with icons
- [ ] Hostname colored per theme palette
- [ ] Error state only in comment (orange text)
- [ ] All agents updated and deployed
