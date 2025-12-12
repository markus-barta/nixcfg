# Secrets Workflow

This document defines the secrets management strategy for the nixcfg infrastructure.

## Overview: Two-Tier Approach

| Tier                            | Scope                              | Tool             | Decrypt Trigger   |
| ------------------------------- | ---------------------------------- | ---------------- | ----------------- |
| **Tier 1: NixOS Secrets**       | System services, Docker containers | agenix           | Automatic at boot |
| **Tier 2: Workstation Secrets** | macOS/developer machines           | age (standalone) | Manual            |

---

## Tier 1: NixOS Secrets

For all NixOS hosts (hsb0, hsb1, hsb8, csb0, csb1, gpc0). Covers both system services and Docker containers.

### Location

| State           | Path                           | Git Status    |
| --------------- | ------------------------------ | ------------- |
| Encrypted       | `secrets/<purpose>-<host>.age` | ✅ Committed  |
| Decrypted       | `/run/agenix/<purpose>-<host>` | N/A (runtime) |
| Key definitions | `secrets/secrets.nix`          | ✅ Committed  |

### Naming Convention

**Pattern**: `<purpose>-<host>.age`

| Component | Description            | Examples                                            |
| --------- | ---------------------- | --------------------------------------------------- |
| `purpose` | What the secret is for | `mqtt`, `static-leases`, `tapo-c210`, `opus-stream` |
| `host`    | Which host decrypts it | `hsb0`, `hsb1`, `hsb8`                              |

**Examples**:

```
secrets/
├── mqtt-hsb0.age              # MQTT credentials for hsb0
├── mqtt-hsb1.age              # MQTT credentials for hsb1
├── static-leases-hsb0.age     # DHCP leases for hsb0
├── static-leases-hsb8.age     # DHCP leases for hsb8
├── tapo-c210-hsb1.age         # Camera credentials for hsb1
├── opus-stream-hsb1.age       # Docker container env for hsb1
└── secrets.nix                # Key definitions
```

### File Formats

Two formats are supported, depending on the secret type:

#### Format A: KEY=VALUE (Credentials)

For credentials, tokens, and simple configuration. Compatible with systemd `EnvironmentFile` and Docker `--env-file`.

```bash
# Example: secrets/mqtt-hsb1.age
MQTT_HOST=localhost
MQTT_USER=smarthome
MQTT_PASS=secretpassword
```

**Use for**: MQTT credentials, API tokens, database passwords, Docker env files.

#### Format B: JSON (Structured Data)

For structured data like arrays or complex objects.

```json
[
  { "mac": "AA:BB:CC:DD:EE:FF", "ip": "192.168.1.100", "hostname": "device1" },
  { "mac": "11:22:33:44:55:66", "ip": "192.168.1.101", "hostname": "device2" }
]
```

**Use for**: DHCP static leases, complex configuration that needs parsing.

### Tooling

| Action             | Command                               |
| ------------------ | ------------------------------------- |
| Create/edit secret | `just edit-secret secrets/<name>.age` |
| Rekey all secrets  | `just rekey`                          |
| Get host SSH key   | `just keyscan` (run on target host)   |

### Workflow: Adding a New Secret

```bash
# 1. Get the host's SSH public key (run ON the target host)
ssh hsb1 "cat /etc/ssh/ssh_host_rsa_key.pub"

# 2. Add host key to secrets/secrets.nix
#    hsb1 = [ "ssh-rsa AAAA..." ];

# 3. Define the secret in secrets/secrets.nix
#    "mqtt-hsb1.age".publicKeys = markus ++ hsb1;

# 4. Create the encrypted secret
just edit-secret secrets/mqtt-hsb1.age
# Editor opens - add content, save, exit

# 5. Reference in host configuration.nix
age.secrets.mqtt-hsb1 = {
  file = ../../secrets/mqtt-hsb1.age;
  mode = "400";
  owner = "root";
};

# 6. Use in service
systemd.services.myservice.serviceConfig.EnvironmentFile =
  config.age.secrets.mqtt-hsb1.path;
# Or for Docker:
# docker run --env-file /run/agenix/mqtt-hsb1 ...

# 7. Deploy
just switch hsb1
```

### Usage in NixOS Configuration

**For systemd services**:

```nix
age.secrets.mqtt-hsb1 = {
  file = ../../secrets/mqtt-hsb1.age;
  mode = "400";
  owner = "root";
};

systemd.services.mqtt-publisher = {
  serviceConfig.EnvironmentFile = config.age.secrets.mqtt-hsb1.path;
  # Service can now access $MQTT_HOST, $MQTT_USER, $MQTT_PASS
};
```

**For Docker containers**:

```nix
age.secrets.opus-stream-hsb1 = {
  file = ../../secrets/opus-stream-hsb1.age;
  owner = "mba";  # User running Docker
  mode = "400";
};

# In docker-compose or run command:
# docker run --env-file /run/agenix/opus-stream-hsb1 ...
```

**For scripts (via bash sourcing)**:

```nix
systemd.services.ups-mqtt = {
  script = ''
    source ${config.age.secrets.mqtt-hsb0.path}
    # Now $MQTT_HOST, $MQTT_USER, $MQTT_PASS are available
    mosquitto_pub -h "$MQTT_HOST" -u "$MQTT_USER" -P "$MQTT_PASS" ...
  '';
};
```

---

## Tier 1b: Runbook Secrets (Documentation)

Human-readable emergency documentation with sensitive information. NOT consumed by NixOS - for sysop reference only.

### Location

| State     | Path                                      | Git Status    |
| --------- | ----------------------------------------- | ------------- |
| Encrypted | `hosts/<host>/runbook-secrets.age`        | ✅ Committed  |
| Decrypted | `hosts/<host>/secrets/runbook-secrets.md` | ❌ Gitignored |

**Rationale**: Kept near host for locality. These are documentation, not system config.

### Tooling

| Action                | Command                               |
| --------------------- | ------------------------------------- |
| List status           | `just list-runbook-secrets`           |
| Decrypt for editing   | `just decrypt-runbook-secrets [host]` |
| Encrypt after editing | `just encrypt-runbook-secrets [host]` |

### Workflow

```bash
# See current status (shows which hosts have secrets, timestamps)
just list-runbook-secrets

# Decrypt a specific host's secrets for editing
just decrypt-runbook-secrets hsb1

# Edit the plain text file
vim hosts/hsb1/secrets/runbook-secrets.md

# Re-encrypt when done
just encrypt-runbook-secrets hsb1

# Commit the encrypted version
git add hosts/hsb1/runbook-secrets.age
git commit -m "Update hsb1 runbook secrets"
```

### Content Guidelines

Runbook secrets should contain:

- 1Password vault/item references (preferred over actual passwords)
- Service URLs and ports
- Recovery procedures that need credentials
- Emergency access information

**Example structure**:

```markdown
# hsb1 Runbook Secrets

## SSH Access

- User: mba
- Key: ~/.ssh/id_rsa (1Password: "SSH Key - Personal")

## Home Assistant

- URL: http://hsb1:8123
- Admin: admin (1Password: "Home Assistant - hsb1")

## MQTT Broker

- User: smarthome
- Password: (1Password: "Mosquitto - hsb1")
```

---

## Tier 2: Workstation Secrets

For macOS hosts (imac0, mba-mbp-work) and non-NixOS machines. These are personal secrets not managed by Nix.

### Location

**Separate private repository**: `~/Secrets/` → `github:youruser/secrets-private`

| State     | Path                                        | Git Status                  |
| --------- | ------------------------------------------- | --------------------------- |
| Encrypted | `~/Secrets/encrypted/<category>/<name>.age` | ✅ Committed (private repo) |
| Decrypted | `~/Secrets/decrypted/<category>/<name>`     | ❌ Gitignored               |
| Scripts   | `~/Secrets/scripts/`                        | ✅ Committed                |

**Why separate repo?**

- nixcfg may be shared/public
- Personal secrets should be isolated
- Cleaner separation of concerns
- Different backup/sync strategy

### Directory Structure

```
~/Secrets/
├── encrypted/                 # ✅ Git-tracked
│   ├── api-keys/
│   │   ├── openai.age
│   │   ├── github.age
│   │   └── cloudflare.age
│   ├── env/
│   │   ├── personal.env.age
│   │   └── work.env.age
│   └── ssh/
│       └── id_rsa_backup.age
│
├── decrypted/                 # ❌ Gitignored
│   ├── api-keys/
│   ├── env/
│   └── ssh/
│
├── scripts/
│   ├── encrypt.sh             # Encrypt files
│   ├── decrypt.sh             # Decrypt files
│   └── list.sh                # Show status
│
├── .gitignore
└── README.md
```

### Encryption Key

Uses SSH key directly: `~/.ssh/id_rsa`

- Simpler (no extra key to manage)
- Already backed up
- Same key used for agenix editing

### Tooling (Scripts)

```bash
# Encrypt a single file
~/Secrets/scripts/encrypt.sh api-keys/openai

# Decrypt a single file
~/Secrets/scripts/decrypt.sh api-keys/openai

# Encrypt all changed files
~/Secrets/scripts/encrypt.sh --all

# Decrypt all files
~/Secrets/scripts/decrypt.sh --all

# Show status (what's encrypted, what's decrypted, timestamps)
~/Secrets/scripts/list.sh
```

### Workflow: Initial Setup

```bash
# 1. Create directory structure
mkdir -p ~/Secrets/{encrypted,decrypted,scripts}
mkdir -p ~/Secrets/encrypted/{api-keys,env,ssh}
mkdir -p ~/Secrets/decrypted/{api-keys,env,ssh}

# 2. Create .gitignore
cat > ~/Secrets/.gitignore << 'EOF'
# Never commit decrypted files
decrypted/

# Keep directory structure
!decrypted/.gitkeep
EOF

# 3. Add scripts (see Implementation section below)

# 4. Initialize git
cd ~/Secrets
git init
git add .
git commit -m "Initial secrets setup"

# 5. Create private repo and push
# Create private repo on GitHub: secrets-private
git remote add origin git@github.com:youruser/secrets-private.git
git push -u origin main
```

### Workflow: Adding a New Secret

```bash
# 1. Create the plain text file
echo "sk-abc123..." > ~/Secrets/decrypted/api-keys/openai

# 2. Encrypt it
~/Secrets/scripts/encrypt.sh api-keys/openai

# 3. Commit the encrypted version
cd ~/Secrets
git add encrypted/api-keys/openai.age
git commit -m "Add OpenAI API key"
git push

# 4. Delete plain text if desired (can always decrypt again)
rm ~/Secrets/decrypted/api-keys/openai
```

---

## Summary: Quick Reference

| What                  | Location                           | Tool   | Command                               |
| --------------------- | ---------------------------------- | ------ | ------------------------------------- |
| NixOS system secret   | `secrets/<purpose>-<host>.age`     | agenix | `just edit-secret secrets/foo.age`    |
| Runbook documentation | `hosts/<host>/runbook-secrets.age` | age    | `just decrypt-runbook-secrets <host>` |
| Workstation secret    | `~/Secrets/encrypted/...`          | age    | `~/Secrets/scripts/decrypt.sh`        |

---

## Implementation Status

### ✅ Implemented

- [x] NixOS secrets (agenix) - working on hsb0, hsb8
- [x] Runbook secrets - script and workflow complete
- [x] `just` commands for agenix and runbook secrets

### 🔲 Pending

- [ ] Add hsb1 host key to `secrets/secrets.nix`
- [ ] Migrate hsb1 plain text secrets to agenix (see backlog)
- [ ] Implement workstation secrets scripts
- [ ] Create `~/Secrets/` repo for imac0

---

## Related Files

- `secrets/secrets.nix` - Key definitions and secret bindings
- `scripts/runbook-secrets.sh` - Runbook encrypt/decrypt script
- `justfile` - Commands in `[group('agenix')]` and `[group('runbook-secrets')]`
- `+pm/backlog/2-medium/2025-12-01-hsb1-agenix-secrets.md` - hsb1 migration plan
- `+pm/backlog/2-medium/2025-12-01-imac0-secrets-management.md` - Workstation secrets plan
