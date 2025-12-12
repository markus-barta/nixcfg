# NixFleet - Action Button Locking During Commands

**Created**: 2025-12-11
**Priority**: Medium
**Status**: Backlog

---

## Goal

Disable action buttons (Pull, Switch, Test) while a command is in progress, re-enable when complete.

---

## Problem

Currently buttons are disabled only briefly after click (1 second timeout). If a command takes longer (e.g., 30s nixos-rebuild), the button re-enables while the command is still running.

## Solution

Track command execution state per-host and disable buttons appropriately:

1. When command queued → disable all buttons for that host
2. When SSE receives `command_queued` event → disable buttons
3. When SSE receives `host_update` with `pending_command: null` → re-enable buttons
4. Visual feedback: change button text to "Pulling...", "Switching...", "Testing..."

---

## Tasks

- [ ] Track per-host "command in progress" state in JavaScript
- [ ] Update `sendCommand()` to set state and disable all action buttons for host
- [ ] Update `updateHostRow()` SSE handler to re-enable buttons when command completes
- [ ] Add visual feedback (button text change, spinner icon)
- [ ] Handle edge cases (page refresh while command running, SSE disconnect)

---

## References

- [pkgs/nixfleet/app/templates/dashboard.html](../../../pkgs/nixfleet/app/templates/dashboard.html)
- [2025-12-10-nixfleet-enhancements.md](../1-high/2025-12-10-nixfleet-enhancements.md)
