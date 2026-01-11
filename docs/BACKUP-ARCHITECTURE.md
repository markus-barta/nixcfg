# Infrastructure Backup Architecture

📍 TL;DR: Unified backup strategy using **Restic** targeting **Hetzner Storage Box** via **SFTP**.

## 🏗️ The Architecture

The goal is a "Zero-Trust" backup system where each host (or group) is isolated but targets a central, cost-effective storage provider.

### 1. Storage Backend: Hetzner Storage Box

We use a single main Hetzner Storage Box account (`u387549`) but partition it using **Sub-accounts**.

- **Isolation**: Each sub-account has its own SSH key and home directory on the Storage Box.
- **Protocol**: `SFTP` is used for security and ease of use with Restic.
- **Endpoint**: `u387549.your-storagebox.de`

### 2. Client-Side: Restic

**Restic** is the engine. It provides:

- **Deduplication**: Content-addressable storage (saving space across snapshots).
- **Encryption**: AES-256 (client-side, Hetzner never sees plain text).
- **Snapshots**: Point-in-time recovery.

### 3. Implementation Patterns

#### A. Docker-based (`csb*`, `hsb1`)

Managed via `restic-cron` container.

- **Mechanism**: Cron job inside the container triggers a backup script.
- **Consistency**: "Cold backups" (stopping containers) are preferred for databases.
- **Configuration**:
  - `RESTIC_PASSWORD`: Stored in `agenix` or `.env` files.
  - `id_rsa`: Private key for SFTP sub-account (bind-mounted).

#### B. NixOS-native (Future Goal)

Moving towards a declarative Nix module that manages the system-wide restic service.

#### C. macOS Workstations

Standardized on Restic alongside Time Machine for off-site redundancy.

---

## 🔑 Sub-account & Repository Mapping

| Sub-account    | Hosts            | Repository Path           | Access Key (agenix)      |
| :------------- | :--------------- | :------------------------ | :----------------------- |
| `u387549-sub1` | `csb0`, `csb1`   | `/` (root of sub-account) | `restic-hetzner-ssh-key` |
| `u387549-sub2` | `hsb1`           | `/` (root of sub-account) | `hsb1-restic-ssh-key`    |
| `u387549-sub3` | `hsb0` (Planned) | `/`                       | TBD                      |

---

## 🛡️ Security & Recovery

### Encryption (Repository Password)

Every Restic repository is encrypted with a master password.

- **Source of Truth**: 1Password (Search: "Restic Repository Password").
- **Local Cache**: `agenix` secrets on each host.

### SSH Keys

Each sub-account must have the corresponding **Public Key** uploaded to the Hetzner Robot/Cloud panel.

### 100% Validation Strategy

To verify a backup is truly valid (not just a successful log entry):

1. **Mount**: `restic mount /mnt/restic`
2. **Compare**: `diff` or `sha256sum` critical files from `/mnt/restic` against the live system.
3. **Prune**: Automated cleanup (pruning) MUST be managed by a single designated host (e.g., `csb0`) to avoid race conditions.

---

## 📖 Maintenance & Cheat Sheet

### List Snapshots

```bash
docker exec <container> restic snapshots
```

### Manual Backup Trigger

```bash
docker exec <container> /usr/local/bin/run_backup.sh
```

### Restore Example

```bash
docker exec <container> restic restore latest --target /tmp/restore --include /data/important-file
```
