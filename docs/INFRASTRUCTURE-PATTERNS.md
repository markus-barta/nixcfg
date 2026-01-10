# Infrastructure Configuration Patterns

This document explains how host configurations (NixOS, Docker, Secrets) are managed across the Barta infrastructure.

## 🏗️ The Hokage-Uzumaki Pattern

Most hosts in this repo follow a layered configuration pattern:

1.  **Hokage (Base)**: Core system management (users, SSH, base packages, security).
2.  **Uzumaki (Personalization)**: User-specific tooling (fish, zellij, themes) and role-based defaults (server/desktop).
3.  **Host Specifics**: `configuration.nix` in the host directory for IP addresses, ZFS pools, and specific services.

## 📦 Docker Orchestration vs. NixOS

While some services are managed directly by NixOS (e.g., `openssh`, `zfs`), others run in **Docker Compose**.

### Why Docker?

- Legacy compatibility (Node-RED flows, Mosquitto data).
- Portability between VPS providers (Netcup, Hetzner).
- Separation of concerns.

### How it's Managed

- Compose files are stored in `hosts/<hostname>/scripts/docker-compose.yml`.
- **CRITICAL**: Do NOT manually edit files on the server.
- **Workflow**:
  1. Edit the compose file locally.
  2. Commit and push to GitHub.
  3. `git pull` on the host.
  4. `docker compose up -d`.

## 🔐 Secret Management (Agenix)

Secrets are never stored in plain text.

1.  **Agenix (Tier 1)**: Encrypted `.age` files in `secrets/`.
2.  **Decryption**: Handled by NixOS during activation.
3.  **Runtime**: Secrets appear in `/run/agenix/`.
4.  **Docker Integration**: Compose files reference `/run/agenix/<secret>` for environment variables and password files.

## 🚦 Traefik Configuration

Traefik is used as the global reverse proxy.

- **NixOS Role**: Handles the `traefik` binary and firewall.
- **Docker Role**: Traefik runs as a container to auto-discover other services via the Docker socket proxy.
- **Configuration**:
  - **Static Config**: Entrypoints (80, 443, 8883) and providers.
  - **Dynamic Config**: TLS certificates (ACME) and middlewares (Cloudflare Warp).

## 🚨 Migration Notes (csb0)

During the 2026-01-10 migration, several legacy patterns were modernized:

- **Environment Files**: Local `.env` files were replaced with Agenix secrets.
- **Volume Paths**: Moved from local `./data` to persistent ZFS volumes at `/var/lib/docker/volumes/`.
- **Config Injections**: Some volumes (Traefik/Mosquitto) are being transitioned to Nix-managed paths to avoid "directory mount" errors.
