# NixFleet Deployment to csb1

**Created**: 2025-12-10
**Priority**: High
**Status**: Ready
**Depends On**: pkgs/nixfleet/ (code complete)

---

## Goal

Deploy NixFleet dashboard to csb1 and connect first agent.

---

## Pre-Deployment Checklist

- [ ] Generate password hash
- [ ] Generate API token
- [ ] Generate session secret
- [ ] Generate TOTP secret (optional)
- [ ] Store credentials in 1Password

---

## Deployment Steps

### 1. Copy Files to csb1

```bash
scp -P 2222 -r pkgs/nixfleet mba@cs1.barta.cm:~/docker/
```

### 2. Create Environment File

```bash
ssh -p 2222 mba@cs1.barta.cm
cd ~/docker/nixfleet

# Generate credentials
PASSWORD_HASH=$(echo -n "your-password" | sha256sum | cut -d' ' -f1)
API_TOKEN=$(openssl rand -hex 32)
SESSION_SECRET=$(openssl rand -hex 32)
TOTP_SECRET=$(python3 -c "import pyotp; print(pyotp.random_base32())")

cat > .env << EOF
NIXFLEET_PASSWORD_HASH=$PASSWORD_HASH
NIXFLEET_API_TOKEN=$API_TOKEN
NIXFLEET_SESSION_SECRET=$SESSION_SECRET
NIXFLEET_TOTP_SECRET=$TOTP_SECRET
EOF

chmod 600 .env
```

### 3. Add Cloudflare DNS

```
fleet.barta.cm → 152.53.64.166 (A record)
```

### 4. Start Container

```bash
cd ~/docker/nixfleet
docker compose up -d
docker compose logs -f
```

### 5. Verify Dashboard

- [ ] Navigate to https://fleet.barta.cm
- [ ] Login with password
- [ ] Verify TOTP works
- [ ] Check empty dashboard loads

### 6. Deploy First Agent (hsb1 - guinea pig)

```bash
# On hsb1
mkdir -p ~/.local/bin
curl -o ~/.local/bin/nixfleet-agent.sh https://raw.githubusercontent.com/.../nixfleet-agent.sh
# Or copy from local
scp pkgs/nixfleet/agent/nixfleet-agent.sh mba@hsb1.lan:~/.local/bin/

chmod +x ~/.local/bin/nixfleet-agent.sh

# Test run
NIXFLEET_URL="https://fleet.barta.cm" \
NIXFLEET_TOKEN="<api-token>" \
~/.local/bin/nixfleet-agent.sh
```

### 7. Verify Agent Connection

- [ ] Agent appears in dashboard
- [ ] Status shows "Online"
- [ ] Pull button works
- [ ] Switch button works
- [ ] Test button works

---

## Acceptance Criteria

- [ ] Dashboard accessible at https://fleet.barta.cm
- [ ] Login works (password + TOTP)
- [ ] At least one agent connected and working
- [ ] Pull command works
- [ ] Switch command works
- [ ] Test command works

---

## Rollback

If something goes wrong:

```bash
cd ~/docker/nixfleet
docker compose down
```

No changes to csb1 NixOS config, so no system rollback needed.

---

## After Deployment

- [ ] Add agent to remaining hosts (Phase 3 in main backlog)
- [ ] Create systemd/launchd services for agents
- [ ] Update INFRASTRUCTURE.md with deployment details
