# 2026-01-17 - csb0 Cloudflare API Token Rotation & Encryption

## Description

Traefik Cloudflare API token currently stored as plain text in `hosts/csb0/docker/traefik/variables.env`. Need to rotate token, encrypt via agenix, and update all affected hosts.

## Context

**Incident:** 2026-01-17 - Traefik config files replaced by empty directories on Jan 15 16:43. During recovery, discovered plain text CF token in repo.

**Current State:**

- Token: `***REDACTED***` (in git history)
- File: `hosts/csb0/docker/traefik/variables.env`
- Used by: csb0 Traefik for DNS-01 ACME challenge (Let's Encrypt)
- Scope: Cloudflare DNS API access for `barta.cm` zone

## Acceptance Criteria

### 1. Git Cleanup

- [ ] Remove `hosts/csb0/docker/traefik/variables.env` from git
- [ ] Add to `.gitignore`
- [ ] Purge from git history (BFG or filter-branch)
- [ ] Force push to remote (coordinate with other agents/users)

### 2. Token Rotation

- [ ] Login to Cloudflare dashboard
- [ ] Navigate to Profile → API Tokens
- [ ] Identify current token (search by prefix or check `barta.cm` zone permissions)
- [ ] Create new token with same permissions:
  - Zone: `barta.cm`
  - Permissions: `Zone:DNS:Edit`
  - Resources: `Include → Specific zone → barta.cm`
- [ ] Copy new token
- [ ] Revoke old token

### 3. Encryption via Agenix

- [ ] Create `secrets/traefik-variables.age` (already defined in `secrets.nix`)
- [ ] Encrypt new token: `agenix -e secrets/traefik-variables.age`
- [ ] Format: `CF_DNS_API_TOKEN=<new-token>`
- [ ] Commit encrypted file

### 4. Update Host Configurations

**csb0:**

- [ ] Update `hosts/csb0/configuration.nix`:
  ```nix
  age.secrets.traefik-variables = {
    file = ../../secrets/traefik-variables.age;
    path = "/home/mba/docker/traefik/variables.env";
    owner = "root";
    group = "root";
    mode = "0644";
  };
  ```
- [ ] Update docker-compose.yml if needed (already references `./traefik/variables.env`)
- [ ] Deploy via NixFleet or `just switch`

**csb1:**

- [ ] Update `hosts/csb1/configuration.nix`:
  ```nix
  age.secrets.traefik-variables = {
    file = ../../secrets/traefik-variables.age;
    path = "/home/mba/docker/traefik/variables.env";
    owner = "root";
    group = "root";
    mode = "0644";
  };
  ```
- [ ] Verify docker-compose.yml references `./traefik/variables.env`
- [ ] Deploy via NixFleet or `just switch`

### 5. Verification

**csb0:**

- [ ] SSH to csb0: `ssh mba@cs0.barta.cm -p 2222`
- [ ] Check file exists: `ls -la /home/mba/docker/traefik/variables.env`
- [ ] Check content (should be decrypted): `sudo cat /home/mba/docker/traefik/variables.env`
- [ ] Restart traefik: `cd ~/docker && docker compose restart traefik`
- [ ] Check logs: `docker logs csb0-traefik-1 --tail 50`
- [ ] Verify ACME: `curl -I https://home.barta.cm` (should be 200)
- [ ] Check cert renewal works (wait for next renewal or force)

**csb1:**

- [ ] SSH to csb1: `ssh mba@cs1.barta.cm -p 2222`
- [ ] Check file exists: `ls -la /home/mba/docker/traefik/variables.env`
- [ ] Check content (should be decrypted): `sudo cat /home/mba/docker/traefik/variables.env`
- [ ] Restart traefik: `cd ~/docker && docker compose restart traefik`
- [ ] Check logs: `docker logs csb1-traefik-1 --tail 50`
- [ ] Verify ACME: `curl -I https://grafana.barta.cm` (should be 200)
- [ ] Check cert renewal works (wait for next renewal or force)

### 6. Verify No Other Hosts

- [ ] Confirm only csb0 and csb1 use Traefik with Cloudflare DNS challenge
- [ ] Check hsb\* hosts don't have traefik/variables.env
- [ ] Document token scope in `docs/SECRETS.md`

## Files to Update

- `hosts/csb0/docker/traefik/variables.env` → DELETE from git
- `hosts/csb1/docker/traefik/variables.env` → DELETE from git (if exists)
- `.gitignore` → ADD `**/traefik/variables.env`
- `secrets/traefik-variables.age` → CREATE (encrypt new token)
- `hosts/csb0/configuration.nix` → ADD agenix secret mount
- `hosts/csb1/configuration.nix` → ADD agenix secret mount
- `docs/SECRETS.md` → DOCUMENT token scope

## Hosts Affected

- **csb0** - Traefik uses token for DNS-01 ACME (home.barta.cm, mosquitto.barta.cm, cs0.barta.cm, whoami0.barta.cm)
- **csb1** - Traefik uses token for DNS-01 ACME (grafana.barta.cm, influxdb.barta.cm, docmost.barta.cm, paperless.barta.cm, whoami1.barta.cm)

## Priority

P6 (Low-Medium) - Security issue but token already exposed in git history. Rotation mitigates risk.

## Effort

Medium (2-3 hours including git cleanup and verification)

## Origin

Discovered during 2026-01-17 Traefik recovery incident on csb0.

## References

- Incident: Traefik config files → directories (Jan 15 16:43)
- Cloudflare API Tokens: https://dash.cloudflare.com/profile/api-tokens
- Agenix docs: https://github.com/ryantm/agenix
