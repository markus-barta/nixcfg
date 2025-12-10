#!/usr/bin/env bash
# NixFleet update script - pulls latest and rebuilds with embedded git hash
#
# Usage: ./update.sh
#
# This script:
# 1. Pulls latest from git
# 2. Copies nixfleet files to docker directory
# 3. Rebuilds container with current git hash embedded
# 4. Restarts the container

set -euo pipefail

NIXCFG_DIR="$HOME/Code/nixcfg"
DOCKER_DIR="$HOME/docker/nixfleet"

echo "📦 Pulling latest..."
cd "$NIXCFG_DIR"
git pull

# Get the current git hash for embedding
GIT_HASH=$(git rev-parse HEAD)
echo "📌 Git hash: ${GIT_HASH:0:7}"

echo "📋 Copying files..."
mkdir -p "$DOCKER_DIR"
cp -r "$NIXCFG_DIR/pkgs/nixfleet/app" "$DOCKER_DIR/"
cp "$NIXCFG_DIR/pkgs/nixfleet/Dockerfile" "$DOCKER_DIR/"
cp "$NIXCFG_DIR/pkgs/nixfleet/docker-compose.yml" "$DOCKER_DIR/"
cp "$NIXCFG_DIR/pkgs/nixfleet/.env" "$DOCKER_DIR/" 2>/dev/null || true

echo "🔨 Rebuilding container..."
cd "$DOCKER_DIR"

# Export git hash for docker-compose build args
export GIT_HASH

docker compose build --no-cache
docker compose up -d

echo "✅ NixFleet updated! (version: ${GIT_HASH:0:7})"
