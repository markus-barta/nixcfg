#!/bin/bash
# Timestamped ping output with dark gray formatting
# Usage: pingt <host> [ping options]

# Configuration
readonly COLOR_GRAY='\033[38;5;240m' # Dark gray (256-color)
# readonly COLOR_GRAY_ALT='\033[2;37m' # Alternative: dim white (unused)
readonly COLOR_RESET='\033[0m'
readonly SEPARATOR='·' # Middle dot, alternatives: • │ ▪ ▸ →

ping "$@" | while IFS= read -r line; do
  printf "${COLOR_GRAY}%(%H:%M:%S)T ${SEPARATOR}${COLOR_RESET} %s\n" -1 "$line"
done
