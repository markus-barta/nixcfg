# csb1 → External Hokage Consumer Migration Plan

**Server**: csb1 (Cloud Server Barta 1)  
**Migration Type**: External Hokage Consumer Pattern  
**Risk Level**: 🔴 **HIGH** - Network issues during deployment (see Incident Report)  
**Status**: 🟡 **RECOVERED** - Services online, but OLD generation (needs re-deploy)  
**Created**: November 29, 2025  
**Last Updated**: December 5, 2025 (Post-Incident)

---

## 🚨 CURRENT STATUS (Post-Incident 2025-12-05)

### ⚠️ INCIDENT OCCURRED - Server Recovered

**On 2025-12-05, deployment caused network loss.** Server recovered via VNC + manual intervention. See [Incident Report](#-incident-report-2025-12-05-network-loss-during-deployment) below.

### Reality Check

| Item                | Status                           | Notes                                            |
| ------------------- | -------------------------------- | ------------------------------------------------ |
| **Server Status**   | ✅ ONLINE                        | Recovered via VNC, all services running          |
| **Running Config**  | ❌ OLD local hokage (Gen 10)     | External hokage deployment FAILED (network loss) |
| **Network**         | ✅ Fixed with NM connection file | Manual fix persists across reboots               |
| **Flake**           | ✅ Fixed                         | Overlays code removed                            |
| **External Hokage** | ❌ NOT DEPLOYED                  | Deployment crashed server - needs retry          |
| **Docker**          | ✅ All 14 containers running     | Paperless, Grafana, InfluxDB, etc.               |

### Blockers Before RE-Deployment

1. ~~**🔴 CRITICAL**: Fix `flake.nix` - overlays directory was deleted~~ ✅ **FIXED**
2. ~~**🟡 MEDIUM**: Validate flake evaluates~~ ✅ **PASS**
3. **🔴 CRITICAL**: Add static IP configuration to configuration.nix (caused network loss!)
4. **🟡 MEDIUM**: Add `hashedPassword` for mba user (recovery fallback)
5. **🟡 PENDING**: Test build: `nix build '.#nixosConfigurations.csb1.config.system.build.toplevel'`
6. **🟡 PENDING**: Re-deploy to csb1 with `nixos-rebuild switch`

### How to Verify Current State

```bash
# SSH to csb1 and check for nixbit (external hokage indicator)
ssh -p 2222 mba@csb1 "which nixbit"
# If "nixbit not found" → OLD local hokage
# If path returned → External hokage deployed
```

---

### Previous Migration Attempt (2025-11-29) - INCOMPLETE

| Milestone              | Status                       | Reality                                    |
| ---------------------- | ---------------------------- | ------------------------------------------ |
| Pre-flight checks      | ✅ Passed                    | ✅                                         |
| Backups created        | ✅ Netcup + Restic + Archive | ✅                                         |
| Configuration deployed | ⚠️ Claimed 13:43             | ❌ Deployed OLD local hokage, not external |
| Services restored      | ✅ 15/15 containers          | ✅ Services work                           |
| Full reboot verified   | ✅ 13:54                     | ✅ System boots                            |
| External hokage active | ❌ NOT VERIFIED              | ❌ No nixbit = not external hokage         |

**Running NixOS**: 25.11.20251117.89c2b23 (Xantusia) - but with LOCAL hokage

---

## 🎯 Migration Overview

### Uzumaki Compatibility ✅

**Yes, uzumaki will work on csb1!**

csb1's `configuration.nix` already imports `../../modules/uzumaki/server.nix` which provides:

| Feature               | Source             | Current (old build)      | After Deploy |
| --------------------- | ------------------ | ------------------------ | ------------ |
| `pingt` function      | uzumaki/common.nix | ✅ Working               | ✅           |
| `sourcefish` function | uzumaki/common.nix | ✅ Working               | ✅           |
| `sourceenv` function  | uzumaki/common.nix | ✅ Working               | ✅           |
| `stress` function     | uzumaki/common.nix | ❌ Missing (added later) | ✅ NEW       |
| `stasysmod` function  | uzumaki/common.nix | ❌ Missing (added later) | ✅ NEW       |
| `helpfish` function   | uzumaki/common.nix | ❌ Missing (added later) | ✅ NEW       |
| `EDITOR=nano`         | uzumaki/server.nix | ✅ Working               | ✅           |
| zellij package        | uzumaki/server.nix | ✅ Working               | ✅           |

**Note**: Current running system (2025-11-29) predates some uzumaki functions. Deploy will add the new ones.

After hokage migration, uzumaki will continue to work because:

1. `uzumaki/server.nix` is imported in `configuration.nix`
2. It uses `lib.mkAfter` so it layers ON TOP of hokage's fish config
3. No conflicts with external hokage - uzumaki adds, hokage provides base

### Current State (Validated 2025-12-05)

| Attribute       | Value                                                     |
| --------------- | --------------------------------------------------------- |
| **Hostname**    | `csb1`                                                    |
| **Role**        | Cloud server for monitoring, docs, and databases          |
| **Criticality** | 🟡 **MEDIUM** - Monitoring/documentation services         |
| **OS**          | NixOS 25.11.20251117.89c2b23 (Xantusia)                   |
| **Structure**   | OLD local hokage (uzumaki functions work, no nixbit)      |
| **Config**      | Main repo flake configured but BROKEN (missing overlays/) |
| **Services**    | 15 Docker containers                                      |
| **Backup**      | Daily at 01:30 AM (working ✅)                            |

### Target State

| Attribute          | Value                                              |
| ------------------ | -------------------------------------------------- |
| **OS**             | NixOS (keep current or update)                     |
| **Structure**      | External hokage consumer from `github:pbek/nixcfg` |
| **Config**         | New configuration in main repo (`~/Code/nixcfg`)   |
| **Services**       | Same Docker services (preserved, declarative)      |
| **Customizations** | Uzumaki namespace for machine-specific config      |
| **Backup**         | Keep Docker restic container (stable, tested)      |

### Migration Strategy

- **Approach**: mixins → external hokage consumer pattern
- **Module Import**: Change from local `../../modules/mixins` to flake input from Patrizio's repo
- **Customizations**: Move csb1-specific services to Uzumaki namespace
- **Services**: Keep Docker-based (declare in NixOS configuration)
- **Data**: Preserve all Docker volumes and bind mounts
- **SSH Keys**: Preserve host keys (avoid "host key changed" warnings)

---

## 📊 COMPARISON TO hsb0 MIGRATION

### What We Learned from hsb0/hsb8 Migrations

Both hsb0 and hsb8 successfully migrated to external hokage consumer pattern in November 2025.

#### Key Lessons Applied

1. ✅ **lib-utils**: External nixcfg uses `nixcfg.commonArgs.lib-utils` - don't try `inputs.nixcfg.lib-utils`
2. ✅ **SSH Key Security**: Use `lib.mkForce` to override SSH keys - prevents omega key injection
3. ✅ **Test Build**: Use a local server for test builds before deployment
4. ✅ **Zero Downtime**: NixOS generation switch is fast and reliable
5. ✅ **Passwordless Sudo**: Add `security.sudo-rs.wheelNeedsPassword = false` explicitly
6. ✅ **Fish Functions**: Restore `sourcefish` in `programs.fish.interactiveShellInit`
7. ✅ **Commit Strategy**: Separate commits per phase for easy rollback

### Critical Differences: csb1 vs hsb0

| Aspect              | hsb0                 | csb1                            |
| ------------------- | -------------------- | ------------------------------- |
| **Location**        | Home network (jhw22) | Cloud (Netcup VPS)              |
| **Physical Access** | Yes                  | No (VNC console only)           |
| **Services**        | DNS/DHCP (critical)  | Monitoring/docs (less critical) |
| **Risk Level**      | 🔴 HIGH              | 🟡 MEDIUM                       |
| **Downtime Impact** | Entire network       | Monitoring data gaps            |
| **SSH Port**        | 22                   | 2222                            |
| **Dependencies**    | All network devices  | csb0 MQTT (for InfluxDB data)   |

---

## 📚 OFFICIAL HOKAGE CONSUMER REFERENCE

**Source**: Patrizio's canonical examples at `github:pbek/nixcfg/examples/hokage-consumer`

### Reference Links

- **Example Flake**: [hokage-consumer/flake.nix](https://github.com/pbek/nixcfg/blob/main/examples/hokage-consumer/flake.nix)
- **Server Config**: [hokage-consumer/server/configuration.nix](https://github.com/pbek/nixcfg/blob/main/examples/hokage-consumer/server/configuration.nix)
- **README**: [hokage-consumer/README.md](https://github.com/pbek/nixcfg/blob/main/examples/hokage-consumer/README.md)
- **Quick Start**: [hokage-consumer/QUICK_START.md](https://github.com/pbek/nixcfg/blob/main/examples/hokage-consumer/QUICK_START.md)

---

## 🔄 Hokage Consumer Pattern Migration

### What's Changing

**From (Current - on server's local ~/nixcfg):**

```nix
# flake.nix - LOCAL fork with mixins embedded
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    # ... other inputs
  };
  # mixins are in modules/mixins/
}

# hosts/csb1/configuration.nix
{
  imports = [
    ../../modules/mixins/server-remote.nix  # OLD structure
    ../../modules/mixins/server-mba.nix
    ../../modules/mixins/zellij.nix
  ];
}
```

**To (Target - in main repo):**

```nix
# flake.nix - Import hokage from Patrizio's repo
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixcfg.url = "github:pbek/nixcfg";  # ← External hokage module
  };

  outputs = { self, nixpkgs, nixcfg, ... }@inputs: {
    nixosConfigurations.csb1 = nixpkgs.lib.nixosSystem {
      modules = commonServerModules ++ [
        nixcfg.nixosModules.hokage  # ← Import from external flake
        ./hosts/csb1/configuration.nix
        disko.nixosModules.disko
      ];
      specialArgs = self.commonArgs // {
        inherit inputs;
        # lib-utils already provided by self.commonArgs
      };
    };
  };
}

# hosts/csb1/configuration.nix
{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.zfs.nix
    # NO local mixins import - comes from flake
  ];

  hokage = {
    hostName = "csb1";
    userLogin = "mba";
    userNameLong = "Markus Barta";
    userNameShort = "Markus";
    userEmail = "markus@barta.com";
    role = "server-remote";              # Remote cloud server
    useInternalInfrastructure = false;   # External consumer
    useSecrets = false;                  # Until agenix migration
    useSharedKey = false;                # No omega keys
    zfs.enable = true;
    zfs.hostId = "<hostid>";             # From current config
    audio.enable = false;
    programs.git.enableUrlRewriting = false;
  };

  # csb1-specific services
  virtualisation.docker.enable = true;
}
```

### Key Benefits

1. **Upstream Updates**: Get hokage improvements from Patrizio automatically
2. **Cleaner Separation**: Your customizations in Uzumaki namespace
3. **No Fork Maintenance**: Don't need to merge upstream changes
4. **Standardized**: Same pattern for all external consumers

---

## 📋 Pre-Migration Checklist

### Information Gathering ✅

- [x] All SSH access documented (see `secrets/RUNBOOK.md`)
- [x] All provider credentials secured in 1Password
- [x] All service credentials in 1Password
- [x] Backup system verified and working
- [x] Docker structure mapped
- [x] Data volumes identified
- [x] Dependencies documented

### Configuration Preparation ⏳

- [ ] Create new `hosts/csb1/configuration.nix` in main repo
- [ ] Add `nixcfg.url = "github:pbek/nixcfg"` to flake inputs (already present)
- [ ] Import hokage as external module (not local path)
- [ ] Set `hokage.useInternalInfrastructure = false`
- [ ] Set `hokage.useSecrets = false` (until agenix migration)
- [ ] Set `hokage.useSharedKey = false`
- [ ] 🚨 Add `lib.mkForce` SSH key override (prevent lockout!)
- [ ] 🚨 Add `security.sudo-rs.wheelNeedsPassword = false`
- [ ] 🚨 Add fish shell `sourcefish` function
- [ ] 🆕 Set `hashedPassword` for mba user (emergency recovery)
- [ ] 🆕 TEMPORARILY enable `PasswordAuthentication = lib.mkForce true`
- [ ] Declare Docker service management in configuration
- [ ] Configure SSH host key preservation
- [ ] Test configuration: `nixos-rebuild build --flake .#csb1`

### Backup Verification ✅ (Completed 2025-11-29)

- [x] Daily backups working
- [x] Backup contains all critical data
- [x] Restore procedure documented (see `secrets/RUNBOOK.md`)
- [x] Manual pre-migration backup triggered
- [x] Pre-migration backup verified

#### Backups Created

| Type                | Details                            | Location                         |
| ------------------- | ---------------------------------- | -------------------------------- |
| **Netcup Snapshot** | `pre-hokage-migration` @ 11:58:42Z | Netcup SCP panel                 |
| **Restic Backup**   | Snapshot `fd569a07`, 31 MiB        | Hetzner Storage Box              |
| **Local Archive**   | 164 files, full old config         | `archive/2025-11-29-pre-hokage/` |

---

## 🚨 CRITICAL: SSH Key Security (Lesson from hsb8)

### The Problem

When switching from local hokage (`serverMba.enable = true`) to external hokage, the mixin that provides your SSH key is removed. The external hokage `server-remote.nix` module auto-injects Patrizio's SSH keys (omega@\*) into ALL users.

**Result without fix**: Complete SSH lockout - only external omega keys present!

### The Fix (REQUIRED)

```nix
# In configuration.nix, AFTER hokage configuration:

# ============================================================================
# 🚨 SSH KEY SECURITY - CRITICAL FIX FROM hsb8 INCIDENT
# ============================================================================
users.users.mba = {
  openssh.authorizedKeys.keys = lib.mkForce [
    # Markus' SSH key ONLY - replace with your actual key
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDGIQIkx1H1iVXWYKnHkxQsS7tGsZq3SoHxlVccd+kroMC/DhC4MWwVnJInWwDpo/bz7LiLuh+1Bmq04PswD78EiHVVQ+O7Ckk32heWrywD2vufihukhKRTy5zl6uodb5+oa8PBholTnw09d3M0gbsVKfLEi4NDlgPJiiQsIU00ct/y42nI0s1wXhYn/Oudfqh0yRfGvv2DZowN+XGkxQQ5LSCBYYabBK/W9imvqrxizttw02h2/u3knXcsUpOEhcWJYHHn/0mw33tl6a093bT2IfFPFb3LE2KxUjVqwIYz8jou8cb0F/1+QJVKtqOVLMvDBMqyXAhCkvwtEz13KEyt" # mba@markus
  ];
};

# ============================================================================
# 🚨 PASSWORDLESS SUDO - Also lost when removing serverMba mixin
# ============================================================================
security.sudo-rs.wheelNeedsPassword = false;

# ============================================================================
# 🚨 FISH SHELL CONFIGURATION - Lost when removing serverMba mixin
# ============================================================================
programs.fish.interactiveShellInit = ''
  function sourcefish --description 'Load env vars from a .env file into current Fish session'
    set file "$argv[1]"
    if test -z "$file"
      echo "Usage: sourcefish PATH_TO_ENV_FILE"
      return 1
    end
    if test -f "$file"
      for line in (cat "$file" | grep -v '^[[:space:]]*#' | grep .)
        set key (echo $line | cut -d= -f1)
        set val (echo $line | cut -d= -f2-)
        set -gx $key "$val"
      end
    else
      echo "File not found: $file"
      return 1
    end
  end
  export EDITOR=nano
'';
```

---

## 🚀 EXECUTION PHASES

### Phase 1: Pre-Migration (30 minutes before)

1. Trigger manual backup
2. Verify backup completed
3. Document snapshot ID for rollback
4. Save docker-compose files locally

See `secrets/MIGRATION-PLAN.md` for detailed commands with credentials.

### Phase 2: Remove Local Hokage Import from configuration.nix

**Status**: ⏸️ Not Started  
**Duration**: 1 minute  
**Risk**: 🟢 LOW (local change only)

Remove `../../modules/mixins/*` imports from configuration.nix

### Phase 2.5: Update Hokage Configuration

**Status**: ⏸️ Not Started  
**Duration**: 5 minutes  
**Risk**: 🔴 HIGH (SSH key security!)

1. Replace mixin with explicit hokage options
2. 🚨 Add `lib.mkForce` SSH key override
3. 🚨 Add passwordless sudo
4. 🚨 Restore fish functions

### Phase 3: Update flake.nix csb1 Definition

**Status**: ⏸️ Not Started  
**Duration**: 2 minutes  
**Risk**: 🟢 LOW (local change only)

Replace `mkServerHost "csb1"` with full `nixosSystem` definition using external hokage.

### Phase 4: Test Build (Local)

**Status**: ✅ Evaluation passes  
**Duration**: 5-15 minutes  
**Risk**: 🟢 LOW (test only)

```bash
# From Mac - test that config evaluates and builds
cd ~/Code/nixcfg

# Quick eval test (already passed!)
nix eval '.#nixosConfigurations.csb1.config.system.build.toplevel'

# Full build test (downloads/builds all packages)
nix build '.#nixosConfigurations.csb1.config.system.build.toplevel' --no-link
```

### Phase 5: Capture Baseline

**Status**: ⏸️ Not Started  
**Duration**: 2 minutes  
**Risk**: 🟢 LOW (read-only)

**CRITICAL: Do this BEFORE deploy!**

```bash
# Save current state for comparison
ssh -p 2222 mba@csb1 "docker ps --format '{{.Names}}: {{.Status}}'" > ~/csb1-baseline-$(date +%Y%m%d).txt
ssh -p 2222 mba@csb1 "fish -i -c 'type pingt'" >> ~/csb1-baseline-$(date +%Y%m%d).txt
```

### Phase 6: Deploy

**Status**: ⏸️ Not Started  
**Duration**: 5-15 minutes  
**Risk**: 🟡 MEDIUM

```bash
# From Mac - deploy to csb1
cd ~/Code/nixcfg

# Option A: Direct deploy (requires nixos-rebuild on Mac with Linux builder)
nixos-rebuild switch --flake .#csb1 \
  --target-host "mba@csb1" \
  --build-host "mba@csb1" \
  --use-remote-sudo \
  --option extra-ssh-option "-p 2222"

# Option B: Build remotely and switch
ssh -p 2222 mba@csb1 "cd ~/nixcfg && git pull && sudo nixos-rebuild switch --flake .#csb1"
```

### Phase 7: Immediate Verification

**Status**: ⏸️ Not Started  
**Duration**: 5 minutes  
**Risk**: 🟢 LOW (verification only)

Run verification checklist from "Post-Migration Verification" section:

```bash
# Quick health check script
ssh -p 2222 mba@csb1 << 'EOF'
echo "=== SSH: OK ==="
echo "=== Sudo: $(sudo whoami) ==="
echo "=== Docker containers: $(docker ps -q | wc -l) running ==="
echo "=== nixbit: $(which nixbit 2>/dev/null || echo 'NOT FOUND') ==="
fish -i -c 'echo "=== pingt: $(type pingt >/dev/null 2>&1 && echo OK || echo MISSING) ==="'
fish -i -c 'echo "=== EDITOR: $EDITOR ==="'
EOF
```

### Phase 8: Documentation

**Status**: ⏸️ Not Started  
**Duration**: 5 minutes

Update this migration plan with:

- Actual deployment time
- Any issues encountered
- Lessons learned

---

## 🔄 Rollback Plan

### Option 1: NixOS Generation Rollback (If SSH works)

```bash
# Immediate rollback
sudo nixos-rebuild switch --rollback

# Or specific generation
sudo nixos-rebuild switch --switch-generation <N>
```

### Option 2: VNC Console (If SSH broken)

1. Access provider's VNC console
2. Login locally
3. Run rollback command
4. Reboot

### Option 3: Restore from Backup (If system broken)

See `secrets/RUNBOOK.md` for full restore procedure with credentials.

---

## ✅ Post-Migration Verification

### Pre-Deploy Baseline (CAPTURE BEFORE DEPLOY!)

Run these commands and save output for comparison:

```bash
# SSH to csb1 and capture baseline
ssh -p 2222 mba@csb1 << 'EOF'
echo "=== BASELINE CAPTURED: $(date -Iseconds) ==="

echo -e "\n=== DOCKER CONTAINERS ==="
docker ps --format 'table {{.Names}}\t{{.Status}}'

echo -e "\n=== DOCKER NETWORKS ==="
docker network ls

echo -e "\n=== LISTENING PORTS ==="
ss -tlnp | grep -E ':(80|443|8181|3000|22222|2222)\s'

echo -e "\n=== FISH FUNCTIONS ==="
fish -i -c 'functions pingt sourcefish helpfish' 2>/dev/null | head -5

echo -e "\n=== DISK USAGE ==="
df -h / /home

echo -e "\n=== ZFS POOLS ==="
zpool status -x
EOF
```

### Immediate Checks (Within 5 minutes of deploy)

#### 🚨 CRITICAL - SSH & Security

- [ ] SSH access working: `ssh -p 2222 mba@csb1 "echo OK"`
- [ ] 🚨 SSH keys verified - ONLY mba keys present: `ssh -p 2222 mba@csb1 "cat ~/.ssh/authorized_keys"`
- [ ] 🚨 NO `omega@*` keys in authorized_keys
- [ ] 🚨 Passwordless sudo working: `ssh -p 2222 mba@csb1 "sudo whoami"`

#### 🐳 Docker Services (14 containers must be running)

- [ ] All containers UP: `docker ps --format '{{.Names}}: {{.Status}}' | grep -c "Up"` = 14
- [ ] Traefik: `curl -s https://csb1/ -o /dev/null -w '%{http_code}'` = 200 or 404
- [ ] Grafana: `curl -s https://grafana.csb1/ -o /dev/null -w '%{http_code}'`
- [ ] Paperless: `curl -s https://paperless.csb1/ -o /dev/null -w '%{http_code}'`
- [ ] Docmost: `curl -s https://docmost.csb1/ -o /dev/null -w '%{http_code}'`
- [ ] InfluxDB: `docker exec csb1-influxdb-1 influx ping`

#### 🐟 Uzumaki (Fish functions)

- [ ] pingt works: `ssh -p 2222 mba@csb1 "fish -i -c 'type pingt'"`
- [ ] sourcefish works: `ssh -p 2222 mba@csb1 "fish -i -c 'type sourcefish'"`
- [ ] helpfish works: `ssh -p 2222 mba@csb1 "fish -i -c 'helpfish'" | head -5`
- [ ] EDITOR set: `ssh -p 2222 mba@csb1 "fish -i -c 'echo \$EDITOR'"` = nano

#### 🔧 External Hokage Indicators

- [ ] nixbit installed: `ssh -p 2222 mba@csb1 "which nixbit"`
- [ ] nixbit works: `ssh -p 2222 mba@csb1 "nixbit --version"`

#### 🔒 SSL/TLS

- [ ] SSL certificates valid (Traefik ACME)
- [ ] No certificate warnings in browser

### Container Status Reference

| Container                   | Purpose        | Health Check       |
| --------------------------- | -------------- | ------------------ |
| csb1-traefik-1              | Reverse proxy  | ports 80, 443 open |
| csb1-grafana-1              | Monitoring UI  | HTTP 200           |
| csb1-influxdb-1             | Time-series DB | `influx ping`      |
| csb1-paperless-1            | Document mgmt  | HTTP 200, healthy  |
| csb1-paperless-redis-1      | Cache          | running            |
| csb1-paperless-db-1         | PostgreSQL     | running            |
| csb1-paperless-tika-1       | OCR            | running            |
| csb1-paperless-gotenberg-1  | PDF            | running            |
| csb1-docmost-1              | Wiki/docs      | HTTP 200           |
| csb1-docmost-redis-1        | Cache          | running            |
| csb1-docmost-db-1           | PostgreSQL     | running            |
| csb1-smtp-1                 | Email relay    | running            |
| csb1-restic-cron-hetzner-1  | Backups        | running            |
| csb1-docker-proxy-traefik-1 | Docker API     | running            |

### 24-Hour Monitoring

- [ ] All services still running
- [ ] Backup completed successfully (next night @ 01:30)
- [ ] No unexpected restarts: `docker ps -a --filter "status=restarting"`
- [ ] Data collection working (csb0 MQTT → InfluxDB)

### 48-Hour Confirmation

- [ ] Two successful backup cycles
- [ ] All services stable
- [ ] No user complaints

---

## 🎯 Success Criteria

### Must Have (Blocking)

- ✅ SSH access working
- ✅ All Docker services accessible
- ✅ No data loss
- ✅ Backup system working
- ✅ No critical errors in logs

### Should Have (Important)

- ✅ SSL certificates working
- ✅ All containers running smoothly
- ✅ Performance acceptable

### Nice to Have (Optional)

- ✅ Cleaner configuration
- ✅ Better monitoring

---

## 📊 Risk Assessment

### Low Risk ✅

- Data loss (daily backups, tested restore)
- Service availability (Docker data preserved)
- Configuration errors (can rollback)

### Medium Risk ⚠️

- SSH lockout (mitigated - see below)
- Docker networking changes
- VNC console access (if needed)

### Mitigation

- 🚨 SSH key security fix (`lib.mkForce`) applied
- 🆕 Password auth temporarily enabled (hsb1 lesson!)
- 🆕 Known password set for mba user
- Pre-migration backup (Netcup + Restic + Archive)
- VNC console access ready
- Rollback procedure tested
- csb1 is less critical than csb0

### hsb1 Lockout Lesson (2025-11-28)

Even with `lib.mkForce` SSH key override, hsb1 got locked out because:

1. Hokage module also controls `PasswordAuthentication`
2. There was a module ordering conflict
3. Neither SSH keys NOR password worked

**Fix for csb1**: Temporarily enable password auth during migration:

```nix
services.openssh.settings.PasswordAuthentication = lib.mkForce true;
```

---

## 📅 Recommended Execution

### Timing

- **Best**: Weekday evening or weekend afternoon
- **Avoid**: During work hours, when monitoring is needed

### Duration

- **Total Window**: 2-3 hours
- **Expected Downtime**: 15-30 minutes

### Communication

- csb1 is monitoring server - brief data gaps acceptable
- No family/neighbor impact (unlike csb0)

---

## 🔗 Related Documentation

- [hsb0 Hokage Migration](../../hsb0/docs/MIGRATION-PLAN-HOKAGE.md) - Completed reference
- [Hokage Options](../../../docs/hokage-options.md) - Module reference
- [Hokage Consumer Example](https://github.com/pbek/nixcfg/tree/main/examples/hokage-consumer) - Official reference
- **[Detailed Plan with Credentials](../secrets/MIGRATION-PLAN.md)** - Full commands (gitignored)

---

## 📝 Investigation Notes

### Validation (2025-12-05)

Investigation revealed the migration was **NOT completed**:

1. **SSH to csb1** confirmed no `nixbit` (external hokage tool) installed
2. **System fish config** shows uzumaki functions (pingt, sourcefish) work - these come from local hokage
3. **Flake.nix** is configured for external hokage BUT cannot evaluate
4. **Blocker**: `overlays/` directory deleted in commit `95a8999` but still referenced

### What's Actually Running

```bash
# Checked via SSH on 2025-12-05
$ which nixbit
# NOT FOUND - confirms OLD local hokage

$ fish -i -c 'type pingt'
# FOUND in /etc/fish/config.fish - uzumaki functions work

$ nixos-version
25.11.20251117.89c2b23 (Xantusia)
```

### Flake Error (FIXED)

```
error: Path 'overlays' does not exist in Git repository "/Users/markus/Code/nixcfg".
```

Commit `95a8999` ("chore: cleanup unused packages") deleted `overlays/` but `flake.nix` still references it at line 46-55.

**Fix applied 2025-12-05**: Removed obsolete overlays loading code from flake.nix. The overlays were:

- `nixbit.nix` - now provided by external hokage
- `qownnotes.nix` - now uses standard nixpkgs package
- `default.nix` - was empty placeholder

### Next Steps

1. ~~Fix flake.nix to handle missing overlays directory~~ ✅ DONE
2. ~~Verify all NixOS configs can evaluate~~ ✅ DONE
3. Test build csb1 configuration
4. Deploy external hokage to csb1

---

---

## 🚨 INCIDENT REPORT: 2025-12-05 Network Loss During Deployment

### Timeline (All times CET/local)

| Time   | Event                                                             |
| ------ | ----------------------------------------------------------------- |
| ~12:30 | Started deployment of csb1 with `nixos-rebuild switch`            |
| ~12:35 | Deployment appeared to be running normally                        |
| ~12:40 | **SSH connection lost** - csb1 became unreachable                 |
| ~12:42 | Ping to 152.53.64.166 failing - request timeouts                  |
| ~12:45 | Accessed Netcup SCP panel, initiated VNC console                  |
| ~12:50 | VNC showed csb1 at login prompt (booted successfully)             |
| ~12:55 | **Problem**: Cannot login - `mba` user has no console password    |
| ~13:00 | Attempted boot to generation 9 - still no network                 |
| ~13:10 | Attempted boot to generation 10 with `single` user mode           |
| ~13:12 | Single user mode = root account locked, unusable                  |
| ~13:15 | Booted gen 10 with `init=/bin/sh` via GRUB edit                   |
| ~13:20 | **New problem**: Keyboard broken - cannot type colon `:`          |
| ~13:25 | Brought up network interface manually via VNC                     |
| ~13:30 | `ip link set ens3 up` - interface UP                              |
| ~13:32 | `ip addr add 152.53.64.166/24 dev ens3` - IP assigned             |
| ~13:34 | `ip route add default via 152.53.64.1` - gateway set              |
| ~13:36 | Ping working from csb1! But cannot SSH in (no sshd running)       |
| ~13:40 | Started sshd: `/nix/var/nix/profiles/system/sw/bin/sshd`          |
| ~13:42 | SSH connection refused - PAM blocking access                      |
| ~13:45 | Started sshd with `-o UsePAM=no`                                  |
| ~13:47 | **SSH ACCESS RESTORED** - connected from Mac                      |
| ~13:50 | Created NetworkManager connection file via SSH                    |
| ~13:52 | Copied file to `/etc/NetworkManager/system-connections/` from VNC |
| ~13:55 | Rebooted normally (no GRUB edits)                                 |
| ~14:00 | **csb1 BACK ONLINE** - all 14 Docker containers running           |

### Root Cause Analysis

**Primary Issue: NetworkManager had no saved connection profile**

The csb1 configuration uses `networking.networkmanager.enable = true` but:

1. **No static IP configuration** was defined in NixOS config
2. NetworkManager relies on saved connection profiles
3. On a fresh generation switch, the connection profile was lost/not present
4. Without a connection profile, NetworkManager didn't know to bring up `ens3`

**Contributing Factors:**

1. **No console password set** - `mba` user only had SSH key auth, no `hashedPassword`
2. **External hokage may have changed network config** - The new generation potentially had different network settings
3. **No fallback mechanism** - Unlike `networking.interfaces.*` which is declarative, NetworkManager needs imperative connection files

### What Broke

| Component        | Status    | Cause                                            |
| ---------------- | --------- | ------------------------------------------------ |
| Network on boot  | ❌ FAILED | No NM connection profile                         |
| Console login    | ❌ FAILED | No user password set                             |
| Single user mode | ❌ FAILED | Root account locked                              |
| SSH              | ❌ FAILED | sshd not running in init=/bin/sh                 |
| VNC keyboard     | ⚠️ BROKEN | Colon `:` character not working (codepage issue) |

### Recovery Actions Taken

#### Phase 1: VNC Access

1. Accessed Netcup Server Control Panel
2. Opened VNC console to csb1
3. Discovered cannot login (no password)

#### Phase 2: Emergency Boot (init=/bin/sh)

1. Rebooted via VNC
2. At GRUB menu, pressed `e` to edit boot entry
3. Found `linux` line, changed `init=/nix/store/...-init` to `init=/bin/sh`
4. Pressed Ctrl+X to boot
5. Got minimal root shell `sh-5.3#`

#### Phase 3: Manual Network Configuration

Commands run from VNC (had to use full paths due to minimal PATH):

```bash
# Check interface status
/nix/var/nix/profiles/system/sw/bin/ip link
# Result: ens3 was DOWN

# Bring up interface
/nix/var/nix/profiles/system/sw/bin/ip link set ens3 up

# Assign IP address (Netcup static IP)
/nix/var/nix/profiles/system/sw/bin/ip addr add 152.53.64.166/24 dev ens3

# Add default gateway
/nix/var/nix/profiles/system/sw/bin/ip route add default via 152.53.64.1

# Verify connectivity
/nix/var/nix/profiles/system/sw/bin/ping 8.8.8.8
# SUCCESS - packets flowing!
```

#### Phase 4: SSH Daemon

```bash
# Start sshd (initially blocked by PAM)
/nix/var/nix/profiles/system/sw/bin/sshd
# FAILED: PAM account configuration denied access

# Fix symlink for run/current-system
/nix/var/nix/profiles/system/sw/bin/ln -sf /nix/var/nix/profiles/system /run/current-system

# Start sshd bypassing PAM
/nix/var/nix/profiles/system/sw/bin/sshd -o UsePAM=no
# SUCCESS - SSH accessible!
```

#### Phase 5: Permanent Fix

From SSH session (as mba user):

```bash
# Create NetworkManager connection file
echo '[connection]
id=ens3
type=ethernet
interface-name=ens3
autoconnect=true

[ipv4]
method=manual
addresses=152.53.64.166/24
gateway=152.53.64.1
dns=8.8.8.8

[ipv6]
method=ignore' > /home/mba/ens3.nmconnection
```

From VNC (as root, because sudo didn't work in minimal boot):

```bash
# Copy to NetworkManager directory
/nix/var/nix/profiles/system/sw/bin/cp /home/mba/ens3.nmconnection /etc/NetworkManager/system-connections/

# Set correct permissions (NM requires 600)
/nix/var/nix/profiles/system/sw/bin/chmod 600 /etc/NetworkManager/system-connections/ens3.nmconnection

# Reboot normally
/nix/var/nix/profiles/system/sw/bin/reboot
```

### Current State (After Recovery)

| Component             | Status                       | Notes                            |
| --------------------- | ---------------------------- | -------------------------------- |
| **Network**           | ✅ Working                   | Static IP via NM connection file |
| **SSH**               | ✅ Working                   | Port 2222, key + password auth   |
| **Docker**            | ✅ All 14 containers running | Started automatically            |
| **Services**          | ✅ All healthy               | Paperless, Grafana, etc.         |
| **NixOS Generation**  | ⚠️ Gen 10 (pre-migration)    | External hokage NOT deployed     |
| **Uzumaki functions** | ❌ Not present               | Needs re-deploy                  |
| **nixbit**            | ❌ Not present               | Needs re-deploy                  |

### Lessons Learned

#### 1. NetworkManager Needs Connection Profiles

**Problem**: `networking.networkmanager.enable = true` without connection profiles = no network on boot

**Solution Options**:

- A) Add explicit static IP to NixOS config:
  ```nix
  networking.interfaces.ens3 = {
    useDHCP = false;
    ipv4.addresses = [{
      address = "152.53.64.166";
      prefixLength = 24;
    }];
  };
  networking.defaultGateway = "152.53.64.1";
  networking.nameservers = [ "8.8.8.8" "8.8.4.4" ];
  ```
- B) Use systemd-networkd instead of NetworkManager for servers
- C) Create NM connection file in NixOS activation script

#### 2. Always Set Console Password for Remote Servers

**Problem**: Cannot recover via VNC if no user has a password

**Solution**: Add to configuration.nix:

```nix
users.users.mba.hashedPassword = "<hash from mkpasswd>";
```

#### 3. Document Network Configuration

**Problem**: Had to guess/look up the correct gateway

**Add to secrets/SECRETS.md**:

```
| **Static IP** | 152.53.64.166/24 |
| **Gateway** | 152.53.64.1 |
| **DNS** | 8.8.8.8, 8.8.4.4 |
```

#### 4. VNC Keyboard Issues

**Problem**: German/international keyboard layout in VNC couldn't type colon `:`

**Workaround**: Used full paths to avoid needing `:` character, or use on-screen keyboard

#### 5. init=/bin/sh Recovery

**Learned**: In minimal `init=/bin/sh` boot:

- PATH is empty - use full paths `/nix/var/nix/profiles/system/sw/bin/*`
- `/home` may not be mounted
- `/run/current-system` symlink doesn't exist
- PAM doesn't work (use `sshd -o UsePAM=no`)
- sudo doesn't work (suid bits not set)
- Must use VNC root shell for privileged operations

### Recommendations for Next Deployment

1. **Add static IP configuration** to csb1's configuration.nix BEFORE re-deploying
2. **Set mba user hashedPassword** as backup recovery method
3. **Keep password auth enabled** (`PasswordAuthentication = lib.mkForce true`) during migration
4. **Have VNC console ready** before starting any deploy
5. **Document IP/gateway** in accessible location
6. **Test locally first**: `nix build '.#nixosConfigurations.csb1.config.system.build.toplevel'`

### Files Modified During Recovery

| File                                                       | Change  | Persistence                |
| ---------------------------------------------------------- | ------- | -------------------------- |
| `/etc/NetworkManager/system-connections/ens3.nmconnection` | Created | ✅ Persists across reboots |
| (no NixOS config changes on server)                        | -       | -                          |

### Action Items Before Re-Deploy

- [ ] Add static networking to `hosts/csb1/configuration.nix`
- [ ] Add `hashedPassword` for mba user
- [ ] Test full build locally
- [ ] Ensure NM connection file approach or switch to systemd-networkd
- [ ] Have incident recovery commands documented

---

**STATUS**: 🟡 RECOVERED - csb1 online but running OLD generation (gen 10)  
**CONFIDENCE**: 🟡 MEDIUM - Need to add static networking before re-deploy  
**NEXT**: 1) Add static IP config to configuration.nix, 2) Re-deploy with proper networking
