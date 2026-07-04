#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║              T11 - Gaming Support - Automated Tests                          ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# Tests gaming-related packages and drivers on gpc0 (Gaming PC)
#
# Usage: ./T11-gaming.sh
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

print_header "T11 - Gaming Support Tests"

echo "Host: $(hostname)"
echo "Date: $(date)"

# ────────────────────────────────────────────────────────────────────────────────
# T11.1 - Steam Client
# ────────────────────────────────────────────────────────────────────────────────

print_test "T11.1 - Steam Client"

if command -v steam &>/dev/null; then
  pass "Steam client available"
else
  fail "Steam client not found"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T11.2 - Gamescope
# ────────────────────────────────────────────────────────────────────────────────

print_test "T11.2 - Gamescope"

if command -v gamescope &>/dev/null; then
  pass "Gamescope compositor available"
else
  fail "Gamescope not found"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T11.3 - AMD GPU Support
# ────────────────────────────────────────────────────────────────────────────────

print_test "T11.3 - AMD GPU Support"

# Check for amdgpu kernel module
if lsmod | grep -q amdgpu; then
  pass "amdgpu kernel module loaded"
else
  fail "amdgpu kernel module not loaded"
fi

# Check for Vulkan support. vulkaninfo is not installed on gpc0 (verified
# absent in all generations, NIX-231) — probe the driver ICD manifests
# instead; use vulkaninfo only if it happens to be present.
if command -v vulkaninfo &>/dev/null; then
  if vulkaninfo 2>/dev/null | grep -q "GPU"; then
    pass "Vulkan GPU detected"
  else
    fail "Vulkan available but no GPU detected"
  fi
elif compgen -G "/run/opengl-driver/share/vulkan/icd.d/*.json" >/dev/null; then
  icds=$(cd /run/opengl-driver/share/vulkan/icd.d/ && echo ./*.json)
  pass "Vulkan ICD manifests present: ${icds//.\//}"
else
  fail "No Vulkan support (no vulkaninfo, no ICD manifests in /run/opengl-driver)"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T11.4 - AMD GPU Monitoring
# ────────────────────────────────────────────────────────────────────────────────

print_test "T11.4 - AMD GPU Monitoring Tools"

if command -v amdgpu_top &>/dev/null; then
  pass "amdgpu_top available"
else
  fail "amdgpu_top not found"
fi

if command -v lact &>/dev/null; then
  pass "LACT (Linux AMD Control Tool) available"
else
  fail "LACT not found"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T11.5 - Graphics Acceleration
# ────────────────────────────────────────────────────────────────────────────────

print_test "T11.5 - Graphics Acceleration"

# Check OpenGL stack. glxinfo is not installed on gpc0 (verified absent in
# all generations, NIX-231) — probe the Mesa DRI driver dir and render
# nodes instead; use glxinfo only if it happens to be present.
if command -v glxinfo &>/dev/null; then
  RENDERER=$(glxinfo 2>/dev/null | grep "OpenGL renderer" | head -1 || echo "unknown")
  if [[ -n "$RENDERER" ]] && [[ "$RENDERER" != "unknown" ]]; then
    pass "OpenGL renderer: $RENDERER"
  else
    fail "Could not detect OpenGL renderer"
  fi
elif [[ -d /run/opengl-driver/lib/dri ]] && compgen -G "/dev/dri/renderD*" >/dev/null; then
  nodes=$(cd /dev/dri && echo ./*)
  pass "Mesa DRI drivers + render node present (/run/opengl-driver/lib/dri, ${nodes//.\//})"
else
  fail "No OpenGL stack (no glxinfo, no /run/opengl-driver/lib/dri or render node)"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T11.6 - Game Mode
# ────────────────────────────────────────────────────────────────────────────────

print_test "T11.6 - GameMode"

if command -v gamemoded &>/dev/null; then
  pass "GameMode daemon available"
else
  # GameMode is optional
  echo -e "${YELLOW}  ⏭️ SKIP: GameMode not installed (optional)${NC}"
fi

# ────────────────────────────────────────────────────────────────────────────────
# T11.7 - Media Players
# ────────────────────────────────────────────────────────────────────────────────

print_test "T11.7 - Media Players"

if command -v vlc &>/dev/null; then
  pass "VLC media player available"
else
  fail "VLC not found"
fi

if command -v mplayer &>/dev/null; then
  pass "MPlayer available"
else
  fail "MPlayer not found"
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
