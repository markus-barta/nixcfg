# Migrate OpenClaw Gateway to Declarative NixOS Service

**Created**: 2026-02-02  
**Priority**: P6600 (Medium/Low)  
**Status**: In Progress (deploy pending)  
**Depends on**: P6380-hsb1-agenix-secrets.md

---

## Problem

The OpenClaw Gateway is currently running as an imperative Systemd User Service (`~/.config/systemd/user/openclaw-gateway.service`) with hardcoded tokens in the unit file. This is insecure and hard to manage across the fleet. Specifically, we need to transition all secrets (Telegram, OpenRouter, Brave Search, Home Assistant) from manual environment variables to the NixOS/Agenix pipeline.

Additionally, `openclaw doctor` regenerates the user service unit and doesn't inherit system-level env vars like `OPENCLAW_TEMPLATES_DIR`, causing template resolution failures.

---

## Solution

Migrate the service to a declarative NixOS system service defined in `hosts/hsb1/configuration.nix`.

1. Uncomment and rewrite the `systemd.services.openclaw-gateway` block in `configuration.nix`.
2. **Wrapper script approach** — openclaw reads env vars directly (no `_FILE` suffix support), so a shell wrapper reads agenix secret files and exports them before exec:
   - `OPENCLAW_GATEWAY_TOKEN` ← `cat /run/agenix/hsb1-openclaw-gateway-token`
   - `TELEGRAM_BOT_TOKEN` ← `cat /run/agenix/hsb1-openclaw-telegram-token`
   - `OPENROUTER_API_KEY` ← `cat /run/agenix/hsb1-openclaw-openrouter-key`
   - `BRAVE_API_KEY` ← `cat /run/agenix/hsb1-openclaw-brave-key`
3. Set `OPENCLAW_TEMPLATES_DIR` in the service environment (points to nix store templates).
4. Don't overwrite `openclaw.json` — it's managed by `openclaw` CLI and contains model config, channel settings, etc.
5. Stop and disable the old user-level service: `systemctl --user disable --now openclaw-gateway.service`.
6. Remove the imperative user service file to avoid confusion.

**Note on HASS**: The HASS token (`hsb1-openclaw-hass-token`) is consumed by an openclaw skill (not via env var). The agenix secret remains available at `/run/agenix/hsb1-openclaw-hass-token` for the skill to read. No env var injection needed.

---

## Acceptance Criteria

- [ ] OpenClaw Gateway runs as a system-wide service under the `mba` user.
- [ ] Secrets (gateway, telegram, openrouter, brave) loaded from `/run/agenix/` via wrapper script.
- [ ] `OPENCLAW_TEMPLATES_DIR` set correctly (no more "Missing workspace template" errors).
- [ ] The service is fully managed via `nixos-rebuild`.
- [ ] Web search and Home Assistant connections remain functional.
- [ ] Old user-level service disabled and removed.

---

## Test Plan

### Manual Test

1. Apply nixos configuration: `sudo nixos-rebuild switch --flake .#hsb1`
2. `systemctl status openclaw-gateway.service` (system-wide, should be active).
3. `systemctl --user status openclaw-gateway.service` (should be inactive/not found).
4. Verify connectivity via Telegram and test web search.
5. Test Home Assistant control (toggle a light).

### Automated Test

```bash
# Check if service is active via systemd (system-level)
systemctl is-active openclaw-gateway.service
```

---

## Post-Deploy Cleanup (Optional)

- Sanitize `openclaw.json`: remove inline `channels.telegram.botToken` and `gateway.auth.token` (env vars take precedence now).
- Fix broken skill symlinks in `~/.openclaw/workspace/skills/` (home-assistant, docker point to GC'd v2026.1.29 store path).
