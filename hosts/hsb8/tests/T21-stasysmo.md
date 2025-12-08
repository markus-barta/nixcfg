# T21: StaSysMo System Metrics (hsb8)

Test StaSysMo (Starship System Monitoring) daemon and reader functionality.

## Host Information

| Property     | Value           |
| ------------ | --------------- |
| **Host**     | hsb8            |
| **Role**     | Parents' Server |
| **IP**       | 192.168.1.100   |
| **Location** | ww87            |

## Prerequisites

- [ ] Uzumaki module deployed to hsb8
- [ ] NixOS configuration applied: `sudo nixos-rebuild switch --flake .#hsb8`
- [ ] StaSysMo enabled in uzumaki config

## Automated Tests

Run: `./T21-stasysmo.sh`

## Manual Test Procedures

### Test 1: StaSysMo Daemon Service

**Steps:**

1. Check service status:
   ```bash
   systemctl status stasysmo-daemon
   ```

**Expected Results:**

- Service is active (running)
- Service is enabled (starts on boot)

**Status:** ⏳ Pending

### Test 2: StaSysMo Output Files

**Steps:**

1. Check output files exist:
   ```bash
   ls -la /dev/shm/stasysmo/
   cat /dev/shm/stasysmo/cpu
   cat /dev/shm/stasysmo/ram
   cat /dev/shm/stasysmo/load
   ```

**Expected Results:**

- `/dev/shm/stasysmo/cpu` exists with percentage value
- `/dev/shm/stasysmo/ram` exists with percentage value
- `/dev/shm/stasysmo/load` exists with load average

**Status:** ⏳ Pending

### Test 3: StaSysMo Reader Command

**Steps:**

1. Check reader exists: `which stasysmo-reader`
2. Run reader: `stasysmo-reader`

**Expected Results:**

- Command exists in PATH
- Outputs formatted system metrics for Starship

**Status:** ⏳ Pending

### Test 4: Starship Integration

**Steps:**

1. Check Starship config:
   ```bash
   grep "custom.stasysmo" ~/.config/starship.toml
   grep "stasysmo-reader" ~/.config/starship.toml
   ```

**Expected Results:**

- Starship config has `[custom.stasysmo]` section
- Uses `stasysmo-reader` command

**Status:** ⏳ Pending

### Test 5: Prompt Shows Metrics

**Steps:**

1. Open new terminal
2. Observe prompt

**Expected Results:**

- CPU, RAM, Load metrics visible in prompt
- Updates periodically (every 2 seconds)

**Status:** ⏳ Pending

## Test Results Summary

| Test | Description          | Status |
| ---- | -------------------- | ------ |
| T1   | Daemon Service       | ⏳     |
| T2   | Output Files         | ⏳     |
| T3   | Reader Command       | ⏳     |
| T4   | Starship Integration | ⏳     |
| T5   | Prompt Metrics       | ⏳     |

## Notes

- StaSysMo daemon writes to `/dev/shm/stasysmo/` (RAM disk for speed)
- Reader formats output for Starship's custom module
- Defined in `modules/uzumaki/stasysmo/`
- **Requires uzumaki migration** - see `.pm/backlog/2025-12-07-hsb8-uzumaki-deployment.md`
