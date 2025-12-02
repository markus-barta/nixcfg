# 2025-12-02 - System Monitor Daemon with Starship Integration

## Description

Create a lightweight system monitoring daemon that writes metrics to RAM-backed storage (`/dev/shm/` on Linux, `/tmp/` on macOS), enabling near-instant metric display in Starship prompts without per-prompt command execution latency.

## Source

- Original: Chat conversation discussing Starship CPU utilization enhancement
- Status at extraction: Design phase complete, ready for implementation

## Scope

Applies to: All hosts (NixOS servers via systemd, macOS via launchd/home-manager)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      sysmon daemon                              │
│  (systemd on NixOS / launchd on macOS)                          │
│                                                                 │
│  Every N milliseconds (configurable, default 5000):             │
│  ├─ Calculate deltas (CPU, Net I/O, Disk I/O)                   │
│  ├─ Read instant values (RAM, Swap, Temp, Load)                 │
│  ├─ Smart interface selection (most active, not loopback)       │
│  ├─ Write individual metric files                               │
│  └─ Write timestamp file for staleness detection                │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  /dev/shm/sysmon/  (Linux) or /tmp/sysmon/ (macOS)              │
│  ├── cpu       → "42"           (%)                             │
│  ├── ram       → "67"           (%)                             │
│  ├── swap      → "2"            (%)                             │
│  ├── load      → "1.24"         (1-min load average)            │
│  ├── net_rx    → "125.3"        (Mbps)                          │
│  ├── net_tx    → "12.1"         (Mbps)                          │
│  ├── disk_r    → "2.1M"         (auto-scaled: K/M/G)            │
│  ├── disk_w    → "384K"         (auto-scaled: K/M/G)            │
│  ├── temp      → "58"           (°C, max across cores)          │
│  ├── iface     → "eth0"         (selected interface name)       │
│  └── timestamp → "1733150400"   (Unix epoch, for staleness)     │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  sysmon-reader (called by Starship per-prompt)                  │
│                                                                 │
│  1. Check staleness (if data > 2× interval old, show "?")       │
│  2. Read $COLUMNS (terminal width - updates on resize!)         │
│  3. Calculate DYNAMIC prompt width from actual context          │
│  4. Compute available = $COLUMNS - left_width - right_width     │
│  5. Select metrics by priority until available exhausted        │
│  6. Apply threshold-based coloring                              │
│  7. Output formatted string (or empty if no space/stale)        │
└─────────────────────────────────────────────────────────────────┘
```

---

## Metrics Collected

| Metric      | Linux Source                   | macOS Source          | Unit       |
| ----------- | ------------------------------ | --------------------- | ---------- |
| CPU %       | `/proc/stat` (delta)           | `ps -A -o %cpu`       | %          |
| RAM %       | `/proc/meminfo`                | `vm_stat`             | %          |
| Swap %      | `/proc/meminfo`                | `sysctl vm.swapusage` | %          |
| Load Avg    | `/proc/loadavg`                | `sysctl vm.loadavg`   | 1-min avg  |
| Net RX      | `/sys/class/net/*/statistics/` | `netstat -ib`         | Mbps       |
| Net TX      | `/sys/class/net/*/statistics/` | `netstat -ib`         | Mbps       |
| Disk Read   | `/proc/diskstats`              | `iostat -d`           | auto-scale |
| Disk Write  | `/proc/diskstats`              | `iostat -d`           | auto-scale |
| Temperature | `/sys/class/thermal/*/temp`    | `osx-cpu-temp`        | °C         |

---

## Configuration Options

```nix
services.sysmon = {
  enable = true;
  interval = 5000;  # milliseconds (default: 5000)

  # Output directory (default: /dev/shm/sysmon on Linux, /tmp/sysmon on macOS)
  outputDir = "/dev/shm/sysmon";

  # ═══════════════════════════════════════════════════════════════════════════
  # DISPLAY FORMATTING
  # ═══════════════════════════════════════════════════════════════════════════

  # Spacing between icon and value (default: empty string)
  # Example: "" → "42%", " " → " 42%"
  iconValueSpacing = "";

  # Spacing between one metric and the next (default: single space)
  # Example: " " → "42% 67%", "  " → "42%  67%", " | " → "42% | 67%"
  metricSpacing = " ";

  # Minimum terminal width to show ANY metrics
  # Below this, sysmon section is completely hidden
  minWidth = 80;

  # ═══════════════════════════════════════════════════════════════════════════
  # PER-METRIC CONFIGURATION
  # ═══════════════════════════════════════════════════════════════════════════
  # Each metric has:
  #   - enable: bool (show/hide this metric entirely)
  #   - icon: string (UTF-8 icon or text label, fully customizable)
  #   - thresholds: [elevated, critical] (trigger color changes)
  #   - priority: int (higher = more important = hides LAST when space limited)

  metrics = {
    cpu = {
      enable = true;
      icon = "\\uf4bc";           # Or "CPU" for text
      thresholds = [50, 80];      # % - [elevated, critical]
      priority = 100;             # Highest = last to hide
    };

    ram = {
      enable = true;
      icon = "\\uefc5";           # Or "RAM" for text
      thresholds = [70, 90];      # %
      priority = 90;
    };

    temp = {
      enable = true;
      icon = "󰔏";                 # \uF050F or "°C"
      thresholds = [60, 80];      # °C
      priority = 80;
    };

    load = {
      enable = true;
      icon = "󰊚";                 # \uF029A or "AVG"
      thresholds = [2.0, 4.0];    # 1-min load average
      priority = 70;
    };

    swap = {
      enable = true;
      icon = "󰾴";                 # \uF0FB4 or "SWP"
      thresholds = [10, 50];      # % (any swap use is noteworthy)
      priority = 60;
    };

    net = {
      enable = true;
      iconRx = "󰇚";               # \uF01DA or "↓"
      iconTx = "󰕒";               # \uF0552 or "↑"

      # Maximum bandwidth from ISP (Mbps)
      # Used to calculate utilization percentage
      maxBandwidth = {
        download = 80;            # Mbps (e.g., 80 Mbps down)
        upload = 20;              # Mbps (e.g., 20 Mbps up)
      };

      # Display mode: "percent" (of max) or "absolute" (raw Mbps)
      displayMode = "percent";    # Shows "󰇚62% 󰕒45%" instead of "󰇚50 󰕒9"

      # Thresholds as PERCENTAGE of maxBandwidth
      # Example: 50% of 80 Mbps = 40 Mbps triggers "elevated"
      thresholds = {
        rx = [50, 80];            # % of maxBandwidth.download
        tx = [50, 80];            # % of maxBandwidth.upload
      };
      priority = 50;
    };

    disk = {
      enable = true;
      icon = "󰋊";                 # \uF02CA or "DSK"
      iconRead = "↓";             # Or "R"
      iconWrite = "↑";            # Or "W"
      thresholds = {
        read = [50, 200];         # MB/s
        write = [50, 200];        # MB/s
      };
      priority = 40;              # Lowest = first to hide
    };
  };
};
```

### Configuration Examples

**Minimal display (CPU only):**

```nix
metrics = {
  cpu = { enable = true; priority = 100; /* ... */ };
  ram = { enable = false; /* ... */ };
  # ... all others disabled
};
```

**Text labels instead of icons:**

```nix
metrics = {
  cpu = { icon = "CPU"; /* ... */ };
  ram = { icon = "RAM"; /* ... */ };
  temp = { icon = ""; /* ... */ };  # Just show "58°" with no prefix
};
```

**Custom spacing:**

```nix
iconValueSpacing = " ";   # " 42%" instead of "42%"
metricSpacing = "  ";     # Double space between metrics
```

**Server-focused (no temp, high load threshold):**

```nix
metrics = {
  temp = { enable = false; };
  load = { thresholds = [4.0, 8.0]; priority = 95; };  # Servers handle more load
};
```

**Custom ISP bandwidth (80/20 Mbps connection):**

```nix
metrics.net = {
  maxBandwidth = {
    download = 80;   # 80 Mbps down
    upload = 20;     # 20 Mbps up
  };
  displayMode = "percent";  # Show "󰇚62%" instead of "󰇚50"
  thresholds = {
    rx = [50, 80];   # 50% = 40 Mbps, 80% = 64 Mbps
    tx = [50, 80];   # 50% = 10 Mbps, 80% = 16 Mbps
  };
};
```

**Gigabit connection (show absolute values):**

```nix
metrics.net = {
  maxBandwidth = { download = 1000; upload = 1000; };
  displayMode = "absolute";  # Show "󰇚125" (Mbps) - percentages less useful at high bandwidth
  thresholds = {
    rx = [50, 80];   # 500 Mbps, 800 Mbps
    tx = [50, 80];
  };
};
```

---

## Color Scheme (Traffic Light)

| State        | Condition                   | Icon Color       | Value Color                      | Purpose                     |
| ------------ | --------------------------- | ---------------- | -------------------------------- | --------------------------- |
| **Normal**   | value < elevated            | `__TEXT_MUTED__` | `__TEXT_MUTED__`                 | Blends in, no distraction   |
| **Elevated** | elevated ≤ value < critical | `__TEXT_MUTED__` | `__TEXT_ON_MEDIUM__` (white-ish) | Noticeable, "pay attention" |
| **Critical** | value ≥ critical            | `__TEXT_MUTED__` | `#ff3333` (neon red)             | Unmissable, "act now"       |

Note: Only the VALUE changes color, not the icon/label. This keeps visual consistency with the theme while highlighting concerning metrics.

---

## Display Format

### Icons Selected

| Metric | Icon | Unicode   | Nerd Font             |
| ------ | ---- | --------- | --------------------- |
| CPU    | ``   | `\uf4bc`  | nf-md-\*              |
| RAM    | ``   | `\uefc5`  | nf-md-\*              |
| Swap   | `󰾴`  | `\uF0FB4` | nf-md-swap-horizontal |
| Load   | `󰊚`  | `\uF029A` | nf-md-gauge           |
| Net ↓  | `󰇚`  | `\uF01DA` | nf-md-download        |
| Net ↑  | `󰕒`  | `\uF0552` | nf-md-upload          |
| Disk   | `󰋊`  | `\uF02CA` | nf-md-harddisk        |
| Temp   | `󰔏`  | `\uF050F` | nf-md-thermometer     |

### Full Display Example

**With network in percent mode (80/20 Mbps ISP):**

```
 42%   67%  󰾴 2%  󰊚 1.2  󰇚 62% 󰕒 45%  󰋊 ↓2↑0  󰔏 58°
```

(62% of 80 Mbps = 50 Mbps down, 45% of 20 Mbps = 9 Mbps up)

**With network in absolute mode:**

```
 42%   67%  󰾴 2%  󰊚 1.2  󰇚 50 󰕒 9  󰋊 ↓2↑0  󰔏 58°
```

(Raw Mbps values)

### Separator

Spaces between metrics (no special characters like pipes or dots)

---

## Smart Interface Selection

Network interface selection logic:

1. List all interfaces excluding: `lo`, `docker*`, `veth*`, `br-*`, `virbr*`
2. For each interface, read `rx_bytes + tx_bytes`
3. Select interface with highest total traffic since boot
4. Cache selection for 60 seconds to prevent flip-flopping

---

## Staleness Detection

The daemon writes a `timestamp` file with the Unix epoch of the last update. The reader uses this to detect stale data:

```bash
# In sysmon-reader:
timestamp=$(cat "$SYSMON_DIR/timestamp" 2>/dev/null || echo 0)
now=$(date +%s)
age=$((now - timestamp))
stale_threshold=$((interval_ms / 1000 * 2))  # 2× the update interval

if [[ $age -gt $stale_threshold ]]; then
  # Data is stale - daemon may have crashed or not started yet
  echo "?"  # Or show nothing, configurable
  exit 0
fi
```

| Scenario                | Behavior                        |
| ----------------------- | ------------------------------- |
| Daemon running normally | Fresh data displayed            |
| Daemon crashed/stopped  | Shows "?" after 2× interval     |
| System just booted      | Shows nothing until first write |
| Files don't exist yet   | Graceful empty output           |

---

## Graceful Error Handling

The sysmon-reader must handle edge cases without errors:

```bash
# Safe file reading - returns empty string if file missing
read_metric() {
  local file="$1"
  local default="${2:-}"
  if [[ -f "$file" ]]; then
    cat "$file"
  else
    echo "$default"
  fi
}

# Usage:
cpu=$(read_metric "$SYSMON_DIR/cpu" "?")
```

| Condition               | Behavior                  |
| ----------------------- | ------------------------- |
| Metric file missing     | Show "?" or skip metric   |
| Directory doesn't exist | Output nothing (no error) |
| Timestamp missing       | Treat as stale            |
| Daemon not installed    | Output nothing            |
| Permission denied       | Output nothing            |

---

## Starship Prompt Placement

The sysmon output is placed in the **middle section** between left and right prompt segments:

```toml
# In starship-template.toml format string:
format = """
...
$docker_context\
[](fg:__DARK__)\
$fill\                          # ← Flexible space
${custom.sysmon}\               # ← SYSMON GOES HERE (in the fill area)
$status\
$cmd_duration\
[](fg:__DARKER__)\
$time\
...
"""
```

The `$fill` module creates flexible space. Sysmon content appears in this middle area, with remaining space distributed around it.

Alternative placement (if $fill can't contain content): Place sysmon as a distinct segment before or after $fill.

---

## Smart Width Handling

### Terminal Resize Support

The shell's `$COLUMNS` variable **automatically updates** when the terminal is resized:

```
┌─────────────────────────────────────────────────────────────────┐
│  User resizes terminal window                                   │
│                    │                                            │
│                    ▼                                            │
│  Terminal sends SIGWINCH signal to shell                        │
│                    │                                            │
│                    ▼                                            │
│  Shell updates $COLUMNS variable automatically                  │
│                    │                                            │
│                    ▼                                            │
│  Next prompt: sysmon-reader uses NEW $COLUMNS value             │
│                    │                                            │
│                    ▼                                            │
│  Metrics adapt to current terminal width                        │
└─────────────────────────────────────────────────────────────────┘
```

Note: Existing prompt lines don't live-update on resize. The new width takes effect on the next prompt (after pressing Enter). This is standard Starship behavior.

### Dynamic Width Calculation

Instead of estimating a fixed "~70 chars", sysmon-reader **calculates actual prompt width** at runtime by detecting the current context:

```bash
# ═══════════════════════════════════════════════════════════════════
# FIXED COSTS (from starship-template.toml analysis)
# ═══════════════════════════════════════════════════════════════════
FIXED_LEFT=14      # ░▒▓(3) + OS(3) + powerline arrows(7) + @(1)
FIXED_RIGHT=15     # time segment(12) + powerline arrows(3)

# ═══════════════════════════════════════════════════════════════════
# DYNAMIC COSTS (detected at runtime)
# ═══════════════════════════════════════════════════════════════════

# Directory path (THE BIG VARIABLE!)
dir_len=${#PWD}

# Username + Hostname
user_len=${#USER}
host_len=$(hostname | wc -c)

# Git context (only if in a git repo)
git_cost=0
if git rev-parse --is-inside-work-tree &>/dev/null; then
  branch=$(git branch --show-current 2>/dev/null)
  git_cost=$((${#branch} + 15))  # branch + icon + status + count estimate
fi

# Language detection (check for marker files)
lang_cost=0
[[ -f "package.json" ]]                         && lang_cost=$((lang_cost + 12))
[[ -f "requirements.txt" || -f "pyproject.toml" ]] && lang_cost=$((lang_cost + 12))
[[ -f "Cargo.toml" ]]                           && lang_cost=$((lang_cost + 12))
[[ -f "go.mod" ]]                               && lang_cost=$((lang_cost + 12))
[[ -f "composer.json" ]]                        && lang_cost=$((lang_cost + 12))

# Right side conditionals
right_extra=0
[[ -n "$IN_NIX_SHELL" ]] && right_extra=$((right_extra + 10))
# Note: cmd_duration and status are usually 0 at fresh prompt time

# ═══════════════════════════════════════════════════════════════════
# FINAL CALCULATION
# ═══════════════════════════════════════════════════════════════════
total_used=$((FIXED_LEFT + dir_len + user_len + 1 + host_len + git_cost + lang_cost + FIXED_RIGHT + right_extra))
available=$((COLUMNS - total_used))
```

### Example Calculations

**Scenario A**: 120-col terminal, in `/Users/markus/Code/nixcfg`, branch `main`

```
FIXED_LEFT:     14
Directory:      25  (/Users/markus/Code/nixcfg)
user@host:      11  (markus@hsb0)
Git:            20  (main + decorations)
Languages:      0
FIXED_RIGHT:    15
────────────────
TOTAL USED:     85
AVAILABLE:      35 chars → CPU + RAM + Temp fit
```

**Scenario B**: 80-col terminal, in `/home/markus`, no git

```
FIXED_LEFT:     14
Directory:      12  (/home/markus)
user@host:      11
Git:            0
Languages:      0
FIXED_RIGHT:    15
────────────────
TOTAL USED:     52
AVAILABLE:      28 chars → CPU + RAM fit
```

**Scenario C**: 200-col terminal, deep path with Node project

```
FIXED_LEFT:     14
Directory:      55  (/Users/markus/Code/nixcfg/hosts/csb0/archive/...)
user@host:      18  (markus@imac-mba-work)
Git:            35  (feature/migrate-hsb1-to-hokage-pattern)
Languages:      12  (Node.js detected)
FIXED_RIGHT:    15
────────────────
TOTAL USED:     149
AVAILABLE:      51 chars → All metrics fit!
```

### Metric Selection Algorithm

```
1. Sort enabled metrics by priority (highest first)
2. available_space = COLUMNS - calculated_prompt_width
3. If available_space < minWidth (default 80): show nothing
4. For each metric in priority order:
   a. Calculate metric width (icon + spacing + value + unit)
   b. If it fits in remaining space: add it, subtract width
   c. If it doesn't fit: skip (try next, might be smaller)
5. Return formatted string
```

### Approximate Metric Widths

| Metric         | Width  | Example     |
| -------------- | ------ | ----------- |
| CPU            | ~5-6   | `42%`       |
| RAM            | ~5-6   | `67%`       |
| Temp           | ~5-6   | `󰔏58°`      |
| Load           | ~6-7   | `󰊚1.24`     |
| Swap           | ~5-6   | `󰾴2%`       |
| Net (percent)  | ~12-14 | `󰇚62%󰕒45%`  |
| Net (absolute) | ~10-14 | `󰇚125󰕒12`   |
| Disk           | ~10-14 | `󰋊↓2M↑384K` |

Total when all shown (with spacing): ~55-70 chars

---

## Implementation Files

| File                                    | Purpose                                    |
| --------------------------------------- | ------------------------------------------ |
| `modules/shared/sysmon.nix`             | NixOS/home-manager module with options     |
| `modules/shared/sysmon-daemon.sh`       | The monitoring daemon script               |
| `modules/shared/sysmon-reader.sh`       | Script called by Starship to format output |
| `modules/shared/starship-template.toml` | Update with sysmon custom module           |

---

## Platform Support

| Platform | Daemon Management        | Output Dir         | Temp Source                 | Status    |
| -------- | ------------------------ | ------------------ | --------------------------- | --------- |
| NixOS    | systemd service          | `/dev/shm/sysmon/` | `/sys/class/thermal/*/temp` | Primary   |
| macOS    | launchd via home-manager | `/tmp/sysmon/`     | `osx-cpu-temp` or fallback  | Secondary |

### macOS Temperature Fallback

Temperature reading on macOS requires SMC access. Options in order of preference:

1. **`osx-cpu-temp`** - If available via nix, use it
2. **`sudo powermetrics`** - Requires root, not practical for daemon
3. **Disable temp on macOS** - Skip temperature metric, show "—" or hide entirely

The daemon detects platform and handles gracefully:

```bash
get_temp() {
  if [[ -d /sys/class/thermal ]]; then
    # Linux: read from thermal zones, find max
    max_temp=0
    for zone in /sys/class/thermal/thermal_zone*/temp; do
      temp=$(cat "$zone" 2>/dev/null || echo 0)
      temp=$((temp / 1000))  # millidegrees → degrees
      [[ $temp -gt $max_temp ]] && max_temp=$temp
    done
    echo "$max_temp"
  elif command -v osx-cpu-temp &>/dev/null; then
    # macOS with osx-cpu-temp installed
    osx-cpu-temp | grep -oE '[0-9]+' | head -1
  else
    echo "—"  # No temperature available
  fi
}
```

---

## Acceptance Criteria

### Core Functionality

- [ ] Daemon starts automatically on boot (NixOS and macOS)
- [ ] Metrics update every N milliseconds (configurable interval)
- [ ] All metric files written to tmpfs (no disk I/O)
- [ ] Timestamp file written for staleness detection
- [ ] CPU calculation accurate (delta-based, not instantaneous)
- [ ] Network interface auto-selected intelligently
- [ ] Disk I/O values auto-scaled (K/M/G suffixes)
- [ ] Temperature shows max across all cores (Linux), fallback on macOS
- [ ] Works on both NixOS servers and macOS workstations

### Display & Starship Integration

- [ ] Starship integration shows metrics in prompt
- [ ] Dynamic width calculation based on actual prompt context
- [ ] Detects: PWD length, git branch, language markers
- [ ] Adapts to terminal resize (via $COLUMNS)
- [ ] Metrics hide progressively when space limited (by priority)
- [ ] Highest priority metric visible if terminal >= minWidth
- [ ] Threshold colors work (muted → white → red)

### Reliability & Error Handling

- [ ] Staleness detection: shows "?" if data older than 2× interval
- [ ] Graceful handling when files missing (no errors, empty output)
- [ ] Graceful handling when daemon not running
- [ ] macOS temperature fallback when osx-cpu-temp unavailable

### Configurability

- [ ] Per-metric enable/disable switch works
- [ ] Per-metric icon customizable (UTF-8 or text string)
- [ ] Per-metric thresholds configurable [elevated, critical]
- [ ] Per-metric priority configurable (controls hide order)
- [ ] Icon-to-value spacing configurable (default: "")
- [ ] Metric-to-metric spacing configurable (default: " ")
- [ ] Update interval configurable
- [ ] Minimum display width configurable
- [ ] Network: maxBandwidth configurable (download/upload in Mbps)
- [ ] Network: displayMode configurable ("percent" or "absolute")
- [ ] Network: thresholds work as percentage of maxBandwidth

---

## Test Plan

### Manual Test

**Core functionality:**

1. Enable sysmon on a test host
2. Verify daemon is running: `systemctl status sysmon` (Linux) or `launchctl list | grep sysmon` (macOS)
3. Check metric files exist: `ls -la /dev/shm/sysmon/`
4. Verify values update: `watch -n1 cat /dev/shm/sysmon/cpu`
5. Generate CPU load: `stress --cpu 4 --timeout 30`
6. Verify CPU metric increases and color changes at thresholds

**Width responsiveness & resize:** 7. Start with wide terminal (150+ cols) → verify all metrics shown 8. Resize to medium (100 cols) → verify lower-priority metrics hide 9. Resize to narrow (80 cols) → verify only CPU shown 10. Press Enter after each resize → verify prompt adapts

**Context-aware width calculation:** 11. In short path (`/tmp`) → verify more metrics fit 12. In deep path (`/very/long/path/to/project`) → verify fewer metrics 13. In git repo with long branch name → verify space calculation adjusts 14. In Node.js project (with package.json) → verify language detection works

**Staleness detection:** 15. Stop sysmon daemon: `systemctl stop sysmon` 16. Wait 2× interval (e.g., 10 seconds) 17. Press Enter → verify "?" shown or metrics hidden 18. Restart daemon → verify normal metrics return

**Configurability:** 19. Disable a metric (e.g., `metrics.swap.enable = false`) → verify it disappears 20. Change an icon to text (e.g., `metrics.cpu.icon = "CPU"`) → verify text shown 21. Adjust spacing (`iconValueSpacing = " "`) → verify space appears 22. Change priority order → verify hide order changes accordingly

**Network bandwidth configuration:** 23. Set `maxBandwidth = { download = 80; upload = 20; }` 24. Set `displayMode = "percent"` → verify shows "󰇚62%" instead of raw Mbps 25. Generate network traffic (e.g., large download) 26. Verify percentage reflects actual usage relative to max 27. Verify threshold colors trigger at configured percentages 28. Switch to `displayMode = "absolute"` → verify shows raw Mbps

### Automated Test

```bash
#!/usr/bin/env bash
# tests/sysmon-test.sh

FAIL=0

# Check daemon running
if systemctl is-active --quiet sysmon 2>/dev/null || \
   launchctl list 2>/dev/null | grep -q sysmon; then
  echo "✓ Daemon running"
else
  echo "✗ Daemon not running"
  FAIL=1
fi

# Check metric files exist
SYSMON_DIR="${SYSMON_DIR:-/dev/shm/sysmon}"
[[ -d "$SYSMON_DIR" ]] || SYSMON_DIR="/tmp/sysmon"

for metric in cpu ram swap load temp net_rx net_tx disk_r disk_w; do
  if [[ -f "$SYSMON_DIR/$metric" ]]; then
    val=$(cat "$SYSMON_DIR/$metric")
    echo "✓ $metric = $val"
  else
    echo "✗ Missing $SYSMON_DIR/$metric"
    FAIL=1
  fi
done

# Verify values are numeric (basic sanity)
for metric in cpu ram swap temp; do
  val=$(cat "$SYSMON_DIR/$metric" 2>/dev/null)
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "✓ $metric is numeric"
  else
    echo "✗ $metric not numeric: $val"
    FAIL=1
  fi
done

# Verify timestamp file exists and is recent
if [[ -f "$SYSMON_DIR/timestamp" ]]; then
  ts=$(cat "$SYSMON_DIR/timestamp")
  now=$(date +%s)
  age=$((now - ts))
  if [[ $age -lt 15 ]]; then
    echo "✓ timestamp recent (${age}s old)"
  else
    echo "✗ timestamp stale (${age}s old)"
    FAIL=1
  fi
else
  echo "✗ Missing timestamp file"
  FAIL=1
fi

# Verify sysmon-reader script exists and is executable
if command -v sysmon-reader &>/dev/null; then
  echo "✓ sysmon-reader available"

  # Test with wide terminal
  output_wide=$(COLUMNS=150 sysmon-reader 2>/dev/null)
  if [[ -n "$output_wide" ]]; then
    echo "✓ Wide (150 cols): $output_wide"
  else
    echo "✗ No output at 150 cols"
    FAIL=1
  fi

  # Test with narrow terminal
  output_narrow=$(COLUMNS=85 sysmon-reader 2>/dev/null)
  echo "✓ Narrow (85 cols): ${output_narrow:-[minimal/empty]}"

  # Verify wide has more content than narrow
  if [[ ${#output_wide} -ge ${#output_narrow} ]]; then
    echo "✓ Width adaptation working"
  else
    echo "✗ Wide output shorter than narrow?"
    FAIL=1
  fi
else
  echo "✗ sysmon-reader not found"
  FAIL=1
fi

if [[ $FAIL -eq 0 ]]; then
  echo "All checks passed"
else
  echo "Some checks failed"
  exit 1
fi
```

---

## Notes

- Icon selection complete: CPU=`` (`\uf4bc`), RAM=`` (`\uefc5`)
- Consider adding battery metric for laptops in future iteration
- Temperature on macOS requires `osx-cpu-temp` package (with graceful fallback)
- Delta calculations require daemon to maintain state between samples
- Terminal resize handled automatically via `$COLUMNS` shell variable
- Dynamic width calculation detects git, languages, path length at runtime
- Network bandwidth: configurable ISP max (Mbps) with percent/absolute display modes
- Network thresholds are percentages of configured max bandwidth

---

## Open Questions

1. ~~**Icons vs Text**: Final decision on CPU/RAM representation~~ → **RESOLVED**: CPU=`\uf4bc`, RAM=`\uefc5`
2. ~~**Space calculation**: How to calculate available space~~ → **RESOLVED**: Dynamic detection of prompt context
3. ~~**Terminal resize**: Does it adapt to window size~~ → **RESOLVED**: Yes, via $COLUMNS
4. ~~**Staleness**: How to detect daemon crash~~ → **RESOLVED**: Timestamp file + timeout
5. **GPU metrics**: Defer to future enhancement (vendor-specific complexity)
6. **Per-host threshold overrides**: Nice to have, not MVP

---

## Test Results

_Completed when moving to Done:_

- Manual test: [ ] Pass / [ ] Fail
- Automated test: [ ] Pass / [ ] Fail
- Date verified: YYYY-MM-DD

---

## GPT-5.1 Codex High - Feedback

**Feasibility snapshot**: Caching metrics in RAM via a daemon and letting Starship render from precomputed data is technically doable, but the current design layers a large amount of bespoke logic (daemon, width calculator, Starship glue) without first proving that per-prompt probes are the real bottleneck. Before investing further, benchmark the existing prompt (`hyperfine 'starship prompt'` or similar) to quantify latency and define an SLA that this architecture must beat.

### Key risks and open questions

- **Prompt-layout coupling**: The dynamic width script hardcodes today’s prompt internals (fixed 14-char left block, guessed git/lang costs, etc.). Any tweak to `starship-template.toml`, theme glyphs, or new modules requires a synchronized edit to this separate calculator, creating permanent drift risk and brittleness on every future prompt change.
- **Reinvented telemetry plumbing**: Parsing `/proc`, `netstat`, `iostat`, `ps`, `vm_stat`, and `osx-cpu-temp` in shell reimplements what mature agents (prometheus-node-exporter textfile collector, sysstat/sar, collectd, telegraf) already deliver with better portability, delta tracking, and error handling. The spec duplicates that complexity just to feed a prompt.
- **Cross-platform fragility**: macOS paths (`/tmp`), binaries (`ps`, `iostat`, `osx-cpu-temp`), SIP, sleep/wake, and multi-user launchd nuances are not addressed. The daemon must contend with permissions, PATH differences under home-manager, and battery-saving states; these are non-trivial compared with a pure shell pipeline.
- **Unclear UX win**: Writing a dozen files per interval and reading them individually per prompt may not meaningfully beat the cost of the original commands once syscall overhead and `cat` invocations are counted. Without measurements, we could be solving a non-issue.
- **State tracking burden**: Smart NIC selection, disk delta math, and temperature fallbacks each add edge cases (VLANs, tunnels, NVMe naming, missing SMC access). Maintaining these by hand across hosts could become a long-term operational load.

### Recommendations for a more senior/elegant path

- Prove the need: capture current prompt latency under typical workloads, and profile which modules dominate time. Use that data to set a target (e.g., cut worst-case prompt from 120 ms to 40 ms).
- Leverage existing collectors: run `prometheus-node-exporter` with its `textfile` output, `collectd` CSV, or `sysstat` data and consume those snapshots instead of building a custom parser farm. They already handle deltas, interface filtering, and cross-platform quirks.
- Consider a compiled daemon (Rust/Go) using libraries such as `heim`, `sysinfo`, or `gopsutil` to standardize metric gathering, state storage, and JSON output. This reduces shell fragility and gives room for tests.
- Rethink width handling: push truncation logic back into Starship (`right_format`, `truncation_length`, or even an upstream custom module) so formatting lives where the prompt already understands its segments. Avoid mirroring prompt layout in an external script.
- Optimize storage: instead of scattering `cpu`, `ram`, etc. files, write one JSON/binary snapshot or expose a Unix socket so the reader performs a single read per prompt.
- Prototype narrowly: ship a minimal CPU-only cache to validate that the architecture improves responsiveness and survives restarts, then iterate once the value is proven.

Bottom line: the idea is promising, but right now it risks becoming a bespoke monitoring stack to shave a few hypothetical milliseconds. Measure the pain, reuse existing telemetry primitives, and simplify the coupling between daemon and prompt before committing to the full scope.

---

## Gemini 3 Pro - Architectural Review & Feedback

Your spec is **solid and feasible**, but as a Senior Engineer reviewing this, I have some critical feedback to push it from "hacky script" to "robust product".

### The Verdict: Is it feasible?

**Yes.** 100%. The architecture (Daemon writes to RAM → Reader reads from RAM) is the **correct** way to handle expensive metrics in a shell prompt. It solves the latency problem perfectly.

### The Critique: Where it falls short

#### 1. The "Dynamic Width" Logic is a Trap 🪤

The section on `sysmon-reader` calculating available width (`COLUMNS - git_cost - dir_len - ...`) is **over-engineered and extremely brittle**.

- **Why**: You are effectively re-implementing Starship's internal rendering logic in a Bash script. If you change your Starship config (add a new module, change an icon, add a prefix), your `sysmon-reader` breaks or miscalculates.
- **Better Way**: Don't try to be so smart. Let Starship handle the layout. Use the `fill` module to push `sysmon` to the right, or give `sysmon` a fixed "budget" (e.g., "I will never take more than 40 chars"). If it truncates, it truncates.

#### 2. "Chart Junk" & Redundancy

You are running `zellij` (based on your history). Zellij already has a status bar.

- **Critique**: Putting these metrics in the prompt means they are printed **on every single line**. Do you really need to see what your CPU was 5 minutes ago in your scrollback? This pollutes your terminal history with ephemeral data.
- **Pro Move**: Move this to the **Zellij Status Bar**. It stays at the bottom, updates instantly (no Enter key required!), and doesn't clutter your history.

#### 3. Implementation Choice (Bash vs. Rust)

- **Bash**: Spawning a shell script (`sysmon-reader`) on _every single prompt_ adds 10-50ms of latency (fork/exec overhead), defeating some of the purpose.
- **macOS Support**: Parsing `sysctl` and `iostat` output with regex in Bash is fragile across macOS versions.

### The "Pro/Senior" Alternative 🚀

Instead of a collection of scripts, build a **single Rust binary** (`sysmon`).

1. **One Binary, Two Modes**:
   - `sysmon daemon`: Runs in background, uses the `sysinfo` crate (cross-platform, no parsing `ps`/`proc` manually!), writes to `/dev/shm`.
   - `sysmon print`: Called by Starship. reads `/dev/shm`, prints formatted string. fast.
2. **Cross-Platform out of the box**: The `sysinfo` Rust crate abstracts away the differences between Linux `/proc` and macOS `sysctl`. You delete 50% of your spec's complexity (the OS-specific commands) instantly.
3. **Performance**: Rust startup time is near-zero.

### Are we re-inventing the wheel?

**Kind of.**

- **Yes**: If you just want stats, `btop` or `zellij` plugins do this.
- **No**: If you specifically want it _inline in your prompt_, there isn't a standard tool that does this "async daemon" pattern out of the box for Starship custom modules.

### Recommendation

If you are married to seeing it in the **prompt**:

> **Go with the Rust implementation.** It removes the fragility of OS-parsing and is much faster. Drop the complex width calculation and just use a priority list that stops printing when it hits a character limit (e.g. 50 chars).

If you just want the **data**:

> **Write a Zellij plugin** (or use an existing one). It's cleaner, persistent, and "pro".
