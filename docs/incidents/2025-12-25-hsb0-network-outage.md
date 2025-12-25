# Incident Report: 2025-12-25 Network Outage (hsb0)

**Date**: Thursday, Dec 25, 2025  
**Duration**: ~15 minutes (10:00 - 10:15 CET)  
**Host**: `hsb0` (Home DNS/DHCP Server)  
**Impact**: Total home LAN network outage (no DNS, no DHCP, no internet routing).

---

## 🚨 What Happened?

During the implementation of the **NCPS Binary Cache Proxy (P5000)**, a configuration switch was attempted on `hsb0`. This switch included:

1.  Adding a new ZFS dataset (`zroot/ncps`) to `disk-config.zfs.nix`.
2.  Configuring `ncps` to use this dataset at `/var/lib/ncps`.

**Root Cause**:  
Systemd attempted to mount the new `/var/lib/ncps` mountpoint defined in the configuration. However, since the ZFS dataset had not been manually created yet (and Disko does not automatically create datasets on a regular `switch`), the mount failed.

This mount failure triggered a cascade of service dependencies failing, including critical networking components or hanging the `nixos-rebuild switch` process, which effectively killed the network stack on the host.

---

## 🔍 Log Evidence

```
Dez 25 10:06:12 hsb0 systemd[1]: Failed to mount /var/lib/ncps.
Dez 25 10:06:12 hsb0 sshd-session[490234]: error: mm_reap: child terminated by signal 15
```

---

## 🛠️ Immediate Recovery

The host `hsb0` was hard-reset/rebooted. It has successfully rolled back or recovered to a working state where **AdGuard Home** is providing DNS and DHCP again.

---

## 🛡️ Prevention & Next Steps

1.  **Stop all host changes**: No further deployments to `hsb0` until a safety plan is in place.
2.  **Disko Safety**: Never add new mountpoints to `disk-config.zfs.nix` and expect a `switch` to work without manual filesystem preparation.
3.  **Network Redundancy**: Add a "DNS Fallback" rule to clients or a secondary DNS server to prevent a single point of failure during `hsb0` maintenance.
4.  **Backlog Task**: Create a safety checklist for `hsb0` deployments.
