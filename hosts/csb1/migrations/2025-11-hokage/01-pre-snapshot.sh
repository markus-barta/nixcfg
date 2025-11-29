#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086,SC2129,SC2016
#
# T08: Pre-Migration Snapshot
# Captures current system state for before/after comparison
#

set -euo pipefail

# Configuration
HOST="${CSB1_HOST:-cs1.barta.cm}"
SSH_USER="${CSB1_USER:-mba}"
SSH_PORT="${CSB1_SSH_PORT:-2222}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
CMD_TIMEOUT="${CMD_TIMEOUT:-30}"

# SSH options with timeout
SSH_OPTS="-o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=5 -o ServerAliveCountMax=3"

# Timeout command (use gtimeout on macOS if available, otherwise skip)
if command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout $CMD_TIMEOUT"
elif command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout $CMD_TIMEOUT"
else
  TIMEOUT_CMD=""
fi

# Output directory and file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_DIR="$SCRIPT_DIR/snapshots"
TIMESTAMP=$(date +"%Y-%m-%d-%H%M%S")
SNAPSHOT_FILE="$SNAPSHOT_DIR/pre-migration-$TIMESTAMP.json"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "=== T08: Pre-Migration Snapshot ==="
echo "Host: $HOST (port $SSH_PORT)"
echo "Timestamp: $TIMESTAMP"
echo

# Create snapshot directory
mkdir -p "$SNAPSHOT_DIR"

# Start JSON
echo "{" >"$SNAPSHOT_FILE"
echo "  \"timestamp\": \"$TIMESTAMP\"," >>"$SNAPSHOT_FILE"
echo "  \"host\": \"$HOST\"," >>"$SNAPSHOT_FILE"

# Collect system info
echo -n "Collecting system info... "
NIXOS_VERSION=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'nixos-version' 2>/dev/null || echo "unknown")
KERNEL=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'uname -r' 2>/dev/null || echo "unknown")
UPTIME=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'uptime -p' 2>/dev/null || echo "unknown")
GEN_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'ls -1 /nix/var/nix/profiles/ | grep -c "system-.*-link"' 2>/dev/null || echo "0")
CURRENT_GEN=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'readlink /nix/var/nix/profiles/system | grep -oP "system-\K[0-9]+"' 2>/dev/null || echo "unknown")
echo -e "${GREEN}✅${NC}"

echo "  \"system\": {" >>"$SNAPSHOT_FILE"
echo "    \"nixos_version\": \"$NIXOS_VERSION\"," >>"$SNAPSHOT_FILE"
echo "    \"kernel\": \"$KERNEL\"," >>"$SNAPSHOT_FILE"
echo "    \"uptime\": \"$UPTIME\"," >>"$SNAPSHOT_FILE"
echo "    \"generation_count\": $GEN_COUNT," >>"$SNAPSHOT_FILE"
echo "    \"current_generation\": \"$CURRENT_GEN\"" >>"$SNAPSHOT_FILE"
echo "  }," >>"$SNAPSHOT_FILE"

# Collect Docker containers
echo -n "Collecting Docker containers... "
CONTAINERS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps --format "{{.Names}}:{{.Image}}:{{.Status}}" | sort' 2>/dev/null || echo "")
CONTAINER_COUNT=$(echo "$CONTAINERS" | grep -c ":" || echo "0")
echo -e "${GREEN}✅${NC} ($CONTAINER_COUNT containers)"

echo "  \"containers\": [" >>"$SNAPSHOT_FILE"
FIRST=true
while IFS= read -r line; do
  if [ -n "$line" ]; then
    NAME=$(echo "$line" | cut -d: -f1)
    IMAGE=$(echo "$line" | cut -d: -f2)
    STATUS=$(echo "$line" | cut -d: -f3-)
    if [ "$FIRST" = true ]; then
      FIRST=false
    else
      echo "," >>"$SNAPSHOT_FILE"
    fi
    echo -n "    {\"name\": \"$NAME\", \"image\": \"$IMAGE\", \"status\": \"$STATUS\"}" >>"$SNAPSHOT_FILE"
  fi
done <<<"$CONTAINERS"
echo "" >>"$SNAPSHOT_FILE"
echo "  ]," >>"$SNAPSHOT_FILE"

# Collect Docker volumes
echo -n "Collecting Docker volumes... "
VOLUMES=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker volume ls -q | sort' 2>/dev/null || echo "")
VOLUME_COUNT=$(echo "$VOLUMES" | grep -c "." || echo "0")
echo -e "${GREEN}✅${NC} ($VOLUME_COUNT volumes)"

echo "  \"volumes\": [" >>"$SNAPSHOT_FILE"
FIRST=true
while IFS= read -r vol; do
  if [ -n "$vol" ]; then
    if [ "$FIRST" = true ]; then
      FIRST=false
    else
      echo "," >>"$SNAPSHOT_FILE"
    fi
    echo -n "    \"$vol\"" >>"$SNAPSHOT_FILE"
  fi
done <<<"$VOLUMES"
echo "" >>"$SNAPSHOT_FILE"
echo "  ]," >>"$SNAPSHOT_FILE"

# Collect service URLs
echo -n "Checking service URLs... "

echo "  \"services\": {" >>"$SNAPSHOT_FILE"

# Check Grafana
GRAFANA_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "https://grafana.barta.cm" 2>/dev/null || echo "000")
echo "    \"grafana\": {\"url\": \"https://grafana.barta.cm\", \"http_code\": \"$GRAFANA_CODE\"}," >>"$SNAPSHOT_FILE"

# Check Docmost
DOCMOST_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "https://docmost.barta.cm" 2>/dev/null || echo "000")
echo "    \"docmost\": {\"url\": \"https://docmost.barta.cm\", \"http_code\": \"$DOCMOST_CODE\"}," >>"$SNAPSHOT_FILE"

# Check Paperless
PAPERLESS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "https://paperless.barta.cm" 2>/dev/null || echo "000")
echo "    \"paperless\": {\"url\": \"https://paperless.barta.cm\", \"http_code\": \"$PAPERLESS_CODE\"}" >>"$SNAPSHOT_FILE"

echo "  }," >>"$SNAPSHOT_FILE"
echo -e "${GREEN}✅${NC}"

# Collect ZFS info
echo -n "Collecting ZFS info... "
ZFS_POOL=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zpool list -H -o name,size,alloc,free,cap,health 2>/dev/null | head -1' 2>/dev/null || echo "unknown")
ZFS_COMPRESS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zfs get -H compressratio 2>/dev/null | head -1 | awk "{print \$3}"' 2>/dev/null || echo "unknown")
echo -e "${GREEN}✅${NC}"

echo "  \"zfs\": {" >>"$SNAPSHOT_FILE"
echo "    \"pool_info\": \"$ZFS_POOL\"," >>"$SNAPSHOT_FILE"
echo "    \"compress_ratio\": \"$ZFS_COMPRESS\"" >>"$SNAPSHOT_FILE"
echo "  }," >>"$SNAPSHOT_FILE"

# Collect SSH key count
echo -n "Collecting SSH key info... "
SSH_KEY_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'cat ~/.ssh/authorized_keys 2>/dev/null | grep -c "^ssh-" || echo 0' 2>/dev/null || echo "0")
echo -e "${GREEN}✅${NC} ($SSH_KEY_COUNT keys)"

echo "  \"security\": {" >>"$SNAPSHOT_FILE"
echo "    \"ssh_key_count\": $SSH_KEY_COUNT" >>"$SNAPSHOT_FILE"
echo "  }" >>"$SNAPSHOT_FILE"

# Close JSON
echo "}" >>"$SNAPSHOT_FILE"

echo
echo -e "${GREEN}🎉 Snapshot saved to:${NC}"
echo -e "${BLUE}$SNAPSHOT_FILE${NC}"
echo
echo "Contents preview:"
head -30 "$SNAPSHOT_FILE"
echo "..."
echo
echo -e "${YELLOW}Keep this file for post-migration comparison with T09!${NC}"

exit 0
