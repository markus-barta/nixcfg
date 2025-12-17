# NCPS Binary Cache Proxy on hsb0

**Created**: 2025-12-13  
**Priority**: MEDIUM  
**Status**: Backlog

---

## Overview

Install [ncps](https://github.com/kalbasit/ncps) (Nix binary Cache Proxy Service) on hsb0 to act as a local binary cache for all home LAN hosts. This will:

- Cache Nix store paths locally, reducing bandwidth
- Speed up rebuilds across all home hosts
- Sign cached packages with local key
- Proxy upstream caches (cache.nixos.org, nix-community, etc.)

---

## Requirements

### 1. Install ncps on hsb0

- [ ] Add ncps flake input or use nixpkgs module
- [ ] Configure ncps service on hsb0
- [ ] Set up storage location (ZFS dataset recommended)
- [ ] Configure upstream caches:
  - `https://cache.nixos.org`
  - `https://nix-community.cachix.org`
- [ ] Set max cache size (e.g., 50G)
- [ ] Enable LRU cleanup schedule
- [ ] Generate and store signing key

### 2. Configure Home LAN Hosts as Clients

Configure these hosts to use hsb0 as substituter:

| Host | Type    | Location    |
| ---- | ------- | ----------- |
| hsb0 | server  | home (self) |
| hsb1 | server  | home        |
| gpc0 | desktop | home        |

- [ ] Add `http://hsb0.lan:8501` to `nix.settings.substituters`
- [ ] Add ncps public key to `nix.settings.trusted-public-keys`
- [ ] Keep upstream caches as fallback

### 3. Firewall & Network

- [ ] Open port 8501 on hsb0 (LAN only)
- [ ] Ensure hsb0.lan resolves correctly for all hosts

---

## Implementation

### hsb0 Configuration

```nix
# In hosts/hsb0/configuration.nix

services.ncps = {
  enable = true;

  cache = {
    hostname = "hsb0.lan";
    dataPath = "/var/lib/ncps/data";
    databaseURL = "sqlite:/var/lib/ncps/db/db.sqlite";
    maxSize = "50G";
    lru.schedule = "0 3 * * *";  # Clean up daily at 3 AM
    allowPutVerb = true;  # Allow pushing to cache
  };

  server.addr = "0.0.0.0:8501";

  upstream = {
    caches = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
    publicKeys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };
};

# Firewall - LAN only
networking.firewall.interfaces."enp2s0".allowedTCPPorts = [ 8501 ];
```

### Client Configuration (uzumaki or per-host)

```nix
# In modules/common.nix or uzumaki module

nix.settings = {
  substituters = [
    "http://hsb0.lan:8501"  # Local cache first
    "https://cache.nixos.org"
    "https://nix-community.cachix.org"
  ];

  trusted-public-keys = [
    "hsb0.lan:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX="  # Get from hsb0
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
  ];
};
```

---

## Storage Considerations

**Option A: Dedicated ZFS Dataset**

```bash
sudo zfs create -o mountpoint=/var/lib/ncps rpool/ncps
```

**Option B: Use existing /var/lib** (WE WANT THIS)

- Simpler but no separate snapshot/quota management

### Notes

- ncps should have a setting to set a quota for about 50 GB.
- Also, we want our backup not to include that cache. --> TODO: Add a backlog item for that.

---

## Verification

After deployment:

```bash
# On hsb0 - get public key
curl http://localhost:8501/pubkey

# On hsb0 - verify service
systemctl status ncps
curl http://localhost:8501/nix-cache-info

# On client (hsb1, gpc0) - test cache
curl http://hsb0.lan:8501/nix-cache-info
nix path-info --store http://hsb0.lan:8501 /nix/store/...
```

---

## Benefits

| Metric          | Before                            | After                                 |
| --------------- | --------------------------------- | ------------------------------------- |
| **Bandwidth**   | Each host downloads from internet | First download cached, others use LAN |
| **Build speed** | Limited by WAN speed              | LAN speed (1 Gbps)                    |
| **Resilience**  | Internet required                 | Can rebuild from cache offline        |

---

## Acceptance Criteria

- [ ] ncps running on hsb0, accessible at `http://hsb0.lan:8501`
- [ ] hsb1 and gpc0 configured to use hsb0 as first substituter
- [ ] Cache verified working: second build of same derivation uses local cache
- [ ] LRU cleanup configured and tested
- [ ] Firewall allows only LAN access to port 8501

---

## Related

- ncps repository: <https://github.com/kalbasit/ncps>
- NixOS module options: search.nixos.org
- hsb0 configuration: `hosts/hsb0/configuration.nix`

---

## Notes

- Consider adding attic as alternative (more features, but more complex)
- macOS hosts (imac0, mba-\*-work) can also use this cache
- Cloud hosts (csb0, csb1) won't benefit (not on LAN)
- hsb8 at parents' house won't have access unless VPN is set up
