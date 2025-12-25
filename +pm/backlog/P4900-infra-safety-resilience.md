# P4900 - Infrastructure Safety & Deployment Resilience

**Created**: 2025-12-25  
**Updated**: 2025-12-25 (Refined after hsb0 outage)  
**Priority**: P4900 (High)  
**Status**: Backlog  
**Host**: hsb0 (Primary), Fleet-wide

---

## Overview

The incident on 2025-12-25 demonstrated that `hsb0` is a "Single Point of Failure" (SPOF) where a configuration error (specifically regarding filesystems/mounts) can take down the entire home network. We need a more robust deployment process for critical infrastructure.

---

## Goals

1.  **Deployment Safety Check**: Establish a clear protocol for "High Risk" changes (filesystems, network interfaces, critical service reconfigs).
2.  **Disko Protocol**: Document and enforce a "prepare-then-switch" workflow for any changes to `disk-config.zfs.nix`.
3.  **Connectivity Health Checks**: Investigate (but do not yet automate) ways to verify host health immediately after a switch.
4.  **Manual Rollback Reference**: Ensure every runbook has a clear, tested "Emergency Rollback" section.

---

## Refined Plan

### 1. The "Critical Server" Protocol

For `hsb0` (and eventually others), we will adopt a **Wait and Verify** approach:

- **Dry Run First**: Always run `nixos-rebuild dry-activate` or check for new mountpoints in the evaluation.
- **Manual Prep**: If a new ZFS dataset is added, it MUST be created manually on the host _before_ the switch.
- **Serial Switching**: Never switch multiple critical hosts at once.

### 2. Post-Switch Verification (Manual for now)

Immediately after a switch on `hsb0`:

1.  Verify `ping 1.1.1.1` (External connectivity).
2.  Verify `dig @127.0.0.1 google.com` (DNS resolving).
3.  Verify `systemctl status adguardhome` (Service health).

### 3. Investigation: Semi-Automated Safety

Instead of full "automatic rollbacks," we will investigate a **"Confirm Connection"** pattern:

- The switch starts a background timer (e.g., 5 minutes).
- If the operator doesn't run a "confirm" command within that time (because they lost SSH access), the system rolls back.
- _Status_: Experimental/Investigation only.

---

## Acceptance Criteria

- [ ] `hsb0` Runbook updated with "Critical Deployment Safety Checklist".
- [ ] `disk-config.zfs.nix` changes documented as "High Risk - Manual Dataset Creation Required".
- [ ] Emergency rollback procedure verified for `hsb0`.
- [ ] Investigation into "operator confirmation" rollback mechanism completed.

---

## Related

- Incident Report: `docs/incidents/2025-12-25-hsb0-network-outage.md`
- NCPS Backlog: `+pm/backlog/P5000-ncps-binary-cache-proxy.md`
