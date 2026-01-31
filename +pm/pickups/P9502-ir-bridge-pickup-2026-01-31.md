# IR → Sony TV Bridge on hsb2 - Session Pickup Document

**Date:** 2026-01-31  
**Session:** IR Bridge Implementation - hsb2 (Raspberry Pi Zero W)  
**Status:** ✅ Implementation Complete, ⏳ Pending Hardware & Configuration

---

## What Was Accomplished

### 1. IR Bridge Python Script Created

**Location:** `hosts/hsb2/files/ir-bridge.py`  
**Deployed to:** `/home/mba/ir-bridge/ir-bridge.py` on hsb2

**Features:**

- Reads FLIRC USB input via `evdev` library
- 39 button mappings (numbers, navigation, media, apps, color buttons)
- Debouncing (300ms default) to prevent double commands
- HTTP retry logic (3 attempts with configurable delay)
- Comprehensive logging (DEBUG/INFO/WARNING/ERROR levels)
- Signal handling (graceful shutdown on SIGTERM/SIGINT)

**Key Mappings:**

```python
# Examples from IRCC_CODES dict
2: ('num1', 'AAAAAQAAAAEAAAAAAw==')
44: ('power', 'AAAAAQAAAAEAAAAVAw==')
103: ('up', 'AAAAAQAAAAEAAAB0Aw==')
49: ('netflix', 'AAAAAQAAAAEAAAAMAw==')
```

### 2. Systemd Service Created

**Location:** `hosts/hsb2/files/ir-bridge.service`  
**Installed:** `/etc/systemd/system/ir-bridge.service`

**Self-Healing Configuration:**

- `Restart=always` - Always restarts on failure
- `RestartSec=5` - 5-second delay between restarts
- `StartLimitInterval=60s` - Rate limiting window
- `StartLimitBurst=3` - Max 3 restarts per minute
- User runs as `mba` with `input` group access

### 3. MQTT State Reporting

**Topics:**

- `home/hsb2/ir-bridge/status` (retained) - JSON with stats
- `home/hsb2/ir-bridge/event` - Per-keypress events
- `home/hsb2/ir-bridge/control` - Control commands (status, restart)

**Status Payload:**

```json
{
  "started_at": "2026-01-31T15:30:00",
  "keys_pressed": 42,
  "commands_sent": 41,
  "errors": 1,
  "last_command": "volumeup",
  "last_key": "volumeup",
  "status": "running"
}
```

### 4. Documentation Created

**Technical Spec:** `hosts/hsb2/docs/IR-BRIDGE.md` (509 lines)

- Complete architecture diagrams
- All 39 button mappings with IRCC codes
- Sony IRCC protocol documentation
- FLIRC configuration guide
- Environment variable reference
- Historical context (hsb1 implementation)

**Runbook Updated:** `hosts/hsb2/docs/RUNBOOK.md`

- New "Services" section with IR Bridge
- Quick commands for debugging
- Troubleshooting procedures
- Migration checklist

### 5. Installation Script

**Location:** `hosts/hsb2/files/install.sh`

- Automated dependency installation
- User group configuration
- Service setup and enablement
- Interactive next-steps guidance

### 6. Configuration Template

**Location:** `hosts/hsb2/files/ir-bridge.env.example`  
**Installed:** `/etc/ir-bridge.env` (needs PSK)

**Configurable via Environment:**

- `SONY_TV_IP` - TV IP address (default: 192.168.1.137)
- `SONY_TV_PSK` - Pre-Shared Key (**REQUIRED**)
- `FLIRC_DEVICE` - Input device path (default: /dev/input/event0)
- `MQTT_BROKER` - MQTT host (default: 192.168.1.101)
- `MQTT_USER/PASS` - MQTT credentials
- `DEBOUNCE_MS` - Debounce time (default: 300)
- `RETRY_COUNT/DELAY` - HTTP retry settings

---

## Current Status

### ✅ Completed

1. **Python script** deployed to `/home/mba/ir-bridge/ir-bridge.py`
2. **Python dependencies** installed (`evdev`, `requests`, `paho-mqtt`)
3. **Systemd service** installed and enabled
4. **Configuration file** created at `/etc/ir-bridge.env`
5. **User permissions** - `mba` added to `input` group
6. **Documentation** committed to git
7. **Git commit** - `b94db22a` feat(hsb2): implement IR to Sony TV bridge

### ⏳ Pending (Next Session)

1. **Configure Sony TV PSK**
   - Get PSK from TV settings or `~/secrets/sonytv.env` on hsb1
   - Edit `/etc/ir-bridge.env` on hsb2
   - Set: `SONY_TV_PSK=your_actual_psk`

2. **Move FLIRC Hardware**
   - Unplug FLIRC from hsb1
   - Connect to hsb2 via USB OTG adapter
   - Verify: `lsusb | grep flirc`
   - Check device: `ls -la /dev/input/event*`

3. **Start Service**
   - Start: `sudo systemctl start ir-bridge`
   - Monitor: `sudo journalctl -u ir-bridge -f`
   - Test: Press remote buttons, watch logs

4. **Verify MQTT Reporting**
   - Subscribe: `mosquitto_sub -h hsb1.lan -t 'home/hsb2/ir-bridge/#' -v`
   - Check status topic shows "running"
   - Verify events published on keypress

5. **Test All 39 Buttons**
   - Numbers 0-9
   - Navigation (up/down/left/right/enter/back/home)
   - Volume (mute/up/down)
   - Media (play/stop/rewind/forward/next/prev)
   - Apps (netflix/youtube)
   - Color buttons (red/green/yellow/blue)
   - Power, Input, HDMI switches

### ❌ Not Started

1. **Disable hsb1 Node-RED flows** (only after hsb2 works)
2. **Monitor for double commands** (documented issue)
3. **Add hsb2 to NixFleet** (optional)

---

## Commands for Next Session

### Setup (On hsb2)

```bash
# 1. Configure TV PSK
ssh mba@192.168.1.95
sudo nano /etc/ir-bridge.env
# Edit SONY_TV_PSK line

# 2. Verify FLIRC hardware
lsusb | grep flirc
# Should show: ID 20a0:0006 flirc.tv flirc

# 3. Find input device
cat /proc/bus/input/devices | grep -A5 flirc
ls -la /dev/input/event*
# Note which event device is flirc

# 4. Start service
sudo systemctl start ir-bridge
sudo systemctl status ir-bridge
```

### Monitoring

```bash
# View logs
sudo journalctl -u ir-bridge -f

# View all logs
sudo journalctl -u ir-bridge --since today

# Test input device directly
sudo evtest /dev/input/event0
# (Press remote buttons, should see events)
```

### MQTT Debug

```bash
# On hsb1 or any MQTT client
mosquitto_sub -h hsb1.lan -t 'home/hsb2/ir-bridge/#' -v

# Expected output:
# home/hsb2/ir-bridge/status {"started_at": "...", "status": "running", ...}
# home/hsb2/ir-bridge/event {"key_name": "volumeup", "success": true, ...}
```

### Service Control

```bash
# Start/stop/restart
sudo systemctl start ir-bridge
sudo systemctl stop ir-bridge
sudo systemctl restart ir-bridge

# Enable/disable auto-start
sudo systemctl enable ir-bridge
sudo systemctl disable ir-bridge

# Check if running
systemctl is-active ir-bridge
```

---

## Blockers & Issues

### ⚠️ Double Commands (Known Issue)

**Symptom:** Single remote press sends 2 commands  
**Status:** Not yet tested  
**Mitigation:** Debounce logic implemented (300ms default)  
**Action:** Monitor during testing, increase `DEBOUNCE_MS` if needed

### ⚠️ Missing PSK

**Blocker:** Cannot start service without Sony TV PSK  
**Resolution:** Need to get PSK from TV or hsb1 secrets  
**Action:** Configure before starting service

### ⚠️ Hardware Not Connected

**Blocker:** FLIRC still on hsb1  
**Resolution:** Physically move USB device  
**Action:** Connect to hsb2, verify with `lsusb`

---

## Files in Repository

All tracked in git (commit `b94db22a`):

```
hosts/hsb2/
├── docs/
│   ├── IR-BRIDGE.md          # Technical specification (509 lines)
│   └── RUNBOOK.md            # Updated with IR Bridge section
└── files/
    ├── ir-bridge.py          # Main Python script
    ├── ir-bridge.service     # Systemd service
    ├── ir-bridge.env.example # Configuration template
    └── install.sh            # Installation script
```

---

## Quick Reference

### Sony TV

- **IP:** 192.168.1.137
- **Protocol:** IRCC over HTTP
- **Port:** 80
- **Auth:** PSK (Pre-Shared Key)

### hsb2 (Pi Zero W)

- **IP:** 192.168.1.95
- **OS:** Raspbian 11 (bullseye)
- **Input:** `/dev/input/event0` (FLIRC)

### MQTT

- **Broker:** hsb1.lan (192.168.1.101)
- **Base Topic:** `home/hsb2/ir-bridge`
- **Credentials:** Same as smarthome (from smarthome.env)

---

## Notes for Tomorrow

1. **First priority:** Get the PSK and configure it
2. **Second:** Move FLIRC hardware and verify detection
3. **Third:** Start service and test a few buttons
4. **Fourth:** Monitor MQTT to confirm reporting works
5. **Fifth:** If all good, test all 39 buttons systematically

**Don't disable hsb1 flows yet** - keep them as backup until hsb2 is confirmed working.

**Double command issue:** If it happens, increase `DEBOUNCE_MS` in config (try 500ms or 1000ms).

---

## References

- **Technical Docs:** `hosts/hsb2/docs/IR-BRIDGE.md`
- **Runbook:** `hosts/hsb2/docs/RUNBOOK.md`
- **Git Commit:** `b94db22a`
- **Original Implementation:** hsb1 Node-RED (flows in docker/nodered/data/)
- **Backlog:** `+pm/backlog/P9501-hsb2-rename-hostname.md` (previous hsb2 task)
