# firewall-port22-cleanup

**Host**: miniserver-bp
**Priority**: P65
**Status**: Cancelled
**Created**: 2026-02-09
**Cancelled**: 2026-02-11

---

## Problem

`hosts/miniserver-bp/configuration.nix` has port 22 open in firewall, but SSH runs on port 2222 (set by Hokage `server-remote` role). Port 22 is unnecessarily exposed.

## Solution

Remove port 22 from firewall configuration. Hokage module automatically opens port 2222.

## Implementation

- [ ] Verify Hokage opens port 2222 automatically (check other hosts for pattern)
- [ ] Remove port 22 from `allowedTCPPorts` in configuration.nix
- [ ] Update: Change `allowedTCPPorts = [ 22 8888 ]` to `allowedTCPPorts = [ 8888 ]`
- [ ] Deploy: `sudo nixos-rebuild switch --flake .#miniserver-bp`
- [ ] Test SSH on port 2222: `ssh -p 2222 mba@10.17.1.40 "echo 'SSH works'"`
- [ ] Verify port 22 closed: `ssh -p 22 mba@10.17.1.40` (expect connection refused)
- [ ] Check with nmap: `nmap -p 22 10.17.1.40` (should show closed/filtered)
- [ ] Update README firewall table (remove port 22 row)

## Acceptance Criteria

- [ ] Port 22 removed from firewall config
- [ ] SSH on port 2222 works after switch
- [ ] Port 22 inaccessible from network
- [ ] Documentation updated

## Notes

- Risk: 🟢 LOW (test server, but verify SSH works before disconnecting!)
- Port 2222 opened by Hokage module automatically

---

## Cancellation Reason

Task already complete. Port 22 was previously removed from firewall configuration. Current config only opens ports 2222 (SSH) and 8888 (pm-tool). No action needed.
