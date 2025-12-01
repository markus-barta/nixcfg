# 2025-12-01 - hsb1 Docker & Scripts Restructure

## Description

Consolidate Docker config and user scripts into main nixcfg repo with symlinks as "signposts".

## Source

- Original: `hosts/hsb1/docs/MIGRATION-PLAN-HSB1.md` (Part B: Phase 10-11)
- Split from: `2025-11-26-hsb1-full-migration.md`

## Scope

Applies to: hsb1

## Current State

```
~/docker/                          ← Separate git repo
├── docker-compose.yml
├── Makefile
├── .git/                          # Separate repo: miniserver24-docker.git
├── mounts/                        # Runtime data (20+ folders)
│   ├── homeassistant/
│   ├── zigbee2mqtt/
│   └── ...
├── restic-cron/
└── smtp/

~/scripts/                         ← Plain directory, not version controlled
├── apc-to-mqtt.sh
├── deploy-miniserver.sh
└── ...
```

## Target State

```
~/Code/nixcfg/hosts/hsb1/
├── docker/                        ← Version controlled
│   ├── docker-compose.yml
│   └── Makefile
├── users/
│   ├── mba/scripts/               ← Version controlled
│   └── kiosk/                     ← Version controlled

~/docker              → symlink to ~/Code/nixcfg/hosts/hsb1/docker/
~/scripts             → symlink to ~/Code/nixcfg/hosts/hsb1/users/mba/scripts/

~/docker-data/                     ← Runtime data (NOT in git)
├── homeassistant/
├── zigbee2mqtt/
└── ...
```

## Acceptance Criteria

- [ ] Create `hosts/hsb1/docker/` with docker-compose.yml
- [ ] Create `hosts/hsb1/users/mba/scripts/` with all scripts
- [ ] Create `hosts/hsb1/users/kiosk/` with kiosk configs
- [ ] Update docker-compose.yml paths: `./mounts/` → `/home/mba/docker-data/`
- [ ] Update hostname refs: `miniserver24` → `hsb1` in all files
- [ ] Move runtime data: `~/docker/mounts` → `~/docker-data`
- [ ] Set up symlinks on server
- [ ] Verify all 11 Docker containers start
- [ ] Verify kiosk display works
- [ ] Retire old ~/docker git repo

## Implementation

See `hosts/hsb1/docs/MIGRATION-PLAN-HSB1.md` Phase 10 for detailed steps.

## Test Plan

### Manual Test

1. After symlinks set up, verify:
   - `ls ~/docker/docker-compose.yml` shows file
   - `ls ~/scripts/apc-to-mqtt.sh` shows file
2. Start Docker: `cd ~/docker && docker compose up -d`
3. Verify all containers: `docker ps | wc -l` (should be 12 = header + 11 containers)
4. Check kiosk display shows camera feed

### Automated Test

```bash
# Verify symlinks
ssh mba@hsb1.lan '[ -L ~/docker ] && echo "✅ ~/docker symlink" || echo "❌ ~/docker not symlink"'
ssh mba@hsb1.lan '[ -L ~/scripts ] && echo "✅ ~/scripts symlink" || echo "❌ ~/scripts not symlink"'

# Verify containers running
ssh mba@hsb1.lan 'docker ps --format "{{.Names}}" | wc -l'
# Expected: 11

# Verify git tracking
ssh mba@hsb1.lan 'cd ~/Code/nixcfg && git status --short hosts/hsb1/docker/'
```

## Notes

- Risk Level: 🟡 MEDIUM - Docker may not start if paths wrong
- Duration: ~90 minutes
- **The Rule**: Every managed file is a symlink. If it's not a symlink, it's not managed.
- Benefits: Single source of truth, changes automatically in git, no sync scripts
