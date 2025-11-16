#!/bin/bash
# Timestamped ping output with dark gray formatting
# Usage: pingt <host> [ping options]

# Configuration
readonly COLOR_GRAY='\033[38;5;240m' # Dark gray (256-color)
# readonly COLOR_GRAY_ALT='\033[2;37m' # Alternative: dim white (unused)
readonly COLOR_RESET='\033[0m'
readonly SEPARATOR='·' # Middle dot, alternatives: • │ ▪ ▸ →

ping "$@" | while IFS= read -r line; do
  timestamp=$(date '+%H:%M:%S')
  printf "${COLOR_GRAY}%s ${SEPARATOR}${COLOR_RESET} %s\n" "$timestamp" "$line"
done
