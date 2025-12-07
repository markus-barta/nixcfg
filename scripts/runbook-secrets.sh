#!/usr/bin/env bash
#
# Runbook Secrets Manager
# Encrypt/decrypt per-host runbook-secrets.md files
#
# Usage:
#   ./scripts/runbook-secrets.sh encrypt [host]   # Encrypt one or all hosts
#   ./scripts/runbook-secrets.sh decrypt [host]   # Decrypt one or all hosts
#   ./scripts/runbook-secrets.sh list             # List hosts with secrets
#
# Files:
#   hosts/<host>/secrets/runbook-secrets.md  - Plain text (gitignored)
#   hosts/<host>/runbook-secrets.age         - Encrypted (committed)

set -euo pipefail

# Base Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Theme palettes path (set after REPO_ROOT is defined)
THEME_PALETTES=""

# Cached JSON from nix eval (loaded once)
HOST_THEME_JSON=""

# Convert hex color to ANSI true color escape sequence
hex_to_ansi() {
  local hex="${1#\#}"
  local r=$((16#${hex:0:2}))
  local g=$((16#${hex:2:2}))
  local b=$((16#${hex:4:2}))
  printf '\033[38;2;%d;%d;%dm' "$r" "$g" "$b"
}

# Load host colors from theme-palettes.nix via nix eval (called once)
load_host_colors() {
  if [[ ! -f "$THEME_PALETTES" ]]; then
    return
  fi

  # Get host data (host -> {color, category, bullet})
  local hosts_json categories_json
  # shellcheck disable=SC2016  # Single quotes intentional - Nix interpolation, not bash
  hosts_json=$(nix eval --json --file "$THEME_PALETTES" --apply \
    'p: builtins.mapAttrs (host: pal: { color = p.palettes.${pal}.gradient.primary; category = p.palettes.${pal}.category; bullet = p.categoryBullets.${p.palettes.${pal}.category} or "○"; }) p.hostPalette' \
    2>/dev/null) || hosts_json="{}"

  # Get category data (category -> {color, bullet})
  # Uses representative colors: cloud=iceBlue, home=yellow, gaming=purple, workstation=lightGray
  categories_json=$(nix eval --json --file "$THEME_PALETTES" --apply \
    'p: { cloud = { bullet = p.categoryBullets.cloud; color = p.palettes.iceBlue.gradient.primary; }; home = { bullet = p.categoryBullets.home; color = p.palettes.yellow.gradient.primary; }; gaming = { bullet = p.categoryBullets.gaming; color = p.palettes.purple.gradient.primary; }; workstation = { bullet = p.categoryBullets.workstation; color = p.palettes.lightGray.gradient.primary; }; }' \
    2>/dev/null) || categories_json="{}"

  # Get default color
  local default_color
  # shellcheck disable=SC2016  # Single quotes intentional - Nix interpolation, not bash
  default_color=$(nix eval --raw --file "$THEME_PALETTES" --apply \
    'p: p.palettes.${p.defaultPalette}.gradient.primary' \
    2>/dev/null) || default_color="#769ff0"

  # Combine into single JSON
  HOST_THEME_JSON=$(jq -n \
    --argjson hosts "$hosts_json" \
    --argjson categories "$categories_json" \
    --arg defaultColor "$default_color" \
    '{hosts: $hosts, categories: $categories, defaultColor: $defaultColor}')
}

# Get host data from cached JSON
get_host_data() {
  local host="$1"
  local field="$2"
  if [[ -n "$HOST_THEME_JSON" ]]; then
    echo "$HOST_THEME_JSON" | jq -r ".hosts.\"$host\".$field // empty"
  fi
}

# Get ANSI color for a host
get_host_color() {
  local host="$1"
  local hex
  hex=$(get_host_data "$host" "color")
  if [[ -n "$hex" ]]; then
    hex_to_ansi "$hex"
  else
    # Fallback: default palette color
    hex=$(echo "$HOST_THEME_JSON" | jq -r '.defaultColor // "#769ff0"')
    hex_to_ansi "$hex"
  fi
}

# Get bullet symbol for a host
get_host_bullet() {
  local host="$1"
  local bullet
  bullet=$(get_host_data "$host" "bullet")
  echo "${bullet:-○}"
}

# Get category for a host
get_host_category() {
  local host="$1"
  local cat
  cat=$(get_host_data "$host" "category")
  echo "${cat:-unknown}"
}

# Get category color and bullet for legend
get_category_data() {
  local cat="$1"
  local field="$2"
  if [[ -n "$HOST_THEME_JSON" ]]; then
    echo "$HOST_THEME_JSON" | jq -r ".categories.\"$cat\".$field // empty"
  fi
}

# Config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOSTS_DIR="$REPO_ROOT/hosts"
AGE_KEY="${AGE_KEY:-$HOME/.ssh/id_rsa}"
THEME_PALETTES="$REPO_ROOT/modules/uzumaki/theme/theme-palettes.nix"

# Initialize host colors from Nix config
load_host_colors

# Check for age command
check_age() {
  if ! command -v age &>/dev/null; then
    echo -e "${RED}Error: 'age' command not found${NC}"
    echo "Run via: just encrypt-runbook-secrets (uses nix-shell)"
    exit 1
  fi
}

# Find all hosts with runbook secrets (either .md or .age)
find_hosts() {
  local hosts=()

  for host_dir in "$HOSTS_DIR"/*/; do
    local host
    host=$(basename "$host_dir")
    # Skip non-host directories
    [[ "$host" == "archived" ]] && continue
    [[ "$host" == "README.md" ]] && continue
    [[ ! -d "$host_dir" ]] && continue

    local md_file="$host_dir/secrets/runbook-secrets.md"
    local age_file="$host_dir/runbook-secrets.age"

    if [[ -f "$md_file" ]] || [[ -f "$age_file" ]]; then
      hosts+=("$host")
    fi
  done

  printf '%s\n' "${hosts[@]}"
}

# Get file modification time as epoch seconds
get_mtime() {
  local file="$1"
  if [[ -f "$file" ]]; then
    # macOS uses -f %m, Linux uses -c %Y
    local result
    result=$(stat -f %m "$file" 2>/dev/null) || result=$(stat -c %Y "$file" 2>/dev/null) || result="0"
    echo "$result"
  else
    echo "0"
  fi
}

# Format timestamp for display (full format: YYYY-MM-DD HH:MM:SS)
format_time() {
  local file="$1"
  if [[ -f "$file" ]]; then
    # macOS uses -r, Linux uses -d
    local result
    result=$(date -r "$file" "+%Y-%m-%d %H:%M:%S" 2>/dev/null) || result=$(date -d "@$(stat -c %Y "$file" 2>/dev/null)" "+%Y-%m-%d %H:%M:%S" 2>/dev/null) || result=""
    echo "$result"
  else
    echo ""
  fi
}

# List hosts with their secret status
cmd_list() {
  echo ""
  echo -e "  ${BOLD}Runbook Secrets Status${NC}"
  echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  # Header (aligned with data: 2 indent + bullet + 2 space + 15 host + 2 gap + 21 plain + 2 gap + encrypted)
  printf "       ${DIM}%-15s${NC}  ${DIM}%-21s${NC}  ${DIM}%s${NC}\n" "HOST" "PLAIN (.md)" "ENCRYPTED (.age)"
  printf "  %b─%b  %b───────────────%b  %b─────────────────────%b  %b─────────────────────%b\n" "$DIM" "$NC" "$DIM" "$NC" "$DIM" "$NC" "$DIM" "$NC"
  echo ""

  for host_dir in "$HOSTS_DIR"/*/; do
    local host
    host=$(basename "$host_dir")
    [[ "$host" == "archived" ]] && continue
    [[ ! -d "$host_dir" ]] && continue

    local md_file="$host_dir/secrets/runbook-secrets.md"
    local age_file="$host_dir/runbook-secrets.age"

    # Only show if at least one exists
    if [[ -f "$md_file" ]] || [[ -f "$age_file" ]]; then
      local md_time age_time md_epoch age_epoch
      md_epoch=$(get_mtime "$md_file")
      age_epoch=$(get_mtime "$age_file")
      md_time=$(format_time "$md_file")
      age_time=$(format_time "$age_file")

      # Get host styling
      local host_color bullet
      host_color=$(get_host_color "$host")
      bullet=$(get_host_bullet "$host")

      # Determine which is older (older = stale = gray, newer = green)
      local md_color_ts="$GREEN"
      local age_color_ts="$GREEN"

      if [[ -f "$md_file" ]] && [[ -f "$age_file" ]]; then
        if [[ "$md_epoch" -lt "$age_epoch" ]]; then
          md_color_ts="$GRAY"
        elif [[ "$age_epoch" -lt "$md_epoch" ]]; then
          age_color_ts="$GRAY"
        fi
      fi

      # Print bullet and host (2 indent + bullet + 2 space + 15 char host)
      printf "  %b%s%b  " "$host_color" "$bullet" "$NC"
      printf "%b%-15s%b  " "$host_color" "$host" "$NC"

      # Print plain (.md) column (21 chars wide)
      if [[ -f "$md_file" ]]; then
        # "✓ " = 2 chars, timestamp = 19 chars = 21 total
        printf "%b✓ %s%b  " "$md_color_ts" "$md_time" "$NC"
      else
        printf "%b✗%b                      " "$RED" "$NC"
      fi

      # Print encrypted (.age) column
      if [[ -f "$age_file" ]]; then
        printf "%b✓ %s%b" "$age_color_ts" "$age_time" "$NC"
      else
        printf "%b✗%b  ${GRAY}not encrypted${NC}" "$RED" "$NC"
      fi

      echo ""
    fi
  done

  echo ""

  # Build legend from categories (all in gray except bullets)
  local legend="  ${GRAY}Legend:${NC} "
  for cat in cloud home gaming workstation; do
    local hex bullet color
    hex=$(get_category_data "$cat" "color")
    bullet=$(get_category_data "$cat" "bullet")
    if [[ -n "$hex" ]]; then
      color=$(hex_to_ansi "$hex")
      legend+="${color}${bullet}${NC} ${GRAY}${cat}${NC}  "
    fi
  done

  echo -e "$legend"
  echo ""
}

# Encrypt a single host's secrets
encrypt_host() {
  local host="$1"
  local md_file="$HOSTS_DIR/$host/secrets/runbook-secrets.md"
  local age_file="$HOSTS_DIR/$host/runbook-secrets.age"

  if [[ ! -f "$md_file" ]]; then
    echo -e "${YELLOW}Skip: $host - no plain text file${NC}"
    return 0
  fi

  # Check if age file exists and is newer
  if [[ -f "$age_file" ]]; then
    if [[ "$age_file" -nt "$md_file" ]]; then
      echo -e "${YELLOW}Skip: $host - .age is newer than .md${NC}"
      return 0
    fi
  fi

  echo -e "${BLUE}Encrypting: $host${NC}"

  # Convert SSH key to age format and encrypt
  age -R "$AGE_KEY.pub" -o "$age_file" "$md_file"

  echo -e "${GREEN}✓ Created: $age_file${NC}"
}

# Decrypt a single host's secrets
decrypt_host() {
  local host="$1"
  local md_file="$HOSTS_DIR/$host/secrets/runbook-secrets.md"
  local age_file="$HOSTS_DIR/$host/runbook-secrets.age"

  if [[ ! -f "$age_file" ]]; then
    echo -e "${YELLOW}Skip: $host - no encrypted file${NC}"
    return 0
  fi

  # Safety check: don't overwrite existing .md without confirmation
  if [[ -f "$md_file" ]]; then
    echo -e "${YELLOW}Warning: $md_file already exists${NC}"
    read -p "Overwrite? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo -e "${YELLOW}Skipped${NC}"
      return 0
    fi
  fi

  echo -e "${BLUE}Decrypting: $host${NC}"

  # Ensure secrets directory exists
  mkdir -p "$HOSTS_DIR/$host/secrets"

  # Decrypt using SSH key
  age -d -i "$AGE_KEY" -o "$md_file" "$age_file"

  echo -e "${GREEN}✓ Created: $md_file${NC}"
}

# Encrypt command
cmd_encrypt() {
  local host="${1:-}"

  check_age

  if [[ -n "$host" ]]; then
    # Single host
    if [[ ! -d "$HOSTS_DIR/$host" ]]; then
      echo -e "${RED}Error: Host '$host' not found${NC}"
      exit 1
    fi
    encrypt_host "$host"
  else
    # All hosts
    echo -e "${BLUE}Encrypting all hosts...${NC}"
    echo ""

    local hosts
    mapfile -t hosts < <(find_hosts)

    if [[ ${#hosts[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No hosts with runbook secrets found${NC}"
      exit 0
    fi

    for host in "${hosts[@]}"; do
      encrypt_host "$host"
    done
  fi

  echo ""
  echo -e "${GREEN}Done!${NC}"
}

# Decrypt command
cmd_decrypt() {
  local host="${1:-}"

  check_age

  if [[ -n "$host" ]]; then
    # Single host
    if [[ ! -d "$HOSTS_DIR/$host" ]]; then
      echo -e "${RED}Error: Host '$host' not found${NC}"
      exit 1
    fi
    decrypt_host "$host"
  else
    # All hosts
    echo -e "${BLUE}Decrypting all hosts...${NC}"
    echo ""

    local hosts
    mapfile -t hosts < <(find_hosts)

    if [[ ${#hosts[@]} -eq 0 ]]; then
      echo -e "${YELLOW}No hosts with runbook secrets found${NC}"
      exit 0
    fi

    for host in "${hosts[@]}"; do
      decrypt_host "$host"
    done
  fi

  echo ""
  echo -e "${GREEN}Done!${NC}"
}

# Help
cmd_help() {
  echo "Runbook Secrets Manager"
  echo ""
  echo "Usage:"
  echo "  $0 encrypt [host]   Encrypt plain text to .age"
  echo "  $0 decrypt [host]   Decrypt .age to plain text"
  echo "  $0 list             List hosts with secrets"
  echo "  $0 help             Show this help"
  echo ""
  echo "Environment:"
  echo "  AGE_KEY             Path to SSH private key (default: ~/.ssh/id_rsa)"
  echo ""
  echo "Files:"
  echo "  hosts/<host>/secrets/runbook-secrets.md  - Plain text (gitignored)"
  echo "  hosts/<host>/runbook-secrets.age         - Encrypted (committed)"
}

# Main
case "${1:-help}" in
encrypt)
  cmd_encrypt "${2:-}"
  ;;
decrypt)
  cmd_decrypt "${2:-}"
  ;;
list)
  cmd_list
  ;;
help | --help | -h)
  cmd_help
  ;;
*)
  echo -e "${RED}Unknown command: $1${NC}"
  cmd_help
  exit 1
  ;;
esac
