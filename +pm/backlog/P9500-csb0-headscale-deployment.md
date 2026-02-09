# P9500: csb0 Headscale Deployment (Self-Hosted Tailscale Control Server)

**Created**: 2026-02-09
**Priority**: 🟡 MEDIUM (P4-5k range)
**Status**: Backlog
**Target Host**: csb0 (89.58.63.96)
**Risk Level**: 🟡 MEDIUM (adds auth surface to existing public server)

---

## Problem

No mesh VPN connecting infrastructure hosts. Currently all management is via individual SSH. A Tailscale-compatible VPN would enable:

- Encrypted tunnels between home LAN hosts, cloud servers, and work machines
- Access to home LAN services from anywhere without port forwarding
- Simplified multi-host management

## Solution

Deploy [Headscale](https://github.com/juanfont/headscale) (self-hosted Tailscale control server) as a Docker container on csb0, behind the existing Traefik reverse proxy.

### Why csb0?

| Option   | Verdict | Reason                                                             |
| -------- | ------- | ------------------------------------------------------------------ |
| **hsb0** | **NO**  | Crown Jewel (DNS/DHCP) - adding public attack surface unacceptable |
| **csb0** | **YES** | Already public-facing, runs Traefik, Node-RED, MQTT                |
| **csb1** | Viable  | Also has Traefik, but monitoring-focused - keep it lean            |

---

## CRITICAL: Cloudflare Proxy Incompatibility

**Headscale does NOT work behind Cloudflare proxy.** Cloudflare does not support WebSocket POSTs required by the Tailscale protocol. See [headscale#1468](https://github.com/juanfont/headscale/issues/1468).

**Action required:**

- The `hs.barta.cm` DNS record in Cloudflare **MUST** be set to **DNS-only** (gray cloud, proxy OFF)
- Do **NOT** apply the `cloudflarewarp@file` middleware to the Headscale Traefik router
- This means the server's real IP (89.58.63.96) will be exposed for this subdomain - acceptable since the IP is already known

---

## Technical Design

### Architecture

```
Tailscale clients
    │
    ├── HTTPS (tcp/443) ──→ Traefik ──→ Headscale container (tcp/8080)
    │                                          │
    │                                    SQLite volume
    │                                    (/var/lib/headscale/)
    │
    └── STUN (udp/3478) ──→ Headscale container (udp/3478)
                           (if embedded DERP enabled)
```

### Container Configuration

Based on official docs and csb0's existing docker-compose patterns:

```yaml
# Addition to hosts/csb0/docker/docker-compose.yml
headscale:
  image: headscale/headscale:0.25 # Pin to minor version, not :latest
  container_name: headscale
  restart: unless-stopped
  read_only: true
  tmpfs:
    - /var/run/headscale
  volumes:
    - ./headscale/config:/etc/headscale:ro
    - headscale-data:/var/lib/headscale
  command: serve
  environment:
    - TZ=Europe/Vienna
  networks:
    - traefik
  labels:
    # Traefik HTTP routing
    - traefik.enable=true
    - traefik.http.routers.headscale.rule=Host(`hs.barta.cm`)
    - traefik.http.routers.headscale.entrypoints=web-secure
    - traefik.http.routers.headscale.tls=true
    - traefik.http.routers.headscale.tls.certresolver=default
    - traefik.http.services.headscale.loadbalancer.server.port=8080
    - traefik.docker.network=csb0_traefik
    # ⚠️ NO cloudflarewarp middleware! Headscale requires direct connection.
    # HTTP to HTTPS redirect
    - traefik.http.routers.headscale-http.rule=Host(`hs.barta.cm`)
    - traefik.http.routers.headscale-http.entrypoints=web
    - traefik.http.routers.headscale-http.middlewares=redirect-to-https@docker
  healthcheck:
    test: ["CMD", "headscale", "health"]
    interval: 30s
    timeout: 10s
    retries: 3
```

**Volume addition:**

```yaml
volumes:
  headscale-data: # <-- add to existing volumes block
```

### Headscale config.yaml

File: `hosts/csb0/docker/headscale/config/config.yaml`

```yaml
# Server
server_url: https://hs.barta.cm
listen_addr: 0.0.0.0:8080
metrics_listen_addr: 0.0.0.0:9090

# TLS handled by Traefik - disable in Headscale
tls_cert_path: ""
tls_key_path: ""

# Noise protocol key (auto-generated on first run)
noise:
  private_key_path: /var/lib/headscale/noise_private.key

# IP allocation for tailnet
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential

# Database
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite
    write_ahead_log: true

# DERP relay servers
derp:
  server:
    enabled: false # Start without embedded DERP
    # Phase 2: enable for better NAT traversal
    # region_id: 999
    # stun_listen_addr: "0.0.0.0:3478"
    # private_key_path: /var/lib/headscale/derp_server_private.key
    # ipv4: 89.58.63.96
  urls:
    - https://controlplane.tailscale.com/derpmap/default
  paths: []
  auto_update_enabled: true
  update_frequency: 3h

# DNS (MagicDNS)
dns:
  magic_dns: true
  base_domain: ts.barta.cm # MagicDNS domain (MUST differ from server_url domain)
  override_local_dns: false # Don't override - home hosts need local DNS (hsb0)
  nameservers:
    global:
      - 1.1.1.1
      - 1.0.0.1

# Disable Tailscale telemetry
logtail:
  enabled: false

# Ephemeral nodes
ephemeral_node_inactivity_timeout: 30m

# Unix socket for CLI
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"

# ACL policy
policy:
  mode: file
  path: ""

# Taildrop (file sharing)
taildrop:
  enabled: true

log:
  level: info
  format: text
```

### Firewall Changes

Current csb0 firewall (configuration.nix):

```nix
firewall.allowedTCPPorts = [ 80 443 2222 ];
```

**Phase 1 (no embedded DERP):** No firewall changes needed. Headscale traffic flows through Traefik on 443.

**Phase 2 (with embedded DERP):** Add UDP/3478 for STUN:

```nix
firewall.allowedTCPPorts = [ 80 443 2222 ];
firewall.allowedUDPPorts = [ 3478 ];  # STUN for Headscale DERP
```

Also requires Traefik ports update or direct host port mapping for the container:

```yaml
ports:
  - "3478:3478/udp" # STUN
```

### DNS (Cloudflare)

Add A record:

```
hs.barta.cm  →  89.58.63.96  (DNS-only / gray cloud / proxy OFF)
```

**Optionally** for MagicDNS (if using split DNS delegation):

```
ts.barta.cm  →  NS records pointing to Headscale (future consideration)
```

---

## Implementation Phases

### Phase 1: Basic Deployment

1. Create `hosts/csb0/docker/headscale/config/config.yaml`
2. Add Headscale service to `docker-compose.yml`
3. Add `headscale-data` volume
4. Create Cloudflare DNS record (DNS-only!)
5. Deploy: `docker compose up -d headscale`
6. Verify: `curl https://hs.barta.cm/health`
7. Create first user: `docker exec headscale headscale users create markus`
8. Generate auth key: `docker exec headscale headscale preauthkeys create --user markus`
9. Connect test device: `tailscale up --login-server https://hs.barta.cm --authkey <KEY>`

### Phase 2: Embedded DERP Server

1. Enable DERP in config.yaml
2. Add UDP/3478 to NixOS firewall
3. Add port mapping to docker-compose
4. Rebuild NixOS on csb0
5. Verify STUN connectivity

### Phase 3: Fleet Rollout

1. Connect all infrastructure hosts
2. Configure ACL policies
3. Set up MagicDNS split DNS (if needed)
4. Document device registration in RUNBOOK

---

## Secrets Management

| Secret                    | Storage                  | Notes                                      |
| ------------------------- | ------------------------ | ------------------------------------------ |
| `noise_private.key`       | Auto-generated in volume | Created on first start                     |
| `derp_server_private.key` | Auto-generated in volume | Phase 2 only                               |
| Pre-auth keys             | CLI-generated, ephemeral | Short-lived, not stored in repo            |
| `config.yaml`             | Git repo                 | No secrets in config (keys auto-generated) |

**No agenix secrets needed for Phase 1.** The Headscale config contains no credentials - private keys are auto-generated in the data volume.

If OIDC is added later, `client_secret` MUST go through agenix.

---

## Resource Estimates

| Resource | Estimate                | csb0 Capacity                |
| -------- | ----------------------- | ---------------------------- |
| RAM      | ~50-100MB idle          | VPS 1000 G11: 4GB+ available |
| CPU      | Minimal (control plane) | 4 vCPUs                      |
| Storage  | <100MB (SQLite + keys)  | ZFS with plenty of space     |
| Network  | Control traffic only    | Already has 443 open         |

---

## Backup Considerations

Headscale data will be in Docker volume `headscale-data`, which maps to `/var/lib/docker/volumes/csb0_headscale-data/`.

The existing restic backup already covers `/var/lib/docker/volumes`, so **Headscale data is automatically backed up** via the `csb0-restic-cron-hetzner-1` container.

**Critical data to protect:**

- `noise_private.key` (if lost, all clients must re-authenticate)
- `db.sqlite` (user/node registrations, ACLs)

---

## Rollback Plan

1. `docker compose stop headscale`
2. Remove service from `docker-compose.yml`
3. Remove Cloudflare DNS record
4. `docker volume rm csb0_headscale-data` (if cleanup desired)
5. No NixOS changes needed for Phase 1

---

## Acceptance Criteria

- [ ] `curl https://hs.barta.cm/health` returns 200
- [ ] DNS record is DNS-only (not Cloudflare-proxied)
- [ ] Can create user via `docker exec headscale headscale users create <name>`
- [ ] Can register a test device and verify connectivity
- [ ] No plaintext secrets in git
- [ ] Headscale data included in restic backups (verify via snapshot listing)
- [ ] csb0 test suite passes (`hosts/csb0/tests/T*.sh`)
- [ ] csb0 README.md updated with Headscale service entry
- [ ] csb0 RUNBOOK.md updated with Headscale troubleshooting

---

## Documentation Updates Required

| File                           | Change                                                          |
| ------------------------------ | --------------------------------------------------------------- |
| `hosts/csb0/README.md`         | Add Headscale to services table, firewall table (Phase 2)       |
| `hosts/csb0/docs/RUNBOOK.md`   | Add Headscale section: health check, user mgmt, troubleshooting |
| `hosts/csb0/ip-89.58.63.96.md` | Add `hs.barta.cm` to services table                             |
| `docs/INFRASTRUCTURE.md`       | Note VPN capability                                             |

---

## Test Script (new)

Create `hosts/csb0/tests/T08-headscale.sh`:

```bash
#!/usr/bin/env bash
# T08: Headscale health check
HOST="${CSB0_HOST:-cs0.barta.cm}"
SSH_CMD="ssh -p 2222 mba@${HOST}"

# 1. Container running
$SSH_CMD "docker ps --filter name=headscale --filter status=running -q" | grep -q . || fail "headscale not running"

# 2. Health endpoint
curl -sf https://hs.barta.cm/health || fail "health endpoint unreachable"

# 3. CLI accessible
$SSH_CMD "docker exec headscale headscale users list" || fail "CLI not working"
```

---

## References

- [Headscale GitHub](https://github.com/juanfont/headscale)
- [Headscale Docs](https://headscale.net/stable/)
- [Container Setup](https://headscale.net/stable/setup/install/container/)
- [Configuration Reference](https://headscale.net/stable/ref/configuration/)
- [Reverse Proxy Guide](https://headscale.net/stable/ref/integration/reverse-proxy/)
- [Cloudflare Incompatibility](https://github.com/juanfont/headscale/issues/1468) - **MUST read before deploy**
- [config-example.yaml](https://github.com/juanfont/headscale/blob/main/config-example.yaml)

---

## Open Questions

- [ ] Enable embedded DERP immediately or start without? (Recommendation: Phase 2)
- [ ] MagicDNS `base_domain` — use `ts.barta.cm` or something else?
- [ ] `override_local_dns: false` — home hosts rely on hsb0 AdGuard, don't override?
- [ ] Pin to specific version (e.g. `0.25.1`) or minor (`0.25`)? Check latest stable at deploy time.
- [ ] Watchtower: should it auto-update Headscale? (Recommendation: NO, pin version, manual updates)
