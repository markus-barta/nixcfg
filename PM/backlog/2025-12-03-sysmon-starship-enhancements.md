# Sysmon Enhancements (Post-MVP)

## Overview

Future enhancements to the sysmon system monitoring daemon after MVP is validated. These features were considered during initial design but deferred to reduce scope.

**Prerequisite:** MVP must be implemented and working first.

---

## Enhancement 1: Dynamic Width Calculation

### Description

Instead of a fixed 45-char budget, calculate actual available space by analyzing the current prompt context.

### Why Deferred

Couples sysmon-reader to starship-template.toml internals. Any prompt change requires updating the width calculator. Adds maintenance burden.

### Implementation Sketch

```bash
# Detect prompt width dynamically
FIXED_LEFT=14      # ░▒▓ + OS icon + arrows
FIXED_RIGHT=15     # Time + arrows

dir_len=${#PWD}
user_len=${#USER}
host_len=$(hostname | wc -c)

git_cost=0
if git rev-parse --is-inside-work-tree &>/dev/null; then
  branch=$(git branch --show-current 2>/dev/null)
  git_cost=$((${#branch} + 15))
fi

# Language detection
lang_cost=0
[[ -f "package.json" ]] && lang_cost=$((lang_cost + 12))
[[ -f "requirements.txt" ]] && lang_cost=$((lang_cost + 12))
# ... etc

total_used=$((FIXED_LEFT + dir_len + user_len + 1 + host_len + git_cost + lang_cost + FIXED_RIGHT))
available=$((COLUMNS - total_used))
```

### Trade-off

| Fixed Budget                      | Dynamic Width            |
| --------------------------------- | ------------------------ |
| Zero coupling                     | Coupled to prompt layout |
| May waste space on wide terminals | Uses all available space |
| Simple, maintainable              | Complex, brittle         |

### Priority

Medium — nice-to-have for power users who want maximum information density.

---

## Enhancement 2: Temperature Metric

### Description

Display CPU temperature in the prompt.

### Why Deferred

- Linux: Easy via `/sys/class/thermal/*/temp`
- macOS: Requires external tool (`osx-cpu-temp`) or shows "—"

### Implementation

**Linux (add to MVP):**

```bash
get_temp() {
  max=0
  for zone in /sys/class/thermal/thermal_zone*/temp; do
    temp=$(($(cat "$zone" 2>/dev/null || echo 0) / 1000))
    [[ $temp -gt $max ]] && max=$temp
  done
  echo "$max"
}
```

**macOS (requires osx-cpu-temp):**

```bash
if command -v osx-cpu-temp &>/dev/null; then
  osx-cpu-temp | grep -oE '[0-9]+' | head -1
else
  echo "—"
fi
```

### Configuration

```nix
metrics.temp = {
  enable = true;
  icon = "󰔏";  # \uF050F
  thresholds = [60 80];
  priority = 80;
};
```

### Priority

High — very useful for monitoring thermal throttling during builds.

---

## Enhancement 3: Network I/O Metrics

### Description

Display network throughput (download/upload) in the prompt.

### Why Deferred

- Requires delta calculation (bytes now vs. bytes N seconds ago)
- Smart interface selection logic (exclude loopback, docker, etc.)
- Optional: percentage of ISP bandwidth

### Implementation

**Interface selection:**

```bash
# Exclude: lo, docker*, veth*, br-*, virbr*
# Select interface with highest traffic since boot
```

**Display modes:**

- Absolute: `󰇚 125 󰕒 12` (Mbps)
- Percentage: `󰇚 62% 󰕒 45%` (of configured ISP max)

### Configuration

```nix
metrics.net = {
  enable = true;
  iconRx = "󰇚";
  iconTx = "󰕒";
  maxBandwidth = { download = 80; upload = 20; };  # Mbps
  displayMode = "percent";  # or "absolute"
  thresholds = { rx = [50 80]; tx = [50 80]; };
  priority = 50;
};
```

### Priority

Medium — useful but adds complexity.

---

## Enhancement 4: Disk I/O Metrics

### Description

Display disk read/write throughput.

### Why Deferred

- Requires delta calculation
- Auto-scaling units (K/M/G)
- Linux: `/proc/diskstats`
- macOS: `iostat` parsing

### Display

```
󰋊 ↓2M ↑384K
```

### Priority

Low — less commonly needed for at-a-glance monitoring.

---

## Enhancement 5: Zellij Status Bar Plugin

### Description

Display sysmon metrics in the Zellij status bar instead of (or in addition to) the prompt.

### Why Deferred

- Different implementation approach (Zellij plugin vs. Starship module)
- Only works when Zellij is running
- Prompt-based is more portable (works over SSH)

### Benefits

- **Live updates** — no need to press Enter
- **Clean scrollback** — metrics don't pollute terminal history
- **Single location** — always at bottom of screen

### Architecture

The daemon writes to the same files. A Zellij plugin reads them and renders in the status bar. Same data, different consumer.

### Priority

Medium — great UX improvement for local workstations.

---

## Enhancement 6: GPU Metrics

### Description

Display GPU utilization and temperature.

### Why Deferred

Vendor-specific complexity:

- NVIDIA: `nvidia-smi`
- AMD: `rocm-smi`
- Intel: different again

### Priority

Low — only relevant for specific workloads (gaming PC, ML).

---

## Enhancement 7: Per-Host Threshold Overrides

### Description

Allow different thresholds per host (servers can handle higher load than laptops).

### Implementation

```nix
# In host configuration
services.sysmon.metrics.load.thresholds = [4.0 8.0];  # Server handles more
```

### Priority

Low — nice-to-have customization.

---

## Enhancement 8: Compiled Reader (Rust)

### Description

Replace `sysmon-reader.sh` with a compiled Rust binary for near-zero startup time.

### Why Deferred

Current bash reader adds ~15-30ms, but this is acceptable given:

- Starship already forks multiple processes (git, node, python)
- Reading from RAM is trivial work
- Complexity not worth it for MVP

### When to Consider

If measurements show prompt latency is a problem and sysmon-reader is the bottleneck.

### Implementation

Use `sysinfo` Rust crate for cross-platform metric reading.

### Priority

Low — optimize only if needed.

---

## Enhancement 9: Trailing Space After nix_shell Segment

### Description

A single trailing space appears after the closing `)` powerline cap of the `nix_shell` (impure) segment. This creates a visible gap before the prompt character `❯`.

### Current State

```
 6%  51% 󰊚 7.47 󰾴 59%  17:29:40  impure) ❯
                                        ^-- unwanted space
```

### Investigation Done

- Hex dump (`xxd`) of `starship prompt` output analyzed
- Space is NOT in `nix_shell` format string
- Space is NOT after the `__PL_RIGHT_SOFT__` cap
- Possibly injected by Starship between modules, or in a module not yet identified

### Debugging Approach

1. Run `starship prompt | xxd` and trace bytes around `impure`
2. Check `character` module format
3. Check main `format` string spacing between `$nix_shell` and `$character`
4. May need to inspect Starship's internal module output concatenation

### Priority

Low — cosmetic issue, ~99.9% of MVP complete.

---

## Implementation Order (Suggested)

1. **Temperature (Linux)** — easy win, high value
2. **Network I/O** — useful for monitoring transfers
3. **Dynamic Width** — power user feature
4. **Zellij Plugin** — better UX for local use
5. **Temperature (macOS)** — requires external dep
6. **Disk I/O** — lower priority
7. **GPU** — niche use case
8. **Compiled Reader** — only if measurements show need
9. **Trailing space fix** — cosmetic, low priority
