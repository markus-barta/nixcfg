# m365-for-percy

**Host**: miniserver-bp
**Priority**: P40
**Status**: Backlog
**Created**: 2026-02-13

---

## Problem

Percy (Percaival) on miniserver-bp needs Microsoft 365 integration (email, calendar via Graph API). Azure AD app is already configured, but credentials and skills are missing.

## Solution

Install and configure m365-skill for Percy:

1. Copy/create M365 secrets for miniserver-bp
2. Install m365-skill in workspace
3. Install @softeria/ms-365-mcp-server
4. Configure mcporter
5. Test M365 access

## Implementation

- [ ] **Copy M365 secrets**: Reuse from hsb1 or create new
  - Files: `secrets/hsb1-openclaw-m365-*.age`
  - Add to `secrets/secrets.nix` with miniserver-bp public key
  - Rekey: `just rekey`
- [ ] Deploy secrets to miniserver-bp via nixos-rebuild
- [ ] **Install m365-skill**:
  ```bash
  ssh -p 2222 mba@10.17.1.40
  sudo mkdir -p /var/lib/openclaw-percaival/data/workspace/skills
  sudo chown -R 1000:1000 /var/lib/openclaw-percaival/data/workspace
  cd /var/lib/openclaw-percaival/data/workspace/skills
  sudo git clone https://github.com/cvsloane/m365-skill ms365
  ```
- [ ] **Install dependencies**: `docker exec openclaw-percaival npm install -g @softeria/ms-365-mcp-server`
- [ ] **Configure mcporter**: Create `~/.clawdbot/mcporter.json` in container
- [ ] **Set env vars**: MS365_MCP_CLIENT_ID, MS365_MCP_CLIENT_SECRET, MS365_MCP_TENANT_ID
- [ ] Test: `docker exec openclaw-percaival mcporter call ms365.list_events`
- [ ] Restart container

## Acceptance Criteria

- [ ] M365 secrets deployed to miniserver-bp
- [ ] m365-skill cloned to workspace/skills/
- [ ] mcporter can list M365 events
- [ ] Percy can access M365 calendar via Telegram

## Notes

**Reference**: https://github.com/cvsloane/m365-skill

**Declarative approach**: M365 secrets should be added to NixOS config (like Telegram token). Skills are non-declarative (git clone to workspace).

**Azure AD app**: Already configured (reuse credentials from hsb1)
