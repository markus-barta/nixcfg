# Migrate OpenClaw Gateway to Declarative NixOS Service

**Created**: 2026-02-02  
**Priority**: P6600 (Medium/Low)  
**Status**: Backlog  
**Depends on**: P6380-hsb1-agenix-secrets.md

---

## Problem

The OpenClaw Gateway is currently running as an imperative Systemd User Service (`~/.config/systemd/user/openclaw-gateway.service`) with hardcoded tokens in the unit file. This is insecure and hard to manage across the fleet.

---

## Solution

Migrate the service to a declarative NixOS system service defined in `hosts/hsb1/configuration.nix`.

1.  Enable/uncomment the `systemd.services.openclaw-gateway` block in `configuration.nix`.
2.  Ensure it uses `agenix` secrets for `OPENCLAW_GATEWAY_TOKEN`, `OPENCLAW_TELEGRAM_TOKEN`, and `OPENCLAW_OPENROUTER_KEY`.
3.  Stop and disable the old user-level service: `systemctl --user disable --now openclaw-gateway.service`.
4.  Remove the imperative unit file to avoid confusion.

---

## Acceptance Criteria

- [ ] OpenClaw Gateway runs as a system-wide service under the `mba` user.
- [ ] Secrets are securely loaded from `/run/agenix/`.
- [ ] The service is fully managed via `nixos-rebuild`.

---

## Test Plan

### Manual Test

1. Apply nixos configuration.
2. `systemctl status openclaw-gateway.service` (system-wide).
3. `systemctl --user status openclaw-gateway.service` (should be inactive/not found).
4. Verify connectivity via Telegram.

### Automated Test

```bash
# Check if service is active via systemd
systemctl is-active openclaw-gateway.service
```
