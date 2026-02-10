# migration-to-new-server

**Host**: csb0
**Priority**: P70
**Status**: Planning
**Created**: 2025-12-25
**Target**: Q1 2026

---

## Problem

Current Netcup VPS is aging, cannot receive security updates, has manual Docker management, and inconsistent configuration. Critical infrastructure needs modernization.

## Solution

Migrate all csb0 services to new server with current NixOS, proper configuration management, and zero-downtime DNS-based cutover.

## Implementation

### Phase 1: Pre-Deployment

- [ ] Confirm new server provisioned (IP: 89.58.63.96, Gateway: 89.58.60.1)
- [ ] Verify SSH access via VNC console (port 2222)
- [ ] Test flake build locally: `nix flake check && nix build .#csb0`
- [ ] Validate restic backups accessible: `restic snapshots && restic mount /mnt/check`
- [ ] Review configuration for new server

### Phase 2: NixOS Deployment

- [ ] Deploy flake via nixos-anywhere: `nixos-anywhere --flake .#csb0 root@89.58.63.96`
- [ ] Verify systemctl status (no failed units)
- [ ] Confirm restic and monitoring exporters active
- [ ] Verify SSH access on port 2222

### Phase 3: Data Migration & Validation

- [ ] Restore Docker volumes from restic: `restic restore latest --target /var/lib/docker-volumes`
- [ ] Verify Node-RED flows.json integrity
- [ ] Add temporary /etc/hosts entry for testing: `89.58.63.96 cs0.barta.cm ...`
- [ ] Test Node-RED, Uptime Kuma, MQTT via new IP
- [ ] Verify all services functional

### Phase 4: Cutover & Decommission

- [ ] Final verification of new server
- [ ] Update DNS records if needed
- [ ] Shutdown old server: `ssh mba@85.235.65.226 "sudo poweroff"`
- [ ] Archive old configuration: `mv hosts/csb0 hosts/csb0-old-$(date +%Y-%m-%d)`
- [ ] Monitor new server for 24 hours
- [ ] Document final state

## Acceptance Criteria

- [ ] New server running current NixOS
- [ ] All Docker services reachable via new IP
- [ ] Application data verified current
- [ ] Traefik dashboard shows green
- [ ] Monitoring confirms health
- [ ] 24 hours stable operation
- [ ] Old server decommissioned
- [ ] Documentation updated

## Notes

### Server Specs

- **Current**: Netcup VPS, 2 vCPUs, 4GB RAM, 80GB SSD
- **New**: Netcup VPS, 4+ vCPUs, 8GB+ RAM, 160GB+ NVMe
- **Network**: MAC 2A:E3:9B:5B:92:23, IP 89.58.63.96/22, SSH port 2222

### Risks

- 🔴 HIGH: Data consistency (uid/gid mismatch) - Verify before migration
- 🔴 HIGH: Service downtime if restore slow - Pre-sync data
- 🟡 MEDIUM: Network routing (Netcup ARP issues) - Keep VNC open
- 🟡 MEDIUM: Certificate re-issuance (Let's Encrypt rate limits)

### Timeline

- Preparation: 2 weeks (2026-01-20)
- Deployment: 2 weeks (2026-02-03)
- Migration: 1 week (2026-02-10)
- Cutover: 1 day (2026-02-14)
- Verification: 1 week (2026-02-21)
- Decommission: 1 day (2026-02-22)

### Lessons from Initial Attempt

- Wrong config applied initially (old IP vs new IP)
- Network isolation due to conflicting ARP entries
- VNC console has character limitations (no "-")
- Always verify correct flake reference before deployment
- Test network connectivity early
- Document MAC addresses beforehand

### Migration Window

- Planned downtime: 4-6 hours
- DNS TTL: Set to 60s one hour before
- Related tickets: P6000 (Uptime Kuma), P4000 (Watchtower), P5000 (Monitoring)
