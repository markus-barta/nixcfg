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

## Adding Hosts

### Adding a macOS Host

macOS hosts use Home Manager with a launchd agent. The token is stored in a plain file.

**Step 1: Create the token file on the macOS host**

```bash
# On the macOS host (e.g., imac0)
mkdir -p ~/.config/nixfleet
echo "YOUR_API_TOKEN_HERE" > ~/.config/nixfleet/token
chmod 600 ~/.config/nixfleet/token
```

**Step 2: Enable the agent in Home Manager**

Edit `hosts/<hostname>/home.nix`:

```nix
{
  imports = [
    ../../modules/home/nixfleet-agent.nix
  ];

  services.nixfleet-agent = {
    enable = true;
    interval = 10;  # Poll every 10 seconds
    # Use absolute paths (~ doesn't expand in launchd)
    tokenFile = "/Users/<username>/.config/nixfleet/token";
    nixcfgPath = "/Users/<username>/Code/nixcfg";
  };
}
```

**Step 3: Rebuild**

```bash
home-manager switch --flake ~/Code/nixcfg#<username>@<hostname>
```

**Step 4: Verify**

```bash
# Check if agent is running
launchctl list | grep nixfleet

# Check logs
tail -f /tmp/nixfleet-agent.err
```

---

### Adding a NixOS Host

NixOS hosts use a systemd service. The token is stored encrypted with agenix.

**Step 1: Add the host key to secrets.nix (if not already)**

Get the host's SSH key and add it to `secrets/secrets.nix`:

```bash
# On the NixOS host
cat /etc/ssh/ssh_host_rsa_key.pub
```

Edit `secrets/secrets.nix`:

```nix
# Add host key
myhost = [
  "ssh-rsa AAAAB3..."
];

# Add to nixfleet-token.age publicKeys
"nixfleet-token.age".publicKeys = markus ++ hsb0 ++ hsb8 ++ myhost;
```

**Step 2: Rekey the secret (if host key was added)**

```bash
# On a machine with your personal SSH key (~/.ssh/id_rsa)
cd ~/Code/nixcfg
agenix --rekey
```

**Step 3: Create the encrypted token (first time only)**

```bash
# On a machine with your personal SSH key
cd ~/Code/nixcfg
agenix -e secrets/nixfleet-token.age
# Editor opens - paste the token (just the token, no variable name):
# 5496cb179f581b9269091ea3eaa0a52870409a200c99b44dcc7aaaa6ec160270
# Save and exit
```

**Step 4: Enable the agent in NixOS configuration**

Edit `hosts/<hostname>/configuration.nix`:

```nix
{ config, ... }:
{
  imports = [
    ../../modules/nixfleet-agent.nix
  ];

  # Load the encrypted token
  age.secrets.nixfleet-token.file = ../../secrets/nixfleet-token.age;

  services.nixfleet-agent = {
    enable = true;
    interval = 10;  # Poll every 10 seconds
    tokenFile = config.age.secrets.nixfleet-token.path;
  };
}
```

**Step 5: Commit, push, and rebuild**

```bash
# Commit the changes
git add -A && git commit -m "feat: enable nixfleet agent on <hostname>" && git push

# On the NixOS host (or via SSH)
cd ~/Code/nixcfg && git pull
sudo nixos-rebuild switch --flake .#<hostname>
```

**Step 6: Verify**

```bash
# Check service status
systemctl status nixfleet-agent.timer
systemctl status nixfleet-agent.service

# Check logs
journalctl -u nixfleet-agent -f
```

---

### Host Registration in Dashboard

When a host's agent starts, it automatically registers with the dashboard. The dashboard will show:

- **Hostname**: Detected from `hostname -s`
- **OS Type**: NixOS or macOS (auto-detected)
- **Location**: cloud/home/work/game (based on hostname pattern)
- **Status**: Online/Offline (based on last heartbeat)
- **Git Hash**: Current commit in nixcfg repo

---

### Watching Agent Logs

To see your local agent respond to commands from the web UI:

**macOS:**

```bash
tail -f /tmp/nixfleet-agent.log /tmp/nixfleet-agent.err
```

**NixOS:**

```bash
journalctl -u nixfleet-agent -f
```

**Server-side (dashboard logs on csb1):**

```bash
ssh -p 2222 mba@152.53.64.166 "docker logs -f nixfleet"
```

---

### Troubleshooting

| Issue                        | Solution                                                              |
| ---------------------------- | --------------------------------------------------------------------- |
| Agent not starting           | Check logs: `/tmp/nixfleet-agent.err` (macOS) or `journalctl` (NixOS) |
| "Missing required commands"  | Ensure `home-manager` or `nixos-rebuild` is in PATH                   |
| "Registration failed"        | Check token is correct and dashboard is reachable                     |
| Host shows as Offline        | Check agent is running and can reach `fleet.barta.cm`                 |
| "nixcfg directory not found" | Use absolute paths in config (no `~`)                                 |

## API Endpoints

| Endpoint                   | Method   | Auth    | Description              |
| -------------------------- | -------- | ------- | ------------------------ |
| `/`                        | GET      | Session | Dashboard UI             |
| `/login`                   | GET/POST | -       | Login page               |
| `/logout`                  | GET      | Session | Logout                   |
| `/api/hosts`               | GET      | Session | List all hosts           |
| `/api/hosts/{id}`          | DELETE   | Session | Remove host from fleet   |
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
