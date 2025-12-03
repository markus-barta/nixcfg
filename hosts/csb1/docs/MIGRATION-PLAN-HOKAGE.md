# csb1 → External Hokage Consumer Migration Plan

**Server**: csb1 (Cloud Server Barta 1)  
**Migration Type**: External Hokage Consumer Pattern  
**Risk Level**: 🟡 **MEDIUM** - Monitoring and documentation services  
**Status**: ✅ **COMPLETE** - Successfully migrated 2025-11-29  
**Created**: November 29, 2025  
**Last Updated**: November 29, 2025

### Migration Complete (2025-11-29)

| Milestone              | Status                       |
| ---------------------- | ---------------------------- |
| Pre-flight checks      | ✅ ALL PASS                  |
| Backups created        | ✅ Netcup + Restic + Archive |
| Configuration deployed | ✅ 13:43                     |
| Services restored      | ✅ 15/15 containers          |
| Full reboot verified   | ✅ 13:54                     |
| Password auth disabled | ✅ Hardened                  |
| Post-migration tests   | ✅ ALL PASS                  |

**Final NixOS**: 25.11.20251117.89c2b23 (Xantusia)

---

## 🎯 Migration Overview

### Current State

| Attribute       | Value                                               |
| --------------- | --------------------------------------------------- |
| **Hostname**    | `csb1`                                              |
| **Role**        | Cloud server for monitoring, docs, and databases    |
| **Criticality** | 🟡 **MEDIUM** - Monitoring/documentation services   |
| **OS**          | NixOS 24.11.20240926.1925c60 (Vicuna)               |
| **Structure**   | OLD modules/mixins (local fork on server)           |
| **Config**      | Local `~/nixcfg` on server (drifted from main repo) |
| **Services**    | 15 Docker containers                                |
| **Backup**      | Daily at 01:30 AM (working ✅)                      |

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

| Type                | Details                            | Location            |
| ------------------- | ---------------------------------- | ------------------- |
| **Netcup Snapshot** | `pre-hokage-migration` @ 11:58:42Z | Netcup SCP panel    |
| **Restic Backup**   | Snapshot `fd569a07`, 31 MiB        | Hetzner Storage Box |

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

### Phase 4: Test Build

**Status**: ⏸️ Not Started  
**Duration**: 5 minutes  
**Risk**: 🟢 LOW (test only)

```bash
# On a local NixOS machine:
cd ~/Code/nixcfg
nixos-rebuild build --flake .#csb1 --show-trace
```

### Phase 5: Deploy

**Status**: ⏸️ Not Started  
**Duration**: 15-30 minutes  
**Risk**: 🟡 MEDIUM

```bash
# From Mac:
nixos-rebuild switch --flake .#csb1 \
  --target-host mba@<hostname> \
  --use-remote-sudo
```

### Phase 6: Verify Services

**Status**: ⏸️ Not Started  
**Duration**: 30 minutes

1. Verify SSH access
2. Check Docker containers
3. Verify each service (Grafana, InfluxDB, Docmost, Paperless, Traefik)
4. Check backup system

### Phase 7: Documentation

**Status**: ⏸️ Not Started  
**Duration**: 5 minutes

Update README and this migration plan with results.

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

### Immediate Checks (Within 1 hour)

- [ ] SSH access working
- [ ] 🚨 SSH keys verified - ONLY `mba@markus` key present
- [ ] 🚨 NO `omega@*` keys in authorized_keys
- [ ] 🚨 Passwordless sudo working
- [ ] All Docker containers running
- [ ] All services accessible via URLs
- [ ] No container restart loops
- [ ] No critical errors in logs
- [ ] SSL certificates valid

### 24-Hour Monitoring

- [ ] All services still running
- [ ] Backup completed successfully (next night)
- [ ] No unexpected restarts
- [ ] Data collection working (MQTT → InfluxDB)

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

## 📝 Post-Migration Notes

### Execution Date

- **Started**: _To be filled_
- **Completed**: _To be filled_
- **Duration**: _To be filled_

### Issues Encountered

- _To be filled post-migration_

### Lessons Learned

1. **What went well**: _To be filled_
2. **What could be improved**: _To be filled_
3. **Apply to csb0 migration**: _To be filled_

---

**STATUS**: ⏳ Planned - Configuration preparation needed  
**CONFIDENCE**: 🟢 HIGH - Lessons from hsb0/hsb8 applied  
**NEXT**: 1) Create configuration.nix, 2) Test build, 3) Execute
