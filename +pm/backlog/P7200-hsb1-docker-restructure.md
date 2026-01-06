# hsb1 Docker & Scripts Restructure

**Created**: 2025-12-01  
**Updated**: 2026-01-06 (Detailed Preparation)  
**Priority**: P7200 (Low)  
**Status**: Backlog (Well-Prepared, Not Urgent)  
**Host**: hsb1

---

## Problem

hsb1's Docker configuration and user scripts are managed in a separate git repository (`miniserver24-docker.git`) and unversioned directories. This creates:

- Two repositories to maintain for one host
- No single source of truth
- Scripts not version controlled
- Inconsistent with the rest of the fleet

**Current State** (verified 2026-01-06):

- ✅ 12 Docker containers running fine
- ✅ Separate repo is version controlled (4 commits, last: 2025-11-28)
- ❌ `~/docker` is a separate git repo, not a symlink
- ❌ `~/scripts` is unversioned (16 files)
- ❌ Runtime data mixed with config in `~/docker/mounts/` (3.5 GB)

---

## Current Structure

```
~/docker/                          ← Separate git repo (miniserver24-docker.git)
├── .git/                          # 4 commits, actively maintained
├── docker-compose.yml             # 12.8 KB, 12 containers
├── Makefile                       # 1.1 KB
├── mounts/                        # 3.5 GB runtime data (18 directories)
│   ├── homeassistant/
│   ├── zigbee2mqtt/
│   ├── mosquitto/
│   ├── nodered/
│   ├── scrypted/
│   ├── matter-server/
│   ├── apprise/
│   ├── opus-stream-to-mqtt/
│   └── ... (10 more)
├── restic-cron/
├── smtp/
└── archive/

~/scripts/                         ← NOT version controlled
├── apc-to-mqtt.sh
├── deploy-miniserver.sh
├── deploy-pixoo.sh
├── fullvolume.sh
├── reboot-all-fritz.sh
├── set_vlc_volume.sh
├── vlc-kiosk-output.sh
├── watchtower-pidicon-run.sh
└── ... (8 more files)
```

---

## Target Structure

```
~/Code/nixcfg/hosts/hsb1/
├── docker/                        ← Version controlled in nixcfg
│   ├── docker-compose.yml
│   ├── Makefile
│   ├── restic-cron/
│   └── smtp/
├── users/
│   └── mba/
│       └── scripts/               ← Version controlled in nixcfg
│           ├── apc-to-mqtt.sh
│           ├── deploy-miniserver.sh
│           └── ... (all scripts)

~/docker              → symlink to ~/Code/nixcfg/hosts/hsb1/docker/
~/scripts             → symlink to ~/Code/nixcfg/hosts/hsb1/users/mba/scripts/

~/docker-data/                     ← Runtime data (NOT in git, .gitignore)
├── homeassistant/
├── zigbee2mqtt/
├── mosquitto/
└── ... (all 18 mount directories)
```

---

## Migration Plan

### Phase 1: Preparation (No Risk)

1. **Create directory structure in nixcfg**:

   ```bash
   cd ~/Code/nixcfg
   mkdir -p hosts/hsb1/docker
   mkdir -p hosts/hsb1/users/mba/scripts
   ```

2. **Copy docker configs to nixcfg**:

   ```bash
   ssh mba@hsb1.lan 'cd ~/docker && tar czf - docker-compose.yml Makefile restic-cron smtp' | tar xzf - -C hosts/hsb1/docker/
   ```

3. **Copy scripts to nixcfg**:

   ```bash
   ssh mba@hsb1.lan 'cd ~/scripts && tar czf - *.sh *.json' | tar xzf - -C hosts/hsb1/users/mba/scripts/
   ```

4. **Update docker-compose.yml paths**:
   - Change all `./mounts/` → `/home/mba/docker-data/`
   - Verify no hardcoded `miniserver24` references remain

5. **Commit to nixcfg**:
   ```bash
   git add hosts/hsb1/docker hosts/hsb1/users
   git commit -m "feat(hsb1): add docker and scripts to nixcfg"
   git push
   ```

### Phase 2: Migration (Medium Risk - 90 minutes)

**Prerequisites:**

- [ ] Phase 1 complete and pushed to GitHub
- [ ] Backup of `~/docker` and `~/scripts` created
- [ ] All containers verified running: `docker ps | wc -l` = 13 (header + 12 containers)
- [ ] Time window: Non-critical hours (not during automation events)

**Steps on hsb1:**

1. **Stop all containers**:

   ```bash
   cd ~/docker
   docker compose down
   ```

2. **Move runtime data**:

   ```bash
   mv ~/docker/mounts ~/docker-data
   ```

3. **Backup old directories**:

   ```bash
   mv ~/docker ~/docker.backup
   mv ~/scripts ~/scripts.backup
   ```

4. **Pull latest nixcfg**:

   ```bash
   cd ~/Code/nixcfg
   git pull
   ```

5. **Create symlinks**:

   ```bash
   ln -s ~/Code/nixcfg/hosts/hsb1/docker ~/docker
   ln -s ~/Code/nixcfg/hosts/hsb1/users/mba/scripts ~/scripts
   ```

6. **Verify symlinks**:

   ```bash
   ls -la ~/docker/docker-compose.yml  # Should show symlink chain
   ls -la ~/scripts/apc-to-mqtt.sh     # Should show symlink chain
   ```

7. **Start containers**:

   ```bash
   cd ~/docker
   docker compose up -d
   ```

8. **Verify all containers running**:
   ```bash
   docker ps --format "{{.Names}}" | sort
   # Expected: 12 containers
   ```

### Phase 3: Cleanup (After 1 week of stable operation)

1. **Archive old repo**:

   ```bash
   cd ~/docker.backup
   git remote rename origin old-origin
   # Keep for reference, don't delete yet
   ```

2. **Remove backups** (after 1 month):
   ```bash
   rm -rf ~/docker.backup ~/scripts.backup
   ```

---

## Rollback Plan

If containers fail to start:

1. **Stop failed containers**:

   ```bash
   docker compose down
   ```

2. **Restore symlinks**:

   ```bash
   rm ~/docker ~/scripts
   mv ~/docker.backup ~/docker
   mv ~/scripts.backup ~/scripts
   ```

3. **Restore runtime data**:

   ```bash
   mv ~/docker-data ~/docker/mounts
   ```

4. **Restart containers**:
   ```bash
   cd ~/docker
   docker compose up -d
   ```

---

## Acceptance Criteria

- [ ] `hosts/hsb1/docker/` exists in nixcfg with docker-compose.yml
- [ ] `hosts/hsb1/users/mba/scripts/` exists in nixcfg with all scripts
- [ ] `~/docker` is a symlink to nixcfg
- [ ] `~/scripts` is a symlink to nixcfg
- [ ] `~/docker-data/` contains all runtime data (3.5 GB)
- [ ] All 12 Docker containers running
- [ ] No references to `miniserver24` in configs
- [ ] Old `miniserver24-docker.git` repo archived

---

## Test Plan

### Pre-Migration Verification

```bash
# Verify current state
ssh mba@hsb1.lan 'docker ps --format "{{.Names}}" | wc -l'  # Should be 12
ssh mba@hsb1.lan 'curl -s http://localhost:8123 | head -5'  # Home Assistant
ssh mba@hsb1.lan 'curl -s http://localhost:1880 | head -5'  # Node-RED
```

### Post-Migration Verification

```bash
# Verify symlinks
ssh mba@hsb1.lan '[ -L ~/docker ] && echo "✅ ~/docker symlink" || echo "❌ FAIL"'
ssh mba@hsb1.lan '[ -L ~/scripts ] && echo "✅ ~/scripts symlink" || echo "❌ FAIL"'

# Verify containers
ssh mba@hsb1.lan 'docker ps --format "{{.Names}}" | sort'
# Expected: apprise, docker-smtp-1, homeassistant, matter-server, mosquitto,
#           nodered, opus-stream-to-mqtt, plex, restic-cron-hetzner,
#           scrypted, watchtower-weekly, zigbee2mqtt

# Verify services responding
ssh mba@hsb1.lan 'curl -s http://localhost:8123 | grep -q "Home Assistant" && echo "✅ HA"'
ssh mba@hsb1.lan 'curl -s http://localhost:1880 | grep -q "Node-RED" && echo "✅ Node-RED"'
ssh mba@hsb1.lan 'curl -s http://localhost:8888 | grep -q "Zigbee2MQTT" && echo "✅ Z2M"'

# Verify git tracking
cd ~/Code/nixcfg
git status hosts/hsb1/docker/
git status hosts/hsb1/users/
```

---

## Risk Assessment

| Risk                        | Probability | Impact | Mitigation                                    |
| --------------------------- | ----------- | ------ | --------------------------------------------- |
| Containers fail to start    | Medium      | High   | Rollback plan, backups, test window           |
| Path errors in compose file | Low         | High   | Pre-verify paths in Phase 1                   |
| Data loss during move       | Very Low    | High   | Use `mv` not `cp`, verify before delete       |
| Home automation downtime    | Medium      | Medium | Do during non-critical hours, have HA app     |
| Symlink confusion           | Low         | Low    | Clear verification steps, visual confirmation |

**Overall Risk**: 🟡 MEDIUM (but well-mitigated with preparation and rollback plan)

---

## Why Not Do It Now?

- ✅ Current setup works fine (12 containers running, actively maintained repo)
- ✅ Separate repo is version controlled (not losing history)
- ⚠️ Migration requires 90-minute maintenance window
- ⚠️ Medium risk of breaking home automation
- ⚠️ Marginal benefit (consolidation vs. functionality)

**Decision**: Prepare thoroughly, execute when:

1. You have a 2-hour maintenance window
2. You're physically present (in case of issues)
3. No critical home automation events scheduled

---

## Related

- `P6380-hsb1-agenix-secrets.md` - System secrets migration
- `P6390-hsb1-opus-mqtt-credentials.md` - Docker container secrets
- `P5700-hsb1-vlc-kiosk-declarative.md` - Kiosk configuration
- Runbook: `hosts/hsb1/docs/RUNBOOK.md` (documents target state)
