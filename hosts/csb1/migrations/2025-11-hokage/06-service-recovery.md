# T13: Service Recovery Test

**Feature ID**: F13  
**Status**: ⏳ Pending  
**Purpose**: Verify services survive restart and auto-recover

## Overview

Tests that all services properly restart after a system reboot or Docker restart. This is critical for migration - after applying new NixOS configuration, services must come back up automatically.

## ⚠️ WARNING

**This test causes service disruption!** Only run:

- During maintenance windows
- When you can monitor recovery
- After taking a snapshot (T08)

## Prerequisites

- SSH access to csb1 (port 2222)
- VNC console access ready (in case SSH doesn't recover)
- Maintenance window

## Test Procedures

### Option A: Docker Restart (Minimal Disruption)

```bash
ssh -p 2222 mba@cs1.barta.cm

# Record current state
docker ps --format "{{.Names}}: {{.Status}}" > /tmp/before-restart.txt

# Restart Docker daemon
sudo systemctl restart docker

# Wait for recovery (60 seconds)
sleep 60

# Check all containers recovered
docker ps --format "{{.Names}}: {{.Status}}" > /tmp/after-restart.txt
diff /tmp/before-restart.txt /tmp/after-restart.txt
```

### Option B: Full System Reboot (Complete Test)

```bash
# From local machine
ssh -p 2222 mba@cs1.barta.cm 'sudo reboot'

# Wait 2-3 minutes for reboot
sleep 180

# Verify SSH recovered
ssh -p 2222 mba@cs1.barta.cm 'uptime'

# Check all containers running
ssh -p 2222 mba@cs1.barta.cm 'docker ps'

# Run full test suite
./tests/T00-nixos-base.sh
./tests/T01-docker-services.sh
# ... etc
```

### Option C: Safe Test (No Restart)

```bash
# Just verify restart policies are set correctly
./tests/T13-service-recovery.sh
```

## What to Verify After Restart

1. **SSH accessible** (most critical!)
2. **Docker daemon running**
3. **All containers restarted**
4. **No containers in restart loop**
5. **Services responding on URLs**
6. **ZFS pools mounted**

## Container Restart Policies

All containers should have `restart: unless-stopped` or `restart: always`:

```bash
# Check restart policies
docker inspect --format '{{.Name}}: {{.HostConfig.RestartPolicy.Name}}' $(docker ps -q)
```

Expected output:

```
/csb1-grafana-1: unless-stopped
/csb1-traefik-1: unless-stopped
...
```

## Automated Test (Safe Mode)

```bash
./tests/T13-service-recovery.sh
```

This only checks restart policies and systemd configuration - does NOT actually restart anything.

## Recovery If Things Go Wrong

### SSH Not Responding After Reboot

1. Wait 5 minutes (services may still be starting)
2. Try direct IP: `ssh -p 2222 mba@152.53.64.166`
3. Use Netcup VNC console
4. Check boot logs in VNC

### Containers Not Starting

```bash
# Via VNC or SSH
sudo systemctl status docker
docker ps -a  # Shows stopped containers
docker logs <container-name>  # Check for errors
```

### Emergency Recovery

```bash
# Rollback to previous NixOS generation
sudo nixos-rebuild switch --rollback
sudo reboot
```

## Success Criteria

- ✅ Docker systemd service enabled
- ✅ All containers have restart policy
- ✅ ZFS import service enabled
- ✅ (Optional) Actual restart test passes

## Test Log

| Date | Tester | Result | Test Type | Notes |
| ---- | ------ | ------ | --------- | ----- |
|      |        | ⏳     |           |       |
