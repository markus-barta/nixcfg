# NixFleet

Simple fleet management dashboard for NixOS and macOS hosts.

## Features

- **Web Dashboard**: View all hosts, their status, and trigger updates
- **Unified Management**: Same agent pattern for NixOS and macOS
- **Authentication**: Password + optional TOTP (2FA)
- **Agent-based**: Hosts poll for commands (works through NAT/firewalls)
- **Docker**: Runs as a container on csb1

## Architecture

```text
┌─────────────────────────────────────────────────────────────────────┐
│                        NIXFLEET DASHBOARD                           │
│                     (Docker on csb1)                                │
│                     fleet.barta.cm                                  │
└─────────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
              ▼               ▼               ▼
        ┌──────────┐    ┌──────────┐    ┌──────────┐
        │   hsb0   │    │   hsb1   │    │  imac0   │
        │  (agent) │    │  (agent) │    │  (agent) │
        │          │    │          │    │          │
        │ NixOS    │    │ NixOS    │    │ macOS    │
        │ rebuild  │    │ rebuild  │    │ hm switch│
        └──────────┘    └──────────┘    └──────────┘
```

## Quick Start

### 1. Generate Credentials

```bash
# Generate password hash (bcrypt required)
python3 -c "import bcrypt; print(bcrypt.hashpw(b'your-password', bcrypt.gensalt()).decode())"

# Generate API token (required in production)
openssl rand -hex 32

# Generate TOTP secret (optional, for 2FA)
python3 -c "import pyotp; print(pyotp.random_base32())"
```

### 2. Deploy Dashboard (on csb1)

```bash
cd ~/docker/nixfleet

# Create .env file
cat > .env << EOF
NIXFLEET_PASSWORD_HASH=<your-bcrypt-hash>
NIXFLEET_API_TOKEN=<your-api-token>
NIXFLEET_TOTP_SECRET=<your-totp-secret>  # Optional, for 2FA
# NIXFLEET_REQUIRE_TOTP=true  # Uncomment to enforce 2FA
EOF

# Start the container
docker compose up -d
```

### 3. Configure DNS

Add to Cloudflare:

```text
fleet.barta.cm → 152.53.64.166 (csb1)
```

### 4. Deploy Agents

Copy the agent script to each host:

```bash
# On each host
curl -o ~/.local/bin/nixfleet-agent https://fleet.barta.cm/agent/nixfleet-agent.sh
chmod +x ~/.local/bin/nixfleet-agent

# Set environment
export NIXFLEET_URL="https://fleet.barta.cm"
export NIXFLEET_TOKEN="<your-api-token>"

# Run (or add to systemd/launchd)
nixfleet-agent
```

## Agent Systemd Service (NixOS)

```nix
systemd.services.nixfleet-agent = {
  description = "NixFleet Agent";
  after = [ "network.target" ];
  wantedBy = [ "multi-user.target" ];
  environment = {
    NIXFLEET_URL = "https://fleet.barta.cm";
    NIXFLEET_TOKEN = "your-token-here";  # Use agenix in production
  };
  serviceConfig = {
    ExecStart = "${pkgs.bash}/bin/bash /path/to/nixfleet-agent.sh";
    Restart = "always";
    RestartSec = 60;
  };
};
```

## Agent LaunchAgent (macOS)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>cm.barta.nixfleet-agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/markus/.local/bin/nixfleet-agent</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>NIXFLEET_URL</key>
        <string>https://fleet.barta.cm</string>
        <key>NIXFLEET_TOKEN</key>
        <string>your-token-here</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

## API Endpoints

| Endpoint                   | Method   | Auth    | Description              |
| -------------------------- | -------- | ------- | ------------------------ |
| `/`                        | GET      | Session | Dashboard UI             |
| `/login`                   | GET/POST | -       | Login page               |
| `/logout`                  | GET      | Session | Logout                   |
| `/api/hosts`               | GET      | Session | List all hosts           |
| `/api/hosts/{id}/register` | POST     | Token   | Register/update host     |
| `/api/hosts/{id}/poll`     | GET      | Token   | Agent polls for commands |
| `/api/hosts/{id}/status`   | POST     | Token   | Agent reports status     |
| `/api/hosts/{id}/command`  | POST     | Session | Queue command            |
| `/api/hosts/{id}/logs`     | GET      | Session | Get command history      |

## Commands

| Command       | Description                                         |
| ------------- | --------------------------------------------------- |
| `pull`        | Run `git pull` in nixcfg                            |
| `switch`      | Run `nixos-rebuild switch` or `home-manager switch` |
| `pull-switch` | Run both in sequence                                |
| `test`        | Run host test suite (`hosts/<host>/tests/T*.sh`)    |

## Security

### Authentication

- **Password**: bcrypt hashed (required, validated at startup)
- **TOTP**: Optional 2FA via authenticator apps (enforceable via `REQUIRE_TOTP`)
- **Sessions**: HTTP-only, secure, same-site cookies with CSRF tokens
- **Agent API**: Bearer token authentication (fails closed when unset)

### Protections

- **Rate limiting**: 5 login attempts/min, 30 agent registrations/min, 60 polls/min
- **CSRF protection**: All state-changing UI actions require CSRF token
- **Input validation**: Host IDs validated against strict pattern (`^[a-zA-Z][a-zA-Z0-9-]{0,62}$`)
- **Security headers**: HSTS, X-Frame-Options, CSP (production only)
- **Fail-closed**: Missing API token = agents cannot connect
- **No sensitive data in logs**: Passwords never logged

### Environment Variables

| Variable                 | Required   | Description                                                         |
| ------------------------ | ---------- | ------------------------------------------------------------------- |
| `NIXFLEET_PASSWORD_HASH` | Yes        | bcrypt hash of admin password (must start with `$2b$` or `$2a$`)    |
| `NIXFLEET_API_TOKEN`     | Yes (prod) | Token for agent authentication - fails closed if unset              |
| `NIXFLEET_TOTP_SECRET`   | No         | Base32-encoded TOTP secret for 2FA                                  |
| `NIXFLEET_REQUIRE_TOTP`  | No         | Set to `true` to enforce 2FA (fails startup if TOTP not configured) |
| `NIXFLEET_DEV_MODE`      | No         | Set to `true` for localhost testing (relaxes security)              |
| `NIXFLEET_DATA_DIR`      | No         | Database directory (default: `/data`)                               |

### Startup Validation

The service will **fail to start** if:

- `bcrypt` package is not installed
- `NIXFLEET_PASSWORD_HASH` is not set or not a valid bcrypt hash
- `NIXFLEET_API_TOKEN` is not set (unless in DEV_MODE)
- `NIXFLEET_REQUIRE_TOTP=true` but TOTP secret/library is missing
