#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                   StaSysMo Reader - Starship Custom Module                    ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Reads system metrics from stasysmo-daemon output files and formats them for
# display in Starship prompt with threshold-based coloring.
#
# Features:
#   - Staleness detection (shows "?" if data too old)
#   - Threshold-based coloring (muted → elevated → critical)
#   - Priority-based truncation within character budget
#   - Graceful error handling (empty output on failure)
#
# Configuration:
#   All settings come from environment variables (set by Nix module).
#   See: modules/shared/stasysmo/config.nix
#
# Usage: stasysmo-reader
#   Called by Starship custom module, outputs formatted metrics string.
#

set -euo pipefail

# ════════════════════════════════════════════════════════════════════════════════
# CONFIGURATION (from environment, with defaults from sysmon-config.nix)
# ════════════════════════════════════════════════════════════════════════════════

# Display settings
MAX_BUDGET="${STASYSMO_MAX_BUDGET:-45}"
STALE_THRESHOLD="${STASYSMO_STALE_THRESHOLD:-10}"

# Thresholds (elevated, critical)
CPU_ELEVATED="${STASYSMO_CPU_ELEVATED:-50}"
CPU_CRITICAL="${STASYSMO_CPU_CRITICAL:-80}"
RAM_ELEVATED="${STASYSMO_RAM_ELEVATED:-70}"
RAM_CRITICAL="${STASYSMO_RAM_CRITICAL:-90}"
LOAD_ELEVATED="${STASYSMO_LOAD_ELEVATED:-2.0}"
LOAD_CRITICAL="${STASYSMO_LOAD_CRITICAL:-4.0}"
SWAP_ELEVATED="${STASYSMO_SWAP_ELEVATED:-10}"
SWAP_CRITICAL="${STASYSMO_SWAP_CRITICAL:-50}"

# Icons (set by Nix module from sysmon-icons.sh, or use fallback)
# The Nix module reads sysmon-icons.sh and passes the Unicode characters
ICON_CPU="${STASYSMO_ICON_CPU:-?}"
ICON_RAM="${STASYSMO_ICON_RAM:-?}"
ICON_LOAD="${STASYSMO_ICON_LOAD:-?}"
ICON_SWAP="${STASYSMO_ICON_SWAP:-?}"

# Colors (ANSI 256)
COLOR_MUTED="${STASYSMO_COLOR_MUTED:-242}"
COLOR_ELEVATED="${STASYSMO_COLOR_ELEVATED:-255}"
COLOR_CRITICAL="${STASYSMO_COLOR_CRITICAL:-196}"

# Spacers (configurable strings)
# Note: Use ${VAR-default} not ${VAR:-default} to allow empty strings
SPACER_ICON_VALUE="${STASYSMO_SPACER_ICON_VALUE- }" # Between icon and value
SPACER_METRICS="${STASYSMO_SPACER_METRICS- }"       # Between metrics

# Platform detection
if [[ "$(uname)" == "Darwin" ]]; then
  STASYSMO_DIR="${STASYSMO_DIR:-/tmp/stasysmo}"
else
  STASYSMO_DIR="${STASYSMO_DIR:-/dev/shm/stasysmo}"
fi

# ════════════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ════════════════════════════════════════════════════════════════════════════════

# Return icon (already a character, not an escape sequence)
get_icon() {
  echo -n "$1"
}

# Read metric file with fallback
read_metric() {
  local file="$1"
  local default="${2:-?}"
  cat "$file" 2>/dev/null || echo "$default"
}

# Get ANSI color escape sequence
ansi_color() {
  local code="$1"
  printf '\033[38;5;%sm' "$code"
}

# Reset ANSI foreground color only (preserve background for Starship powerline)
# Use \033[39m instead of \033[0m to avoid resetting Starship's background styling
ansi_reset() {
  printf '\033[39m'
}

# Get color code based on value and thresholds (integer comparison)
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

# Get color code based on value and thresholds (float comparison)
get_color_float() {
  local value="$1"
  local thresh_elevated="$2"
  local thresh_critical="$3"

  if [[ "$value" == "?" ]]; then
    echo "$COLOR_MUTED"
  else
    # Use awk for float comparison
    awk -v v="$value" -v e="$thresh_elevated" -v c="$thresh_critical" -v cm="$COLOR_MUTED" -v ce="$COLOR_ELEVATED" -v cc="$COLOR_CRITICAL" \
      'BEGIN { if (v >= c) print cc; else if (v >= e) print ce; else print cm }'
  fi
}

# Format a metric with icon, value, suffix, and color
format_metric() {
  local icon_escape="$1"
  local value="$2"
  local suffix="$3"
  local color_code="$4"

  local icon
  icon=$(get_icon "$icon_escape")
  local color
  color=$(ansi_color "$color_code")
  local reset
  reset=$(ansi_reset)

  # Use configurable spacer between icon and value
  printf '%s%s%s%s%s%s' "$color" "$icon" "$SPACER_ICON_VALUE" "$value" "$suffix" "$reset"
}

# Calculate display width of a string (accounting for ANSI codes)
visible_width() {
  local str="$1"
  # Remove ANSI escape codes and count remaining characters
  echo -n "$str" | sed 's/\x1b\[[0-9;]*m//g' | wc -c | tr -d ' '
}

# ════════════════════════════════════════════════════════════════════════════════
# MAIN LOGIC
# ════════════════════════════════════════════════════════════════════════════════

# Get actual terminal width (more reliable than COLUMNS)
get_terminal_width() {
  # Try tput first (most reliable in interactive shells)
  local width
  width=$(tput cols 2>/dev/null)
  if [[ -n "$width" && "$width" -gt 0 && "$width" -ne 80 ]]; then
    # Accept tput result if it's not the generic default
    echo "$width"
    return
  fi
  # Check COLUMNS (set by some shells)
  if [[ -n "$COLUMNS" && "$COLUMNS" -gt 0 ]]; then
    echo "$COLUMNS"
    return
  fi
  # Default to wide (show all metrics) when we can't detect
  # Better to show more info than hide it when unsure
  echo "200"
}

# Terminal width thresholds (from config, with sensible defaults)
WIDTH_HIDE_ALL="${STASYSMO_WIDTH_HIDE_ALL:-80}"
WIDTH_SHOW_ONE="${STASYSMO_WIDTH_SHOW_ONE:-100}"
WIDTH_SHOW_TWO="${STASYSMO_WIDTH_SHOW_TWO:-120}"
WIDTH_SHOW_THREE="${STASYSMO_WIDTH_SHOW_THREE:-150}"

# Calculate dynamic budget based on terminal width
# Returns: number of metrics to show (0-4)
# Strategy: Gracefully reduce metrics as terminal narrows to preserve prompt
calculate_metric_slots() {
  local cols="$1"

  if [[ "$cols" -lt "$WIDTH_HIDE_ALL" ]]; then
    echo 0 # Hide completely - preserve prompt
  elif [[ "$cols" -lt "$WIDTH_SHOW_ONE" ]]; then
    echo 1 # CPU only
  elif [[ "$cols" -lt "$WIDTH_SHOW_TWO" ]]; then
    echo 2 # CPU + RAM
  elif [[ "$cols" -lt "$WIDTH_SHOW_THREE" ]]; then
    echo 3 # CPU + RAM + Load
  else
    echo 4 # All metrics
  fi
}

main() {
  # Get actual terminal width
  local cols
  cols=$(get_terminal_width)

  # Calculate how many metrics we can show
  local max_metrics
  max_metrics=$(calculate_metric_slots "$cols")

  # If terminal too narrow, show nothing - exit non-zero so Starship skips module
  if [[ "$max_metrics" -eq 0 ]]; then
    exit 1
  fi

  # Check if sysmon directory exists
  if [[ ! -d "$STASYSMO_DIR" ]]; then
    exit 0 # Daemon not running, graceful exit
  fi

  # Check staleness
  local timestamp
  timestamp=$(read_metric "$STASYSMO_DIR/timestamp" "0")
  local now
  now=$(date +%s)
  local age=$((now - timestamp))

  if [[ "$age" -gt "$STALE_THRESHOLD" ]]; then
    # Data is stale, show indicator
    printf '%s?%s' "$(ansi_color "$COLOR_MUTED")" "$(ansi_reset)"
    exit 0
  fi

  # Read metrics
  local cpu ram swap load
  cpu=$(read_metric "$STASYSMO_DIR/cpu" "?")
  ram=$(read_metric "$STASYSMO_DIR/ram" "?")
  swap=$(read_metric "$STASYSMO_DIR/swap" "?")
  load=$(read_metric "$STASYSMO_DIR/load" "?")

  # Build metrics array with priorities (higher = more important)
  # Format: "priority|formatted_string"
  declare -a metrics=()

  # CPU (priority 100 - highest, always first to show)
  local cpu_color
  cpu_color=$(get_color_int "$cpu" "$CPU_ELEVATED" "$CPU_CRITICAL")
  metrics+=("100|$(format_metric "$ICON_CPU" "$cpu" "%" "$cpu_color")")

  # RAM
  local ram_color
  ram_color=$(get_color_int "$ram" "$RAM_ELEVATED" "$RAM_CRITICAL")
  metrics+=("90|$(format_metric "$ICON_RAM" "$ram" "%" "$ram_color")")

  # Load
  local load_color
  load_color=$(get_color_float "$load" "$LOAD_ELEVATED" "$LOAD_CRITICAL")
  metrics+=("70|$(format_metric "$ICON_LOAD" "$load" "" "$load_color")")

  # Swap (only show if > 0)
  if [[ "$swap" != "?" && "$swap" != "0" ]]; then
    local swap_color
    swap_color=$(get_color_int "$swap" "$SWAP_ELEVATED" "$SWAP_CRITICAL")
    metrics+=("60|$(format_metric "$ICON_SWAP" "$swap" "%" "$swap_color")")
  fi

  # Sort by priority (descending) and build output
  # Respect both character budget AND terminal-width-based slot limit
  local output=""
  local current_width=0
  local metric_count=0
  local separator="$SPACER_METRICS" # Configurable spacer between metrics

  # Sort metrics by priority (highest first)
  # Using while loop for bash 3.2 compatibility (macOS)
  while IFS= read -r item; do
    # Stop if we've reached the terminal-width-based limit
    if [[ "$metric_count" -ge "$max_metrics" ]]; then
      break
    fi

    local formatted="${item#*|}" # Remove priority prefix
    local item_width
    item_width=$(visible_width "$formatted")

    # Add separator width if not first item
    local sep_width=0
    if [[ -n "$output" ]]; then
      sep_width=${#separator}
    fi

    # Check if adding this item would exceed character budget
    if [[ $((current_width + item_width + sep_width)) -le "$MAX_BUDGET" ]]; then
      if [[ -n "$output" ]]; then
        output="${output}${separator}${formatted}"
      else
        output="$formatted"
      fi
      current_width=$((current_width + item_width + sep_width))
      metric_count=$((metric_count + 1))
    fi
  done < <(printf '%s\n' "${metrics[@]}" | sort -t'|' -k1 -rn)

  # Output final string
  echo -e "$output"
}

main "$@"
