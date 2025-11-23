#!/bin/bash
# Timestamped ping output with dark gray formatting and color-coded errors
# Usage: pingt <host> [ping options]

# Configuration
readonly COLOR_GRAY='\033[38;5;240m'   # Dark gray (256-color)
readonly COLOR_YELLOW='\033[38;5;136m' # Dark yellow for timeouts
readonly COLOR_RED='\033[38;5;167m'    # Dark red for errors
readonly COLOR_RESET='\033[0m'
readonly SEPARATOR='·' # Middle dot, alternatives: • │ ▪ ▸ →

ping "$@" 2>&1 | while IFS= read -r line; do
  timestamp=$(date '+%H:%M:%S')

  # Determine line color based on content
  if [[ "$line" =~ "timeout" ]] || [[ "$line" =~ "Request timeout" ]]; then
    # Timeout messages in dark yellow
    printf "${COLOR_GRAY}%s ${SEPARATOR}${COLOR_RESET} ${COLOR_YELLOW}%s${COLOR_RESET}\n" "$timestamp" "$line"
  elif [[ "$line" =~ "sendto:" ]] || [[ "$line" =~ "No route to host" ]] || [[ "$line" =~ "Host is down" ]] || [[ "$line" =~ "Destination Host Unreachable" ]]; then
    # Error messages in dark red
    printf "${COLOR_GRAY}%s ${SEPARATOR}${COLOR_RESET} ${COLOR_RED}%s${COLOR_RESET}\n" "$timestamp" "$line"
  else
    # Normal output (no color)
    printf "${COLOR_GRAY}%s ${SEPARATOR}${COLOR_RESET} %s\n" "$timestamp" "$line"
  fi
done
