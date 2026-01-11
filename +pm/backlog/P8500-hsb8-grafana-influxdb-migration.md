# P8500: hsb8 Grafana + InfluxDB Migration (Parents' Network)

**Created**: 2026-01-07  
**Priority**: P8500 (Backlog - Low Priority)  
**Status**: Backlog  
**Depends on**: P5000 (Uptime Kuma deployment)

---

## Problem

The parents' home has a Raspberry Pi 4 (`p4-1` at `192.168.1.11`) running Grafana and InfluxDB for monitoring smart home devices and network metrics. This legacy setup needs to be migrated to hsb8 to:

1. Consolidate services onto the new NixOS server (hsb8)
2. Eliminate maintenance of the aging Raspberry Pi
3. Provide a unified monitoring platform for parents' infrastructure
4. Ensure data continuity during the migration

**Current State (p4-1):**
- **Hostname**: p4-1
- **IP**: 192.168.1.11
- **Services**: Grafana + InfluxDB (likely Docker-based)
- **Data**: Historical metrics from smart home devices (Shelly switches, ESP32 controllers, etc.)
- **Status**: Running, needs migration

**Target State (hsb8):**
- **IP**: 192.168.1.100 (already configured)
- **Services**: Grafana + InfluxDB (native NixOS or Docker)
- **Integration**: Works with existing hsb8 services (AdGuard Home, Home Assistant)
- **Independence**: No dependencies on external infrastructure

---

## Solution

Migrate Grafana and InfluxDB from `p4-1` to `hsb8` using a phased approach:

### Architecture

```
p4-1 (192.168.1.11)                    hsb8 (192.168.1.100)
├── Grafana (port 3000) ──────────────┐
├── InfluxDB (port 8086)              │
└── Data volumes                      │
                                       ▼
                               ┌──────────────────┐
                               │ Migration Phase  │
                               │ 1. Export data   │
                               │ 2. Deploy on hsb8│
                               │ 3. Import data   │
                               │ 4. Update sources│
                               └──────────────────┘
                                       │
                                       ▼
                               Grafana + InfluxDB
                               Running on hsb8
                               (192.168.1.100)
```

### Implementation Options

**Option A: Native NixOS Services** (Preferred for hsb8)
```nix
services.grafana = {
  enable = true;
  settings.server.http_port = 3000;
  # ... configuration
};

services.influxdb2 = {
  enable = true;
  settings.http-bind-address = ":8086";
  # ... configuration
};
```

**Option B: Docker Compose** (If data migration is complex)
- Use Docker for easier data volume migration
- Match p4-1's Docker setup if it exists
- Later refactor to native NixOS if desired

---

## Acceptance Criteria

- [ ] **Data Export**: All Grafana dashboards and InfluxDB data exported from p4-1
- [ ] **Service Deployment**: Grafana and InfluxDB running on hsb8
- [ ] **Data Import**: Historical metrics successfully imported to hsb8
- [ ] **Data Sources Updated**: All Grafana data sources point to hsb8 InfluxDB
- [ ] **Notifications**: Alert rules migrated and tested
- [ ] **Network Access**: Services accessible at hsb8 IP (192.168.1.100)
- [ ] **Documentation**: Updated hsb8 README and RUNBOOK
- [ ] **Tests**: Health checks created and passing
- [ ] **Rollback Plan**: Procedure documented if migration fails
- [ ] **Decommission**: p4-1 safely powered down after verification

---

## Test Plan

### Phase 1: Pre-Migration (p4-1)

**Manual Tests:**

1. **Inventory Services**
   ```bash
   ssh pi@192.168.1.11
   docker ps  # or systemctl status
   # Document: Grafana port, InfluxDB port, data locations
   ```

2. **Export Grafana Dashboards**
   ```bash
   # Via Grafana API or UI export
   # Save all dashboards to archive
   ```

3. **Export InfluxDB Data**
   ```bash
   # Use InfluxDB export tools
   # Backup all buckets
   ```

4. **Document Configuration**
   - Grafana users and passwords
   - InfluxDB tokens and buckets
   - Data retention policies
   - Current data volume size

### Phase 2: Deployment (hsb8)

**Automated Tests:**

```bash
# After deploying configuration
ssh mba@hsb8.lan

# Check services
systemctl status grafana
systemctl status influxdb2

# Test endpoints
curl http://localhost:3000/api/health
curl http://localhost:8086/health

# Verify data import
influx bucket list
influx query 'from(bucket:"parents_data") |> range(start:-1h) |> limit(n:10)'
```

**Manual Tests:**

1. **Grafana Access**
   - Navigate to http://192.168.1.100:3000
   - Login with admin credentials
   - Verify dashboards load
   - Check data sources connected

2. **InfluxDB Verification**
   - Query recent data points
   - Verify bucket structure matches p4-1
   - Test write operations

3. **Integration Testing**
   - Verify Home Assistant can send metrics
   - Check Shelly device data flowing
   - Confirm ESP32 controllers reporting

### Phase 3: Post-Migration

**Verification:**

1. **Data Integrity**
   - Compare record counts between p4-1 and hsb8
   - Spot-check historical data
   - Verify no gaps in time series

2. **Performance**
   - Grafana dashboard load times
   - InfluxDB query performance
   - Resource usage on hsb8

3. **Monitoring**
   - Add hsb8 Grafana/InfluxDB to Uptime Kuma (P5000)
   - Set up alerts for service health

---

## Migration Steps

### Step 1: Discovery & Backup (p4-1)

```bash
# SSH to p4-1
ssh pi@192.168.1.11

# Check running services
docker ps  # or: systemctl list-units --type=service

# If Docker:
docker inspect grafana_container
docker inspect influxdb_container
docker volume ls

# Export Grafana data
# Method 1: Grafana API
curl -s http://localhost:3000/api/dashboards/db > grafana-dashboards.json

# Method 2: Grafana UI
# Dashboard → Share → Export → Save to file

# Export InfluxDB data
# Using influx export
influx export all --file influx-export.txt

# Or backup data directory
sudo tar -czf /tmp/influxdb-backup.tar.gz /var/lib/influxdb
```

### Step 2: Deploy Services on hsb8

**Option A: Native NixOS** (Recommended)

```nix
# hosts/hsb8/configuration.nix

# Add to imports:
services.grafana = {
  enable = true;
  settings = {
    server = {
      http_port = 3000;
      http_addr = "0.0.0.0";
    };
    security = {
      admin_user = "admin";
      admin_password = "CHANGE_ME";  # Use agenix secret
    };
  };
};

services.influxdb2 = {
  enable = true;
  settings = {
    http-bind-address = ":8086";
    # Add organization, token via environment or config
  };
};

# Firewall
networking.firewall.allowedTCPPorts = [ 3000 8086 ];
```

**Option B: Docker Compose** (If needed for migration)

```yaml
# /home/gb/docker/docker-compose.yml (or similar)
version: '3'
services:
  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    volumes:
      - grafana-data:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=...
      
  influxdb:
    image: influxdb:2.7
    ports:
      - "8086:8086"
    volumes:
      - influxdb-data:/var/lib/influxdb2
    environment:
      - DOCKER_INFLUXDB_INIT_MODE=setup
      - DOCKER_INFLUXDB_INIT_USERNAME=admin
      - DOCKER_INFLUXDB_INIT_PASSWORD=...
      - DOCKER_INFLUXDB_INIT_ORG=parents
      - DOCKER_INFLUXDB_INIT_BUCKET=parents_data
```

### Step 3: Data Migration

**InfluxDB Data:**
```bash
# On hsb8, after InfluxDB is running
# Export from p4-1
influx export all --file export.txt

# Or use telegraf to stream data
# Or restore from backup
```

**Grafana Dashboards:**
```bash
# Import via API
curl -X POST http://localhost:3000/api/dashboards/db \
  -H "Content-Type: application/json" \
  -d @dashboard.json
```

### Step 4: Update Data Sources

1. In Grafana UI: Settings → Data Sources
2. Update InfluxDB URL to `http://192.168.1.100:8086`
3. Update tokens if needed
4. Test data source connection

### Step 5: Verify & Decommission

1. **Monitor for 24-48 hours**
   - Check data continuity
   - Verify alerts work
   - Confirm no errors

2. **Power down p4-1**
   ```bash
   ssh pi@192.168.1.11
   sudo shutdown now
   ```

3. **Update documentation**
   - Remove p4-1 from network reference
   - Update hsb8 README with new services
   - Add to runbook

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Data loss during migration** | 🔴 High | Multiple backups, test restore on staging |
| **Service downtime** | 🟡 Medium | Migrate during low-activity hours, keep p4-1 running until verification |
| **Configuration mismatch** | 🟡 Medium | Document p4-1 config thoroughly before migration |
| **Network issues** | 🟢 Low | hsb8 already on same network, static IP configured |
| **Resource constraints** | 🟢 Low | hsb8 has 7.7GB RAM, 99GB disk free - should be sufficient |

**Rollback Plan:**
- Keep p4-1 powered off but intact for 1 week post-migration
- If issues arise: power on p4-1, update DNS to point back to .11
- NixOS rollback on hsb8 if configuration issues

---

## Dependencies

- **P5000**: Uptime Kuma should be deployed first to monitor these new services
- **Network**: hsb8 must be at ww87 location (parents' home)
- **Storage**: Verify hsb8 has sufficient disk space for historical data

---

## Related

- **P5000**: hsb8 Uptime Kuma integration (prerequisite for monitoring)
- **P8400**: imac0 Homebrew maintenance (unrelated but same timeframe)
- **Reference**: csb1 Grafana/InfluxDB setup (csb1/tests/T02-grafana.md, T03-influxdb.md)

---

## Notes

### Data Volume Estimation
- Need to check p4-1: `du -sh /var/lib/influxdb` or `docker volume ls -q | xargs docker volume inspect`
- hsb8 has 99GB free - should accommodate historical data

### Service Ports
- **Grafana**: 3000 (HTTP)
- **InfluxDB**: 8086 (HTTP)
- Both will be exposed on hsb8 (192.168.1.100)

### Security Considerations
- Use agenix for admin passwords and tokens
- Consider firewall rules (only allow from local network)
- Update any client configurations that point to p4-1

### Timing
- Best done during low-activity period (evening/night)
- Coordinate with family to avoid disrupting monitoring
- Allow 2-4 hours for complete migration

---

**Last Updated**: 2026-01-07  
**Created By**: SYSOP (via user request)

