# Network Runbook — ww87 (Parents' Home)

**Owner:** Gerhard (`gb`)
**Primary admin host:** `hsb8` (192.168.1.100) — runs DNS + DHCP via AdGuard Home
**Upstream gateway:** FRITZ!Box at `192.168.1.1` (WAN + Wi-Fi SSID for fritz.box guests)
**Wi-Fi mesh:** NETGEAR Orbi (1 router + 2 satellites), provides the main house Wi-Fi

**DHCP layout:**

- Statics: `192.168.1.2 – 192.168.1.221` (27 entries, managed via agenix)
- Buffer:  `192.168.1.222 – 192.168.1.224` (reserved for future statics)
- Dynamic: `192.168.1.225 – 192.168.1.254` (30 slots, handed out by hsb8 AdGuard)

> ⚠️ **MAC addresses live only in `secrets/static-leases-hsb8.age`** (agenix-encrypted). Never paste MACs into this file. Reference devices by IP + hostname + location.

---

## Topology

```
Internet
   │
   ▼
┌────────────────────────┐
│  FRITZ!Box  192.168.1.1│   ← WAN, optional Wi-Fi, DNS forwarder to hsb8
└────────────┬───────────┘
             │ wired LAN (192.168.1.0/24)
             │
   ┌─────────┼──────────────────────────────────────────┐
   ▼         ▼                                          ▼
┌──────┐  ┌────────────────────────┐               ┌──────────────┐
│ hsb8 │  │ Orbi Router .2 (EG-VR) │◀── mesh ──▶   │ Orbi Sat1    │
│ .100 │  │ main mesh unit         │               │  .3 (DG-WR)  │
│ DHCP │  └──────┬─────────────────┘               └──────────────┘
│ DNS  │         │ mesh
│ HA   │         ▼
└──────┘  ┌────────────────────────┐
          │ Orbi Sat2 .4 (EG-WR)   │
          │                        │
          └────────────────────────┘
```

**Key points:**

- FRITZ!Box handles WAN (internet uplink) and is the default gateway.
- hsb8 handles **DHCP** (dynamic range `.225–.254`) and **DNS** (AdGuard Home, upstream Cloudflare).
- Orbi mesh provides Wi-Fi. If an Orbi node is offline, devices bound to it lose Wi-Fi.
- Static IPs (`.2`–`.221`) are managed via **agenix-encrypted static leases** on hsb8 (see `secrets/static-leases-hsb8.age`).
- **Rule:** statics and the dynamic range must not overlap. Buffer `.222–.224` is reserved for growth.

---

## Floor / Room Abbreviations

The device comments in LanScan / AdGuard follow a `FLOOR-ROOM name` pattern.

### Floors

| Code | German          | English      |
| ---- | --------------- | ------------ |
| EG   | Erdgeschoss     | Ground floor |
| DG   | Dachgeschoss    | Top floor    |
| KG   | Kellergeschoss  | Basement     |

### Rooms (seen in current inventory)

| Code | Likely meaning        | Status          |
| ---- | --------------------- | --------------- |
| VR   | Vorraum (entry hall)  | confirmed       |
| WR   | Wohnraum (living)     | confirmed       |
| SZG  | Schlafzimmer (bedroom)| confirmed       |
| GA   | Garage                | confirmed       |
| KÜ   | Küche (kitchen)       | confirmed       |
| BZ   | Badezimmer (bath)     | confirmed       |
| BR   | ? (Bastelraum?)       | **TBD — Gerhard to fill in** |
| DI   | ? (Diele?)            | **TBD — Gerhard to fill in** |
| DB   | ? (Dachboden?)        | **TBD — Gerhard to fill in** |

> 📝 When you confirm `BR`/`DI`/`DB`, update this table.

---

## Core Device Inventory (static, by IP)

**Source of truth for MACs:** `secrets/static-leases-hsb8.age` (edit via `agenix -e`).
This table is derived from the AdGuard lease list + LanScan comments — **IPs and labels only**.

| IP             | Hostname / Label         | Location  | Role                                |
| -------------- | ------------------------ | --------- | ----------------------------------- |
| 192.168.1.1    | `fritz.box`              | EG-VR     | **WAN gateway** (FRITZ!Box)         |
| 192.168.1.2    | `orbi-rbr`               | EG-VR     | Orbi Router (mesh backbone)         |
| 192.168.1.3    | `orbi-rbs1`              | DG-WR     | Orbi Satellit1 (top floor)          |
| 192.168.1.4    | `orbi-rbs2`              | EG-WR     | Orbi Satellit2 (ground floor)       |
| 192.168.1.11   | `p4-2.fritz.box`         | DG-WR     | Raspberry Pi — Zigbee2MQTT, MQTT    |
| 192.168.1.20   | `pva-wr.fritz.box`       | EG-GA     | Kostal Piko PV inverter             |
| 192.168.1.100  | `hsb8`                   | —         | **DHCP + DNS + Home Assistant**     |
| 192.168.1.104  | `gs4-esp32`              | KG-WR     | ESP32 sensor node                   |
| 192.168.1.105  | `bz-rasierer-zb`         | DG-BZ     | Shaver + ZB (Zigbee)                |
| 192.168.1.106  | `kg-waschmaschine`       | KG-WR     | Washing machine sensor              |
| 192.168.1.107  | `snapmaker-u1`           | KG-KÜ?    | Snapmaker U1 3D printer (network)   |
| 192.168.1.134  | `kg-br-akku-lader`       | KG-BR     | Battery chargers                    |
| 192.168.1.159  | `dg-di-pixxoo`           | DG-DI     | Pixxoo display                      |
| 192.168.1.240  | `dg-db-esp32-1`          | DG-DB     | ESP32 sensor node                   |
| 192.168.1.241  | `p4-1-eth`               | DG-WR     | Raspberry Pi (wired)                |

**Dynamic range `192.168.1.225–254`** is handed out to phones, tablets, laptops, visitors, and any device without a static lease. Actual addresses rotate — check LanScan or hsb8 AdGuard UI for the current mapping.

Full static list lives in `secrets/static-leases-hsb8.age` (27 entries). Edit with `agenix -e secrets/static-leases-hsb8.age` (Gerhard only — requires SSH key + editor).

> ⚠️ Known stale statics (MACs no longer match the real device — device currently gets a dynamic lease instead):
> - `.168` `imac-gb` — iMac's current MAC isn't in the agenix file
> - `.88` `iPad-Air-GB` — same
>
> Fix path: `agenix -e secrets/static-leases-hsb8.age`, replace MAC with current one from LanScan, rebuild.

---

## Orbi Wi-Fi Mesh

| Node         | Location | IP (static)   | Notes                                         |
| ------------ | -------- | ------------- | --------------------------------------------- |
| Orbi Router  | EG-VR    | 192.168.1.2   | **Mesh backbone — everything else depends**   |
| Orbi Sat1    | DG-WR    | 192.168.1.3   | Top floor coverage                            |
| Orbi Sat2    | EG-WR    | 192.168.1.4   | Ground floor living room coverage             |

**Dependency rule:** if the **Orbi Router (EG-VR)** goes offline, both satellites lose their mesh backhaul and Wi-Fi coverage collapses on ground + attic floors. Wired devices on hsb8 / FRITZ!Box keep working.

---

## Diagnostic Playbook: "Half the network is down"

Use this when some devices work and others can't get online.

### Step 1 — Classify what's down

From `imac-gb` (the iMac, wired or on surviving Wi-Fi), open **LanScan** and look at which devices have green ping vs no IP. Note the **room/floor prefixes** of the failures.

- **Failures clustered on one floor?** → suspect the **Orbi node covering that floor**.
- **Failures across many floors, but all Wi-Fi?** → suspect the **Orbi Router (EG-VR)**.
- **Failures mix wired + Wi-Fi?** → suspect **hsb8 DHCP/DNS** or **FRITZ!Box**.
- **Everything down incl. internet?** → **FRITZ!Box** (WAN or power).

### Step 2 — Check hsb8 (DHCP + DNS health)

From the iMac:

```bash
ping -c2 hsb8.lan
ssh gb@hsb8.lan 'systemctl status adguardhome --no-pager | head -15'
ssh gb@hsb8.lan 'sudo journalctl -u adguardhome -n 50 --no-pager | tail -30'
ssh gb@hsb8.lan 'ss -ulnp | grep -E ":(53|67)\b"'   # DNS + DHCP listening?
```

Expected: AdGuard Home `active (running)`, ports 53 (DNS) and 67 (DHCP) listening. If DHCP is down, **every** device trying to renew its lease fails — restart AdGuard (see `RUNBOOK.md` → Troubleshooting).

### Step 3 — Check Orbi mesh

1. **Physically walk to the Orbi Router (EG-VR):**
   - Power LED on? Ring light color? (white = OK, magenta/amber = problem)
   - Ethernet uplink plugged into the FRITZ!Box and link LED lit?
2. **Power-cycle test (30s off, then on):**
   - Unplug Orbi Router power.
   - Wait 30s.
   - Plug back in; wait 2–3 min for full mesh re-sync.
3. **Check satellites:** if the main router comes back, the satellites should re-sync within ~1 min. Their ring LEDs should go white.

### Step 4 — Check FRITZ!Box

If hsb8 is fine and the Orbi Router won't come back even after a power cycle, the upstream may be at fault:

- Open `http://192.168.1.1` from a wired device or the iMac.
- Check: **System → Event Log** for port/link errors.
- Check: **Home Network → Network** for the Orbi Router's presence.
- If the FRITZ!Box itself is unreachable → power cycle it (this will drop internet and Wi-Fi for a few minutes).

### Step 5 — Last resort: lease conflict / duplicate DHCP

If `hsb8` AdGuard is healthy but devices still can't get addresses:

```bash
ssh gb@hsb8.lan 'sudo journalctl -u adguardhome --since "1 hour ago" | grep -i -E "dhcp|conflict|offer"'
```

Look for conflict / duplicate server warnings. The FRITZ!Box's own DHCP must stay **disabled** — if someone re-enabled it, both servers will fight and clients will get random/no leases.

> 🛑 **Rule:** FRITZ!Box DHCP = OFF. hsb8 AdGuard DHCP = ON. Only one DHCP server per LAN.

---

## Current Incident — 2026-04-14

**Symptom:** Several devices have no IP in LanScan:

- `Orbi Router (EG-VR)` — NETGEAR main mesh node
- `Orbi Satellit2 (EG-WR)` — NETGEAR satellite (ground floor living room)
- `iPad Air (DG-SZG)` — top floor bedroom
- `U1 Snapmaker` — 3D printer (network)
- 1 × Apple device (`DG-BZ` area)

**Working:**

- `FRITZ!Box 192.168.1.1`
- `Orbi Satellit1 (DG-WR)` at 192.168.1.3
- `hsb8` (DNS/DHCP/HA) at 192.168.1.100
- `imac-gb` at 192.168.1.201
- Most wired/ESP32 static devices

**Leading hypothesis:** the **Orbi Router (EG-VR)** is offline. Satellit2 depends on it via wireless backhaul, so it also drops. Satellit1 on DG is either wired back to the FRITZ!Box directly or has enough mesh range through a different path and stays up. The iPad, Snapmaker, and the `DG-BZ` Apple device were likely associated with SSIDs served by the offline Orbi units and can't roam to Sat1.

**Next actions (in order):**

1. Check power + LEDs on the **Orbi Router (EG-VR)** physically.
2. Check its Ethernet cable to the FRITZ!Box (link LED on both ends).
3. Power-cycle it (30 s off). Wait 2–3 min.
4. If LEDs stay wrong after power cycle → Orbi Router likely dead (hardware or firmware). Check NETGEAR admin UI via FRITZ!Box's device list for any error.
5. Once the Orbi Router is back, verify: iPad Air, Snapmaker, and the `DG-BZ` device reconnect automatically; if not, toggle Wi-Fi on each.

**Do NOT:**

- ❌ Reboot `hsb8` — DHCP/DNS for the whole house will drop with it.
- ❌ Re-enable DHCP on the FRITZ!Box — causes duplicate-server conflicts.
- ❌ Factory-reset the Orbi without confirming it's actually dead — you'll lose the mesh config.

---

## Related Documentation

- [hsb8 RUNBOOK](./RUNBOOK.md) — service-level runbook for the server itself
- [hsb8 README](../README.md) — full host documentation
- [ip-100.md](../ip-100.md) — hsb8 identity card (static IP, gateway, DNS)
- [enable-ww87.md](./enable-ww87.md) — location switching guide
- `secrets/static-leases-hsb8.age` — **agenix-encrypted** MAC → IP mapping (edit with `agenix -e`)
