#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                     SYSMON DAEMON - System Metrics Collector                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Collects system metrics (CPU, RAM, Load, Swap) every N seconds and writes
# them to a RAM-backed directory for fast reading by sysmon-reader.
#
# Platform Support:
#   - Linux: /proc/stat, /proc/meminfo, /proc/loadavg
#   - macOS: ps, vm_stat, sysctl
#
# Output Directory:
#   - Linux: /dev/shm/sysmon/ (RAM-backed tmpfs)
#   - macOS: /tmp/sysmon/ (SSD-backed, acceptable for small files)
#
# Usage: sysmon-daemon [interval_ms]
#   interval_ms: Sampling interval in milliseconds (default: 5000)
#

set -euo pipefail

# ════════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ════════════════════════════════════════════════════════════════════════════════

INTERVAL_MS="${1:-5000}"
INTERVAL_S=$((INTERVAL_MS / 1000))

# Detect platform and set output directory
if [[ "$(uname)" == "Darwin" ]]; then
  PLATFORM="darwin"
  SYSMON_DIR="/tmp/sysmon"
else
  PLATFORM="linux"
  SYSMON_DIR="/dev/shm/sysmon"
fi

# ════════════════════════════════════════════════════════════════════════════════
# INITIALIZATION
# ════════════════════════════════════════════════════════════════════════════════

# Create output directory
mkdir -p "$SYSMON_DIR"

# Previous CPU sample for delta calculation (Linux only)
prev_cpu_total=0
prev_cpu_idle=0

# ════════════════════════════════════════════════════════════════════════════════
# LINUX METRIC FUNCTIONS
# ════════════════════════════════════════════════════════════════════════════════

get_cpu_linux() {
  # Read CPU times from /proc/stat
  # Format: cpu user nice system idle iowait irq softirq steal guest guest_nice
  read -r _ user nice system idle iowait irq softirq steal _ _ </proc/stat

  # Calculate totals
  local idle_total=$((idle + iowait))
  local non_idle=$((user + nice + system + irq + softirq + steal))
  local total=$((idle_total + non_idle))

  # Calculate delta from previous sample
  local total_delta=$((total - prev_cpu_total))
  local idle_delta=$((idle_total - prev_cpu_idle))

  # Store for next iteration
  prev_cpu_total=$total
  prev_cpu_idle=$idle_total

  # Calculate CPU percentage (avoid division by zero)
  if [[ $total_delta -gt 0 ]]; then
    local cpu_pct=$(((total_delta - idle_delta) * 100 / total_delta))
    echo "$cpu_pct"
  else
    echo "0"
  fi
}

get_ram_linux() {
  # Parse /proc/meminfo for memory usage
  local mem_total mem_available
  while IFS=': ' read -r key value _; do
    case "$key" in
    MemTotal) mem_total=$value ;;
    MemAvailable) mem_available=$value ;;
    esac
  done </proc/meminfo

  # Calculate used percentage
  if [[ -n "$mem_total" && -n "$mem_available" && $mem_total -gt 0 ]]; then
    local used=$((mem_total - mem_available))
    echo $((used * 100 / mem_total))
  else
    echo "0"
  fi
}

get_swap_linux() {
  # Parse /proc/meminfo for swap usage
  local swap_total=0 swap_free=0
  while IFS=': ' read -r key value _; do
    case "$key" in
    SwapTotal) swap_total=$value ;;
    SwapFree) swap_free=$value ;;
    esac
  done </proc/meminfo

  # Calculate used percentage
  if [[ $swap_total -gt 0 ]]; then
    local used=$((swap_total - swap_free))
    echo $((used * 100 / swap_total))
  else
    echo "0"
  fi
}

get_load_linux() {
  # Read 1-minute load average from /proc/loadavg
  read -r load1 _ </proc/loadavg
  echo "$load1"
}

# ════════════════════════════════════════════════════════════════════════════════
# MACOS METRIC FUNCTIONS
# ════════════════════════════════════════════════════════════════════════════════

get_cpu_darwin() {
  # Sum all process CPU usage (simpler than parsing top)
  # Note: This can exceed 100% on multi-core systems, so we cap it
  local cpu_sum
  cpu_sum=$(ps -A -o %cpu | awk '{sum += $1} END {print int(sum)}')

  # Get number of CPU cores to normalize
  local cores
  cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)

  # Normalize to 0-100 range
  local cpu_pct=$((cpu_sum / cores))
  if [[ $cpu_pct -gt 100 ]]; then
    cpu_pct=100
  fi
  echo "$cpu_pct"
}

get_ram_darwin() {
  # Parse vm_stat output for memory usage
  local page_size pages_active pages_speculative pages_wired

  page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)

  # Parse vm_stat (values are in pages)
  # Note: We only use active, wired, and speculative for "used" memory
  while IFS=': ' read -r key value; do
    value="${value%.}" # Remove trailing period
    case "$key" in
    "Pages active") pages_active=$value ;;
    "Pages speculative") pages_speculative=$value ;;
    "Pages wired down") pages_wired=$value ;;
    esac
  done < <(vm_stat 2>/dev/null)

  # Get total physical memory
  local mem_total
  mem_total=$(sysctl -n hw.memsize 2>/dev/null || echo 0)

  # Calculate used memory (active + wired + speculative)
  # Free = free + inactive (inactive is reclaimable)
  local used_pages=$((pages_active + pages_wired + ${pages_speculative:-0}))
  local used_bytes=$((used_pages * page_size))

  if [[ $mem_total -gt 0 ]]; then
    echo $((used_bytes * 100 / mem_total))
  else
    echo "0"
  fi
}

get_swap_darwin() {
  # Parse sysctl vm.swapusage
  # Format: vm.swapusage: total = 2048.00M  used = 123.45M  free = 1924.55M  (encrypted)
  local swap_info
  swap_info=$(sysctl vm.swapusage 2>/dev/null || echo "")

  if [[ -n "$swap_info" ]]; then
    local total used
    # Extract total and used values (in MB)
    total=$(echo "$swap_info" | grep -oE 'total = [0-9.]+' | grep -oE '[0-9.]+')
    used=$(echo "$swap_info" | grep -oE 'used = [0-9.]+' | grep -oE '[0-9.]+')

    if [[ -n "$total" && -n "$used" ]]; then
      # Use awk for floating point calculation
      awk -v t="$total" -v u="$used" 'BEGIN { if (t > 0) printf "%d", (u/t)*100; else print "0" }'
      return
    fi
  fi
  echo "0"
}

get_load_darwin() {
  # Parse sysctl vm.loadavg
  # Format: vm.loadavg: { 1.23 4.56 7.89 }
  local load_info
  load_info=$(sysctl vm.loadavg 2>/dev/null || echo "")

  if [[ -n "$load_info" ]]; then
    # Extract first (1-min) load average
    echo "$load_info" | awk '{print $3}' | tr -d '{'
  else
    echo "0.00"
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
# MAIN LOOP
# ════════════════════════════════════════════════════════════════════════════════

write_metrics() {
  local cpu ram swap load timestamp

  if [[ "$PLATFORM" == "darwin" ]]; then
    cpu=$(get_cpu_darwin)
    ram=$(get_ram_darwin)
    swap=$(get_swap_darwin)
    load=$(get_load_darwin)
  else
    cpu=$(get_cpu_linux)
    ram=$(get_ram_linux)
    swap=$(get_swap_linux)
    load=$(get_load_linux)
  fi

  timestamp=$(date +%s)

  # Write metrics atomically (write to temp, then move)
  echo "$cpu" >"$SYSMON_DIR/cpu.tmp" && mv "$SYSMON_DIR/cpu.tmp" "$SYSMON_DIR/cpu"
  echo "$ram" >"$SYSMON_DIR/ram.tmp" && mv "$SYSMON_DIR/ram.tmp" "$SYSMON_DIR/ram"
  echo "$swap" >"$SYSMON_DIR/swap.tmp" && mv "$SYSMON_DIR/swap.tmp" "$SYSMON_DIR/swap"
  echo "$load" >"$SYSMON_DIR/load.tmp" && mv "$SYSMON_DIR/load.tmp" "$SYSMON_DIR/load"
  echo "$timestamp" >"$SYSMON_DIR/timestamp.tmp" && mv "$SYSMON_DIR/timestamp.tmp" "$SYSMON_DIR/timestamp"
}

# Initial sample for CPU delta calculation (Linux)
if [[ "$PLATFORM" == "linux" ]]; then
  get_cpu_linux >/dev/null
  sleep 0.1 # Brief pause to get meaningful delta on first real sample
fi

# Main loop
while true; do
  write_metrics
  sleep "$INTERVAL_S"
done
