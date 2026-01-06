# P5000: hsb8 Uptime Kuma + Apprise (Parents' Network)

## Overview

Deploy independent monitoring stack on hsb8 for parents' infrastructure.
Complete separation from your network - no shared components, no dependencies.

## Network

- **Location**: Parents' home (ww87)
- **IP**: 192.168.1.100
- **Access**: http://192.168.1.100:3001
- **Independence**: Works without VPN, operates standalone

## Architecture

```
hsb8 (192.168.1.100)
├── Uptime Kuma (port 3001)
│   ├── Monitors all parents' services
│   └── Sends webhook to Apprise
│
└── Apprise Service (port 8000)
    ├── Receives webhooks from Uptime Kuma
    ├── Dad's notifications: Telegram + Email
    └── All alerts (no filtering)
```

## Implementation

### 1. Uptime Kuma Service

```nix
# hosts/hsb8/configuration.nix
services.uptime-kuma = {
  enable = true;
  settings = {
    PORT = "3001";
    HOST = "0.0.0.0";
  };
};

networking.firewall.allowedTCPPorts = [ 3001 ];
```

### 2. Apprise Service (Dad's Alerts)

```nix
# hosts/hsb8/configuration.nix
systemd.services.apprise-dad = {
  enable = true;
  description = "Apprise notification service for parents";
  wantedBy = [ "multi-user.target" ];

  serviceConfig = {
    Type = "simple";
    ExecStart = ''
      ${pkgs.apprise}/bin/apprise \
        -t "hsb8 Alert" \
        -b "$MESSAGE" \
        "$NOTIFY_URL"
    '';
    EnvironmentFile = config.age.secrets.uptime-kuma-env-hsb8.path;
    Restart = "always";
    RestartSec = "30s";
  };
};

# Apprise listens for webhooks
systemd.services.apprise-listener = {
  enable = true;
  description = "Apprise webhook listener";
  wantedBy = [ "multi-user.target" ];

  serviceConfig = {
    Type = "simple";
    ExecStart = ''
      ${pkgs.apprise}/bin/apprise \
        --listen 0.0.0.0:8000 \
        --config ${config.age.secrets.uptime-kuma-env-hsb8.path}
    '';
    Restart = "always";
  };
};

networking.firewall.allowedTCPPorts = [ 8000 ];
```

### 3. Secrets (Independent)

```nix
# hosts/hsb8/secrets.nix
age.secrets.uptime-kuma-env-hsb8 = {
  file = ../../secrets/uptime-kuma-env-hsb8.age;
  mode = "400";
  owner = "root";
  group = "root";
};
```

**Secrets file content** (`secrets/uptime-kuma-env-hsb8.age`):

```bash
# Dad's notification channels
NOTIFY_URL=telegram://token@telegram?discord=webhook_url&mailto:email@example.com
```

### 4. Uptime Kuma → Apprise Integration

**In Uptime Kuma UI** (http://192.168.1.100:3001):

1. Settings → Notifications → Add Notification
2. Type: **Webhook**
3. URL: `http://localhost:8000/notify`
4. Method: POST
5. Body: JSON with alert details
6. Save and test

**Webhook payload format** (Uptime Kuma sends):

```json
{
  "monitor": "Service Name",
  "status": "UP/DOWN",
  "message": "Details",
  "time": "Timestamp"
}
```

**Apprise processes** → Sends to Telegram + Email

---

## Monitors to Configure

### Core Services (High Priority)

| Monitor            | Type | Host               | Purpose         | Priority |
| ------------------ | ---- | ------------------ | --------------- | -------- |
| **Home Assistant** | HTTP | 192.168.1.100:8123 | Core automation | HIGH     |
| **MQTT Broker**    | MQTT | 192.168.1.100:1883 | Message bus     | HIGH     |
| **AdGuard Home**   | HTTP | 192.168.1.100:3000 | DNS/DHCP        | HIGH     |
| **SSH Access**     | TCP  | 192.168.1.100:22   | Server access   | HIGH     |

### Migration Period (Medium Priority)

| Monitor                 | Type | Host           | Purpose            | Notes                    |
| ----------------------- | ---- | -------------- | ------------------ | ------------------------ |
| **InfluxDB (Pi)**       | HTTP | [Pi IP]:8086   | Historical data    | Until migration complete |
| **Grafana (Pi)**        | HTTP | [Pi IP]:3000   | Data visualization | Until migration complete |
| **Temperature Logging** | HTTP | [Pi IP]:[port] | Dad's kitchen data | Legacy service           |

### Optional (Low Priority)

| Monitor         | Type | Host               | Purpose       |
| --------------- | ---- | ------------------ | ------------- |
| **Zigbee2MQTT** | HTTP | 192.168.1.100:8080 | Zigbee bridge |
| **gpc0**        | Ping | 192.168.1.154      | Gaming PC     |

---

## Alert Routing

### Dad's Alerts (All Events)

- **Channels**: Telegram + Email
- **Triggers**: All monitor status changes
- **Format**: Simple, clear messages
- **Examples**:
  - "hsb8 - Home Assistant is DOWN"
  - "hsb8 - MQTT Broker is UP"
  - "hsb8 - DNS resolution failed"

### Your Alerts (Via VPN)

- **Method**: When VPN connected, hsb0 Uptime Kuma monitors hsb8
- **Channels**: Your Apprise (SMS/Telegram)
- **Triggers**: Critical services only (HA, MQTT, DNS)
- **Format**: Brief, actionable

**Note**: Your alerts don't come from hsb8 - they come from hsb0 monitoring hsb8 via VPN.

---

## Implementation Steps

### Phase 1: Service Deployment

1. Add Uptime Kuma to `hosts/hsb8/configuration.nix`
2. Add Apprise service configuration
3. Create secrets file `secrets/uptime-kuma-env-hsb8.age`
4. Deploy configuration to hsb8

### Phase 2: Uptime Kuma Configuration

1. Access http://192.168.1.100:3001
2. Set up admin account
3. Configure all monitors from tables above
4. Add webhook notification to Apprise (localhost:8000/notify)
5. Test notifications

### Phase 3: Apprise Setup

1. Verify Apprise service is running
2. Test webhook endpoint: `curl -X POST http://localhost:8000/notify -d '{"test": "message"}'`
3. Verify Telegram notifications work
4. Verify Email notifications work
5. Document dad's notification preferences

### Phase 4: Documentation

1. Update `hosts/hsb8/README.md` with Uptime Kuma info
2. Create simple RUNBOOK for dad:
   - How to access dashboard
   - What alerts mean
   - Basic troubleshooting
   - Who to contact
3. Add to infrastructure docs

---

## Success Criteria

### Deployment

- [ ] Uptime Kuma service running on hsb8
- [ ] Web UI accessible at http://192.168.1.100:3001
- [ ] Apprise service running and listening on port 8000
- [ ] Webhook from Uptime Kuma reaches Apprise
- [ ] Dad receives Telegram notifications
- [ ] Dad receives Email notifications
- [ ] All monitors configured and working

### Independence

- [ ] Works without VPN connection
- [ ] No shared secrets with your network
- [ ] Separate configuration files
- [ ] Dad can manage his own alerts

### Parent Experience

- [ ] Dad knows dashboard URL
- [ ] Dad understands alert messages
- [ ] Simple troubleshooting guide exists
- [ ] Dad can restart services if needed

---

## Dependencies

- None (standalone, independent from your network)

---

## Related

- P4100: Your network monitoring
- P6000: Cloud services monitoring
