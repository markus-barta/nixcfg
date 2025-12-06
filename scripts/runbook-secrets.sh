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

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Config
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOSTS_DIR="$REPO_ROOT/hosts"
AGE_KEY="${AGE_KEY:-$HOME/.ssh/id_rsa}"

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

# List hosts with their secret status
cmd_list() {
  echo -e "${BLUE}Hosts with runbook secrets:${NC}"
  echo ""
  printf "%-20s %-15s %-15s\n" "HOST" "PLAIN (.md)" "ENCRYPTED (.age)"
  printf "%-20s %-15s %-15s\n" "----" "-----------" "-----------------"

  for host_dir in "$HOSTS_DIR"/*/; do
    local host
    host=$(basename "$host_dir")
    [[ "$host" == "archived" ]] && continue
    [[ ! -d "$host_dir" ]] && continue

    local md_file="$host_dir/secrets/runbook-secrets.md"
    local age_file="$host_dir/runbook-secrets.age"

    local md_status="${RED}✗${NC}"
    local age_status="${RED}✗${NC}"

    [[ -f "$md_file" ]] && md_status="${GREEN}✓${NC}"
    [[ -f "$age_file" ]] && age_status="${GREEN}✓${NC}"

    # Only show if at least one exists
    if [[ -f "$md_file" ]] || [[ -f "$age_file" ]]; then
      printf "%-20s %-15b %-15b\n" "$host" "$md_status" "$age_status"
    fi
  done
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
