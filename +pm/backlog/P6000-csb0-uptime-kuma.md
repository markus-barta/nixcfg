# P6000: csb0 Uptime Kuma - Cloud Services Monitoring

## Overview

Deploy Uptime Kuma on csb0 to monitor all cloud infrastructure services (csb0, csb1, and other cloud resources).

## Scope

- **Network**: Cloud infrastructure (public internet)
- **Instance**: csb0 (accessible via public IP or VPN)
- **Goal**: Monitor all cloud services independently from local network
- **Independence**: Works without VPN, no dependency on hsb0/hsb8

## Architecture

```
csb0 (Cloud Server)
├── Uptime Kuma (port 3001)
│   ├── Monitors csb0 services
│   └── Monitors csb1 services
│
└── Apprise (notifications)
    ├── Telegram
    └── Email
```

## Implementation

### 1. Uptime Kuma Service on csb0

```nix
# hosts/csb0/configuration.nix (if NixOS)
services.uptime-kuma = {
  enable = true;
  settings = {
    PORT = "3001";
    HOST = "0.0.0.0";
  };
};

networking.firewall.allowedTCPPorts = [ 3001 ];
```

**Or via Docker** (if csb0 is not NixOS):

```bash
docker run -d \
  --name uptime-kuma \
  --restart unless-stopped \
  -p 3001:3001 \
  -v uptime-kuma-data:/app/data \
  --name uptime-kuma \
  louislam/uptime-kuma:1
```

### 2. Apprise Integration (csb0)

```nix
# Separate from hsb0/h8
age.secrets.uptime-kuma-env-csb0 = {
  file = ../../secrets/uptime-kuma-env-csb0.age;
  mode = "400";
  owner = "root";
};
```

**Secrets file** (`secrets/uptime-kuma-env-csb0.age`):

```bash
# Your notification channels
NOTIFY_URL=telegram://token@telegram?mailto:your-email@example.com
```

### 3. Monitors to Configure

#### csb0 Services (High Priority)

| Monitor         | Type     | Host                     | Purpose          | Priority |
| --------------- | -------- | ------------------------ | ---------------- | -------- |
| **Traefik**     | HTTP     | https://traefik.barta.cm | Reverse proxy    | HIGH     |
| **SSH**         | TCP Port | csb0 public IP:2222      | Server access    | HIGH     |
| **Node-RED**    | HTTP     | https://home.barta.cm    | Automation flows | HIGH     |
| **Uptime Kuma** | HTTP     | http://localhost:3001    | Self-monitoring  | HIGH     |

#### csb1 Services (High Priority)

| Monitor       | Type     | Host                           | Purpose         | Priority |
| ------------- | -------- | ------------------------------ | --------------- | -------- |
| **InfluxDB**  | HTTP     | https://influxdb.barta.cm/ping | Metrics storage | HIGH     |
| **Docmost**   | HTTP     | https://docmost.barta.cm       | Documentation   | MEDIUM   |
| **Grafana**   | HTTP     | https://grafana.barta.cm       | Metrics viz     | MEDIUM   |
| **Paperless** | HTTP     | https://paperless.barta.cm     | Documents       | MEDIUM   |
| **SSH**       | TCP Port | csb1 public IP:2222            | Server access   | HIGH     |

#### Optional

| Monitor       | Type | Host                       | Purpose          |
| ------------- | ---- | -------------------------- | ---------------- |
| **Nextcloud** | HTTP | https://nextcloud.barta.cm | File sync        |
| **Bitwarden** | HTTP | https://bitwarden.barta.cm | Password manager |

### 4. Alert Routing

- **Channels**: Telegram + Email (same as your preference)
- **Triggers**: All monitor status changes
- **Format**: Clear, actionable messages

## Implementation Steps

### Phase 1: Service Deployment

1. Deploy Uptime Kuma on csb0 (NixOS or Docker)
2. Configure firewall (port 3001)
3. Set up Apprise with secrets
4. Test notifications

### Phase 2: Monitor Configuration

1. Access http://csb0:3001
2. Set up admin account
3. Add all monitors from tables above
4. Configure webhook to Apprise
5. Test all monitors

### Phase 3: Documentation

1. Update csb0 README with Uptime Kuma info
2. Document access URL
3. Add to infrastructure docs

## Success Criteria

- [ ] Uptime Kuma running on csb0
- [ ] Web UI accessible (public IP or VPN)
- [ ] All csb0 services monitored
- [ ] All csb1 services monitored
- [ ] Telegram notifications working
- [ ] Email notifications working
- [ ] Independent from local network

## Dependencies

- None (standalone cloud infrastructure)

## Timeline

- **Priority**: Medium (P6000 range)
- **Effort**: 2-3 hours
- **When**: After P4100 and P5000 complete

## Related

- P4100: Local network monitoring (hsb0)
- P5000: Parents' network monitoring (hsb8)
