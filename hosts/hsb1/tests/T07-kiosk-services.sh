#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                  T07 - Kiosk & Media Services Automated Tests                 ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Host: hsb1
# Feature: X11, Openbox, Kiosk User, VLC Volume Control
#
# Usage: ./T07-kiosk-services.sh
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

check_service_active() {
  if systemctl is-active --quiet "$1"; then
    pass "Service $1 is active"
    return 0
  else
    fail "Service $1 is NOT active"
    return 1
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
# Test Suite
# ════════════════════════════════════════════════════════════════════════════════

print_header "T07 - Kiosk & Media Services Tests (hsb1)"

echo "Host: $(hostname)"
echo "Date: $(date)"

# ────────────────────────────────────────────────────────────────────────────────
# T07.1 - Display Manager & X11
# ────────────────────────────────────────────────────────────────────────────────

print_test "T07.1 - Display Manager (LightDM)"
check_service_active "display-manager.service" || true

# ────────────────────────────────────────────────────────────────────────────────
# T07.2 - Kiosk User
# ────────────────────────────────────────────────────────────────────────────────

print_test "T07.2 - Kiosk User Session"
if id "kiosk" >/dev/null 2>&1; then
  pass "Kiosk user exists"
  if pgrep -u kiosk -f "openbox" >/dev/null 2>&1; then
    pass "Openbox is running for kiosk user"
  else
    echo -e "${YELLOW}  ⚠️ INFO: Openbox is NOT running for kiosk user (might not be logged in)${NC}"
  fi
else
  fail "Kiosk user does NOT exist"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T07.3 - VLC Media Player
# ────────────────────────────────────────────────────────────────────────────────

print_test "T07.3 - VLC availability"
if command -v vlc >/dev/null 2>&1; then
  pass "VLC is installed and in PATH"
else
  fail "VLC is NOT installed or NOT in PATH"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T07.4 - MQTT Volume Control Service
# ────────────────────────────────────────────────────────────────────────────────

print_test "T07.4 - MQTT Volume Control"
check_service_active "mqtt-volume-control.service" || true

# Check secrets for volume control
print_test "T07.5 - Media Secrets"
# NIX-158: media secrets moved from plaintext /etc/secrets/* to agenix /run/agenix/*.
if [[ -f "/run/agenix/hsb1-mqtt-client-env" ]]; then
  pass "MQTT secrets file exists (agenix)"
else
  fail "MQTT secrets file missing (/run/agenix/hsb1-mqtt-client-env)"
fi

if [[ -f "/run/agenix/hsb1-tapo-c210-env" ]]; then
  pass "Tapo camera secrets file exists (agenix)"
else
  fail "Tapo camera secrets file missing (/run/agenix/hsb1-tapo-c210-env)"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T07.6 - Audio Configuration
# ────────────────────────────────────────────────────────────────────────────────

print_test "T07.6 - Audio System"
if systemctl is-active --user --quiet pulseaudio || pgrep pulseaudio >/dev/null 2>&1; then
  pass "PulseAudio is running"
else
  echo -e "${YELLOW}  ⚠️ INFO: PulseAudio is NOT detected (required for HomePod audio)${NC}"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T07.7 - Babycam health watchdog (NIX-151)
# ────────────────────────────────────────────────────────────────────────────────
#
# The babycam went silent twice with a perfect picture and nothing noticed. These
# tests exist so that can never again be true without something failing loudly.

print_test "T07.7 - Babycam watchdog timer"
if systemctl is-active --quiet babycam-watchdog.timer; then
  pass "babycam-watchdog.timer is active"
else
  fail "babycam-watchdog.timer is NOT active — nothing is watching the babycam"
fi

print_test "T07.8 - Watchdog last run did not fail"
if systemctl is-failed --quiet babycam-watchdog.service; then
  fail "babycam-watchdog.service is in a failed state"
else
  pass "babycam-watchdog.service is not failed"
fi

print_test "T07.9 - Recorded user intent (desired volume)"
DESIRED_FILE=/var/lib/babycam-watchdog/desired-volume
if [[ -r "$DESIRED_FILE" ]]; then
  DESIRED=$(tr -cd '0-9' <"$DESIRED_FILE")
  pass "desired-volume recorded: ${DESIRED:-<empty>}"
else
  # Not fatal: it is seeded on the watchdog's first run, adopting whatever
  # volume VLC is already at.
  echo -e "${YELLOW}  ⚠️ INFO: $DESIRED_FILE absent (seeded on first watchdog run)${NC}"
  DESIRED=""
fi

# THE CORE INVARIANT. Everything else is scaffolding around this one line:
# what the user ASKED FOR must be what VLC is ACTUALLY doing.
#
# desired 0 / actual 0     -> healthy. The babycam is muted ON PURPOSE (door open,
#                             the boy is audible directly). This is a nightly habit
#                             and must NEVER be reported as a fault.
# desired 512 / actual 0   -> the NIX-151 bug: a restarted VLC came up silently mute.
print_test "T07.10 - VLC volume matches the user's intent"
VLC_TELNET_PASSWORD_FILE=/run/user/1001/kiosk-vlc/telnet-password
if ! pgrep -u kiosk -f -- '--video-title=hsb1-kiosk-babycam( |$)' >/dev/null 2>&1; then
  fail "VLC is not running — babycam is down"
elif [[ -z "$DESIRED" ]]; then
  echo -e "${YELLOW}  ⚠️ SKIP: no recorded intent to compare against${NC}"
elif [[ ! -r "$VLC_TELNET_PASSWORD_FILE" ]]; then
  fail "VLC telnet password missing or unreadable (run as root)"
else
  # Read in a subshell and piped via printf (a bash BUILTIN) so the password
  # never reaches argv or the journal. And NO trailing `quit`: VLC would close
  # the connection before flushing its reply, and `nc -q 2` is what lets the
  # answer actually arrive.
  ACTUAL=$(
    IFS= read -r vlc_password <"$VLC_TELNET_PASSWORD_FILE" || exit 1
    printf '%s\nstatus\n' "$vlc_password" |
      timeout 10 nc -q 2 127.0.0.1 4212 2>/dev/null |
      sed -n 's/.*( audio volume: \([0-9]*\) ).*/\1/p' | head -1
  ) || ACTUAL=""
  if [[ -z "$ACTUAL" ]]; then
    fail "VLC telnet gave no volume — is it holding an input?"
  elif ((ACTUAL >= DESIRED - 5 && ACTUAL <= DESIRED + 5)); then
    if ((DESIRED == 0)); then
      pass "volume $ACTUAL == intent $DESIRED (deliberately MUTED — correct, not a fault)"
    else
      pass "volume $ACTUAL == intent $DESIRED (audible)"
    fi
  else
    fail "SILENT-FAILURE: user wants $DESIRED but VLC is at $ACTUAL"
  fi
fi

print_test "T07.11 - Babycam audio path is intact"
# Runs regardless of mute state, ON PURPOSE. The dangerous failure is not a quiet
# monitor at night; it is the path being broken so that when the volume IS turned
# up, no sound comes out anyway — while VLC cheerfully reports a healthy volume.
if sudo -u kiosk XDG_RUNTIME_DIR=/run/user/1001 pactl list sink-inputs 2>/dev/null |
  grep -q 'application.id = "org.VideoLAN.VLC"'; then
  pass "VLC has a live PipeWire sink-input (audio can actually reach the speakers)"
else
  fail "VLC has NO sink-input — audio is orphaned; volume commands would be a LIE"
fi

print_test "T07.12 - Kiosk MQTT passwords stay out of argv"
# pgrep emits PIDs only; never use -a, ps or /proc/*/cmdline in these checks.
if pgrep -u kiosk -f -- '(^|[[:space:]])-P' >/dev/null 2>&1; then
  fail "A kiosk process has an MQTT password option in argv"
elif [[ $? -eq 1 ]]; then
  pass "No kiosk process has an MQTT password option in argv"
else
  fail "Could not inspect kiosk processes for MQTT password options"
fi

print_test "T07.13 - No legacy VLC password in argv"
if pgrep -f -- '--telnet-password=' >/dev/null 2>&1; then
  fail "A process still has a VLC telnet password option in argv"
elif [[ $? -eq 1 ]]; then
  pass "No process has a VLC telnet password option in argv"
else
  fail "Could not inspect processes for legacy VLC password options"
fi

print_test "T07.14 - VLC telnet listens only on IPv4 loopback"
if ! LISTENERS=$(ss -H -ltn 'sport = :4212' 2>/dev/null); then
  fail "Could not inspect TCP listeners on port 4212"
elif awk '
  { if ($4 != "127.0.0.1:4212") bad=1; count++ }
  END { exit (count == 0 || bad) }
' <<<"$LISTENERS"; then
  pass "Port 4212 listens on 127.0.0.1 only"
else
  fail "Port 4212 is absent or has a non-loopback/IPv6 listener"
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
