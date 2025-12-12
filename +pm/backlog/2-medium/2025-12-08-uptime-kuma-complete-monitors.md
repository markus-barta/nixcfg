# 2025-12-08 - Uptime Kuma: Complete Monitor Configuration

## Description

Complete the Uptime Kuma monitoring setup on hsb0 by adding all missing service monitors. Leverage native monitor types (DNS, MQTT, TCP Port) instead of relying solely on HTTP checks.

## Scope

Applies to: hsb0 (Uptime Kuma instance at <http://192.168.1.99:3001>)

## Context

Uptime Kuma was installed on 2025-12-07 with initial HTTP monitors. This backlog item tracks the remaining monitors needed for comprehensive infrastructure coverage.

### Current State (8 monitors, all HTTP)

| Monitor               | URL/Host           | Status                |
| --------------------- | ------------------ | --------------------- |
| csb0 - node RED       | home.barta.cm      | ✅ Working            |
| csb1 - Docmost        | docmost.barta.cm   | ✅ Working            |
| csb1 - Grafana        | grafana.barta.cm   | ✅ Working            |
| csb1 - Paperless      | paperless.barta.cm | ✅ Working            |
| hsb0 - AdGuard Home   | 192.168.1.99:3000  | ✅ Working            |
| hsb1 - Apprise        | 192.168.1.101:8001 | ✅ Working            |
| hsb1 - Home Assistant | 192.168.1.101:1880 | ✅ Working (misnamed) |
| hsb1 - Zigbee2MQTT    | 192.168.1.101:8888 | ✅ Working            |

---

## Tasks

### Fixes

- [ ] **Rename** "hsb1 - Home Assistant" → "hsb1 - Node-RED" (it's actually Node-RED on :1880)

### High Priority - Core Services

| Task | Monitor Name           | Type | Host/URL                         | Port | Notes                      |
| ---- | ---------------------- | ---- | -------------------------------- | ---- | -------------------------- |
| [ ]  | **hsb0 - DNS**         | DNS  | 192.168.1.99                     | 53   | Query: google.com          |
| [ ]  | **hsb1 - MQTT Broker** | MQTT | 192.168.1.101                    | 1883 | Topic: `home/#` or similar |
| [ ]  | **csb0 - Traefik**     | HTTP | <https://traefik.barta.cm>       | 443  | Reverse proxy health       |
| [ ]  | **csb1 - InfluxDB**    | HTTP | <https://influxdb.barta.cm/ping> | 443  | `/ping` endpoint (no auth) |

### Medium Priority - SSH Access Monitoring

| Task | Monitor Name   | Type     | Host          | Port | Notes        |
| ---- | -------------- | -------- | ------------- | ---- | ------------ |
| [ ]  | **csb0 - SSH** | TCP Port | 85.235.65.226 | 2222 | Cloud server |
| [ ]  | **csb1 - SSH** | TCP Port | 152.53.64.166 | 2222 | Cloud server |
| [ ]  | **hsb0 - SSH** | TCP Port | 192.168.1.99  | 22   | Home server  |
| [ ]  | **hsb1 - SSH** | TCP Port | 192.168.1.101 | 22   | Home server  |

### Low Priority - Optional

| Task | Monitor Name         | Type | Host          | Notes     |
| ---- | -------------------- | ---- | ------------- | --------- |
| [ ]  | **gpc0 - Gaming PC** | Ping | 192.168.1.154 | Often OFF |

---

## Monitor Type Reference

Uptime Kuma supports these relevant monitor types:

| Type         | Use Case                 | Example            |
| ------------ | ------------------------ | ------------------ |
| **HTTP(s)**  | Web services, APIs       | grafana.barta.cm   |
| **TCP Port** | SSH, database ports      | :22, :2222         |
| **Ping**     | Basic host availability  | Gaming PC          |
| **DNS**      | DNS server health        | AdGuard DNS on :53 |
| **MQTT**     | MQTT broker connectivity | Mosquitto on :1883 |

---

## Not Monitored (By Design)

| Item                 | Reason                                      |
| -------------------- | ------------------------------------------- |
| hsb8 (192.168.1.100) | At parents' home (ww87) - different network |
| HedgeDoc             | No longer in use                            |
| Uptime Kuma itself   | Don't monitor yourself                      |

---

## Implementation Notes

### DNS Monitor Configuration

```
Monitor Type: DNS
Hostname: 192.168.1.99
Port: 53
DNS Resolve Type: A
DNS Query: google.com (or any reliable domain)
```

### MQTT Monitor Configuration

```
Monitor Type: MQTT
Hostname: 192.168.1.101
Port: 1883
Topic: home/# (or specific topic like home/status)
Username: (if required)
Password: (if required)
```

### InfluxDB Health Check

Use `/ping` endpoint which returns 204 No Content without authentication:

```
URL: https://influxdb.barta.cm/ping
Expected Status: 204
```

---

## Acceptance Criteria

- [ ] All 8 existing monitors continue working
- [ ] "hsb1 - Home Assistant" renamed to "hsb1 - Node-RED"
- [ ] DNS monitor verifies AdGuard Home is resolving queries
- [ ] MQTT monitor confirms Mosquitto broker is accepting connections
- [ ] All SSH ports monitored via TCP Port checks
- [ ] Traefik and InfluxDB added for csb0/csb1 coverage
- [ ] (Optional) Gaming PC ping monitor added

## Resources

- Uptime Kuma Dashboard: <http://192.168.1.99:3001>
- [Uptime Kuma Documentation](https://github.com/louislam/uptime-kuma/wiki)
- Related: `+pm/done/2025-12-07-hsb0-uptime-kuma.md` (initial installation)
