# T15: Uptime Kuma Service Monitoring (hsb0)

Test Uptime Kuma service monitoring web interface.

## Host Information

| Property | Value        |
| -------- | ------------ |
| **Host** | hsb0         |
| **Role** | DNS/DHCP     |
| **IP**   | 192.168.1.99 |
| **Port** | 3001         |

## Prerequisites

- [ ] NixOS configuration applied: `sudo nixos-rebuild switch --flake .#hsb0`
- [ ] Uptime Kuma enabled in configuration

## Automated Tests

Run: `./T15-uptime-kuma.sh`

## Manual Test Procedures

### Test 1: Service Running

**Steps:**

1. Check service status: `systemctl status uptime-kuma`

**Expected Results:**

- Service is active (running)
- No errors in recent logs

**Status:** ⏳ Pending

### Test 2: Web Interface Accessible

**Steps:**

1. Open browser to: http://192.168.1.99:3001
2. Or test with curl: `curl -s http://localhost:3001 | head -20`

**Expected Results:**

- Web UI loads
- Page contains "Uptime Kuma" text

**Status:** ⏳ Pending

### Test 3: Port Listening

**Steps:**

1. Check port: `ss -tlnp | grep 3001`

**Expected Results:**

- Port 3001 is listening
- Bound to expected interface

**Status:** ⏳ Pending

## Test Results Summary

| Test | Description       | Status |
| ---- | ----------------- | ------ |
| T1   | Service Running   | ⏳     |
| T2   | Web UI Accessible | ⏳     |
| T3   | Port Listening    | ⏳     |

## Notes

- Uptime Kuma provides web-based service monitoring
- Configuration in `configuration.nix` under `services.uptime-kuma`
- Data stored in `/var/lib/uptime-kuma/`
