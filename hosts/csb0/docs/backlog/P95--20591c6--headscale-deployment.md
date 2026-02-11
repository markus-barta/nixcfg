# headscale-deployment

**Host**: csb0
**Priority**: P95
**Status**: In Progress (Phase 1 Complete)
**Created**: 2026-02-09

---

## Problem

No mesh VPN connecting infrastructure. Need encrypted tunnels between home LAN, cloud servers, and work machines for simplified management and access without port forwarding.

## Solution

Deploy Headscale (self-hosted Tailscale control server) on csb0 behind Traefik. Provides Tailscale-compatible mesh VPN.

## Implementation

### Phase 1: Basic Deployment (COMPLETE ✅)

- [x] Create config.yaml in `hosts/csb0/docker/headscale/config/`
- [x] Add Headscale service to docker-compose.yml
- [x] Add `headscale-data` volume
- [x] Create Cloudflare DNS record (DNS-only, proxy OFF!)
- [x] Deploy: `docker compose up -d headscale`
- [x] Verify TLS cert provisioned
- [x] Create user: `docker exec headscale headscale users create markus`
- [x] Generate auth key and connect test device (imac0)

### Phase 2: Embedded DERP Server

- [ ] Enable DERP in config.yaml
- [ ] Add UDP/3478 to NixOS firewall
- [ ] Add port mapping to docker-compose
- [ ] Rebuild NixOS on csb0
- [ ] Verify STUN connectivity

### Phase 3: Fleet Rollout

- [ ] Connect all infrastructure hosts
- [ ] Configure ACL policies
- [ ] Set up MagicDNS if needed
- [ ] Document device registration in RUNBOOK

## Acceptance Criteria

- [ ] `curl https://hs.barta.cm/health` returns 200
- [ ] Can create users via CLI
- [ ] Devices can register and connect
- [ ] No plaintext secrets in git
- [ ] Backups include headscale data
- [ ] Tests pass
- [ ] Documentation updated

## Notes

### Critical: Cloudflare Incompatibility

**Headscale does NOT work behind Cloudflare proxy.** DNS record `hs.barta.cm` MUST be DNS-only (gray cloud).

### Network Config

- Server URL: `https://hs.barta.cm`
- MagicDNS: `ts.barta.cm`
- IP ranges: v4 `100.64.0.0/10`, v6 `fd7a:115c:a1e0::/48`

### Lessons Phase 1

- Healthcheck: `headscale health` doesn't exist in v0.25, use `headscale configtest`
- Traefik filters `health: starting` containers
- Tailscale macOS: Use `.app` version (not brew CLI)

### Related

- Backup: Auto-included in restic (Docker volumes)
- Priority: 🟡 MEDIUM (infrastructure enhancement)
