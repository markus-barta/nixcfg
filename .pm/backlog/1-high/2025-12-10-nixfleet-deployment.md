# NixFleet Deployment to csb1

**Created**: 2025-12-10
**Priority**: High
**Status**: ✅ Complete
**Depends On**: pkgs/nixfleet/ (code complete)

---

## Goal

Deploy NixFleet dashboard to csb1 and connect first agent.

---

## Pre-Deployment Checklist

- [x] Generate password hash (bcrypt)
- [x] Generate API token
- [x] Generate TOTP secret
- [x] Store credentials in 1Password

---

## Deployment Steps

### 1. Clone Repo on csb1

```bash
cd ~/Code && git clone https://github.com/markus-barta/nixcfg.git
```

### 2. Copy Files to Docker Directory

```bash
mkdir -p ~/docker/nixfleet
cp -r ~/Code/nixcfg/pkgs/nixfleet/* ~/docker/nixfleet/
```

### 3. Create Environment File

```bash
# .env file with:
NIXFLEET_PASSWORD_HASH=<bcrypt-hash>
NIXFLEET_API_TOKEN=<64-char-hex>
NIXFLEET_TOTP_SECRET=<base32-secret>
```

### 4. Add Cloudflare DNS

```text
fleet.barta.cm → 152.53.64.166 (A record)
```

### 5. Start Container

```bash
cd ~/docker/nixfleet
docker compose up -d
```

### 6. Verify Dashboard

- [x] Navigate to https://fleet.barta.cm
- [ ] Login with password
- [ ] Verify TOTP works
- [ ] Check empty dashboard loads

---

## Future Updates

To update NixFleet after pushing changes:

```bash
ssh -p 2222 mba@cs1.barta.cm "~/docker/nixfleet/update.sh"
```

---

## Remaining Tasks

### 7. Deploy First Agent (hsb1 - guinea pig)

```bash
# On hsb1
NIXFLEET_URL="https://fleet.barta.cm" \
NIXFLEET_TOKEN="<api-token>" \
~/Code/nixcfg/pkgs/nixfleet/agent/nixfleet-agent.sh
```

### 8. Verify Agent Connection

- [ ] Agent appears in dashboard
- [ ] Status shows "Online"
- [ ] Pull button works
- [ ] Switch button works
- [ ] Test button works

---

## Acceptance Criteria

- [x] Dashboard accessible at https://fleet.barta.cm
- [ ] Login works (password + TOTP)
- [ ] At least one agent connected and working
- [ ] Commands work (pull, switch, test)

---

## Rollback

```bash
cd ~/docker/nixfleet
docker compose down
```

---

## After Deployment

- [ ] Add agent to remaining hosts
- [ ] Create systemd/launchd services for agents
- [ ] Update INFRASTRUCTURE.md with deployment details
