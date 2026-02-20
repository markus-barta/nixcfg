# opus-mqtt-migration

**Host**: hsb1
**Priority**: P40
**Status**: Backlog
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

- [ ] **Phase 1: Backup & Reconstruction**
  - [ ] Backup existing `~/docker/mounts/opus-stream-to-mqtt/app` on `hsb1` to `~/docker/backups/opus-stream-to-mqtt-backup-$(date +%F)`.
  - [ ] Copy source files (`opus_stream_to_mqtt.js`, `package.json`, `package-lock.json`, `.env.example`, `.gitignore`) to a new local workspace `~/Code/opus-stream-to-mqtt` on the iMac (discarding `node_modules`, `archive`, and `.env`).
  - [ ] Write a clean `README.md` for the project.
  - [ ] Create a private GitHub repository (`markus-barta/opus-stream-to-mqtt`) and push the initial commit.
- [ ] **Phase 2: NixOS Integration**
  - [ ] Add the new GitHub repository as a Flake input in `nixcfg/flake.nix`.
  - [ ] Update `hosts/hsb1/configuration.nix` to use `environment.etc."opus-stream-to-mqtt".source = inputs.opus-stream;` to place the source code on the host.
  - [ ] Create a new Agenix secret `secrets/opus-stream-hsb1.age` containing the required `.env` values and add it to `secrets/secrets.nix`.
  - [ ] Configure `age.secrets.opus-stream-hsb1` in `hosts/hsb1/configuration.nix`.
  - [ ] Update `hosts/hsb1/docker/docker-compose.yml` to change the volume bind to `- /etc/opus-stream-to-mqtt:/app` and add an `env_file:` directive pointing to the Agenix secret.
  - [ ] Close the related old backlog item `P63--7a52404--opus-mqtt-credentials.md`.

## Acceptance Criteria

- [ ] A new private GitHub repository contains the clean source code for `opus-stream-to-mqtt`.
- [ ] The `opus-stream-to-mqtt` container starts successfully using the code from `/etc/opus-stream-to-mqtt`.
- [ ] The container receives its configuration securely via Agenix without any plain-text `.env` files in unmanaged directories.
- [ ] The application successfully connects to the OPUS gateway and publishes to MQTT.

## Notes

- Critical finding during analysis: `~/docker/docker-compose.yml` on `hsb1` is actually a symlink to `~/Code/nixcfg/hosts/hsb1/docker/docker-compose.yml`. RUNBOOK has been updated to reflect this.
