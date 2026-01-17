# 2026-01-17 - csb0/csb1 Cloudflare Token Rotation - Cleanup & QA

## Description

Final cleanup and quality assurance after Cloudflare API token rotation and infrastructure refactoring. Ensure all old credentials are removed from git history and local systems, and verify proper documentation.

## Context

**Completed Work:**

- Rotated Cloudflare API token (scope: `barta.cm` only, IP-filtered)
- Encrypted via agenix (`secrets/traefik-variables.age`)
- Refactored csb0 with proper directory structure (`/var/lib/csb0-docker/`)
- Token deployed to both csb0 and csb1
- Services verified working

**Remaining:**

- Old token still exists in Cloudflare (not revoked yet)
- Need to verify no leaked secrets in git history
- Check for leftover files from refactoring
- Final QA pass

## Acceptance Criteria

### 1. Revoke Old Token

- [ ] Login to Cloudflare: https://dash.cloudflare.com/profile/api-tokens
- [ ] Find old token: **"Edit zone DNS"** (with "All zones" access)
- [ ] Revoke old token
- [ ] Verify both csb0 and csb1 still working (using new token)
- [ ] Document in SECRETS.md: old token revoked on [date]

### 2. Git History Cleanup

- [ ] Search for old token in git history:
  ```bash
  cd ~/Code/nixcfg
  git log --all --full-history -S '***REDACTED***' --oneline
  ```
- [ ] If found: Use BFG Repo-Cleaner or git-filter-repo to remove
- [ ] Verify plain text token never committed:
  ```bash
  git log --all --full-history -- hosts/csb0/docker/traefik/variables.env
  git log --all --full-history -- hosts/csb1/docker/traefik/variables.env
  ```
- [ ] Update P6400 task with findings

### 3. Check Local Decrypted Secrets on Hosts

- [ ] **csb0:** Check for plain text secrets
  ```bash
  ssh mba@cs0.barta.cm -p 2222 "find ~ -name '*.env' -type f 2>/dev/null | grep -v Code/nixcfg"
  ```
- [ ] **csb1:** Check for plain text secrets
  ```bash
  ssh mba@cs1.barta.cm -p 2222 "find ~ -name '*.env' -type f 2>/dev/null | grep -v Code/nixcfg"
  ```
- [ ] Remove any found (only keep in `/run/agenix/` and repo examples)

### 4. Check for Leftover Files

**csb0:**

- [ ] Old repo dir removed: `ssh mba@cs0.barta.cm -p 2222 "test ! -d ~/nixcfg && echo OK"`
- [ ] Backup files cleaned: `ssh mba@cs0.barta.cm -p 2222 "ls -lah ~/docker-backup-* ~/traefik-broken-*"`
- [ ] Old docker dir structure: Check `~/Code/nixcfg/hosts/csb0/docker/traefik/` for unexpected files

**csb1:**

- [ ] Old repo dir removed: `ssh mba@cs1.barta.cm -p 2222 "test ! -d ~/nixcfg && echo OK"`
- [ ] Check for old token file: `ssh mba@cs1.barta.cm -p 2222 "cat ~/docker/traefik/variables.env | head -1"`
  - Should be symlink to `/run/agenix/traefik-variables`

### 5. Final QA & Documentation

**Verify Services:**

- [ ] csb0 services working:
  - `curl -sI https://home.barta.cm | head -2` (expect HTTP/2 200)
  - `curl -sI https://cs0.barta.cm | head -2` (expect HTTP/2 404)
  - MQTT: `mosquitto.barta.cm:8883` (test with IoT device)
- [ ] csb1 services working:
  - `curl -sI https://grafana.barta.cm | head -2` (expect HTTP/2 302)
  - `curl -sI https://influxdb.barta.cm | head -2` (expect HTTP/2 200)
  - `curl -sI https://docmost.barta.cm | head -2` (expect HTTP/2 200)

**Documentation:**

- [ ] Update `hosts/csb0/docs/RUNBOOK.md`:
  - Document new directory structure (`/var/lib/csb0-docker/`)
  - Update secret management section (agenix)
- [ ] Update `hosts/csb1/docs/RUNBOOK.md`:
  - Document token rotation
  - Add TODO for docker files migration
- [ ] Update `docs/SECRETS.md`:
  - Document Cloudflare token scope
  - List which hosts use which secrets
- [ ] Close P6400 task with summary

## Files to Check/Update

- `.gitignore` → Verify `*.env` and `acme.json` ignored
- `hosts/csb0/docs/RUNBOOK.md` → Document new structure
- `hosts/csb1/docs/RUNBOOK.md` → Document token rotation
- `docs/SECRETS.md` → Document secret inventory
- `+pm/backlog/P6400-csb0-cloudflare-token-rotation.md` → Mark complete

## Priority

P6 (Low-Medium) - Cleanup and verification, no urgent operational impact

## Effort

Low (1-2 hours) - Mostly verification and documentation

## Origin

Follow-up to P6400 token rotation work (2026-01-17)
