#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                     SYSMON READER - Starship Custom Module                    ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Reads system metrics from sysmon-daemon output files and formats them for
# display in Starship prompt with threshold-based coloring.
#
# Features:
#   - Staleness detection (shows "?" if data > 10s old)
#   - Threshold-based coloring (muted → white → red)
#   - Priority-based truncation within character budget
#   - Graceful error handling (empty output on failure)
#
# Usage: sysmon-reader
#   Called by Starship custom module, outputs formatted metrics string.
#

set -euo pipefail

# ════════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ════════════════════════════════════════════════════════════════════════════════

# Character budget for output (prevents prompt overflow)
MAX_BUDGET="${SYSMON_MAX_BUDGET:-45}"

# Minimum terminal width to show metrics (hide on narrow terminals)
MIN_TERMINAL="${SYSMON_MIN_TERMINAL:-100}"

# Staleness threshold in seconds
STALE_THRESHOLD="${SYSMON_STALE_THRESHOLD:-10}"

# Metric thresholds: [elevated, critical]
# Configurable via environment variables
CPU_THRESH_ELEVATED="${SYSMON_CPU_ELEVATED:-50}"
CPU_THRESH_CRITICAL="${SYSMON_CPU_CRITICAL:-80}"
RAM_THRESH_ELEVATED="${SYSMON_RAM_ELEVATED:-70}"
RAM_THRESH_CRITICAL="${SYSMON_RAM_CRITICAL:-90}"
LOAD_THRESH_ELEVATED="${SYSMON_LOAD_ELEVATED:-2.0}"
LOAD_THRESH_CRITICAL="${SYSMON_LOAD_CRITICAL:-4.0}"
SWAP_THRESH_ELEVATED="${SYSMON_SWAP_ELEVATED:-10}"
SWAP_THRESH_CRITICAL="${SYSMON_SWAP_CRITICAL:-50}"

# Icons (Nerd Font)
ICON_CPU="${SYSMON_ICON_CPU:-}"    # \uf4bc - chip
ICON_RAM="${SYSMON_ICON_RAM:-}"    # \uefc5 - memory
ICON_LOAD="${SYSMON_ICON_LOAD:-󰊚}" # \uF029A - pulse
ICON_SWAP="${SYSMON_ICON_SWAP:-󰾴}" # \uF0FB4 - swap

# Colors (ANSI escape codes for Starship)
# These work within Starship's custom module output
COLOR_MUTED="\033[38;5;242m"    # Gray (blends in)
COLOR_ELEVATED="\033[38;5;255m" # White (noticeable)
COLOR_CRITICAL="\033[38;5;196m" # Red (urgent)
COLOR_RESET="\033[0m"

# Detect platform and set input directory
if [[ "$(uname)" == "Darwin" ]]; then
  SYSMON_DIR="/tmp/sysmon"
else
  SYSMON_DIR="/dev/shm/sysmon"
fi

# ════════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ════════════════════════════════════════════════════════════════════════════════

# Read metric file with fallback
read_metric() {
  local file="$1"
  local default="${2:-?}"
  cat "$file" 2>/dev/null || echo "$default"
}

# Get color based on value and thresholds (integer comparison)
get_color_int() {
  local value="$1"
  local thresh_elevated="$2"
  local thresh_critical="$3"

  if [[ "$value" == "?" ]]; then
    echo "$COLOR_MUTED"
  elif [[ "$value" -ge "$thresh_critical" ]]; then
    echo "$COLOR_CRITICAL"
  elif [[ "$value" -ge "$thresh_elevated" ]]; then
    echo "$COLOR_ELEVATED"
  else
    echo "$COLOR_MUTED"
  fi
}

# Get color based on value and thresholds (float comparison)
get_color_float() {
  local value="$1"
  local thresh_elevated="$2"
  local thresh_critical="$3"

  if [[ "$value" == "?" ]]; then
    echo "$COLOR_MUTED"
  else
    # Use awk for float comparison
    local level
    level=$(awk -v v="$value" -v e="$thresh_elevated" -v c="$thresh_critical" \
      'BEGIN { if (v >= c) print "critical"; else if (v >= e) print "elevated"; else print "normal" }')

    case "$level" in
    critical) echo "$COLOR_CRITICAL" ;;
    elevated) echo "$COLOR_ELEVATED" ;;
    *) echo "$COLOR_MUTED" ;;
    esac
  fi
}

# Format a metric with icon, value, and color
format_metric() {
  local icon="$1"
  local value="$2"
  local suffix="$3"
  local color="$4"

  echo -e "${color}${icon} ${value}${suffix}${COLOR_RESET}"
}

# Calculate display width of a string (accounting for ANSI codes)
# Note: ANSI escape sequences don't count toward visible width
visible_width() {
  local str="$1"
  # Remove ANSI escape codes and count remaining characters
  echo -n "$str" | sed 's/\x1b\[[0-9;]*m//g' | wc -c | tr -d ' '
}

# ════════════════════════════════════════════════════════════════════════════════
# MAIN LOGIC
# ════════════════════════════════════════════════════════════════════════════════

main() {
  # Check terminal width
  # Note: When run by Starship, tput may return 80 (default) even on wide terminals
  # Only hide on genuinely narrow terminals where COLUMNS is explicitly set
  local cols="${COLUMNS:-200}" # Assume wide if not set (Starship context)
  if [[ "$cols" -lt "$MIN_TERMINAL" ]]; then
    exit 0 # Too narrow, show nothing
  fi

  # Check if sysmon directory exists
  if [[ ! -d "$SYSMON_DIR" ]]; then
    exit 0 # Daemon not running, graceful exit
  fi

  # Check staleness
  local timestamp
  timestamp=$(read_metric "$SYSMON_DIR/timestamp" "0")
  local now
  now=$(date +%s)
  local age=$((now - timestamp))

  if [[ "$age" -gt "$STALE_THRESHOLD" ]]; then
    # Data is stale, show indicator
    echo -e "${COLOR_MUTED}?${COLOR_RESET}"
    exit 0
  fi

  # Read metrics
  local cpu ram swap load
  cpu=$(read_metric "$SYSMON_DIR/cpu" "?")
  ram=$(read_metric "$SYSMON_DIR/ram" "?")
  swap=$(read_metric "$SYSMON_DIR/swap" "?")
  load=$(read_metric "$SYSMON_DIR/load" "?")

  # Build metrics array with priorities (higher = more important)
  # Format: "priority|formatted_string"
  declare -a metrics=()

  # CPU (priority 100)
  local cpu_color
  cpu_color=$(get_color_int "$cpu" "$CPU_THRESH_ELEVATED" "$CPU_THRESH_CRITICAL")
  metrics+=("100|$(format_metric "$ICON_CPU" "$cpu" "%" "$cpu_color")")

  # RAM (priority 90)
  local ram_color
  ram_color=$(get_color_int "$ram" "$RAM_THRESH_ELEVATED" "$RAM_THRESH_CRITICAL")
  metrics+=("90|$(format_metric "$ICON_RAM" "$ram" "%" "$ram_color")")

  # Load (priority 70)
  local load_color
  load_color=$(get_color_float "$load" "$LOAD_THRESH_ELEVATED" "$LOAD_THRESH_CRITICAL")
  metrics+=("70|$(format_metric "$ICON_LOAD" "$load" "" "$load_color")")

  # Swap (priority 60) - only show if > 0
  if [[ "$swap" != "?" && "$swap" != "0" ]]; then
    local swap_color
    swap_color=$(get_color_int "$swap" "$SWAP_THRESH_ELEVATED" "$SWAP_THRESH_CRITICAL")
    metrics+=("60|$(format_metric "$ICON_SWAP" "$swap" "%" "$swap_color")")
  fi

  # Sort by priority (descending) and build output within budget
  local output=""
  local current_width=0
  local separator=" "

  # Sort metrics by priority (highest first)
  # Using while loop instead of mapfile for bash 3.2 compatibility (macOS)
  while IFS= read -r item; do
    local formatted="${item#*|}" # Remove priority prefix
    local item_width
    item_width=$(visible_width "$formatted")

    # Add separator width if not first item
    local sep_width=0
    if [[ -n "$output" ]]; then
      sep_width=${#separator}
    fi

    # Check if adding this item would exceed budget
    if [[ $((current_width + item_width + sep_width)) -le "$MAX_BUDGET" ]]; then
      if [[ -n "$output" ]]; then
        output="${output}${separator}${formatted}"
      else
        output="$formatted"
      fi
      current_width=$((current_width + item_width + sep_width))
    fi
  done < <(printf '%s\n' "${metrics[@]}" | sort -t'|' -k1 -rn)

  # Output final string
  echo -e "$output"
}

main "$@"
