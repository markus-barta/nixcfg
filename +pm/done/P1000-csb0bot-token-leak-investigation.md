# CSB0 Telegram Bot Token Leak Investigation

**Created**: 2025-12-21  
**Completed**: 2025-12-21  
**Priority**: P1000 (Critical - Security Incident)  
**Status**: DONE

---

## Incident Summary

On **2025-12-20** (first noticed 2025-12-21), the `@csb0bot` Telegram bot started sending casino spam (TonPlay) to users. This indicates the bot token (`CSB0_BOT_TOKEN`) was compromised.

### Timeline

| Date              | Event                       |
| ----------------- | --------------------------- |
| 2025-12-20 20:14  | First spam message observed |
| 2025-12-21 00:19  | Second spam message         |
| 2025-12-21 ~09:30 | Token revoked and rotated   |

### Affected Bot

- **Bot**: `@csb0bot` (Bot ID: `7010071349`)
- **Token**: `CSB0_BOT_TOKEN` in `~/docker/nodered/telegram.env` on csb0
- **Usage**: NOT actively used by Node-RED flows (legacy/test bot)
- **Building bot** (`@janischhofweg22bot`): NOT affected

---

## What We Know

### Token Storage

| Location | File                            | Permissions     | Last Modified |
| -------- | ------------------------------- | --------------- | ------------- |
| csb0     | `~/docker/nodered/telegram.env` | 0600 (mba only) | 2024-09-08    |

### Verified NOT Leaked Via

- [x] nixfleet git history — clean
- [x] File permissions on csb0 — proper (0600)
- [x] Shell history — clean
- [x] Local env files outside repo — clean

### ❌ LEAKED VIA

- **nixcfg git history** — Token committed in `.cursor/rules/git-security-policy.mdc`
- Cursor worktrees also contained copies of this file

---

## Root Cause: IDENTIFIED ✅

### The Leak Source

The token was committed to the git repository in a **Cursor rules file**:

```
.cursor/rules/git-security-policy.mdc (line 59)
```

**Commit**: `c388d2e8` — "pm: Major cleanup and task housekeeping"  
**Date**: 2025-12-07 09:18

### The Irony

The file is a security policy meant to PREVENT secrets from being committed. The real token was used as a "bad example":

```nix
# BAD - API token
telegram.botToken = "7010071349:**REDACTED**";
```

### How It Happened

1. During documentation of security policies, a real token was used as an example instead of a fake one
2. The file was committed and pushed to GitHub
3. Attackers/bots scan GitHub for Telegram bot tokens and exploit them for spam
4. Anyone with access to the repo could see the token

### Exposure Timeline

| Event                     | Date              |
| ------------------------- | ----------------- |
| Token committed to GitHub | 2025-12-07 09:18  |
| First spam observed       | 2025-12-20 20:14  |
| Token rotated             | 2025-12-21 ~09:30 |

**Time to exploitation**: ~13 days from commit to spam

---

## Remediation

### Immediate (DONE)

- [x] Revoke compromised token via BotFather
- [x] Generate new token
- [x] Update `telegram.env` on csb0
- [x] Recreate Node-RED container

### Follow-up

- [x] Replace real token with fake in `git-security-policy.mdc`
- [x] Audit other `.mdc` files for accidental secrets — clean
- [x] Document bot architecture in csb0 runbook
- [ ] Commit and push the fix
- [ ] Migrate secrets to agenix (see `P5200-hsb1-agenix-secrets.md`) — separate backlog item
- [ ] Remove unused `CSB0_BOT_TOKEN` from env file on csb0 — optional cleanup

---

## Lessons Learned

1. **Never use real secrets as examples** — Even in "bad example" documentation, always use clearly fake values like `1234567890:XXXXXXXXXXX`

2. **Cursor rules files are committed to git** — The `.cursor/rules/` directory is NOT gitignored by default. These files become part of the repo.

3. **GitHub token scanners are real** — Attackers actively scan GitHub for Telegram bot tokens. Exposure to compromise can be within days or even hours.

4. **Unused tokens are still valuable** — Even though `@csb0bot` wasn't actively used, the compromised token allowed spamming all users who had ever interacted with the bot.

5. **Review all files before commit** — The `-S` search in `git log` didn't find it initially because we searched for "BOT_TOKEN" (the variable name), not the actual token value.

---

## Related

- CSB0 Runbook: `hosts/csb0/docs/RUNBOOK.md`
- Agenix migration: `+pm/backlog/P5200-hsb1-agenix-secrets.md`
- Secrets documentation: `+pm/backlog/P6450-populate-secrets-documentation.md`
