# P8000: Migrate miniserver-bp to NixOS

**Status**: BACKLOG  
**Priority**: P8 (Backlog - future enhancement)  
**Created**: 2025-12-19

---

## Overview

Migrate `miniserver-bp` (Ubuntu 24.04 server at BYTEPOETS) to NixOS for declarative configuration management.

---

## Current State

| Item         | Value                                 |
| ------------ | ------------------------------------- |
| **Hostname** | miniserver-bp                         |
| **OS**       | Ubuntu 24.04.2 LTS                    |
| **Kernel**   | 6.8.0-86-generic                      |
| **IP (VPN)** | 10.100.0.51                           |
| **Role**     | Jump host for accessing mba-imac-work |
| **User**     | mba                                   |

---

## Access

From home (via VPN):

```bash
# 1. Connect to "BYTEPOETS+" VPN entry in WireGuard app
# 2. SSH to miniserver-bp
ssh mba@10.100.0.51
```

---

## Motivation

- **Consistency**: Match other infrastructure using NixOS
- **Declarative config**: Version-controlled server configuration
- **Reproducibility**: Easy to redeploy if needed
- **Integration**: Could integrate with NixFleet monitoring

---

## Considerations

- [ ] Physical vs VM access for installation?
- [ ] Backup current Ubuntu configuration first
- [ ] Minimal server profile (SSH, basic tools)
- [ ] May need BYTEPOETS IT approval

---

## Acceptance Criteria

- [ ] miniserver-bp running NixOS
- [ ] SSH access working (same 10.100.0.51 IP)
- [ ] Jump host functionality preserved
- [ ] Configuration in nixcfg repo
- [ ] NixFleet agent installed (optional)

---

## Notes

This is a low-priority future enhancement. The Ubuntu server works fine as a jump host.
