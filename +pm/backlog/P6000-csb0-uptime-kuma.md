# P6000: csb0 Uptime Kuma - Cloud Services Monitoring

## Overview

Deploy Uptime Kuma on csb0 to monitor all cloud infrastructure services (csb0, csb1, and other cloud resources).

**Status**: 📋 Ready for implementation  
**Criticality**: 🔴 HIGH (csb0 is critical infrastructure)  
**Build Host**: csb0 (local NixOS build)

## Scope

- **Network**: Cloud infrastructure (public internet)
- **Instance**: csb0 (accessible via public IP)
- **Goal**: Monitor all cloud servers and service types (NixOS, Docker, any type of service)
- **Independence**: Works without VPN, no dependency on hsb0/hsb8

## Architecture

```
csb0 (Cloud Server)
├── Uptime Kuma (port 3001, HTTPS via Traefik)
│   ├── Monitors csb0 services
│   └── Monitors csb1 services
│
├── Apprise (notifications)
│   ├── Telegram
│   └── Email
│
└── Firewall: Port 3001 closed to public, HTTPS only
```

**Security**: Uptime Kuma NOT exposed directly. Access via:

- Traefik reverse proxy: `https://uptime.barta.cm`
- Internal only: `http://localhost:3001` (for debugging)

## Implementation

### 1. Uptime Kuma Service on csb0

**NixOS Configuration** (via Hokage module):

```nix
# hosts/csb0/configuration.nix
{ config, ... }:

{
  # Uptime Kuma service
  services.uptime-kuma = {
    enable = true;
    settings = {
      PORT = "3001";
      HOST = "0.0.0.0";
    };
  };

  # Firewall - keep port 3001 internal only
  # Access via Traefik reverse proxy with HTTPS
  networking.firewall.allowedTCPPorts = [
    # 3001  # ❌ DO NOT expose publicly
  ];

  # Secrets for notifications
  age.secrets.uptime-kuma-env = {
    file = ../../secrets/uptime-kuma-env.age;
    owner = "uptime-kuma";
    group = "uptime-kuma";
    mode = "400";
  };

  # Firewall: Port 3001 stays internal (no public exposure)
  # Only HTTPS via Traefik (ports 80/443 already open)
}
```

**Traefik Docker Configuration** (add to `~/docker/docker-compose.yml` on csb0):

```yaml
# Add to the traefik service labels
services:
  traefik:
    # ... existing config ...
    labels:
      # ... existing labels ...
      # Uptime Kuma route
      - "traefik.http.routers.uptime-kuma.rule=Host(\`uptime.barta.cm\`)"
      - "traefik.http.routers.uptime-kuma.entrypoints=websecure"
      - "traefik.http.routers.uptime-kuma.tls=true"
      - "traefik.http.services.uptime-kuma.loadbalancer.server.port=3001"
      - "traefik.http.routers.uptime-kuma.middlewares=security-headers@file"
```

**Build & Deploy** (on csb0 directly):

```bash
# 1. SSH to csb0
ssh mba@cs0.barta.cm -p 2222

# 2. Navigate to config repo
cd ~/Code/nixcfg

# 3. Build and test locally (NixOS can build on itself)
sudo nixos-rebuild test --flake .#csb0

# 4. Verify service
systemctl status uptime-kuma

# 5. If all good, switch to generation
sudo nixos-rebuild switch --flake .#csb0
```

**Alternative: Remote deploy from local machine**:

```bash
# From imac0/gpc0 (no SSH needed to csb0 for build)
cd ~/Code/nixcfg
nixos-rebuild switch --flake .#csb0 --target-host mba@cs0.barta.cm --use-remote-sudo
```

### 2. Secrets Management (agenix)

**Create the secrets file:**

```bash
# On any machine with agenix (imac0, gpc0, or csb0)
cd ~/Code/nixcfg

# Create plaintext file
echo 'NOTIFY_URL=telegram://123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11@telegram?mailto:your-email@example.com' > /tmp/uptime.env

# Encrypt with agenix
agenix -e secrets/uptime-kuma-env.age

# Clean up plaintext
rm /tmp/uptime.env

# Verify encrypted file size (>1KB)
ls -lh secrets/uptime-kuma-env.age
```

**Update secrets.nix** (if entry doesn't exist):

```nix
# secrets/secrets.nix
"uptime-kuma-env.age".publicKeys = markus ++ csb0;
```

**Reference in config:**

- Already included in configuration.nix above
- Service will read from `/run/agenix/uptime-kuma-env`

### 3. DNS Configuration

**Add DNS record** (Cloudflare):

```
Type: A
Name: uptime
Content: 85.235.65.226 (csb0 IP)
Proxy status: DNS only (gray cloud)
TTL: Auto
```

### 4. Monitors to Configure

**Access Uptime Kuma**: `https://uptime.barta.cm` (after Traefik config)

#### csb0 Services (High Priority)

| Monitor         | Type     | Host                       | Purpose          | Priority |
| --------------- | -------- | -------------------------- | ---------------- | -------- |
| **Traefik**     | HTTP     | `https://traefik.barta.cm` | Reverse proxy    | HIGH     |
| **SSH**         | TCP Port | `cs0.barta.cm:2222`        | Server access    | HIGH     |
| **Node-RED**    | HTTP     | `https://home.barta.cm`    | Automation flows | HIGH     |
| **Uptime Kuma** | HTTP     | `https://uptime.barta.cm`  | Self-monitoring  | HIGH     |
| **MQTT**        | TCP Port | `cs0.barta.cm:1883`        | IoT messaging    | HIGH     |

#### csb1 Services (High Priority)

| Monitor       | Type     | Host                             | Purpose         | Priority |
| ------------- | -------- | -------------------------------- | --------------- | -------- |
| **InfluxDB**  | HTTP     | `https://influxdb.barta.cm/ping` | Metrics storage | HIGH     |
| **Grafana**   | HTTP     | `https://grafana.barta.cm`       | Metrics viz     | HIGH     |
| **Docmost**   | HTTP     | `https://docmost.barta.cm`       | Documentation   | MEDIUM   |
| **Paperless** | HTTP     | `https://paperless.barta.cm`     | Documents       | MEDIUM   |
| **SSH**       | TCP Port | `cs1.barta.cm:2222`              | Server access   | HIGH     |

#### Optional (Future)

| Monitor       | Type | Host                         | Purpose          |
| ------------- | ---- | ---------------------------- | ---------------- |
| **Nextcloud** | HTTP | `https://nextcloud.barta.cm` | File sync        |
| **Bitwarden** | HTTP | `https://bitwarden.barta.cm` | Password manager |

### 5. Alert Routing

**Configuration in Uptime Kuma UI:**

1. Settings → Notifications → Add Apprise
2. Use `NOTIFY_URL` from secrets file
3. Test notification

**Channels**: Telegram + Email (via Apprise)  
**Triggers**: All monitor status changes  
**Format**: Clear, actionable messages with host/service names

## Implementation Steps

### Phase 0: Pre-Flight Checks

```bash
# 1. Verify csb0 is reachable
ping -c1 cs0.barta.cm

# 2. Check current service state
ssh mba@cs0.barta.cm -p 2222 "systemctl status uptime-kuma 2>/dev/null || echo 'Not installed'"

# 3. Verify secrets exist
ls -lh secrets/uptime-kuma-env.age

# 4. Check git status
git status
git diff  # Review all changes before proceeding

# 5. Verify Traefik is running
ssh mba@cs0.barta.cm -p 2222 "docker ps | grep traefik"
```

### Phase 1: Secrets & Configuration

1. **Create secrets** (see Section 2 above)
   - Encrypt `uptime-kuma-env.age`
   - Verify `secrets.nix` entry exists

2. **Update csb0 configuration**
   - Add Uptime Kuma service to `hosts/csb0/configuration.nix`
   - Add Traefik virtual host config
   - Commit changes: `git add . && git commit -m "feat(csb0): deploy uptime-kuma"`

3. **Push to remote**
   ```bash
   git push origin main
   ```

### Phase 2: Service Deployment

```bash
# 1. SSH to csb0
ssh mba@cs0.barta.cm -p 2222

# 2. Navigate to config
cd ~/Code/nixcfg

# 3. Build and test (dry run)
sudo nixos-rebuild test --flake .#csb0

# 4. Verify service started
systemctl status uptime-kuma

# 5. Check logs if needed
journalctl -u uptime-kuma -n 50

# 6. Verify Traefik routing
docker logs traefik 2>&1 | grep uptime

# 7. If all good, switch to generation
sudo nixos-rebuild switch --flake .#csb0
```

### Phase 3: Initial Setup

1. **Access Uptime Kuma**
   - URL: `https://uptime.barta.cm`
   - First login: Create admin account
   - Save credentials in 1Password

2. **Configure notifications**
   - Settings → Notifications → Add Apprise
   - Copy `NOTIFY_URL` from secrets file
   - Test notification

3. **Add monitors**
   - Add all monitors from tables above
   - Set retry intervals (recommended: 60s)
   - Enable retries (3x)
   - Configure heartbeat timeout (60s)

4. **Test each monitor**
   - Verify all show "UP" status
   - Test notification by temporarily failing a monitor
   - Verify Telegram/email alerts arrive

5. **Verify Traefik routing**
   - Check `https://uptime.barta.cm` loads correctly
   - Verify SSL certificate is valid

### Phase 4: Documentation & Tests

1. **Update csb0 README**
   - Add Uptime Kuma to "Critical Services" table
   - Document access URL: `https://uptime.barta.cm`
   - Add to "Services (Docker)" section (or create new "Services (NixOS)")

2. **Create test script**

   ```bash
   # hosts/csb0/tests/T08-uptime-kuma.sh
   #!/usr/bin/env bash
   # Test Uptime Kuma via Traefik
   curl -sf https://uptime.barta.cm/api/health || exit 1
   ```

3. **Update infrastructure docs**
   - Add Uptime Kuma to `docs/INFRASTRUCTURE.md` if monitoring section exists
   - Update OPS-STATUS.md

4. **Run full test suite**

   ```bash
   cd hosts/csb0/tests
   for f in T*.sh; do ./$f; done
   ```

5. **Commit and push**
   ```bash
   git add .
   git commit -m "feat(csb0): deploy uptime-kuma monitoring"
   git push origin main
   ```

## Success Criteria

### Pre-Deployment

- [ ] Secrets encrypted: `secrets/uptime-kuma-env.age` exists
- [ ] `secrets.nix` entry added for csb0
- [ ] Configuration committed and pushed
- [ ] Build host (gpc0) verified reachable

### Deployment

- [ ] Uptime Kuma service running on csb0
- [ ] Service healthy: `systemctl status uptime-kuma` = active
- [ ] Traefik virtual host configured
- [ ] HTTPS accessible: `https://uptime.barta.cm`

### Configuration

- [ ] Admin account created (credentials in 1Password)
- [ ] Apprise notifications configured
- [ ] Telegram alerts tested and working
- [ ] Email alerts tested and working

### Monitoring

- [ ] All csb0 services monitored (5 monitors)
- [ ] All csb1 services monitored (5 monitors)
- [ ] All monitors show "UP" status
- [ ] Self-monitoring (Uptime Kuma itself) configured

### Documentation & Tests

- [ ] csb0 README updated with Uptime Kuma section
- [ ] Test script created: `hosts/csb0/tests/T08-uptime-kuma.sh`
- [ ] Test script passes
- [ ] OPS-STATUS.md updated
- [ ] Changes committed and pushed

### Security

- [ ] Port 3001 NOT exposed to public internet
- [ ] Access only via HTTPS reverse proxy
- [ ] Firewall rules verified
- [ ] Secrets file size >1KB (encrypted)
- [ ] DNS record added: `uptime.barta.cm`

## Dependencies

- ✅ csb0 infrastructure (already deployed)
- ✅ Traefik on csb0 (already running)
- ✅ agenix configured (already in use)
- 📋 DNS record for `uptime.barta.cm` (needs to be added)

## Risk Assessment

**🔴 HIGH** - csb0 is critical infrastructure

**Mitigations:**

- Build on gpc0 (verified NixOS build host)
- Test deployment first (`nixos-rebuild test`, not `switch`)
- Rollback available: `sudo nixos-rebuild switch --rollback`
- No public exposure of port 3001
- Secrets encrypted with agenix

## Timeline

- **Priority**: Medium-High (P6000 range)
- **Effort**: 3-4 hours (includes testing)
- **When**: Ready to deploy now
- **Build Time**: ~15-20 minutes (on gpc0)

## Related

- P4100: Local network monitoring (hsb0)
- P5000: Parents' network monitoring (hsb8)
- **csb0 README**: `hosts/csb0/README.md`
- **csb0 RUNBOOK**: `hosts/csb0/docs/RUNBOOK.md`

## Quick Reference Commands

```bash
# Build & deploy (on csb0)
ssh mba@cs0.barta.cm -p 2222
cd ~/Code/nixcfg
sudo nixos-rebuild test --flake .#csb0
systemctl status uptime-kuma
sudo nixos-rebuild switch --flake .#csb0

# Test
curl -sf https://uptime.barta.cm/api/health

# Rollback (if needed)
ssh mba@cs0.barta.cm -p 2222 "sudo nixos-rebuild switch --rollback"

# Alternative: Remote deploy from local
cd ~/Code/nixcfg
nixos-rebuild switch --flake .#csb0 --target-host mba@cs0.barta.cm --use-remote-sudo
```
