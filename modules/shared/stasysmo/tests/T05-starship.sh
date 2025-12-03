#!/usr/bin/env bash
#
# T05: Starship Integration - Manual Test Checklist
# These tests require visual inspection in a real terminal with Starship
#

set -euo pipefail

# Colors
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║        T05: Starship Integration - MANUAL TEST CHECKLIST         ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo
echo -e "${CYAN}These tests cannot be automated - they require visual inspection.${NC}"
echo -e "${CYAN}Run these tests in a terminal with Starship prompt active.${NC}"
echo
echo "════════════════════════════════════════════════════════════════════"
echo "PREREQUISITES"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "[ ] Starship is installed and active in shell"
echo "[ ] StaSysMo daemon is running (check: ls /tmp/stasysmo/ or /dev/shm/stasysmo/)"
echo "[ ] home-manager switch (macOS) or nixos-rebuild switch (Linux) completed"
echo "[ ] Using a Nerd Font in terminal (for icons)"
echo
echo "════════════════════════════════════════════════════════════════════"
echo "TEST 1: POWERLINE SEGMENT APPEARANCE"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "Expected: StaSysMo appears as a rounded powerline segment"
echo "          (same style as 'impure' badge)"
echo
echo "[ ] Left edge has rounded cap character ()"
echo "[ ] Right edge has rounded cap character ()"
echo "[ ] Background color matches 'impure' segment (dark)"
echo "[ ] No gap/artifact between StaSysMo and time segment"
echo "[ ] No gap/artifact between StaSysMo and fill space"
echo
echo "════════════════════════════════════════════════════════════════════"
echo "TEST 2: METRICS DISPLAY"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "Expected: Metrics show with Nerd Font icons"
echo "          CPU () RAM () Load (󰊚) Swap (󰾴)"
echo
echo "[ ] CPU shows with  icon and percentage"
echo "[ ] RAM shows with  icon and percentage"
echo "[ ] Load shows with 󰊚 icon and decimal value"
echo "[ ] Swap shows with 󰾴 icon and percentage (if swap > 0)"
echo "[ ] Icons display correctly (not ? or boxes)"
echo "[ ] Values update periodically (every ~5 seconds by default)"
echo
echo "════════════════════════════════════════════════════════════════════"
echo "TEST 3: THRESHOLD COLORING"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "Expected: Colors change based on threshold values"
echo
echo "To test CPU thresholds, run: stress --cpu 4 --timeout 30"
echo "To test RAM thresholds, run a memory-intensive process"
echo
echo "[ ] Normal values: Muted gray color"
echo "[ ] Elevated values: Bright white color"
echo "[ ] Critical values: Red color"
echo
echo "════════════════════════════════════════════════════════════════════"
echo "TEST 4: PROGRESSIVE HIDING (TERMINAL WIDTH)"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "Resize terminal window and observe changes:"
echo
echo "[ ] Very narrow (<60 cols): NO StaSysMo segment at all (no artifacts!)"
echo "[ ] Narrow (60-79 cols): Only CPU shown"
echo "[ ] Medium (80-99 cols): CPU + RAM shown"
echo "[ ] Wide (100-129 cols): CPU + RAM + Load shown"
echo "[ ] Very wide (130+ cols): All 4 metrics shown"
echo "[ ] NO leftover artifacts (empty segment, floating caps) at any width"
echo
echo "════════════════════════════════════════════════════════════════════"
echo "TEST 5: HIDEALL BEHAVIOR (CRITICAL)"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "When terminal is narrower than hideAll threshold:"
echo
echo "[ ] NO powerline caps () visible"
echo "[ ] NO empty segment/gap visible"
echo "[ ] NO spacing artifacts before next segment"
echo "[ ] Prompt looks clean as if StaSysMo doesn't exist"
echo
echo "════════════════════════════════════════════════════════════════════"
echo "TEST 6: STALENESS INDICATION"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "To test: Stop the daemon and wait 10+ seconds"
echo "  macOS: launchctl bootout gui/\$(id -u)/com.stasysmo.daemon"
echo "  Linux: sudo systemctl stop stasysmo-daemon"
echo
echo "[ ] After daemon stopped + 10s: Shows '?' instead of values"
echo "[ ] After restarting daemon: Normal values return"
echo
echo "════════════════════════════════════════════════════════════════════"
echo "TEST 7: COMMAND DURATION INTEGRATION"
echo "════════════════════════════════════════════════════════════════════"
echo
echo "Run a slow command: sleep 3"
echo
echo "[ ] Duration appears after time: ⊕ HH:MM:SS ⏱ Xs"
echo "[ ] Duration has correct background (matches time segment)"
echo "[ ] No overlap/gap with StaSysMo segment"
echo
echo "════════════════════════════════════════════════════════════════════"
echo
echo -e "${YELLOW}This script documents manual tests only.${NC}"
echo -e "${YELLOW}Automated testing of Starship integration is not possible.${NC}"
echo
exit 0
