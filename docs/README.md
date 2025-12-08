# NixOS Configuration Documentation

> **Fork Attribution**: This configuration is a fork of Patrizio's (pbek) NixOS setup. The "hokage" module is imported externally from `github:pbek/nixcfg`.

This repository is a **blueprint factory** for all your computers. Instead of manually installing software, you declare what you want in configuration files, and Nix makes it happen—reproducibly, every time.

---

## Infrastructure Overview

See [INFRASTRUCTURE.md](./INFRASTRUCTURE.md) for the complete host inventory, IPs, dependencies, and build platforms.

**Quick summary**: 6 NixOS servers (hsb0, hsb1, hsb8, csb0, csb1, gpc0) + 3 macOS workstations (imac0, imac-mba-work, mba-mbp-work).

---

## Architecture

### Layered Module System

```text
┌────────────────────────────────────────────────────────────────────────┐
│                         HOST CONFIGURATION                             │
│                   hosts/hsb1/configuration.nix                         │
└──────────────────────────┬─────────────────────┬───────────────────────┘
                           │                     │
          ┌────────────────▼──────────┐ ┌────────▼────────────────────────┐
          │      UZUMAKI MODULE       │ │       EXTERNAL HOKAGE           │
          │    modules/uzumaki/       │ │    github:pbek/nixcfg           │
          │                           │ │                                 │
          │  "Son of Hokage" 🌀       │ │  "Village Leader" 🍥            │
          │  • Fish functions         │ │  • User management              │
          │  • StaSysMo monitoring    │ │  • System roles                 │
          │  • Tokyo Night theming    │ │  • Core programs (git, ssh)     │
          │  • Zellij configuration   │ │  • ZFS, networking              │
          └───────────────────────────┘ └─────────────────────────────────┘
```

**Hokage** (external) provides the foundation: roles, users, core programs.  
**Uzumaki** (local) adds personal touch: fish functions, theming, monitoring.

### Repository Structure

| Directory            | Purpose                                    |
| -------------------- | ------------------------------------------ |
| `flake.nix`          | Entry point, defines all hosts             |
| `hosts/`             | Per-machine configurations                 |
| `modules/uzumaki/`   | Personal tooling (fish, stasysmo, theme)   |
| `modules/common.nix` | Shared config for all NixOS systems        |
| `secrets/`           | Encrypted secrets (agenix .age files)      |
| `infrastructure/`    | External infrastructure (Cloudflare, etc.) |
| `pkgs/`              | Custom packages                            |

---

## Essential Commands

```bash
# Build & Deploy
just check              # Validate configuration syntax
just switch             # Build and deploy to current machine
just upgrade            # Update flake inputs and rebuild
just rollback           # Revert to previous generation
just cleanup            # Free up disk space

# Remote Deployment
just hsb0-switch        # Deploy to hsb0
just hsb1-switch        # Deploy to hsb1
just csb0-switch        # Deploy to csb0
just csb1-switch        # Deploy to csb1

# Quick SSH (fish abbreviations)
qc0                     # SSH into hsb0 with zellij
qc1                     # SSH into hsb1 with zellij
```

---

## Common Tasks

### Understanding Secret Types

This repo has two types of secrets with different purposes:

| Type                | Location                      | Git Status   | Consumed by NixOS?      |
| ------------------- | ----------------------------- | ------------ | ----------------------- |
| **agenix secrets**  | `secrets/*.age`               | ✅ Committed | ✅ Yes (runtime)        |
| **runbook-secrets** | `hosts/*/runbook-secrets.age` | ✅ Committed | ❌ No (human reference) |

> **Key distinction**: Agenix secrets are decrypted by NixOS at boot. Runbook secrets are just an encrypted backup for humans — NixOS never reads them.

---

### 1. Agenix Secrets (Runtime Secrets)

These `.age` files are decrypted by NixOS at runtime. Used for static leases, API tokens, etc.

**Workflow**: `just edit-secret` handles decrypt → edit → encrypt automatically.

```bash
# Edit an existing secret (auto decrypt/encrypt)
just edit-secret secrets/static-leases-hsb0.age

# Create a new secret
agenix -e secrets/new-secret.age

# Rekey all secrets (after adding new host keys)
just rekey

# View which keys can decrypt which secrets
cat secrets/secrets.nix
```

**Example: Update static DHCP leases for AdGuard**

```bash
# 1. Edit the encrypted leases file
just edit-secret secrets/static-leases-hsb0.age

# 2. Your editor opens with decrypted JSON:
# [
#   {"mac": "AA:BB:CC:DD:EE:FF", "ip": "192.168.1.50", "hostname": "device1"},
#   {"mac": "11:22:33:44:55:66", "ip": "192.168.1.51", "hostname": "device2"}
# ]

# 3. Save and exit → automatically re-encrypted

# 4. Commit and deploy
git add secrets/static-leases-hsb0.age
git commit -m "Update static leases"
ssh mba@hsb0 "cd ~/nixcfg && git pull && just switch"
```

---

### 2. Runbook Secrets (Human Reference Backup)

Complete credentials documentation encrypted for git storage. **NixOS does NOT consume these** — they're purely for human reference during emergencies or setup.

**Files:**

- `hosts/<host>/secrets/runbook-secrets.md` — Plain text working copy (gitignored)
- `hosts/<host>/runbook-secrets.age` — Encrypted for Git (committed)

**Workflow:**

```bash
# Step 1: Decrypt to working copy
just decrypt-runbook-secrets hsb0

# Step 2: Edit the plain text file
nano hosts/hsb0/secrets/runbook-secrets.md

# Step 3: Re-encrypt when done
just encrypt-runbook-secrets hsb0

# Step 4: Commit the encrypted file
git add hosts/hsb0/runbook-secrets.age
git commit -m "Update hsb0 runbook secrets"
```

**When to update:**

- Password changed for a service
- New service deployed that needs credentials
- Emergency access info updated (VNC, recovery passwords, etc.)

**List hosts with runbook secrets:**

```bash
just list-runbook-secrets
```

### Adding a New Host

1. Create host directory:

   ```bash
   mkdir -p hosts/newhostname/{docs,secrets,tests}
   ```

2. Add configuration files:
   - `configuration.nix` - Main config
   - `hardware-configuration.nix` - From `nixos-generate-config`
   - `README.md` - Host documentation
   - `secrets/runbook-secrets.md` - Credentials (gitignored)

3. Add to `flake.nix`:

   ```nix
   nixosConfigurations.newhostname = mkServer ./hosts/newhostname;
   ```

4. Add host key to `secrets/secrets.nix`:

   ```bash
   # Get host public key
   ssh-keyscan newhostname

   # Add to secrets.nix
   newhostname = [ "ssh-ed25519 AAAA..." ];
   ```

5. Rekey secrets if the new host needs access:
   ```bash
   just rekey
   ```

---

## Security: SSH Keys with External Hokage

⚠️ **Critical**: External hokage injects pbek's SSH keys by default. Override with `lib.mkForce`:

```nix
# In configuration.nix
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    "ssh-rsa AAAAB3..." # Your key ONLY
  ];

  # Recovery password for VNC console access
  hashedPassword = "$y$j9T$...";  # Generate with: mkpasswd -m yescrypt
};
```

**Verify no external keys after deployment:**

```bash
ssh mba@hostname 'grep -c "omega" ~/.ssh/authorized_keys'
# Expected: 0
```

---

## Key Concepts

| Term           | Meaning                                        |
| -------------- | ---------------------------------------------- |
| **Flake**      | Modern Nix project with pinned dependencies    |
| **Module**     | Reusable configuration piece (hokage, uzumaki) |
| **Generation** | Snapshot of system config (enables rollback)   |
| **Derivation** | Recipe for building something reproducibly     |
| **agenix**     | Tool for encrypted secrets in Git              |
| **disko**      | Declarative disk/ZFS management                |

---

## Host Configuration Pattern

Each host follows this structure:

```text
hosts/hsb1/
├── configuration.nix         # Main config (hokage + uzumaki settings)
├── hardware-configuration.nix # Auto-generated hardware details
├── disk-config.zfs.nix       # Declarative ZFS layout
├── README.md                 # Host documentation
├── runbook-secrets.age       # Encrypted credentials (committed, NOT consumed by NixOS)
├── secrets/                  # Gitignored credentials
│   └── runbook-secrets.md    # Plain text working copy
└── tests/                    # Host-specific tests
```

**Example configuration.nix:**

```nix
{ lib, ... }:
{
  imports = [ ./hardware-configuration.nix ../../modules/uzumaki ];

  uzumaki = {
    enable = true;
    role = "server";
    stasysmo.enable = true;
  };

  hokage = {
    hostName = "hsb1";
    role = "server-home";
    zfs.enable = true;
  };

  # SSH key security (REQUIRED for external hokage)
  users.users.mba.openssh.authorizedKeys.keys = lib.mkForce [ "ssh-rsa ..." ];
}
```

---

## Related Documentation

### This Repository

- **[INFRASTRUCTURE.md](./INFRASTRUCTURE.md)** - Host inventory, IPs, dependencies
- **[AGENT-WORKFLOW.md](./AGENT-WORKFLOW.md)** - How to work with this codebase
- **[HOST-TEMPLATE.md](./HOST-TEMPLATE.md)** - Required file structure per host
- **Host READMEs**: `hosts/*/README.md` - Per-machine details

### External

- **Hokage Options**: `just hokage-options` or see `pbek-nixcfg/docs/hokage-options.md`
- **NixOS Manual**: https://nixos.org/manual/nixos/stable/
- **agenix**: https://github.com/ryantm/agenix
- **Home Manager**: https://github.com/nix-community/home-manager

---

_Declare what you want, Nix ensures it exists. Pure, reproducible infrastructure as code._
