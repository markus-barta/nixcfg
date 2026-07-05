# hsb9 - Parents-in-law Home Automation Server

**Mac mini "Late 2009"** (Macmini3,1, Intel Core 2 Duo P7550) running NixOS for light home automation at parents-in-law.

---

## Quick Reference

| Item                 | Value                                                            |
| -------------------- | ---------------------------------------------------------------- |
| **Hostname**         | `hsb9`                                                           |
| **Model**            | Mac mini "Late 2009" (Macmini3,1)                                |
| **CPU**              | Intel Core 2 Duo P7550 @ 2.26 GHz (2 cores)                      |
| **RAM**              | 4 GB DDR3                                                        |
| **Storage**          | Crucial CT250MX200SSD1 — 250 GB SATA SSD (ext4)                  |
| **Static IP**        | `192.168.1.200` (live at parents-in-law since 2026-05-31)        |
| **Prior IP (jhw22)** | `192.168.1.203` (Markus' home migration-prep — retired)          |
| **MAC**              | _(not committed — `ip link show enp0s10` on host)_               |
| **NIC**              | NVIDIA MCP79 onboard (`enp0s10`, `forcedeth` driver)             |
| **SSH**              | `ssh mba@hsb9.ts.barta.cm` (tailnet) or `ssh mba@192.168.1.200`  |
| **HostDash**         | `http://hsb9.lan/` or `http://192.168.1.200/`                    |
| **Location**         | parents-in-law (live since 2026-05-31; was jhw22 migration-prep) |
| **PPM**              | NIX-138                                                          |

---

## Scope

Lighter than hsb8. Just home automation, no DNS/DHCP for the host network:

- MQTT broker (mosquitto)
- Zigbee2MQTT (SONOFF Zigbee 3.0 USB dongle migrated from existing Pi 3 setup)
- Home Assistant (Docker)
- HostDash (`hsb9-home` nginx container on port 80)
- HomeKit bridge
- A handful of light automations

---

## NIX-138 — Install-day notes

- Kernel pinned to **6.18** (matches msbp's stable Mac mini 2009 config).
  Default 6.12.63 had a forcedeth regression on this hardware.
- **DHCP is OFF, static IP is required**: `dhcpcd`'s broadcast-before-link-up
  wedges forcedeth's TX queue on this NIC. Static configuration sidesteps
  it. See NIX-138 comment thread for root cause.
- `b43` (WiFi) blacklisted — no firmware, we're wired-only.
- `forcedeth debug_tx_timeout=1` enabled for future diagnostic insurance.

---

## Location switch

Edit `configuration.nix`:

```nix
location = "parents-in-law"; # was "jhw22"
```

Then deploy. Gateway at parents-in-law is confirmed `192.168.1.1` (Fritz!Box);
DNS via Cloudflare (`1.1.1.1` / `1.0.0.1`). Live at `192.168.1.200` since
2026-05-31 (NIX-138).
