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

# ────────────────────────────────────────────────────────────────────────────────
# T06.5 - Time Machine pool: two caps in place, headroom left, witness alive
# ────────────────────────────────────────────────────────────────────────────────

print_test "T06.5 - Time Machine datasets (OPS-226)"
# Declared caps (GiB) per user — must match hosts/hsb1/tm-caps.nix.
declare -A WANT_REFQUOTA=([markus]=2253 [mailina]=1434)
declare -A WANT_QUOTA=([markus]=3277 [mailina]=2048)
for user in markus mailina; do
  ds="tm/${user}"
  # Both caps are imperative (tm-caps.nix documents the `zfs set`); with -p an
  # unset cap prints 0. Capture the command's status — a partial answer must
  # not pass as a healthy pair.
  if ! props=$(zfs get -Hp -o value refquota,quota,referenced,usedbysnapshots "$ds" 2>/dev/null); then
    fail "$ds: zfs get failed (pool not imported?)"
    continue
  fi
  read -r refquota quota referenced snaps <<<"$(echo "$props" | tr '\n' ' ')"
  if ! [[ "$refquota" =~ ^[0-9]+$ && "$quota" =~ ^[0-9]+$ && "$referenced" =~ ^[0-9]+$ && "$snaps" =~ ^[0-9]+$ ]]; then
    fail "$ds: unexpected zfs get output"
    continue
  fi
  if [[ "$refquota" -eq $((WANT_REFQUOTA[$user] * 1024 ** 3)) && "$quota" -eq $((WANT_QUOTA[$user] * 1024 ** 3)) ]]; then
    pass "$ds: refquota ${WANT_REFQUOTA[$user]}G / quota ${WANT_QUOTA[$user]}G as declared"
  else
    fail "$ds: refquota $((refquota / 1024 ** 3))G / quota $((quota / 1024 ** 3))G differ from tm-caps.nix — run its zfs set"
  fi
  headroom=$((quota - referenced - snaps))
  if [[ "$headroom" -gt $((100 * 1024 ** 3)) ]]; then
    pass "$ds: $((headroom / 1024 ** 3))G below quota"
  else
    fail "$ds: only $((headroom / 1024 ** 3))G below quota — Time Machine will report a full volume"
  fi
done
if systemctl is-active --quiet tm-watch.timer; then
  pass "tm-watch.timer is active"
else
  fail "tm-watch.timer is NOT active"
fi
# Oneshot: Result=success also covers exit 1 (problems found), and a unit that
# never ran reports ExecMainStatus=0 too — require a run within the last hour.
TMW_EXIT=$(systemctl show tm-watch.service -p ExecMainStatus --value)
TMW_LAST=$(systemctl show tm-watch.service -p ExecMainExitTimestamp --value)
TMW_AGE=$((($(date +%s) - $(date -d "${TMW_LAST:-1970-01-01}" +%s 2>/dev/null || echo 0)) / 60))
if [[ -n "$TMW_LAST" && "$TMW_AGE" -le 60 && "$TMW_EXIT" == "0" ]]; then
  pass "tm-watch ran ${TMW_AGE} min ago: clean (0 active problems)"
else
  fail "tm-watch last run: exit ${TMW_EXIT}, ${TMW_AGE} min ago (last='${TMW_LAST}') — journalctl -u tm-watch"
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
