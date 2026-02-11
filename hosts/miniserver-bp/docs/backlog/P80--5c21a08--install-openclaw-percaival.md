# install-openclaw-percaival

**Host**: miniserver-bp
**Priority**: P80
**Status**: New
**Created**: 2026-02-10

---

## Problem

Need to install OpenClaw AI agent on miniserver-bp with identifier "Percaival", nicknames "Percai/Percy" for testing and experimentation.

## Solution

Install OpenClaw via nixpkgs or flake input, configure agent name as "Percaival", enable as systemd service.

## Implementation

- [ ] Research OpenClaw installation requirements (nixpkgs vs flake)
- [ ] Verify OpenClaw availability in nixpkgs or add as flake input
- [ ] Add OpenClaw configuration to `hosts/miniserver-bp/configuration.nix`
- [ ] Configure agent name/identifier as "Percaival"
- [ ] Enable service and set auto-start on boot
- [ ] Test installation: verify agent responds to "Percaival"
- [ ] Update `hosts/miniserver-bp/README.md` with service details
- [ ] Update `hosts/miniserver-bp/docs/RUNBOOK.md` with operational procedures

## Acceptance Criteria

- [ ] OpenClaw service running on miniserver-bp
- [ ] Agent responds to name "Percaival"
- [ ] Service starts automatically on boot
- [ ] `systemctl status openclaw` shows active
- [ ] README.md updated with OpenClaw entry
- [ ] RUNBOOK.md updated with ops procedures

## Notes

- **Host**: miniserver-bp (10.17.1.40) - BYTEPOETS office test server
- **SSH**: `ssh -p 2222 mba@10.17.1.40`
- **Criticality**: 🟢 LOW (non-production test environment, safe to experiment)
- **OpenClaw**: Open-source AI agent (confirm exact project/repo)
- No production dependencies
