# IR → Sony TV Bridge Technical Documentation

**Host**: hsb2 (Raspberry Pi Zero W)  
**Purpose**: Convert IR remote signals to Sony Bravia TV commands  
**Status**: 🔵 PLANNED / IN DEVELOPMENT  
**TV IP**: `192.168.1.137`  
**Created**: 2026-01-31  
**Based on**: Migration from hsb1 Node-RED setup

---

## Table of Contents

1. [Overview](#overview)
2. [Hardware Architecture](#hardware-architecture)
3. [Signal Flow](#signal-flow)
4. [Button Mapping Reference](#button-mapping-reference)
5. [Sony IRCC Protocol](#sony-ircc-protocol)
6. [FLIRC Configuration](#flirc-configuration)
7. [Implementation Plan](#implementation-plan)
8. [Environment Variables](#environment-variables)
9. [Known Issues & TODOs](#known-issues--todos)
10. [Historical Context](#historical-context)

---

## Overview

This bridge converts IR remote control signals (via FLIRC USB receiver) into Sony Bravia TV commands sent over HTTP. It replaces the Node-RED based implementation on hsb1 with a lightweight Python script suitable for the resource-constrained Raspberry Pi Zero W.

### Why hsb2?

The original implementation on hsb1 (Node-RED in Docker) experienced:

- Unavailability during high load or reboots
- Slowdowns affecting responsiveness
- Double commands for single presses
- Docker/Node-RED overhead on shared automation server

Moving to hsb2 provides:

- Dedicated, isolated service
- No Docker overhead (Python script directly on OS)
- Independent from hsb1's automation stack
- Lower latency (single-purpose device)

---

## Hardware Architecture

### hsb2 (Raspberry Pi Zero W)

```
┌─────────────────────────────────────────────┐
│           Raspberry Pi Zero W               │
│              (192.168.1.95)                 │
│                                             │
│  ┌──────────────┐      ┌─────────────────┐ │
│  │  FLIRC USB   │──────│  Python Script  │ │
│  │   Receiver   │      │   (ir-bridge)   │ │
│  └──────────────┘      └────────┬────────┘ │
│         │                       │          │
│    USB OTG                HTTP/MQTT        │
│         │                       │          │
└─────────┼───────────────────────┼──────────┘
          │                       │
    IR Remote              Sony TV (192.168.1.137)
    (physical)                  │
                           ┌────┴────────────┐
                           │  Sony Bravia    │
                           │  HTTP/IRCC API  │
                           └─────────────────┘
```

### Hardware Specifications

**FLIRC USB Receiver:**

- Product: `flirc.tv flirc Keyboard` (USB ID: `20a0:0006`)
- Function: Converts IR signals → USB HID keyboard events
- Connection: USB via OTG adapter on Pi Zero W
- Input Device: `/dev/input/event0` (on hsb2)
- Driver: Standard Linux `usbhid` driver (kernel module)

**Raspberry Pi Zero W:**

- CPU: ARMv6-compatible processor rev 7 (v6l) @ 1GHz
- RAM: 512MB (429MB usable)
- Storage: 32GB MicroSD
- OS: Raspbian 11 (bullseye)
- Network: WiFi (802.11 b/g/n)
- USB: Single OTG port (micro-USB)

**Sony Bravia TV:**

- IP: `192.168.1.137`
- Protocol: IRCC (IR Control Client) over HTTP
- Port: 80 (HTTP) or 443 (HTTPS)
- Authentication: PSK (Pre-Shared Key)
- API: Sony Bravia REST API

---

## Signal Flow

### Current Flow (hsb1 - Node-RED)

```
IR Remote Button Press
    ↓
FLIRC Receiver (USB)
    ↓
Linux evdev (/dev/input/event1)
    ↓
Node-RED evdev-in node
    ↓
Switch node (routes by keycode)
    ↓
bravia-ircc node
    ↓
HTTP POST to TV (IRCC protocol)
    ↓
Sony TV executes command
```

### Target Flow (hsb2 - Python)

```
IR Remote Button Press
    ↓
FLIRC Receiver (USB)
    ↓
Linux evdev (/dev/input/event0)
    ↓
Python script (evdev library)
    ↓
Keycode mapping (dictionary lookup)
    ↓
Sony IRCC HTTP request
    ↓
MQTT publish (debug/logging)
    ↓
Sony TV executes command
```

### Data Transformation

```
IR Signal → FLIRC → Key Code → Sony IRCC Code → TV Command

Example:
"Power button on remote"
    → FLIRC interprets as KEY_TVPOWER (code 44)
    → Script maps to IRCC code "AAAAAQAAAAEAAAAVAw=="
    → HTTP POST to TV
    → TV powers on/off
```

---

## Button Mapping Reference

### Complete Key Code Mapping

Based on analysis of hsb1 Node-RED configuration and FLIRC evdev output.

**Note**: FLIRC converts IR signals to standard Linux input event codes (evdev).

#### Number Pad

| Key Code | evdev Name | Sony IRCC Command    | Function |
| -------- | ---------- | -------------------- | -------- |
| 2        | KEY_1      | AAAAAQAAAAEAAAAAAw== | Number 1 |
| 3        | KEY_2      | AAAAAQAAAAEAAAABAw== | Number 2 |
| 4        | KEY_3      | AAAAAQAAAAEAAAACAw== | Number 3 |
| 5        | KEY_4      | AAAAAQAAAAEAAAADAw== | Number 4 |
| 6        | KEY_5      | AAAAAQAAAAEAAAAEAw== | Number 5 |
| 7        | KEY_6      | AAAAAQAAAAEAAAAFAw== | Number 6 |
| 8        | KEY_7      | AAAAAQAAAAEAAAAGAw== | Number 7 |
| 9        | KEY_8      | AAAAAQAAAAEAAAAHAw== | Number 8 |
| 10       | KEY_9      | AAAAAQAAAAEAAAAIAw== | Number 9 |
| 11       | KEY_0      | AAAAAQAAAAEAAAAJAw== | Number 0 |

#### Navigation

| Key Code | evdev Name | Sony IRCC Command    | Function    |
| -------- | ---------- | -------------------- | ----------- |
| 103      | KEY_UP     | AAAAAQAAAAEAAAB0Aw== | Up          |
| 108      | KEY_DOWN   | AAAAAQAAAAEAAAB1Aw== | Down        |
| 105      | KEY_LEFT   | AAAAAQAAAAEAAAA0Aw== | Left        |
| 106      | KEY_RIGHT  | AAAAAQAAAAEAAAAzAw== | Right       |
| 96       | KEY_ENTER  | AAAAAQAAAAEAAABlAw== | Confirm/OK  |
| 1        | KEY_ESC    | AAAAAQAAAAEAAAAAw==  | Return/Back |
| 102      | KEY_HOME   | AAAAAQAAAAEAAABgAw== | Home        |

#### Media Controls

| Key Code | evdev Name       | Sony IRCC Command    | Function     |
| -------- | ---------------- | -------------------- | ------------ |
| 113      | KEY_MUTE         | AAAAAQAAAAEAAAAUAw== | Mute         |
| 114      | KEY_VOLUMEDOWN   | AAAAAQAAAAEAAAASAw== | Volume Down  |
| 115      | KEY_VOLUMEUP     | AAAAAQAAAAEAAAATAw== | Volume Up    |
| 164      | KEY_PLAYPAUSE    | AAAAAQAAAAEAAAANAw== | Play/Pause   |
| 166      | KEY_STOP         | AAAAAQAAAAEAAAAOAw== | Stop         |
| 168      | KEY_REWIND       | AAAAAQAAAAEAAAA4Aw== | Rewind       |
| 208      | KEY_FASTFORWARD  | AAAAAQAAAAEAAAA5Aw== | Fast Forward |
| 163      | KEY_NEXTSONG     | AAAAAQAAAAEAAAAXAw== | Next         |
| 165      | KEY_PREVIOUSSONG | AAAAAQAAAAEAAAAYAw== | Previous     |

#### System & Apps

| Key Code | evdev Name  | Sony IRCC Command    | Function              |
| -------- | ----------- | -------------------- | --------------------- |
| 44       | KEY_TVPOWER | AAAAAQAAAAEAAAAVAw== | Power Toggle          |
| 23       | KEY_I       | AAAAAQAAAAEAAAAlAw== | Input                 |
| 30       | KEY_A       | AAAAAQAAAAEAAAA6Aw== | Action Menu           |
| 49       | KEY_N       | AAAAAQAAAAEAAAAMAw== | Netflix               |
| 25       | KEY_P       | AAAAAQAAAAEAAABDAw== | YouTube (Google Play) |

#### Color Buttons

| Key Code | evdev Name | Sony IRCC Command    | Function      |
| -------- | ---------- | -------------------- | ------------- |
| 19       | KEY_R      | AAAAAQAAAAEAAAATAw== | Red Button    |
| 34       | KEY_G      | AAAAAQAAAAEAAAAUAw== | Green Button  |
| 21       | KEY_Y      | AAAAAQAAAAEAAAAVAw== | Yellow Button |
| 48       | KEY_B      | AAAAAQAAAAEAAAAWAw== | Blue Button   |

#### Channel/Input

| Key Code | evdev Name | Sony IRCC Command    | Function     |
| -------- | ---------- | -------------------- | ------------ |
| 20       | KEY_T      | AAAAAQAAAAEAAAA+Aw== | Channel Up   |
| 47       | KEY_V      | AAAAAQAAAAEAAAA9Aw== | Channel Down |
| 17       | KEY_W      | AAAAAQAAAAEAAAAAAw== | HDMI 1       |
| 22       | KEY_U      | AAAAAQAAAAEAAABAAw== | HDMI 2       |

**Note**: IRCC codes are Base64-encoded Sony remote control commands.

---

## Sony IRCC Protocol

### Overview

IRCC (Infrared Remote Control Client) is Sony's HTTP-based protocol for remote controlling Bravia TVs.

### Authentication

Uses **PSK** (Pre-Shared Key) authentication:

- Key is configured on TV: Settings → Network → Home Network Setup → IP Control → Pre-Shared Key
- Key is sent in HTTP header: `X-Auth-PSK: <key>`
- Will be configured via environment variable on hsb2

### HTTP Request Format

```http
POST /sony/IRCC HTTP/1.1
Host: 192.168.1.137
Content-Type: text/xml; charset=UTF-8
SOAPACTION: "urn:schemas-sony-com:service:IRCC:1#X_SendIRCC"
X-Auth-PSK: <PSK_FROM_ENV>
Content-Length: <length>

<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:X_SendIRCC xmlns:u="urn:schemas-sony-com:service:IRCC:1">
      <IRCCCode>AAAAAQAAAAEAAAAVAw==</IRCCCode>
    </u:X_SendIRCC>
  </s:Body>
</s:Envelope>
```

### IRCC Code Format

Codes are Base64 strings that represent the actual IR signal:

- Format: `AAAAAQAAAAE<command>`
- Example Power: `AAAAAQAAAAEAAAAVAw==`
- Example Volume Up: `AAAAAQAAAAEAAAATAw==`

### Response

Success:

```xml
<?xml version="1.0"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:X_SendIRCCResponse xmlns:u="urn:schemas-sony-com:service:IRCC:1"/>
  </s:Body>
</s:Envelope>
```

---

## FLIRC Configuration

### Overview

FLIRC (FLIRC.tv) is a USB IR receiver that appears as a standard USB HID keyboard to the operating system. It translates IR remote signals into keyboard key presses.

### Device Information

- **Product**: flirc.tv flirc Keyboard
- **USB ID**: `20a0:0006`
- **Driver**: `usbhid` (standard Linux USB HID driver)
- **Input Interface**: `/dev/input/event*` (event device)
- **Device Class**: Human Interface Device (HID)

### How It Works

1. IR remote sends signal
2. FLIRC receives IR signal and decodes it
3. FLIRC sends USB HID keyboard report to host
4. Linux kernel receives HID report via `usbhid` driver
5. Kernel generates input event (evdev)
6. User-space application reads `/dev/input/event*`

### Configuration Files

On hsb1, FLIRC configuration backups are stored at:

```
/home/mba/flirc/
├── flirc_config_20250101.fcfg
├── flirc_config_20250101-v2.fcfg
├── flirc_config_20250102.fcfg
└── flirc_config_20250102_125525.fcfg
```

**Note**: These are binary configuration files, not human-readable.

### Programming FLIRC

#### Option 1: FLIRC GUI Application (Windows/Mac/Linux)

The official FLIRC application provides a GUI for programming:

- Download: https://flirc.tv/software
- Run on any computer
- Program IR → key mappings
- Configuration is stored on the device itself
- Move device to hsb2 after programming

#### Option 2: FLIRC CLI Tool (Linux)

There is a command-line interface available:

```bash
# Download FLIRC CLI for Linux ARM
wget https://flirc.tv/software/cli/linux/arm/flirc_cli
chmod +x flirc_cli
sudo ./flirc_cli

# Common commands:
flirc_cli status              # Check device status
flirc_cli settings            # View/modify settings
flirc_cli format              # Clear all mappings
flirc_cli record              # Record new IR mapping
flirc_cli delete              # Delete mapping
flirc_cli save config.fcfg    # Save config to file
flirc_cli load config.fcfg    # Load config from file
```

**Note**: FLIRC CLI availability for ARM (Pi Zero W) needs verification. May require building from source or using the GUI app on another machine.

### Important: Configuration Persistence

The FLIRC device stores its configuration internally in EEPROM/Flash. Once programmed, it retains mappings even when:

- Powered off
- Moved to different USB port
- Connected to different computer
- Factory reset of host OS

**Therefore**: If the device is already programmed on hsb1, it should work immediately when plugged into hsb2 without reprogramming.

### Verification

To verify FLIRC is working on hsb2:

```bash
# Check device is detected
lsusb | grep flirc

# Should show: Bus 001 Device 00X: ID 20a0:0006 flirc.tv flirc

# Check input device
cat /proc/bus/input/devices | grep -A5 flirc

# Monitor events (press remote buttons)
sudo evtest /dev/input/event0
# (event number may vary, check which one is flirc)
```

---

## Implementation Plan

### Phase 1: Hardware Setup

1. **Move FLIRC to hsb2**
   - Connect FLIRC to Pi Zero W via USB OTG adapter
   - Verify device detection: `lsusb | grep flirc`
   - Verify input device: `ls /dev/input/event*`
   - Test with `evtest`

2. **Network Verification**
   - Verify hsb2 can reach TV: `ping 192.168.1.137`
   - Check TV web interface accessible from hsb2

### Phase 2: Software Installation

1. **Install Dependencies**

   ```bash
   # System packages
   sudo apt update
   sudo apt install python3 python3-pip

   # Python libraries
   pip3 install evdev requests paho-mqtt
   ```

2. **Create Script Directory**
   ```bash
   mkdir -p ~/ir-bridge
   cd ~/ir-bridge
   ```

### Phase 3: Script Development

Create `ir-bridge.py`:

- Read from `/dev/input/event0` (FLIRC)
- Map keycodes to Sony IRCC commands
- Send HTTP POST to TV
- Publish to MQTT for debugging
- Environment variable configuration

### Phase 4: Configuration

Create environment file `/etc/ir-bridge.env`:

```bash
SONY_TV_IP=192.168.1.137
SONY_TV_PSK=<your_psk_here>
MQTT_BROKER=192.168.1.101
MQTT_TOPIC=home/hsb2/ir-debug
LOG_LEVEL=INFO
```

### Phase 5: Service Setup

Create systemd service for auto-start:

- Service file: `/etc/systemd/system/ir-bridge.service`
- Enable on boot: `sudo systemctl enable ir-bridge`
- Start: `sudo systemctl start ir-bridge`

### Phase 6: Testing

1. Test each button
2. Verify TV responds
3. Check MQTT debug messages
4. Monitor for double commands
5. Log any issues

### Phase 7: Hsb1 Cleanup

After hsb2 is working:

- Disable TV-related flows in hsb1 Node-RED
- Keep as backup/fallback
- Document fallback procedure

---

## Environment Variables

The script will use environment variables for configuration (no hardcoded secrets):

| Variable       | Required | Default              | Description                              |
| -------------- | -------- | -------------------- | ---------------------------------------- |
| `SONY_TV_IP`   | Yes      | -                    | Sony TV IP address (192.168.1.137)       |
| `SONY_TV_PSK`  | Yes      | -                    | Pre-Shared Key for TV authentication     |
| `FLIRC_DEVICE` | No       | `/dev/input/event0`  | Input device path                        |
| `MQTT_BROKER`  | No       | 192.168.1.101        | MQTT broker for debug logging            |
| `MQTT_TOPIC`   | No       | `home/hsb2/ir-debug` | MQTT topic for events                    |
| `MQTT_PORT`    | No       | 1883                 | MQTT broker port                         |
| `LOG_LEVEL`    | No       | INFO                 | Logging level (DEBUG/INFO/WARNING/ERROR) |
| `DEBOUNCE_MS`  | No       | 300                  | Debounce time in milliseconds            |
| `RETRY_COUNT`  | No       | 3                    | HTTP retry attempts                      |
| `RETRY_DELAY`  | No       | 1.0                  | Seconds between retries                  |

### Setup

```bash
# Create environment file
sudo tee /etc/ir-bridge.env > /dev/null << 'EOF'
SONY_TV_IP=192.168.1.137
SONY_TV_PSK=your_psk_here
MQTT_BROKER=192.168.1.101
MQTT_TOPIC=home/hsb2/ir-debug
LOG_LEVEL=INFO
EOF

# Secure the file
sudo chmod 600 /etc/ir-bridge.env
sudo chown root:root /etc/ir-bridge.env
```

---

## Known Issues & TODOs

### Issues Identified

1. **Double Commands** ⚠️
   - **Symptom**: Single remote press sends 2 commands to TV
   - **Current State**: Not yet analyzed
   - **Possible Causes**:
     - FLIRC sending duplicate key events
     - Bouncing in IR signal
     - Script not debouncing properly
     - TV responding twice
   - **Plan**: Document and monitor in initial testing
   - **Future**: Implement debounce logic if confirmed

2. **High Load / Reboot Unavailability** ⚠️
   - **Symptom**: Node-RED on hsb1 not available during high load or reboots
   - **Solution**: Moving to dedicated hsb2 eliminates this
   - **Risk**: hsb2 reboots will still cause downtime
   - **Mitigation**: hsb1 keeps backup config disabled but ready

3. **FLIRC Programming** ❓
   - **Status**: Unknown if device needs reprogramming
   - **Assumption**: Config stored on device, should work when moved
   - **Verification**: Test immediately after connecting to hsb2
   - **Fallback**: Use FLIRC GUI app on Windows/Mac if needed

4. **Pi Zero W Limitations**
   - **Constraint**: 512MB RAM, single core
   - **Impact**: Must keep script lightweight
   - **Mitigation**: No Docker, direct Python, minimal dependencies

### TODO List

- [ ] Move FLIRC hardware to hsb2
- [ ] Install Python dependencies on hsb2
- [ ] Create ir-bridge.py script
- [ ] Set up environment file with PSK
- [ ] Create systemd service
- [ ] Test all 39 buttons
- [ ] Verify MQTT debug logging
- [ ] Monitor for double commands
- [ ] Document fallback to hsb1 procedure
- [ ] Disable hsb1 Node-RED TV flows (after hsb2 works)

---

## Historical Context

### Original Implementation (hsb1)

**Host**: hsb1 (Mac mini 2014)  
**Platform**: NixOS with Docker  
**Implementation**: Node-RED flow

**Components:**

- **FLIRC USB receiver**: Connected to hsb1
- **Node-RED**: Docker container with evdev and bravia-ircc nodes
- **Flows**: Tab "📺 TV" (z: 6dc70811ea15ad90)
- **Logic**: Switch node routes 39 different keycodes to bravia-ircc nodes

**Files Analyzed:**

- `/home/mba/flirc/*.fcfg` - FLIRC configuration backups
- `/home/mba/docker/nodered/data/flows.json` - Node-RED flow definitions
- `/dev/input/event1` - FLIRC input device on hsb1

**Why It Was Problematic:**

1. Docker/Node-RED overhead on shared automation server
2. Competes with Home Assistant, Zigbee2MQTT, other containers
3. Reboot of hsb1 takes down entire automation stack
4. High CPU/Memory usage affects IR responsiveness
5. Complex stack for simple IR→HTTP translation

### Migration Decision

**Date**: 2026-01-31  
**Decision**: Move to lightweight Python script on dedicated hsb2  
**Rationale**:

- Pi Zero W has sufficient resources for this single task
- Eliminates Docker overhead
- Independent from hsb1's automation stack
- Simpler codebase (Python vs Node-RED + dependencies)
- Easier to debug and maintain

**Fallback Strategy:**

- Keep hsb1 Node-RED TV flows in place but disabled
- If hsb2 fails, re-enable hsb1 flows
- FLIRC can be moved back to hsb1 if needed
- Zero-downtime rollback capability

---

## Appendix

### A. Sony IRCC Code Reference

Full list of IRCC codes extracted from Node-RED configuration:

```python
IRCC_CODES = {
    # Power
    "power": "AAAAAQAAAAEAAAAVAw==",
    "wake_up": "AAAAAQAAAAEAAAA6Aw==",

    # Numbers
    "num0": "AAAAAQAAAAEAAAAJAw==",
    "num1": "AAAAAQAAAAEAAAAAAw==",
    "num2": "AAAAAQAAAAEAAAABAw==",
    "num3": "AAAAAQAAAAEAAAACAw==",
    "num4": "AAAAAQAAAAEAAAADAw==",
    "num5": "AAAAAQAAAAEAAAAEAw==",
    "num6": "AAAAAQAAAAEAAAAFAw==",
    "num7": "AAAAAQAAAAEAAAAGAw==",
    "num8": "AAAAAQAAAAEAAAAHAw==",
    "num9": "AAAAAQAAAAEAAAAIAw==",

    # Navigation
    "up": "AAAAAQAAAAEAAAB0Aw==",
    "down": "AAAAAQAAAAEAAAB1Aw==",
    "left": "AAAAAQAAAAEAAAA0Aw==",
    "right": "AAAAAQAAAAEAAAAzAw==",
    "confirm": "AAAAAQAAAAEAAABlAw==",
    "enter": "AAAAAQAAAAEAAABlAw==",
    "back": "AAAAAQAAAAEAAAAAw==",
    "return": "AAAAAQAAAAEAAAAAw==",
    "home": "AAAAAQAAAAEAAABgAw==",

    # Volume
    "volume_up": "AAAAAQAAAAEAAAATAw==",
    "volume_down": "AAAAAQAAAAEAAAASAw==",
    "mute": "AAAAAQAAAAEAAAAUAw==",

    # Channel
    "channel_up": "AAAAAQAAAAEAAAA+Aw==",
    "channel_down": "AAAAAQAAAAEAAAA9Aw==",

    # Media
    "play": "AAAAAQAAAAEAAAANAw==",
    "pause": "AAAAAQAAAAEAAAA5Aw==",
    "stop": "AAAAAQAAAAEAAAAOAw==",
    "rewind": "AAAAAQAAAAEAAAA4Aw==",
    "forward": "AAAAAQAAAAEAAAA5Aw==",
    "next": "AAAAAQAAAAEAAAAXAw==",
    "previous": "AAAAAQAAAAEAAAAYAw==",

    # Input
    "input": "AAAAAQAAAAEAAAAlAw==",
    "hdmi1": "AAAAAQAAAAEAAABAAw==",
    "hdmi2": "AAAAAQAAAAEAAABBAw==",
    "hdmi3": "AAAAAQAAAAEAAABCAw==",
    "hdmi4": "AAAAAQAAAAEAAABDAw==",

    # Apps
    "netflix": "AAAAAQAAAAEAAAAMAw==",
    "youtube": "AAAAAQAAAAEAAABDAw==",
    "action_menu": "AAAAAQAAAAEAAAA6Aw==",

    # Color buttons
    "red": "AAAAAQAAAAEAAAATAw==",
    "green": "AAAAAQAAAAEAAAAUAw==",
    "yellow": "AAAAAQAAAAEAAAAVAw==",
    "blue": "AAAAAQAAAAEAAAAWAw==",
}
```

### B. Linux Input Event Codes

From `/usr/include/linux/input-event-codes.h`:

```c
#define KEY_1            2
#define KEY_2            3
#define KEY_3            4
#define KEY_4            5
#define KEY_5            6
#define KEY_6            7
#define KEY_7            8
#define KEY_8            9
#define KEY_9            10
#define KEY_0            11
#define KEY_MINUS        12
#define KEY_EQUAL        13
#define KEY_BACKSPACE    14
#define KEY_TAB          15
#define KEY_Q            16
#define KEY_W            17
#define KEY_E            18
#define KEY_R            19
#define KEY_T            20
#define KEY_Y            21
#define KEY_U            22
#define KEY_I            23
#define KEY_O            24
#define KEY_P            25
#define KEY_LEFTBRACE    26
#define KEY_RIGHTBRACE   27
#define KEY_ENTER        28
#define KEY_LEFTCTRL     29
#define KEY_A            30
#define KEY_S            31
#define KEY_D            32
#define KEY_F            33
#define KEY_G            34
#define KEY_H            35
#define KEY_J            36
#define KEY_K            37
#define KEY_L            38
#define KEY_SEMICOLON    39
#define KEY_APOSTROPHE   40
#define KEY_GRAVE        41
#define KEY_LEFTSHIFT    42
#define KEY_BACKSLASH    43
#define KEY_Z            44
#define KEY_X            45
#define KEY_C            46
#define KEY_V            47
#define KEY_B            48
#define KEY_N            49
#define KEY_M            50
#define KEY_COMMA        51
#define KEY_DOT          52
#define KEY_SLASH        53
#define KEY_RIGHTSHIFT   54
#define KEY_KPASTERISK   55
#define KEY_LEFTALT      56
#define KEY_SPACE        57
#define KEY_CAPSLOCK     58
#define KEY_F1           59
#define KEY_F2           60
#define KEY_F3           61
#define KEY_F4           62
#define KEY_F5           63
#define KEY_F6           64
#define KEY_F7           65
#define KEY_F8           66
#define KEY_F9           67
#define KEY_F10          68
#define KEY_NUMLOCK      69
#define KEY_SCROLLLOCK   70
#define KEY_KP7          71
#define KEY_KP8          72
#define KEY_KP9          73
#define KEY_KPMINUS      74
#define KEY_KP4          75
#define KEY_KP5          76
#define KEY_KP6          77
#define KEY_KPPLUS       78
#define KEY_KP1          79
#define KEY_KP2          80
#define KEY_KP3          81
#define KEY_KP0          82
#define KEY_KPDOT        83
```

### C. Resources

- **FLIRC Website**: https://flirc.tv
- **FLIRC Software**: https://flirc.tv/software
- **Sony IRCC Documentation**: Available in TV's API documentation
- **Linux Input Subsystem**: https://www.kernel.org/doc/html/latest/input/input.html
- **evdev Python Library**: https://python-evdev.readthedocs.io/

---

**Document Version**: 1.0  
**Last Updated**: 2026-01-31  
**Author**: Infrastructure automation analysis  
**Review**: Pending implementation
