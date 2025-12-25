# P5100 - Infrastructure Safety & Network Resilience

**Created**: 2025-12-25  
**Priority**: CRITICAL  
**Status**: Backlog  
**Host**: Fleet-wide (Focus on hsb0)

---

## Overview

The incident on 2025-12-25 proved that `hsb0` is a "Single Point of Failure" (SPOF). A failed deployment can take down the entire network. We need to implement safety measures and redundancy.

---

## Goals

1.  **Redundant DNS**: Configure a secondary DNS server (e.g., `hsb1` or external fallback) so clients can resolve names even if `hsb0` is down.
2.  **Deployment Safety Check**: Implement a "dry-run" and "rollback" strategy for critical servers.
3.  **Disko Awareness**: Establish a protocol for adding ZFS datasets/mounts without breaking boot/switch.
4.  **Automatic Rollback**: Use `nixos-rebuild switch --rollback` or similar if network connectivity isn't restored within X minutes.

---

## Acceptance Criteria

- [ ] Clients have a secondary DNS entry pointing to a reliable fallback.
- [ ] `hsb0` configuration includes a "Network Health Check" script that rolls back if it can't ping the gateway after a switch.
- [ ] Documentation updated with "Critical Server Maintenance" protocol.
- [ ] NCPS deployment (P5000) retried ONLY after manual filesystem preparation.

---

## Related

- Incident Report: `docs/incidents/2025-12-25-hsb0-network-outage.md`
- NCPS Backlog: `+pm/backlog/P5000-ncps-binary-cache-proxy.md`
