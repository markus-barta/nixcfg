# StaSysMo: System Metrics in Starship Prompt (MVP)

**Status:** ✅ Completed 2025-12-03
**Renamed:** sysmon → StaSysMo (Starship System Monitoring)

---

## Goal

Display system health metrics (CPU, RAM, load, swap) in the Starship prompt for at-a-glance awareness of background load while working.

## Outcome

MVP successfully implemented and deployed on:

- **macOS**: imac0 (via Home Manager + launchd)
- **NixOS**: hsb0 (via systemd)

All core functionality working. One minor cosmetic issue (trailing space after nix_shell segment) deferred to enhancements backlog.

---

## Architecture (Implemented)

```text
┌─────────────────────────────────────────────────────────────────┐
│                    stasysmo-daemon                              │
│  (systemd on NixOS / launchd on macOS)                          │
│                                                                 │
│  Every 5 seconds (configurable):                                │
│  ├─ Calculate CPU% (delta from previous sample)                 │
│  ├─ Read RAM%, Swap%, Load average                              │
│  ├─ Write to /dev/shm/stasysmo/ (Linux) or /tmp/stasysmo/ (macOS)│
│  └─ Write timestamp for staleness detection                     │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  /dev/shm/stasysmo/  (RAM-backed on Linux)                      │
│  ├── cpu       → "42"           (percentage)                    │
│  ├── ram       → "67"           (percentage)                    │
│  ├── swap      → "2"            (percentage)                    │
│  ├── load      → "1.24"         (1-min average)                 │
│  └── timestamp → "1733150400"   (Unix epoch)                    │
└─────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  stasysmo-reader (called by Starship per-prompt)                │
│                                                                 │
│  1. Detect terminal width via /dev/tty                          │
│  2. Check staleness (if data > 10s old, show "?")               │
│  3. Read metric files                                           │
│  4. Apply threshold coloring (muted → white → red)              │
│  5. Progressive hiding based on terminal width                  │
│  6. Output formatted string with powerline segment              │
└─────────────────────────────────────────────────────────────────┘
```

---

## Implementation Files

| File                                       | Purpose                                      |
| ------------------------------------------ | -------------------------------------------- |
| `modules/shared/stasysmo/config.nix`       | Centralized configuration (no magic numbers) |
| `modules/shared/stasysmo/daemon.sh`        | Background daemon (Linux + macOS)            |
| `modules/shared/stasysmo/reader.sh`        | Starship custom module with width detection  |
| `modules/shared/stasysmo/icons.sh`         | Nerd Font icons (Python-generated)           |
| `modules/shared/stasysmo/nixos.nix`        | NixOS module (systemd service)               |
| `modules/shared/stasysmo/home-manager.nix` | Home Manager module (launchd agent)          |
| `modules/shared/stasysmo/tests/`           | Automated + manual test suite                |
| `modules/shared/stasysmo/README.md`        | Full documentation + dev notes               |

---

## Features Implemented

### Core

- [x] Daemon starts on boot (systemd/launchd)
- [x] Metrics update every 5 seconds (configurable)
- [x] CPU% accurate (delta-based calculation)
- [x] Works on NixOS and macOS
- [x] Platform-specific swap thresholds (macOS more tolerant)

### Display

- [x] Starship shows metrics in powerline segment
- [x] Fixed budget (45 chars) with priority truncation
- [x] Threshold colors work (muted → white → red)
- [x] Progressive hiding based on terminal width
- [x] Proper powerline transitions (rounded caps)
- [x] Command duration integrated in time segment

### Configuration

- [x] Main `enable` switch
- [x] No magic numbers (all in config.nix)
- [x] Presets for intervals, budgets, spacers
- [x] Per-metric thresholds configurable
- [x] Configurable spacers (icon-value, between-metrics)

### Reliability

- [x] Staleness shows "?" after 10s
- [x] No errors when daemon not running
- [x] No errors when files missing
- [x] No artifacts when hideAll threshold active

---

## Key Technical Discoveries

| Challenge                    | Solution                                             |
| ---------------------------- | ---------------------------------------------------- |
| Terminal width in subprocess | Query `/dev/tty` directly: `stty size < /dev/tty`    |
| Unicode corruption in edits  | Placeholders (`__PL_LEFT_SOFT__`) substituted in Nix |
| ANSI resets breaking bg      | Use `\033[39m` (fg only) not `\033[0m` (full reset)  |
| Bash 3.2 on macOS            | Avoid `mapfile`, `((x++))` when x=0                  |
| Empty spacer config          | Use `${VAR-default}` not `${VAR:-default}`           |
| vm_stat parsing              | Regex without `$` anchor (trailing whitespace)       |

---

## Known Issues (Deferred)

1. **Trailing space after nix_shell segment** — cosmetic, added to enhancements backlog

---

## Deployment

```nix
# NixOS (configuration.nix)
imports = [ ../../modules/shared/stasysmo/nixos.nix ];
services.stasysmo.enable = true;

# macOS (home.nix)
imports = [ ../../modules/shared/stasysmo/home-manager.nix ];
services.stasysmo.enable = true;
```

---

## Test Results

```
T00: Platform detection     ✓
T01: Daemon execution       ✓
T02: Output file format     ✓
T03: Reader output          ✓
T04: Width thresholds       ✓ (manual verification)
T05: Starship integration   ✓ (manual verification)
```

---

## Out of Scope (See Enhancements Backlog)

- Dynamic width calculation
- Temperature metric
- Network I/O metrics
- Disk I/O metrics
- Zellij status bar plugin
- GPU metrics
- Compiled reader (Rust)
