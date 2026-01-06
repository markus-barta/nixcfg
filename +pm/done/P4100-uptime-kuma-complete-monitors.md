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

## Monitor Status (Last Updated: 2026-01-06)

| Service            | Hostname           | Port  | Type     | Tags     | Status    |
| ------------------ | ------------------ | ----- | -------- | -------- | --------- |
| **AdGuard Home**   | 192.168.1.99       | 3000  | HTTP     | 🏠 hsb0  | ✅ 100%   |
| **Apprise**        | 192.168.1.101      | 8001  | HTTP     | 🏠 hsb1  | ✅ 100%   |
| **DNS**            | 192.168.1.99       | 53    | DNS      | 🏠 hsb0  | ✅ 100%   |
| **Docmost**        | docmost.barta.cm   | —     | HTTP     | ☁️ csb1  | ✅ 100%   |
| **FritzBox**       | 192.168.1.5        | —     | Ping     | 🏠 infra | ✅ 100%   |
| **Grafana**        | grafana.barta.cm   | —     | HTTP     | ☁️ csb1  | ✅ 100%   |
| **Home Assistant** | 192.168.1.101      | 8123  | HTTP     | 🏠 hsb1  | ✅ 99.93% |
| **HUE Bridge**     | 192.168.1.104      | —     | Ping     | 🏠 infra | ✅ 100%   |
| **Matter Server**  | 192.168.1.101      | 5580  | HTTP     | 🏠 hsb1  | ✅ 100%   |
| **Mosquitto**      | 192.168.1.101      | 1883  | MQTT     | 🏠 hsb1  | ✅ 100%   |
| **NCPS**           | 192.168.1.99       | 8501  | HTTP     | 🏠 hsb0  | ✅ 100%   |
| **Netgear Switch** | 192.168.1.3        | —     | Ping     | 🏠 infra | ✅ 100%   |
| **node RED**       | home.barta.cm      | 1880  | HTTP     | ☁️ csb0  | ✅ 100%   |
| **OpenDTU**        | 192.168.1.160      | —     | Ping     | 🏠 infra | ✅ 100%   |
| **OPUS Gateway**   | 192.168.1.102      | —     | Ping     | 🏠 infra | ✅ 100%   |
| **Paperless**      | paperless.barta.cm | —     | HTTP     | ☁️ csb1  | ✅ 100%   |
| **Scrypted**       | 192.168.1.101      | 11080 | HTTP     | 🏠 hsb1  | ✅ 94.74% |
| **SSH - hsb1**     | 192.168.1.101      | 22    | TCP Port | 🏠 hsb1  | ✅ 100%   |
| **SolarEdge**      | 192.168.1.31       | —     | Ping     | 🏠 infra | ✅ 100%   |
| **Sonnen Battery** | 192.168.1.32       | —     | Ping     | 🏠 infra | ✅ 100%   |
| **TADO Bridge**    | 192.168.1.103      | —     | Ping     | 🏠 infra | ✅ 93.18% |
| **Zigbee2MQTT**    | 192.168.1.101      | 8888  | HTTP     | 🏠 hsb1  | ✅ 100%   |
| **Zigbee Adapter** | 192.168.1.16       | —     | Ping     | 🏠 infra | ✅ 100%   |

### Tag Legend

| Tag      | Meaning                 |
| -------- | ----------------------- |
| 🏠       | On-site (local network) |
| ☁️       | Cloud service           |
| **Tags** | hsb0, hsb1, infra       |

### Not Monitored (By Design)

| Service                | Reason                                           |
| ---------------------- | ------------------------------------------------ |
| **SSH - hsb0**         | Loopback from hsb0 → hsb0 adds no value          |
| **Uptime Kuma (self)** | Self-monitoring adds no value                    |
| **Gaming PC**          | Only active a few hours/week — always shows down |
| **Fritz Repeaters**    | If main FritzBox works, they're fine             |
| **Mobile Devices**     | Phones/iPads - always moving, not infrastructure |

### Future Consideration

| Service                 | Notes                                          |
| ----------------------- | ---------------------------------------------- |
| **Uptime Kuma (cloud)** | Consider when csb0/csb1 monitoring is deployed |

## Monitor Type Reference

| Type         | Use Case                 |
| ------------ | ------------------------ |
| **HTTP(s)**  | Web services, APIs       |
| **TCP Port** | SSH, database ports      |
| **Ping**     | Basic host availability  |
| **DNS**      | DNS server health        |
| **MQTT**     | MQTT broker connectivity |

## Resources

- Uptime Kuma Dashboard: http://192.168.1.99:3001
- Related: `+pm/done/2025-12-07-hsb0-uptime-kuma.md` (initial installation)
- P5000: Parents' network monitoring
- P6000: Cloud services monitoring
