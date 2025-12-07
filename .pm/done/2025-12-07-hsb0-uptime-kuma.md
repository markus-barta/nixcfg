# 2025-12-07 - hsb0 Uptime Kuma Installation

## Description

Install Uptime Kuma on hsb0 for monitoring service uptime and availability using the native NixOS `services.uptime-kuma` module.

## Scope

Applies to: hsb0

## Context

hsb0 is the DNS/DHCP server (Mac mini 2011) running AdGuard Home. Adding Uptime Kuma provides:

- Network service monitoring (DNS, HTTP, TCP, ping)
- Status page for infrastructure health
- Alerting via Telegram/webhook for service outages
- Lightweight monitoring complementing the existing setup

## Options

### Option A: Native NixOS Service (Recommended) ⭐

Use the built-in [`services.uptime-kuma`](https://search.nixos.org/options?channel=unstable&show=services.uptime-kuma.settings&query=services.uptime-kuma) module - no Docker required!

```nix
services.uptime-kuma = {
  enable = true;
  settings = {
    PORT = "3001";
  };
};
```

**Pros:**

- Native NixOS service - no Docker/container overhead
- Managed by systemd with proper service integration
- Automatic state management in `/var/lib/uptime-kuma`
- Minimal configuration needed
- Follows NixOS best practices

**Cons:**

- None significant

### Option B: NixOS OCI Containers

Use `virtualisation.oci-containers` for a Docker container managed by NixOS/systemd:

```nix
virtualisation.oci-containers.containers.uptime-kuma = {
  image = "louislam/uptime-kuma:1";
  ports = [ "3001:3001" ];
  volumes = [
    "/var/lib/uptime-kuma:/app/data"
  ];
};
```

**Pros:**

- Uses official Docker image
- Follows Docker patterns

**Cons:**

- Requires Docker runtime enabled
- More resource overhead than native service
- Not needed when native service exists

### Option C: Dedicated Docker Compose

Traditional docker-compose setup - **not recommended** when native NixOS service exists.

## Current State

- hsb0 has Docker enabled (but not required for Option A)
- No monitoring solution installed
- Port 3001 available

## Target State

- Uptime Kuma running as native NixOS service on port 3001
- Accessible at: <http://192.168.1.99:3001>
- Persistent data in /var/lib/uptime-kuma (automatic)
- Firewall rule added for TCP 3001
- Monitoring configured for critical services:
  - hsb0 AdGuard Home (port 3000)
  - hsb1 Home Assistant
  - Cloud servers (csb0, csb1, gpc0)
  - Other network services

## Acceptance Criteria

- [x] Uptime Kuma running via native `services.uptime-kuma`
- [x] Web UI accessible at <http://192.168.1.99:3001>
- [x] Firewall port 3001 opened
- [x] Service auto-starts on boot
- [ ] Basic monitors configured for key services (manual setup in UI)
- [ ] (Optional) Telegram notifications configured

## Implementation

### Option A Implementation (Recommended - Native NixOS)

1. Add to `hosts/hsb0/configuration.nix`:

```nix
# Uptime Kuma - Service Monitoring
services.uptime-kuma = {
  enable = true;
  settings = {
    PORT = "3001";
    HOST = "0.0.0.0"; # Listen on all interfaces
  };
};

# Firewall (add to existing allowedTCPPorts)
networking.firewall.allowedTCPPorts = [ 3001 ];
```

1. Rebuild: `just switch`
1. Access web UI: <http://192.168.1.99:3001>
1. Complete initial setup (create admin account)
1. Configure monitors for critical services

## Test Plan

### Manual Test

1. After deployment, verify service is running:
   ```bash
   ssh mba@hsb0 "systemctl status uptime-kuma"
   ```
1. Access web UI: <http://192.168.1.99:3001>
1. Complete initial setup (create admin account)
1. Add a test monitor (ping localhost)
1. Verify monitor shows as UP

### Automated Test

```bash
# Verify systemd service running
ssh mba@hsb0.lan 'systemctl is-active uptime-kuma && echo "✅ Service active" || echo "❌ Service not active"'

# Verify port accessible
curl -s -o /dev/null -w "%{http_code}" http://192.168.1.99:3001 | grep -q "200\|302" && echo "✅ Web UI accessible" || echo "❌ Web UI not accessible"

# Verify state directory exists
ssh mba@hsb0.lan '[ -d /var/lib/uptime-kuma ] && echo "✅ State dir exists" || echo "❌ State dir missing"'
```

## Notes

- Risk Level: 🟢 LOW - Additive change, no impact on existing services
- Duration: ~15 minutes (simpler than Docker approach)
- Dependencies: None (native NixOS service)
- Port 3001 chosen to avoid conflict with AdGuard Home (3000)
- Consider adding to hsb0 README Features table after implementation

## Resources

- [Uptime Kuma GitHub](https://github.com/louislam/uptime-kuma)
- [NixOS services.uptime-kuma Options](https://search.nixos.org/options?channel=unstable&query=services.uptime-kuma)

## Completion

**Completed:** 2025-12-07

**Implementation:**

- Used native NixOS `services.uptime-kuma` module (no Docker needed)
- Uptime Kuma v1.23.16 installed
- Service running on port 3001, listening on all interfaces
- Firewall configured

**Commits:**

- `feat(hsb0): add Uptime Kuma service monitoring`
- `fix(hsb0): bind Uptime Kuma to all interfaces`

**Next Steps:**

- Complete initial setup at <http://192.168.1.99:3001> (create admin account)
- Configure monitors for critical services
