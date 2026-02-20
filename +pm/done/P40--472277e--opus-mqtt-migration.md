# opus-mqtt-migration

**Host**: hsb1
**Priority**: P40
**Status**: Done
**Created**: 2026-02-20

---

## Problem

The `opus-stream-to-mqtt` application running on `hsb1` is currently a raw Node.js script located directly in the unmanaged `~/docker/mounts/opus-stream-to-mqtt/app` directory. It lacks its own version control repository, and its secrets are stored in a plain-text `.env` file within the same unmanaged directory. The docker-compose configuration for it relies on this local unmanaged state.

## Solution

1. Create a dedicated, private GitHub repository (`markus-barta/opus-stream-to-mqtt`) for the application's source code.
2. Integrate the source code into the NixOS configuration using a Flake input.
3. Manage the application's secrets using Agenix.
4. Keep the current Docker Compose deployment strategy (using `node:alpine` and building on-the-fly), but update it to mount the Nix-managed source code and the Agenix-managed secrets.

## Implementation

- [x] **Phase 1: Backup & Reconstruction**
  - [x] Backup existing `~/docker/mounts/opus-stream-to-mqtt/app` on `hsb1` to `~/docker/backups/opus-stream-to-mqtt-backup-$(date +%F)`.
  - [x] Copy source files (`opus_stream_to_mqtt.js`, `package.json`, `package-lock.json`, `.env.example`, `.gitignore`) to a new local workspace `~/Code/opus-stream-to-mqtt` on the iMac (discarding `node_modules`, `archive`, and `.env`).
  - [x] Write a clean `README.md` for the project.
  - [x] Create a private GitHub repository (`markus-barta/opus-stream-to-mqtt`) and push the initial commit.
- [x] **Phase 2: NixOS Integration**
  - [x] Add the new GitHub repository as a Flake input in `nixcfg/flake.nix` (private repo, uses `git+ssh`).
  - [x] Update `hosts/hsb1/configuration.nix`:
    - `environment.etc."opus-stream-to-mqtt".source = inputs.opus-stream;` (read-only source in Nix store)
    - `age.secrets.opus-stream-hsb1` for credentials
  - [x] Add `opus-stream-hsb1.age` to `secrets/secrets.nix`.
  - [x] Update `hosts/hsb1/docker/docker-compose.yml`:
    - Mount source read-only: `/etc/opus-stream-to-mqtt:/source:ro`
    - Named volume for mutable `/app` (persists `node_modules` across restarts)
    - `env_file:` pointing to `/run/agenix/opus-stream-hsb1`
    - `command:` copies source into `/app` on boot, then runs `npm install && npm start`
  - [ ] Close the related old backlog item `P63--7a52404--opus-mqtt-credentials.md`.
- [x] **Phase 3: Deployment & Validation**
  - [x] Markus creates agenix secret: `agenix -e secrets/opus-stream-hsb1.age` (copy values from current `.env`)
  - [x] Commit, push, pull on hsb1, `just switch`
  - [x] Restart opus container: `docker compose up -d opus-stream-to-mqtt`
  - [x] Verify container logs: `docker logs opus-stream-to-mqtt --tail 20`
  - [x] Verify MQTT messages arrive on `opus2mqtt/telegrams`
  - [x] Verify Node-RED flows still consume events
  - [x] Remove old plain-text `.env` from `~/docker/mounts/opus-stream-to-mqtt/app/`

## Acceptance Criteria

- [x] A new private GitHub repository contains the clean source code for `opus-stream-to-mqtt`.
- [x] The `opus-stream-to-mqtt` container starts successfully using Nix-managed source from `/etc/opus-stream-to-mqtt`.
- [x] The container receives its configuration securely via Agenix without any plain-text `.env` files in unmanaged directories.
- [x] The application successfully connects to the OPUS gateway and publishes to MQTT.

## Notes

- Critical finding during analysis: `~/docker/docker-compose.yml` on `hsb1` is actually a symlink to `~/Code/nixcfg/hosts/hsb1/docker/docker-compose.yml`. RUNBOOK has been updated to reflect this.
- **Read-only fix:** `environment.etc` produces read-only files (Nix store symlinks). Since `npm install` needs to write `node_modules`, we use Option 2: mount source as `/source:ro`, copy into mutable `/app` (named Docker volume) on container boot. This keeps `node_modules` cached across restarts while source stays immutable.
