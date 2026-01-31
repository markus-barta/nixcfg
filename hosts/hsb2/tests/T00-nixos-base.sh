#!/usr/bin/env bash
set -e

echo "=========================================="
echo "Test T00: NixOS Base System"
echo "Host: hsb2"
echo "=========================================="
echo ""

# Test variables
IP="192.168.1.95"
SSH_USER="mba"

echo "1. Testing SSH connectivity to hsb2..."
if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "${SSH_USER}@${IP}" "echo 'SSH OK'" >/dev/null 2>&1; then
  echo "   ✓ SSH connection successful"
else
  echo "   ✗ SSH connection failed"
  exit 1
fi

echo ""
echo "2. Checking NixOS version..."
ssh "${SSH_USER}@${IP}" "nixos-version || echo 'Not a NixOS system'"

echo ""
echo "3. Checking system uptime..."
ssh "${SSH_USER}@${IP}" "uptime"

echo ""
echo "4. Checking disk usage..."
ssh "${SSH_USER}@${IP}" "df -h /"

echo ""
echo "5. Checking memory usage..."
ssh "${SSH_USER}@${IP}" "free -h"

echo ""
echo "=========================================="
echo "Test T00 completed successfully"
echo "=========================================="
