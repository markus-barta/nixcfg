#!/usr/bin/env bash

# OpenClaw Autopilot Update Script
# Designed to run on hsb1 (Linux) from ~/Code/nixcfg
#
# Updates version, source hash, and pnpm dependencies hash automatically.
#
# IMPORTANT IMPLEMENTATION NOTES:
# ================================
# 1. The pnpmDepsHash in package.nix uses a ternary structure:
#      pnpmDepsHash =
#        if stdenvNoCC.hostPlatform.isDarwin then
#          "sha256-DARWIN..."
#        else
#          "sha256-LINUX...";
#    We target the "else" line specifically using line-based sed.
#
# 2. To get the correct hash, we must trigger a build failure.
#    We build the full package (not .pnpmDeps) because the latter
#    isn't directly exposed. The pnpm fetch phase fails first.
#
# 3. The script expects to be run from ~/Code/nixcfg (repo root).

set -euo pipefail

# Ensure we're in the repo root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

PACKAGE_FILE="pkgs/openclaw/package.nix"
GITHUB_REPO="openclaw/openclaw"

echo "🦞 OpenClaw Update Autopilot starting..."
echo "📂 Working directory: $(pwd)"

# Validate package file exists
if [ ! -f "$PACKAGE_FILE" ]; then
  echo "❌ Package file not found: $PACKAGE_FILE"
  exit 1
fi

# 1. Find latest version from GitHub
echo "🔍 Fetching latest version from GitHub..."
LATEST_TAG=$(curl -s "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | jq -r .tag_name)

if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" == "null" ]; then
  echo "❌ Failed to fetch latest release from GitHub"
  exit 1
fi

NEW_VERSION=${LATEST_TAG#v} # remove 'v' prefix
echo "✨ Latest version: $NEW_VERSION"

# 2. Check if we are already on this version
CURRENT_VERSION=$(grep 'version = "' "$PACKAGE_FILE" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
echo "📌 Current version: $CURRENT_VERSION"

if [ "$CURRENT_VERSION" == "$NEW_VERSION" ] && [ "${OPENCLAW_FORCE:-0}" != "1" ]; then
  echo "✅ Already on version $NEW_VERSION. Nothing to do."
  echo "   Tip: run with OPENCLAW_FORCE=1 to re-probe hashes."
  exit 0
fi

# 3. Calculate new source hash
echo "📥 Calculating source hash for v$NEW_VERSION..."
SRC_URL="https://github.com/$GITHUB_REPO/archive/refs/tags/$LATEST_TAG.tar.gz"
NEW_SRC_HASH=$(nix-prefetch-url --unpack "$SRC_URL" 2>/dev/null | xargs nix hash convert --hash-algo sha256)
echo "📦 New source hash: $NEW_SRC_HASH"

# 4. Extract current source hash for later comparison
OLD_SRC_HASH=$(grep -A5 'src = fetchFromGitHub' "$PACKAGE_FILE" | grep 'hash = "' | sed -E 's/.*"([^"]+)".*/\1/')

# 5. Patch version in package.nix
echo "📝 Patching version..."
sed -i "s/version = \"$CURRENT_VERSION\";/version = \"$NEW_VERSION\";/" "$PACKAGE_FILE"

# 6. Patch source hash in package.nix
echo "📝 Patching source hash..."
sed -i "s|hash = \"$OLD_SRC_HASH\";|hash = \"$NEW_SRC_HASH\";|" "$PACKAGE_FILE"

# 7. Reset Linux pnpmDepsHash to trigger recalculation
# Structure in package.nix:
#   pnpmDepsHash =
#     if stdenvNoCC.hostPlatform.isDarwin then
#       "sha256-DARWIN..."    <- line 27
#     else
#       "sha256-LINUX...";    <- line 29 (THIS IS WHAT WE TARGET)
#
# We use a marker hash that's obviously fake
FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
echo "🔄 Resetting Linux pnpmDepsHash to trigger probe build..."

# Find the line number of "else" in the pnpmDepsHash block
ELSE_LINE=$(grep -n "else" "$PACKAGE_FILE" | head -n1 | cut -d: -f1)
LINUX_HASH_LINE=$((ELSE_LINE + 1))

# Extract current Linux hash for replacement/comparison
OLD_LINUX_HASH=$(sed -n "${LINUX_HASH_LINE}p" "$PACKAGE_FILE" | sed -E 's/.*"([^"]+)".*/\1/')
echo "📌 Current Linux hash: $OLD_LINUX_HASH"

# Replace the Linux hash line
sed -i "${LINUX_HASH_LINE}s|\"$OLD_LINUX_HASH\"|\"$FAKE_HASH\"|" "$PACKAGE_FILE"

# 8. Run probe build to get the real pnpmDepsHash
echo "🏗️ Running probe build (this will fail to reveal the correct hash)..."
echo "   Expect ~2-8 minutes on hsb1 depending on cache/network."
LOG_FILE="/tmp/openclaw-update-error.log"

run_probe_build() {
  local cmd="$1"
  echo "⏳ Build in progress... (log: $LOG_FILE)"
  PROBE_SECONDS=0
  bash -c "$cmd" 2>&1 | tee "$LOG_FILE" &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15
    PROBE_SECONDS=$((PROBE_SECONDS + 15))
    echo "⏳ still running (${PROBE_SECONDS}s elapsed)"
  done
  wait "$pid"
  return $?
}

set +e
run_probe_build "nix build .#openclaw --no-link"
BUILD_EXIT=$?

# If the flake doesn't expose openclaw, fall back to a direct nixpkgs callPackage
if grep -q "does not provide attribute 'packages.x86_64-linux.openclaw'" "$LOG_FILE"; then
  echo "ℹ️  Flake does not expose openclaw package; falling back to callPackage expression."
  run_probe_build "nix build --impure --no-link --expr 'let flake = builtins.getFlake (toString ./.); pkgs = flake.inputs.nixpkgs.legacyPackages.x86_64-linux; in pkgs.callPackage ./pkgs/openclaw/package.nix {}'"
  BUILD_EXIT=$?
fi
set -e

# 9. Extract the "got:" hash from the error output
echo "🧪 Extracting new hash from build output..."
NEW_LINUX_HASH=$(sed -nE 's/.*got:[[:space:]]*(sha256-[A-Za-z0-9+/=]+).*/\1/p' "$LOG_FILE" | head -n1)

if [ -z "$NEW_LINUX_HASH" ]; then
  echo "❌ Failed to extract hash from build output."
  echo "   Build exit code: $BUILD_EXIT"
  echo "   Looking for 'got:' pattern in output..."
  grep -i "got:" "$LOG_FILE" || echo "   (no 'got:' found)"
  echo ""
  echo "📋 Full build output saved to $LOG_FILE"
  exit 1
fi

echo "✅ Found new Linux hash: $NEW_LINUX_HASH"

# 10. Apply the final hash
echo "📝 Applying final pnpmDepsHash..."
sed -i "${LINUX_HASH_LINE}s|\"$FAKE_HASH\"|\"$NEW_LINUX_HASH\"|" "$PACKAGE_FILE"

# 11. Verify evaluation (fast check, single host)
echo "🛡️ Verifying flake evaluation for hsb1..."
if ! just check-host hsb1; then
  echo "❌ Flake evaluation failed. Check $PACKAGE_FILE for issues."
  exit 1
fi

# 12. Summary message
SUMMARY="OpenClaw: 🧙🏻‍♂️ Update von $CURRENT_VERSION auf $NEW_VERSION
- Source: $OLD_SRC_HASH -> $NEW_SRC_HASH
- PNPM (Linux): $OLD_LINUX_HASH -> $NEW_LINUX_HASH"

# 13. Commit and Push
echo "🚀 Committing and pushing changes..."
git add "$PACKAGE_FILE"
git commit -m "$SUMMARY"
git push

echo ""
echo "🎉 $SUMMARY"
echo ""
echo "🎉 OpenClaw updated successfully!"
echo "   Run 'just switch' on hsb1 to deploy."
