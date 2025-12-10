# NixFleet - Fleet Management Dashboard

**Created**: 2025-12-10
**Priority**: Medium
**Status**: In Progress

---

## Goal

Run NixFleet as the fleet dashboard for all NixOS and macOS hosts, Docker-deployed on csb1 with agent-based polling so hosts behind NAT stay manageable; Thymis was considered but skipped because it lacks macOS coverage and a Docker-first path.

---

## What is NixFleet?

A simple, custom-built fleet management dashboard that:

- Shows all hosts (NixOS + macOS) in one view
- Displays OPS-STATUS data: audit status, criticality, test results
- Allows triggering `git pull`, `switch`, and `test` commands
- Uses agent-based polling (works through NAT/firewalls)
- Runs in Docker on csb1
- Auth: password with optional TOTP

---

## Architecture

```text
┌──────────────────────────────────────────────────────────┐
│                    NIXFLEET DASHBOARD                    │
│                     (Docker on csb1)                     │
│                     fleet.barta.cm                       │
└──────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              │               │               │
              ▼               ▼               ▼
        ┌──────────┐    ┌──────────┐    ┌──────────┐
        │   hsb0   │    │   hsb1   │    │  imac0   │
        │  (agent) │    │  (agent) │    │  (agent) │
        │          │    │          │    │          │
        │ NixOS    │    │ NixOS    │    │ macOS    │
        │ rebuild  │    │ rebuild  │    │ hm switch│
        └──────────┘    └──────────┘    └──────────┘
```

---

## Decisions Made

### Domain

- **URL**: `fleet.barta.cm`

### Authentication

- Password hash env (`NIXFLEET_PASSWORD_HASH`), bcrypt recommended; legacy SHA-256 still accepted
- TOTP optional if `pyotp` + `NIXFLEET_TOTP_SECRET` are present
- Agent bearer token (`NIXFLEET_API_TOKEN`) is optional today (fail-open if unset) — tighten

### Commands Available

| Command       | Description                               |
| ------------- | ----------------------------------------- |
| `pull`        | Run `git pull` in nixcfg                  |
| `switch`      | Run `nixos-rebuild switch` or `hm switch` |
| `pull-switch` | Both in sequence                          |
| `test`        | Run host test suite                       |

### Data Displayed

| Field       | Source                   |
| ----------- | ------------------------ |
| Host        | Agent registration       |
| Type        | NixOS / macOS            |
| Criticality | Agent-provided           |
| Status      | Online / Offline / Error |
| Last Seen   | Agent polling            |
| Audited     | Manual via PATCH API     |
| Tests       | Agent test results       |
| Comment     | Manual via PATCH API     |

---

## Acceptance Criteria

### Phase 1: Dashboard (Code Complete ✅)

- [x] FastAPI dashboard (Tokyo Night theme)
- [x] Password auth + optional TOTP
- [x] Agent bearer token support
- [x] Host registration & status
- [x] Command queue (pull, switch, test)
- [x] Dockerfile + compose

### Phase 2: Harden AuthZ/AuthN (TODO)

- [ ] Make `NIXFLEET_API_TOKEN` mandatory (fail-closed agent auth)
- [ ] Enforce bcrypt-only hashes; reject SHA-256
- [ ] Require TOTP when configured; block login if missing code/secret
- [ ] Sign/validate session cookies; add CSRF for dashboard actions; make logout POST
- [ ] Restrict `/health` or redact sensitive flags
- [ ] Extend rate limits beyond login (agent + queue endpoints)

### Phase 3: Deploy to csb1

- [ ] Copy nixfleet to csb1
- [ ] Create .env with credentials (bcrypt hash, mandatory API token, TOTP secret, session secret)
- [ ] Add to Traefik network with HSTS and correct real-ip headers
- [ ] Configure Cloudflare DNS (fleet.barta.cm)
- [ ] Verify dashboard reachable over HTTPS only

### Phase 4: Agent Deployment

- [ ] Deploy agent to hsb0 (test)
- [ ] Deploy agent to all NixOS hosts
- [ ] Deploy agent to macOS hosts
- [ ] Create systemd service (NixOS)
- [ ] Create launchd plist (macOS)

### Phase 5: Documentation

- [ ] Update INFRASTRUCTURE.md
- [ ] Update AGENT-WORKFLOW.md
- [ ] Add to host READMEs

---

## Files Created

```text
pkgs/nixfleet/
├── app/
│   ├── main.py           # FastAPI application
│   └── requirements.txt  # Python dependencies
├── agent/
│   └── nixfleet-agent.sh # Agent script
├── Dockerfile            # Container build
├── docker-compose.yml    # csb1 deployment
└── README.md             # Documentation
```

---

## Deployment Steps

### 1. Generate Credentials

```bash
# bcrypt password hash (preferred)
python3 -c "import bcrypt; print(bcrypt.hashpw(b'your-password', bcrypt.gensalt()).decode())"

# API token (required)
openssl rand -hex 32

# Session secret (required)
openssl rand -hex 32

# TOTP secret (recommended)
python3 -c "import pyotp; print(pyotp.random_base32())"
```

### 2. Deploy to csb1

```bash
# Copy files
scp -r pkgs/nixfleet mba@cs1.barta.cm:~/docker/

# SSH to csb1
ssh -p 2222 mba@cs1.barta.cm

# Create .env
cd ~/docker/nixfleet
cat > .env << EOF
NIXFLEET_PASSWORD_HASH=<hash>
NIXFLEET_API_TOKEN=<token>
NIXFLEET_SESSION_SECRET=<secret>
NIXFLEET_TOTP_SECRET=<totp>
EOF

# Start
docker compose up -d
```

### 3. Configure DNS

Add to Cloudflare: `fleet.barta.cm → 152.53.64.166`

---

## Hosts to Manage

| Host          | Type  | Location | Criticality |
| ------------- | ----- | -------- | ----------- |
| hsb0          | NixOS | Home     | 🔴 HIGH     |
| hsb1          | NixOS | Home     | 🟡 MEDIUM   |
| hsb8          | NixOS | Parents  | 🟡 MEDIUM   |
| gpc0          | NixOS | Home     | 🟢 LOW      |
| csb0          | NixOS | Cloud    | 🔴 HIGH     |
| csb1          | NixOS | Cloud    | 🟡 MEDIUM   |
| imac0         | macOS | Home     | 🟢 LOW      |
| mba-imac-work | macOS | Work     | 🟢 LOW      |
| mba-mbp-work  | macOS | Work     | 🟢 LOW      |

---

## Security TODOs (from current implementation)

- Require `NIXFLEET_API_TOKEN`; reject agent calls when unset.
- Enforce bcrypt-only hashes; drop SHA-256 fallback.
- Make TOTP mandatory when configured; fail login if code/secret absent.
- Sign/verify session cookies; add CSRF protection; make logout POST.
- Rate-limit agent and queue endpoints; not just login.
- Lock down `/health` or hide token/TOTP configuration signals.
- Add HSTS/secure cookies by default; ensure Traefik forwards real client IPs for rate limits.
- Consider per-host credentials or mTLS to avoid single shared agent token.

---

## References

- [pkgs/nixfleet/README.md](../../pkgs/nixfleet/README.md) — Full documentation
- [docs/INFRASTRUCTURE.md](../../docs/INFRASTRUCTURE.md) — Architecture context
