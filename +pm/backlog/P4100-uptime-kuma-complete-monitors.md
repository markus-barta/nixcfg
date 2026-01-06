# P4100: hsb0 Uptime Kuma - Local Network Monitoring

## Overview

Complete Uptime Kuma setup on hsb0 for monitoring your local network infrastructure (jhw22 - 192.168.1.x).

## Scope

- **Network**: jhw22 (192.168.1.x)
- **Instance**: hsb0 at 192.168.1.99:3001
- **Goal**: Monitor all local infrastructure services
- **Excludes**:
  - hsb8 (parents' network) - see P5000
  - Cloud services (csb0/csb1) - see P6000

## Current State (8 HTTP monitors, all working)

| Monitor               | URL/Host           | Status     |
| --------------------- | ------------------ | ---------- |
| csb0 - node RED       | home.barta.cm      | ✅ Working |
| csb1 - Docmost        | docmost.barta.cm   | ✅ Working |
| csb1 - Grafana        | grafana.barta.cm   | ✅ Working |
| csb1 - Paperless      | paperless.barta.cm | ✅ Working |
| hsb0 - AdGuard Home   | 192.168.1.99:3000  | ✅ Working |
| hsb1 - Apprise        | 192.168.1.101:8001 | ✅ Working |
| hsb1 - Home Assistant | 192.168.1.101:8123 | ✅ Working |
| hsb1 - Zigbee2MQTT    | 192.168.1.101:8888 | ✅ Working |

## Tasks

### ✅ Verified (2026-01-06)

- All 8 monitors are configured and working (100% uptime)
- Home Assistant correctly on port 8123 (not 1880)
- node RED is on csb0 (home.barta.cm:1880), not hsb1

### High Priority - Core Local Infrastructure

| Task | Monitor Name           | Type     | Host/URL      | Port | Notes                  |
| ---- | ---------------------- | -------- | ------------- | ---- | ---------------------- |
| [ ]  | **hsb0 - DNS**         | DNS      | 192.168.1.99  | 53   | Query: google.com      |
| [ ]  | **hsb1 - MQTT Broker** | MQTT     | 192.168.1.101 | 1883 | Topic: home/#          |
| [ ]  | **hsb0 - SSH**         | TCP Port | 192.168.1.99  | 22   | Home server            |
| [ ]  | **hsb1 - SSH**         | TCP Port | 192.168.1.101 | 22   | Home automation server |

### Medium Priority - Local Services

| Task | Monitor Name              | Type | Host/URL                   | Port  | Notes               |
| ---- | ------------------------- | ---- | -------------------------- | ----- | ------------------- |
| [ ]  | **hsb0 - Uptime Kuma**    | HTTP | http://192.168.1.99:3001   | 3001  | Monitor the monitor |
| [ ]  | **hsb0 - NCPS**           | HTTP | http://192.168.1.99:8501   | 8501  | Binary cache proxy  |
| [ ]  | **hsb1 - Home Assistant** | HTTP | http://192.168.1.101:8123  | 8123  | Core automation     |
| [ ]  | **hsb1 - Scrypted**       | HTTP | http://192.168.1.101:10443 | 10443 | Camera/NVR bridge   |
| [ ]  | **hsb1 - Matter Server**  | HTTP | http://192.168.1.101:5580  | 5580  | Matter protocol     |

### Optional - Local Infrastructure

| Task | Monitor Name         | Type | Host/URL      | Port | Notes          |
| ---- | -------------------- | ---- | ------------- | ---- | -------------- |
| [ ]  | **gpc0 - Gaming PC** | Ping | 192.168.1.154 | -    | Often OFF      |
| [ ]  | **fritzbox**         | Ping | 192.168.1.5   | -    | Router/gateway |

## Not Monitored (By Design)

| Item                 | Reason                       |
| -------------------- | ---------------------------- |
| hsb8 (192.168.1.100) | Parents' network - see P5000 |
| csb0/csb1            | Cloud services - see P6000   |
| HedgeDoc             | No longer in use             |
| Uptime Kuma itself   | Don't monitor yourself       |

## Monitor Type Reference

| Type         | Use Case                 | Example            |
| ------------ | ------------------------ | ------------------ |
| **HTTP(s)**  | Web services, APIs       | grafana.barta.cm   |
| **TCP Port** | SSH, database ports      | :22, :2222         |
| **Ping**     | Basic host availability  | Gaming PC          |
| **DNS**      | DNS server health        | AdGuard DNS on :53 |
| **MQTT**     | MQTT broker connectivity | Mosquitto on :1883 |

## Acceptance Criteria

- [ ] All 8 existing monitors continue working
- [ ] DNS monitor verifies AdGuard Home is resolving queries
- [ ] MQTT monitor confirms Mosquitto broker is accepting connections
- [ ] All SSH ports monitored via TCP Port checks
- [ ] Core local services added (HA, Scrypted, Matter, NCPS, Uptime Kuma)
- [ ] (Optional) Gaming PC and FritzBox ping monitors added

## Resources

- Uptime Kuma Dashboard: http://192.168.1.99:3001
- Related: `+pm/done/2025-12-07-hsb0-uptime-kuma.md` (initial installation)
- P5000: Parents' network monitoring
- P6000: Cloud services monitoring
