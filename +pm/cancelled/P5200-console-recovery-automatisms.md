# P5200 - Console Recovery & Boot Rollback Automatisms

**Created**: 2025-12-25  
**Priority**: LOW  
**Status**: Backlog  
**Host**: hsb0 (Critical), Fleet-wide

---

## Overview

The incident on 2025-12-25 showed that if a boot fails into Emergency Mode and the console is locked (locked root account), recovery requires a manual GRUB rollback. We want to investigate ways to make this more resilient and "automatic."

---

## Goals

1.  **Emergency Console Access**:
    - Investigate setting a "secret" root password via `agenix` for emergency use.
    - Alternatively, investigate configuring `systemd` to allow emergency console access without a password (security trade-off for physically secure home server).
2.  **Automatic Boot Rollback**:
    - Investigate [systemd-boot](https://www.freedesktop.org/wiki/Software/systemd/systemd-boot/) "boot counting" or similar mechanisms to automatically revert to the previous generation if a boot doesn't reach a successful state.
    - Evaluate NixOS options for `systemd.watchdog`.
3.  **Physical Access Procedure**:
    - Document exactly where the keyboard/monitor are for each host in their respective `RUNBOOK.md`.

---

## Acceptance Criteria

- [ ] Decision made on emergency console authentication (password vs. passwordless).
- [ ] Investigation into "Boot Counting" rollback mechanisms completed.
- [ ] If feasible, implement a "Safe Boot" watchdog that rolls back on boot loops/hangs.
- [ ] All Runbooks updated with physical recovery hardware locations.
