#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2086
#
# 01: Pre-Migration Snapshot
# Captures system state before migration
#

set -euo pipefail

HOST="${CSB0_HOST:-cs0.barta.cm}"
SSH_USER="${CSB0_USER:-mba}"
SSH_PORT="${CSB0_SSH_PORT:-2222}"
SSH_TIMEOUT="${SSH_TIMEOUT:-10}"
CMD_TIMEOUT="${CMD_TIMEOUT:-60}"

SSH_OPTS="-o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

if command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout $CMD_TIMEOUT"
elif command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout $CMD_TIMEOUT"
else
  TIMEOUT_CMD=""
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_DIR="$SCRIPT_DIR/snapshots"
TIMESTAMP=$(date +%Y-%m-%d-%H%M%S)
SNAPSHOT_FILE="$SNAPSHOT_DIR/pre-migration-$TIMESTAMP.json"

mkdir -p "$SNAPSHOT_DIR"

echo "=== 01: Pre-Migration Snapshot ==="
echo "Host: $HOST (port $SSH_PORT)"
echo "Output: $SNAPSHOT_FILE"
echo

# Collect system information
echo "Collecting system information..."

NIXOS_VERSION=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'nixos-version' 2>/dev/null || echo "unknown")
KERNEL=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'uname -r' 2>/dev/null || echo "unknown")
UPTIME=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'uptime -p' 2>/dev/null || echo "unknown")
GENERATION=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'readlink /nix/var/nix/profiles/system | grep -oP "system-\K[0-9]+"' 2>/dev/null || echo "0")

echo "  NixOS: $NIXOS_VERSION"
echo "  Kernel: $KERNEL"
echo "  Uptime: $UPTIME"
echo "  Generation: $GENERATION"

# Collect Docker information
echo "Collecting Docker information..."
CONTAINER_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps -q | wc -l' 2>/dev/null | tr -d ' ' || echo "0")
VOLUME_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker volume ls -q | wc -l' 2>/dev/null | tr -d ' ' || echo "0")

echo "  Containers: $CONTAINER_COUNT"
echo "  Volumes: $VOLUME_COUNT"

# Container list
CONTAINERS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'docker ps --format "{{.Names}}"' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")

# Service URLs
echo "Checking service URLs..."
NODERED_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "https://home.barta.cm" 2>/dev/null || echo "000")

# ZFS info
ZFS_HEALTH=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zpool status -x 2>/dev/null | head -1' 2>/dev/null || echo "unknown")
ZFS_USAGE=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'sudo zpool list -H -o capacity 2>/dev/null | head -1' 2>/dev/null || echo "unknown")

# SSH keys
SSH_KEY_COUNT=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'cat ~/.ssh/authorized_keys 2>/dev/null | grep -c "^ssh-" || echo 0' 2>/dev/null | tr -d '\n\r' || echo "0")
OMEGA_KEYS=$($TIMEOUT_CMD ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_USER@$HOST" 'cat ~/.ssh/authorized_keys 2>/dev/null | grep -c "omega" || echo 0' 2>/dev/null | tr -d '\n\r' || echo "0")

# Write snapshot
cat >"$SNAPSHOT_FILE" <<EOF
{
  "timestamp": "$TIMESTAMP",
  "host": "$HOST",
  "system": {
    "nixos_version": "$NIXOS_VERSION",
    "kernel": "$KERNEL",
    "uptime": "$UPTIME",
    "generation": "$GENERATION"
  },
  "docker": {
    "container_count": $CONTAINER_COUNT,
    "volume_count": $VOLUME_COUNT,
    "containers": "$CONTAINERS"
  },
  "services": {
    "nodered_http": "$NODERED_STATUS"
  },
  "zfs": {
    "health": "$ZFS_HEALTH",
    "usage": "$ZFS_USAGE"
  },
  "ssh": {
    "key_count": $SSH_KEY_COUNT,
    "omega_keys": $OMEGA_KEYS
  }
}
EOF

echo
echo "=========================================="
echo "✅ Snapshot saved to: $SNAPSHOT_FILE"
echo
cat "$SNAPSHOT_FILE"
