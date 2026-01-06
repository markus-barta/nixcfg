# P5000: hsb8 Uptime Kuma + Apprise (Parents' Network)

## Overview

Deploy independent monitoring stack on hsb8 for parents' infrastructure.
Complete separation from your network - no shared components, no dependencies.

## Network

- **Location**: Parents' home (ww87)
- **IP**: 192.168.1.100
- **Access**: http://192.168.1.100:3001
- **Independence**: Works without VPN, operates standalone

## Current State (2026-01-06)

| Component        | Status                                                    |
| ---------------- | --------------------------------------------------------- |
| **NixOS**        | ✅ 26.05 (Yarara), kernel 6.17.8                          |
| **Docker**       | ✅ Running (Home Assistant, Mosquitto, Watchtower)        |
| **Uptime Kuma**  | ❌ Not installed                                          |
| **Apprise**      | ❌ Not installed                                          |
| **AdGuard Home** | ✅ Running (DNS/DHCP at ww87 location)                    |
| **Resources**    | 7.7GB RAM (5.1GB available), 99GB disk free on zroot/root |

## Architecture

```
hsb8 (192.168.1.100)
├── Uptime Kuma (port 3001) - Native NixOS service
│   ├── Monitors all parents' services
│   └── Uses Apprise CLI for notifications
│
└── Apprise CLI (in uptime-kuma PATH)
    ├── Environment variables from agenix secret
    ├── Dad's notifications: Telegram + Email
    └── Supports $VAR_NAME expansion in URLs
```

## Implementation

### 1. Uptime Kuma Service (Native NixOS - same as hsb0)

```nix
# hosts/hsb8/configuration.nix

# ============================================================================
# Uptime Kuma - Service Monitoring
# ============================================================================
# Monitors service uptime and availability. Web interface: http://192.168.1.100:3001
# Uses native NixOS service (no Docker required).
# ============================================================================
services.uptime-kuma = {
  enable = true;
  settings = {
    PORT = "3001";
    HOST = "0.0.0.0"; # Listen on all interfaces
  };
};

# Apprise support for Uptime Kuma with Environment Variable expansion.
# This allows using $VAR_NAME in the Apprise URL within the Uptime Kuma UI.
# Tokens are stored securely in agenix and expanded by the wrapper script.
systemd.services.uptime-kuma = {
  path = [
    (pkgs.writeShellScriptBin "apprise" ''
      # Apprise Wrapper for Environment Variable Expansion
      # Usage in Uptime Kuma UI: tgram://$TELEGRAM_TOKEN/ChatID

      args=()
      for arg in "$@"; do
        # Use envsubst to safely expand environment variables
        # We provide the variables from the EnvironmentFile
        expanded_arg=$(echo "$arg" | ${pkgs.gettext}/bin/envsubst)
        args+=("$expanded_arg")
      done

      exec ${pkgs.apprise}/bin/apprise "''${args[@]}"
    '')
  ];
  serviceConfig.EnvironmentFile = [ config.age.secrets.uptime-kuma-env-hsb8.path ];
};

# Firewall - add 3001 to existing allowedTCPPorts
networking.firewall.allowedTCPPorts = [
  # ... existing ports ...
  3001 # Uptime Kuma web interface
];
```

### 2. Secrets Configuration

```nix
# hosts/hsb8/configuration.nix (add to existing age.secrets)

# Uptime Kuma environment variables (for Apprise tokens)
age.secrets.uptime-kuma-env-hsb8 = {
  file = ../../secrets/uptime-kuma-env-hsb8.age;
  mode = "400";
  owner = "root";
};
```

### 3. Secrets File Setup

**Update `secrets/secrets.nix`:**

```nix
# Uptime Kuma environment variables for hsb8 (Apprise tokens)
# Format: KEY=VALUE lines (TELEGRAM_TOKEN, etc.)
# Edit: agenix -e secrets/uptime-kuma-env-hsb8.age
"uptime-kuma-env-hsb8.age".publicKeys = markus ++ gb ++ hsb8;
```

**Create secret file:**

```bash
# From nixcfg directory on a machine with agenix
agenix -e secrets/uptime-kuma-env-hsb8.age
```

**Secret file content** (example):

```bash
# Dad's Telegram bot token (get from @BotFather)
TELEGRAM_TOKEN=123456789:ABCdefGHIjklMNOpqrsTUVwxyz

# Optional: Email SMTP credentials
# SMTP_USER=alerts@example.com
# SMTP_PASS=app-password-here
```

### 4. System Packages

```nix
# Add to environment.systemPackages
environment.systemPackages = with pkgs; [
  # ... existing packages ...
  apprise # Apprise CLI for Uptime Kuma notifications
];
```

---

## Monitors to Configure

### Core Services (High Priority)

| Monitor            | Type     | Target             | Purpose         |
| ------------------ | -------- | ------------------ | --------------- |
| **Home Assistant** | HTTP     | 192.168.1.100:8123 | Core automation |
| **MQTT Broker**    | TCP Port | 192.168.1.100:1883 | Message bus     |
| **AdGuard Home**   | HTTP     | 192.168.1.100:3000 | DNS/DHCP        |
| **DNS**            | DNS      | 192.168.1.100:53   | DNS resolution  |

### Optional (Low Priority)

| Monitor         | Type     | Target             | Purpose       |
| --------------- | -------- | ------------------ | ------------- |
| **Zigbee2MQTT** | HTTP     | 192.168.1.100:8080 | Zigbee bridge |
| **SSH**         | TCP Port | 192.168.1.100:22   | Server access |

---

## Alert Configuration

### In Uptime Kuma UI

1. Settings → Notifications → Add Notification
2. Type: **Apprise (Installed)**
3. Apprise URL: `tgram://$TELEGRAM_TOKEN/<chat_id>`
4. Test and save

### Telegram Setup (for Dad)

1. Create bot via @BotFather → get token
2. Get chat ID: send message to bot, then `https://api.telegram.org/bot<TOKEN>/getUpdates`
3. Add token to `uptime-kuma-env-hsb8.age`
4. Use in Uptime Kuma: `tgram://$TELEGRAM_TOKEN/<chat_id>`

---

## Implementation Steps

### Phase 1: Service Deployment

1. [ ] Update `secrets/secrets.nix` with new secret definition
2. [ ] Create `secrets/uptime-kuma-env-hsb8.age` with Telegram token
3. [ ] Add Uptime Kuma service to `hosts/hsb8/configuration.nix`
4. [ ] Add Apprise wrapper to systemd service
5. [ ] Add firewall rule for port 3001
6. [ ] Add `apprise` to system packages
7. [ ] Deploy configuration to hsb8

### Phase 2: Uptime Kuma Configuration (Manual in UI)

1. [ ] Access http://192.168.1.100:3001
2. [ ] Create admin account
3. [ ] Configure Apprise notification with Telegram
4. [ ] Add monitors from table above
5. [ ] Test notifications

### Phase 3: Documentation

1. [ ] Update `hosts/hsb8/README.md` with Uptime Kuma info
2. [ ] Update `hosts/hsb8/docs/RUNBOOK.md` with procedures
3. [ ] Create simple guide for Dad (optional)

---

## Success Criteria

### Deployment

- [ ] Uptime Kuma service running on hsb8 (native NixOS, not Docker)
- [ ] Web UI accessible at http://192.168.1.100:3001
- [ ] Apprise CLI available in uptime-kuma service PATH
- [ ] Environment variables loaded from agenix secret
- [ ] Dad receives Telegram notifications on service down/up
- [ ] All core monitors configured and working

### Independence

- [ ] Works without VPN connection
- [ ] Separate secrets file (`uptime-kuma-env-hsb8.age`)
- [ ] No dependencies on hsb0 or other home network services

---

## Risk Assessment

- **Risk Level**: 🟢 LOW
- **Impact**: Additive change, no impact on existing Docker services
- **Duration**: ~30 minutes deployment + ~15 minutes UI configuration
- **Rollback**: Remove service from configuration.nix, rebuild

---

## Dependencies

- None (standalone, independent from your network)

---

## Related

- P4100: hsb0 local network monitoring (completed)
- P5200: hsb0 Uptime Kuma installation (completed, reference implementation)
- P5300: hsb0 Apprise integration (completed, reference implementation)

---

## Reference: hsb0 Implementation

The hsb0 implementation in `hosts/hsb0/configuration.nix` (lines 386-420) serves as the reference:

- Native `services.uptime-kuma` module
- Apprise wrapper script with `envsubst` for variable expansion
- EnvironmentFile pointing to agenix secret
- Port 3001 on all interfaces
