# msbp: Remove stale port 22 from firewall

**Created**: 2026-02-09
**Priority**: P6500 (Low)
**Status**: Backlog

---

## Problem

`hosts/miniserver-bp/configuration.nix` has port 22 open in the firewall, but SSH runs on port 2222 (set by Hokage `server-remote` role). Port 22 is unnecessarily exposed.

```nix
# Current (wrong):
allowedTCPPorts = [ 22 8888 ];

# Should be:
allowedTCPPorts = [ 8888 ];
# Port 2222 is opened by Hokage module automatically
```

---

## Solution

1. Verify Hokage opens port 2222 automatically (check other hosts for pattern)
2. Remove port 22 from `allowedTCPPorts`
3. Verify SSH still works after switch

---

## Acceptance Criteria

- [ ] Port 22 removed from firewall config
- [ ] SSH on port 2222 still works after `nixos-rebuild switch`
- [ ] `nmap -p 22 10.17.1.40` shows closed/filtered
- [ ] README firewall table updated (remove port 22 row)

---

## Test Plan

```bash
# After switch:
ssh -p 2222 mba@10.17.1.40 "echo 'SSH works'"
ssh -p 22 mba@10.17.1.40 "echo 'should fail'" # expect: connection refused
```

---

## Risk

🟢 LOW — test server, but verify SSH works before disconnecting!
