# Sysmon: System Metrics in Starship Prompt (MVP)

## Goal

Display system health metrics (CPU, RAM, load, swap) in the Starship prompt for at-a-glance awareness of background load while working.

## Why a Daemon?

Metrics like CPU% and network I/O require **delta calculations** over time — you can't just read `/proc/stat` once and get a percentage. A background daemon:

1. Samples system state every N seconds
2. Calculates deltas (CPU ticks, network bytes, disk I/O)
3. Writes pre-computed values to RAM-backed storage
4. Starship reads these instantly — no per-prompt calculations

---

## Architecture

```text
┌─────────────────────────────────────────────────────────────────┐
│                      sysmon-daemon                              │
│  (systemd on NixOS / launchd on macOS)                          │
│                                                                 │
│  Every 5 seconds (configurable):                                │
│  ├─ Calculate CPU% (delta from previous sample)                 │
│  ├─ Read RAM%, Swap%, Load average                              │
│  ├─ Write to /dev/shm/sysmon/ (Linux) or /tmp/sysmon/ (macOS)   │
│  └─ Write timestamp for staleness detection                     │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  /dev/shm/sysmon/  (RAM-backed on Linux)                        │
│  ├── cpu       → "42"           (percentage)                    │
│  ├── ram       → "67"           (percentage)                    │
│  ├── swap      → "2"            (percentage)                    │
│  ├── load      → "1.24"         (1-min average)                 │
│  └── timestamp → "1733150400"   (Unix epoch)                    │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  sysmon-reader (called by Starship per-prompt)                  │
│                                                                 │
│  1. Check staleness (if data > 10s old, show "?")               │
│  2. Read metric files                                           │
│  3. Apply threshold coloring (normal → elevated → critical)     │
│  4. Add metrics by priority until budget (45 chars) exhausted   │
│  5. Output formatted string                                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## MVP Metrics

| Metric | Linux Source         | macOS Source          | Priority      |
| ------ | -------------------- | --------------------- | ------------- |
| CPU %  | `/proc/stat` (delta) | `ps -A -o %cpu` sum   | 100 (highest) |
| RAM %  | `/proc/meminfo`      | `vm_stat`             | 90            |
| Load   | `/proc/loadavg`      | `sysctl vm.loadavg`   | 70            |
| Swap % | `/proc/meminfo`      | `sysctl vm.swapusage` | 60            |

**Deferred to enhancements:** Temperature, Network I/O, Disk I/O (require external tools or complex parsing)

---

## Display

### Format

```text
 42%   67%  󰊚 1.2  󰾴 2%
```

### Icons (Nerd Font)

| Metric | Icon | Unicode   |
| ------ | ---- | --------- |
| CPU    | ``   | `\uf4bc`  |
| RAM    | ``   | `\uefc5`  |
| Load   | `󰊚`  | `\uF029A` |
| Swap   | `󰾴`  | `\uF0FB4` |

### Color Scheme (Traffic Light)

| State    | Condition                       | Color              |
| -------- | ------------------------------- | ------------------ |
| Normal   | value < threshold₁              | Muted (blends in)  |
| Elevated | threshold₁ ≤ value < threshold₂ | White (noticeable) |
| Critical | value ≥ threshold₂              | Red (urgent)       |

Default thresholds:

- CPU: 50%, 80%
- RAM: 70%, 90%
- Load: 2.0, 4.0
- Swap: 10%, 50%

---

## Width Handling: Fixed Budget

The reader uses a **fixed character budget** (default: 45 chars) rather than calculating available space dynamically. This:

- **Decouples** sysmon-reader from prompt layout
- **Avoids brittleness** when prompt config changes
- **Simplifies** implementation

```bash
MAX_BUDGET=45
MIN_TERMINAL=100

if [[ $COLUMNS -lt $MIN_TERMINAL ]]; then
  exit 0  # Too narrow, show nothing
fi

# Add metrics by priority until budget exhausted
```

---

## Staleness Detection

```bash
timestamp=$(cat "$SYSMON_DIR/timestamp" 2>/dev/null || echo 0)
age=$(($(date +%s) - timestamp))

if [[ $age -gt 10 ]]; then
  echo "?"  # Daemon stale or not running
  exit 0
fi
```

| Scenario           | Behavior                 |
| ------------------ | ------------------------ |
| Daemon running     | Fresh metrics displayed  |
| Daemon crashed     | Shows "?" after 10s      |
| System just booted | Empty until first sample |
| Files missing      | Graceful empty output    |

---

## Graceful Error Handling

All failure modes result in empty output or "?" — never errors or hung prompts:

```bash
read_metric() {
  cat "$1" 2>/dev/null || echo "${2:-?}"
}
```

---

## Platform Support

| Platform | Daemon                   | Output Dir         | Notes                  |
| -------- | ------------------------ | ------------------ | ---------------------- |
| NixOS    | systemd service          | `/dev/shm/sysmon/` | Primary target         |
| macOS    | launchd via home-manager | `/tmp/sysmon/`     | `/tmp` is SSD, not RAM |

### macOS Limitations (MVP)

- Output directory is `/tmp/sysmon/` (SSD-backed, acceptable for small files)
- After wake from sleep, first prompt may show "?" until daemon catches up
- Temperature deferred to enhancement (requires external `osx-cpu-temp`)

---

## Configuration

```nix
services.sysmon = {
  enable = true;
  interval = 5000;  # ms

  # Display
  maxBudget = 45;
  minTerminalWidth = 100;

  # Per-metric
  metrics = {
    cpu = { enable = true; icon = "\\uf4bc"; thresholds = [50 80]; priority = 100; };
    ram = { enable = true; icon = "\\uefc5"; thresholds = [70 90]; priority = 90; };
    load = { enable = true; icon = "󰊚"; thresholds = [2.0 4.0]; priority = 70; };
    swap = { enable = true; icon = "󰾴"; thresholds = [10 50]; priority = 60; };
  };
};
```

---

## Implementation Files

| File                              | Purpose                       |
| --------------------------------- | ----------------------------- |
| `modules/shared/sysmon.nix`       | NixOS/home-manager module     |
| `modules/shared/sysmon-daemon.sh` | Background daemon script      |
| `modules/shared/sysmon-reader.sh` | Starship custom module script |

---

## Starship Integration

```toml
[custom.sysmon]
command = "sysmon-reader"
when = "test -f /dev/shm/sysmon/timestamp || test -f /tmp/sysmon/timestamp"
format = "[$output]($style)"
style = ""
```

---

## Acceptance Criteria

### Core AC

- [ ] Daemon starts on boot (systemd/launchd)
- [ ] Metrics update every 5 seconds
- [ ] CPU% accurate (delta-based calculation)
- [ ] Works on NixOS and macOS

### Display AC

- [ ] Starship shows metrics in prompt
- [ ] Fixed budget (45 chars) with priority truncation
- [ ] Threshold colors work (muted → white → red)
- [ ] Hidden if terminal < 100 cols

### Reliability AC

- [ ] Staleness shows "?" after 10s
- [ ] No errors when daemon not running
- [ ] No errors when files missing

---

## Test Plan

1. Enable on test host, verify daemon running
2. Check files exist: `ls /dev/shm/sysmon/`
3. Generate load: `stress --cpu 4 --timeout 30`
4. Verify CPU% increases and colors change
5. Stop daemon, wait 10s, verify "?" appears
6. Restart daemon, verify metrics return

---

## Out of Scope (See Enhancements)

- Dynamic width calculation
- Temperature (requires external tools on macOS)
- Network I/O metrics
- Disk I/O metrics
- Zellij status bar plugin
- GPU metrics
