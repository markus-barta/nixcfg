# NCPS Binary Cache Proxy on hsb0

**Created**: 2025-12-13  
**Updated**: 2025-12-24 (Refined Analysis & Plan)  
**Priority**: MEDIUM  
**Status**: In Progress (Planning)

---

## Overview

Install [ncps](https://github.com/kalbasit/ncps) (Nix binary Cache Proxy Service) on hsb0 to act as a local binary cache for all home LAN hosts.

### Why NCPS?

- **Bandwidth**: Reduces internet usage by caching common store paths.
- **Speed**: LAN-speed rebuilds (1 Gbps) vs WAN-speed.
- **Sign locally**: Packages built locally (e.g., on gpc0) can be pushed to hsb0 and shared.
- **Transparency**: Acts as a pull-through proxy for `cache.nixos.org` and others.
- **Cache Warming**: Pre-fetches updates during off-peak hours (nightly) to ensure zero impact on web-usage during work hours.

---

## Detailed Analysis & Plan

### 1. Service Source

`ncps` is NOT in standard `nixpkgs`. We must use the flake provided by the author.

- **Flake**: `github:kalbasit/ncps`
- **Module**: `inputs.ncps.nixosModules.ncps`

### 2. Storage Strategy (ZFS)

`hsb0` uses ZFS. We will create a dedicated dataset for the cache.

- **Dataset**: `zroot/ncps`
- **Mountpoint**: `/var/lib/ncps`
- **Quota**: 50GB (enforced by ZFS)
- **Backup Exclusion**: Exclude this dataset from Restic backups (cache is transient).

### 3. Signing & Trust

A signing key pair is required for clients to trust the cache.

- **Private Key**: Generated on-device, stored via `agenix`.
- **Public Key**: Shared with all clients.
- **Trusted Public Keys**: Added to `nix.settings.trusted-public-keys` across the fleet.

### 4. Network Configuration

- **Host**: `hsb0.lan` (192.168.1.99)
- **Port**: `8501` (TCP)
- **Firewall**: Open port 8501 on `enp2s0f0` (LAN only).
- **DNS**: Resolution is already handled by AdGuard Home on hsb0.

### 5. Cache Warming (Nightly Pre-fetch)

To prevent rebuilds from consuming bandwidth during work hours, we will implement a "Warmer" service on `hsb0` or `gpc0`.

- **Schedule**:
  - **Fri ➔ Sat**: (Saturday 03:00) Prepares for weekend tinkering.
  - **Sun ➔ Mon**: (Monday 03:00) Prepares for the start of the work week.
- **Action**: Runs `nix build --dry-run` or `nix build --eval-only` for all flake outputs, triggering `ncps` to fetch missing paths from upstream.
- **Fail-Safe**: If `hsb0` is unreachable, clients fall back to `cache.nixos.org` immediately.

---

## Implementation Steps

### Phase 1: Infrastructure (hsb0)

1.  [x] Add `ncps` flake input to `flake.nix`.
2.  [x] Add `zroot/ncps` dataset to `hosts/hsb0/disk-config.zfs.nix`.
3.  [x] Generate signing key: `nix-store --generate-binary-cache-key hsb0.lan-1 secret-key public-key`.
4.  [x] Add secret key to `secrets/ncps-key.age`.
5.  [x] Configure `services.ncps` in `hosts/hsb0/configuration.nix`.
6.  [x] Open firewall port 8501.
7.  [x] **Implement Cache Warmer**: Create Systemd Timer with the defined schedule.

### Phase 2: Client Deployment

1.  [ ] Update `modules/common.nix` or `modules/uzumaki/server.nix` with the new substituter.
2.  [ ] Add the public key to `trusted-public-keys`.
3.  [ ] Test on `hsb1` (NixOS).
4.  [ ] Test on `gpc0` (NixOS).
5.  [ ] Test on `imac0` (macOS).

---

## Configuration Snippets

### hsb0 configuration.nix (Draft)

```nix
services.ncps = {
  enable = true;
  settings = {
    cache = {
      hostname = "hsb0.lan";
      dataPath = "/var/lib/ncps/data";
      databaseURL = "sqlite:/var/lib/ncps/db/db.sqlite";
      maxSize = "50G";
      lru.schedule = "0 3 * * *";
      allowPutVerb = true;
    };
    server.addr = "0.0.0.0:8501";
    upstream = {
      caches = [ "https://cache.nixos.org" "https://nix-community.cachix.org" ];
      publicKeys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
    };
  };
};
```

### Client configuration (Draft)

```nix
nix.settings = {
  substituters = lib.mkBefore [ "http://hsb0.lan:8501" ];
  trusted-public-keys = [ "hsb0.lan-1:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX=" ];
};
```

---

## Verification Plan

1.  **Service check**: `curl http://hsb0.lan:8501/nix-cache-info`.
2.  **Pull check**: Run a build on `hsb1`, then the same build on `gpc0`. Check `nix log` for "copying from http://hsb0.lan:8501".
3.  **Push check**: `nix copy --to http://hsb0.lan:8501 <path>`.
4.  **Fail-safe check**: Temporarily block 8501 on hsb0 and verify clients still rebuild using `cache.nixos.org`.

---

## Acceptance Criteria

- [ ] `ncps` service active on `hsb0`.
- [ ] `zroot/ncps` dataset mounted with 50GB quota.
- [ ] LAN hosts successfully pull paths from `hsb0`.
- [ ] Local builds successfully pushed/shared via `hsb0`.
- [ ] No rebuild failures when `hsb0` is unreachable.
- [ ] Backup configuration updated to exclude `/var/lib/ncps`.

---

## Related

- ncps repository: <https://github.com/kalbasit/ncps>
- NixOS module options: search.nixos.org
- hsb0 configuration: `hosts/hsb0/configuration.nix`
- Deployment Safety: `+pm/backlog/P4900-infra-safety-resilience.md`
