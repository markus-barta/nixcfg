#!/bin/sh
set -e

# Build env file from mounted secrets
# This file is sourced by the gateway AND by docker exec commands
ENV_FILE=/home/node/.env
cat >"$ENV_FILE" <<EOF
export TELEGRAM_BOT_TOKEN=$(cat /run/secrets/telegram-token)
export OPENCLAW_GATEWAY_TOKEN=$(cat /run/secrets/gateway-token)
export OPENROUTER_API_KEY=$(cat /run/secrets/openrouter-key)
export BRAVE_API_KEY=$(cat /run/secrets/brave-key)
export GITHUB_PAT=$(cat /run/secrets/github-pat | sed 's/^GITHUB_PAT=//')
export MATTERMOST_BOT_TOKEN=$(cat /run/secrets/mattermost-bot-token)
export MATTERMOST_URL=https://mattermost.bytepoets.com
EOF

# Source env for this process
# shellcheck disable=SC1090,SC1091
. "$ENV_FILE"

# Deploy git-managed config (backup existing, then overwrite)
CONFIG_SRC=/home/node/.openclaw-config/openclaw.json
CONFIG_DST=/home/node/.openclaw/openclaw.json
if [ -f "$CONFIG_DST" ]; then
  BACKUP="$CONFIG_DST.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG_DST" "$BACKUP"
  echo "[config] Backed up existing config to $BACKUP"
fi
cp "$CONFIG_SRC" "$CONFIG_DST"
echo "[config] Deployed git-managed openclaw.json"

# Initialize workspace from git if not already cloned
WORKSPACE_DIR=/home/node/.openclaw/workspace
if [ ! -d "$WORKSPACE_DIR/.git" ]; then
  echo "Cloning workspace from GitHub..."
  rm -rf "$WORKSPACE_DIR"
  git clone "https://$GITHUB_PAT@github.com/bytepoets-mba/oc-workspace-percy.git" "$WORKSPACE_DIR"
  cd "$WORKSPACE_DIR"
  git config user.name "Percy AI"
  git config user.email "bytepoets-percyai@users.noreply.github.com"
else
  echo "Workspace already cloned, pulling latest..."
  cd "$WORKSPACE_DIR"
  git config user.name "Percy AI"
  git config user.email "bytepoets-percyai@users.noreply.github.com"
  git pull --ff-only || echo "Pull failed or conflicts, continuing..."
fi

# Install bundled plugins if not already present (persisted in data volume)
OPENCLAW_EXT=/usr/local/lib/node_modules/openclaw/extensions
# shellcheck disable=SC2043
for PLUGIN in mattermost; do
  if ! openclaw plugins list 2>/dev/null | grep -q "$PLUGIN"; then
    echo "[plugins] Installing $PLUGIN from bundled extensions..."
    openclaw plugins install "$OPENCLAW_EXT/$PLUGIN"
  fi
done

# Daily auto-push safety net (runs in background, every 24h)
(while true; do
  sleep 86400
  cd "$WORKSPACE_DIR"
  if [ -n "$(git status --porcelain)" ]; then
    echo "[auto-push] Uncommitted workspace changes detected, pushing..."
    git add -A
    git commit -m "auto: daily workspace sync"
    git push || echo "[auto-push] Push failed, will retry next cycle"
  fi
done) &

exec openclaw gateway --port 18789
