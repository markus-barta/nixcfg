#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                  T06 - Storage & Mounts Automated Tests                       ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Host: hsb1
# Feature: ZFS health & Fritz!Box SMB automount
#
# Usage: ./T06-storage-mounts.sh
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0
TOTAL=0

# ════════════════════════════════════════════════════════════════════════════════
# Helper Functions
# ════════════════════════════════════════════════════════════════════════════════

print_header() {
  echo ""
  echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
}

print_test() {
  echo -e "\n${YELLOW}▶ $1${NC}"
  ((TOTAL++)) || true
}

pass() {
  echo -e "${GREEN}  ✅ PASS: $1${NC}"
  ((PASSED++)) || true
}

fail() {
  echo -e "${RED}  ❌ FAIL: $1${NC}"
  ((FAILED++)) || true
}

# ════════════════════════════════════════════════════════════════════════════════
# Test Suite
# ════════════════════════════════════════════════════════════════════════════════

print_header "T06 - Storage & Mounts Tests (hsb1)"

echo "Host: $(hostname)"
echo "Date: $(date)"

# ────────────────────────────────────────────────────────────────────────────────
# T06.1 - ZFS Health
# ────────────────────────────────────────────────────────────────────────────────

print_test "T06.1 - ZFS Status"
if zpool status >/dev/null 2>&1; then
  if zpool status | grep -q "ONLINE" && ! zpool status | grep -qi "DEGRADED\|FAULTED"; then
    pass "ZFS pools are ONLINE and healthy"
  else
    fail "ZFS pool issue detected! Check 'zpool status'"
  fi
else
  fail "zpool command failed or no pools found"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T06.2 - Fritz!Box SMB Mount Config
# ────────────────────────────────────────────────────────────────────────────────

print_test "T06.2 - Fritz!Box SMB Config"
MOUNT_POINT="/mnt/fritzbox-media"
if grep -q "$MOUNT_POINT" /etc/fstab; then
  pass "Mount point $MOUNT_POINT exists in fstab"
  if grep "$MOUNT_POINT" /etc/fstab | grep -q "x-systemd.automount"; then
    pass "Automount is enabled for $MOUNT_POINT"
  else
    fail "Automount NOT found in fstab for $MOUNT_POINT"
  fi
else
  fail "Mount point $MOUNT_POINT NOT found in fstab"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T06.3 - SMB Credentials
# ────────────────────────────────────────────────────────────────────────────────

print_test "T06.3 - SMB Credentials"
# agenix secret path
CREDS_FILE="/run/agenix/fritzbox-smb-credentials"
if [[ -f "$CREDS_FILE" ]]; then
  pass "Credentials file exists at $CREDS_FILE"
  # Check if root-readable only
  PERMS=$(stat -c "%a" "$CREDS_FILE")
  if [[ "$PERMS" == "400" ]]; then
    pass "Credentials file has secure permissions (400)"
  else
    fail "Credentials file has insecure permissions ($PERMS)"
  fi
else
  fail "Credentials file missing at $CREDS_FILE"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T06.4 - Mount Connectivity (Optional/Soft-Fail)
# ────────────────────────────────────────────────────────────────────────────────

print_test "T06.4 - SMB Connectivity Check"
# We don't want to fail the whole test if the Fritz!Box is just offline
# but we want to know if it's currently mounted or accessible
if mountpoint -q "$MOUNT_POINT"; then
  pass "$MOUNT_POINT is currently mounted"
else
  echo -e "${YELLOW}  ⚠️ INFO: $MOUNT_POINT is NOT currently mounted (expected for automount)${NC}"
  # Check if we can reach the Fritz!Box IP
  if ping -c 1 -W 2 192.168.1.5 >/dev/null 2>&1; then
    pass "Fritz!Box (192.168.1.5) is reachable"
  else
    echo -e "${YELLOW}  ⚠️ INFO: Fritz!Box (192.168.1.5) is UNREACHABLE${NC}"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════════════

print_header "Test Summary"

echo ""
echo -e "  Total:  ${TOTAL}"
echo -e "  ${GREEN}Passed: ${PASSED}${NC}"
echo -e "  ${RED}Failed: ${FAILED}${NC}"
echo ""

if [[ $FAILED -eq 0 ]]; then
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ✅ ALL TESTS PASSED${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
  exit 0
else
  echo -e "${RED}═══════════════════════════════════════════════════════════════════${NC}"
  echo -e "${RED}  ❌ SOME TESTS FAILED${NC}"
  echo -e "${RED}═══════════════════════════════════════════════════════════════════${NC}"
  exit 1
fi
