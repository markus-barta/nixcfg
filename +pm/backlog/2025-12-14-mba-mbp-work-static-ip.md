# Assign Static IP to mba-mbp-work

**Priority**: Low
**Status**: Open
**Date**: 2024-12-14
**Host**: hsb0 (DHCP server), mba-mbp-work (client)

---

## Problem

`mba-mbp-work` currently uses DHCP and gets a dynamic IP address. This means:

- SSH references use `mba-mbp-work.local` (mDNS) which may be unreliable
- IP-based references become stale when the lease changes
- Inconsistent with other hosts that have static IPs

---

## Solution

Add a static DHCP lease for `mba-mbp-work` in hsb0's AdGuard Home / DHCP configuration.

### Steps

1. **Get MAC address** of mba-mbp-work:

   ```bash
   # On mba-mbp-work
   ifconfig en0 | grep ether
   ```

2. **Add static lease** in hsb0's DHCP config:
   - Edit `nixcfg/hosts/hsb0/` DHCP configuration
   - Add MAC → IP mapping (suggest: `192.168.1.237` to keep current)

3. **Update documentation**:
   - `hosts/mba-mbp-work/docs/RUNBOOK.md` - add IP to Quick Reference
   - `.cursor/rules/SYSOP.mdc` - update SSH quick reference
   - Memory ID 12214258 - update SSH commands

4. **Deploy**:

   ```bash
   ssh mba@hsb0.lan
   cd ~/Code/nixcfg && git pull && just switch
   ```

5. **Renew lease** on mba-mbp-work to get static IP

---

## Acceptance Criteria

- [ ] mba-mbp-work has static IP in hsb0 DHCP config
- [ ] Can SSH using `ssh mba@<static-ip>`
- [ ] Can SSH using `ssh mba@mba-mbp-work.lan` (not just .local)
- [ ] RUNBOOK.md updated with IP
- [ ] SYSOP.mdc updated with IP
