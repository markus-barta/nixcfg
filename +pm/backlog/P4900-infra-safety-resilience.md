# P4900 - Infrastructure Safety & Deployment Resilience

**Created**: 2025-12-25  
**Updated**: 2025-12-25 (Refined after hsb0 outage)  
**Priority**: P4900 (High)  
**Status**: Backlog  
**Host**: hsb0 (full protocol), other hosts (dry-run + serial only)

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

### 0. Resilience Requirements (What “good” looks like)

We optimize for **network availability** over convenience.

- **RTO (Recovery Time Objective)**: \(< 2 minutes\) to restore DNS/DHCP after a bad change (via rollback/reboot).
- **Allowed blast radius**: A bad change may break _itself_ (e.g., `ncps`) but must not take down **DNS/DHCP**.
- **Critical invariant**: `adguardhome` must always come up and keep port 53/67 working after boot and after switch.

### 1. The "Critical Server" Protocol

For `hsb0` (and eventually others), we will adopt a **Wait and Verify** approach:

- **High-Risk Change Gate**: If the change touches any of:
  - `disk-config.zfs.nix` / `fileSystems.*` / mountpoints
  - `networking.*` (interfaces/gateway/nameservers)
  - `services.adguardhome.*` (DNS/DHCP)
    Then it MUST be treated as a “maintenance event”.
- **Dry Run First**: Always run `nixos-rebuild dry-activate` (or `nh os switch --dry`) and scan for:
  - New mountpoints
  - Unit changes affecting `adguardhome` / networking
- **Manual Prep**: If a new ZFS dataset is added, it MUST be created manually on the host _before_ the switch.
- **Serial Switching**: Never switch multiple critical hosts at once.

### 2. Post-Switch Verification (Manual for now)

Immediately after a switch on `hsb0`:

1.  Verify `ping 1.1.1.1` (External connectivity).
2.  Verify `dig @127.0.0.1 google.com` (DNS resolving).
3.  Verify `systemctl status adguardhome` (Service health).
4.  Verify DHCP is alive: `sudo journalctl -u adguardhome -n 50 --no-pager | grep -i dhcp || true`
5.  Verify a LAN client can resolve: from another host `dig @192.168.1.99 google.com` and `dig @192.168.1.99 hsb1.lan`

### 3. Investigation: Semi-Automated Safety

Instead of full "automatic rollbacks," we will investigate a **"Confirm Connection"** pattern:

- The switch starts a background timer (e.g., 5 minutes).
- If the operator doesn't run a "confirm" command within that time (because they lost SSH access), the system rolls back.
- _Status_: Experimental/Investigation only.

### 4. Filesystem/Mount Resilience Rules (to prevent "mount breaks DNS")

When adding new mountpoints for **non-critical services** (like caches):

- **Rule**: Ensure the service unit (e.g., `ncps.service`) depends on the mount (`var-lib-ncps.mount`), **not** the other way around. A missing dataset fails the service, not the boot.
- **Implementation**: Use `systemd.services.<name>.requires` and `after` to tie the service to its mount.

We explicitly avoid any design where a failed mount can cascade into DNS/DHCP downtime.

---

## Acceptance Criteria

- [ ] `hsb0` Runbook updated with a **Critical Deployment Safety Checklist** (pre-flight + post-flight).
- [ ] `disk-config.zfs.nix` changes documented as **High Risk - Manual Dataset Creation Required**.
- [ ] A documented “maintenance event” flow exists for filesystem/network changes on `hsb0`.
- [ ] Emergency rollback procedure verified for `hsb0` (explicit commands + where to run them from).
- [ ] Investigation into **operator confirmation** rollback mechanism completed (decision: adopt or reject).
- [ ] Optional service mounts (e.g., `ncps`) use **service-depends-on-mount** pattern (not blocking boot).

---

## Related

- Incident Report: `docs/incidents/2025-12-25-hsb0-network-outage.md`
- NCPS Backlog: `+pm/backlog/P5000-ncps-binary-cache-proxy.md`
- hsb0 Runbook: `hosts/hsb0/docs/RUNBOOK.md` (target for safety checklist)
