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
export GITHUB_PAT=$(cat /run/secrets/github-pat)
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

# Seed auth-profiles.json with OPENROUTER_API_KEY if key field is missing
AUTH_PROFILES=/home/node/.openclaw/agents/agent/auth-profiles.json
if [ -f "$AUTH_PROFILES" ]; then
  HAS_KEY=$(python3 -c "import json,sys; d=json.load(open('$AUTH_PROFILES')); p=d.get('profiles',{}).get('openrouter:default',{}); print('yes' if p.get('key') else 'no')" 2>/dev/null || echo "no")
  if [ "$HAS_KEY" = "no" ]; then
    echo "[auth] openrouter:default missing key — seeding from OPENROUTER_API_KEY"
    python3 -c "
import json
path = '$AUTH_PROFILES'
key = '$OPENROUTER_API_KEY'
with open(path) as f:
    d = json.load(f)
d.setdefault('profiles', {}).setdefault('openrouter:default', {})['key'] = key
d['profiles']['openrouter:default']['type'] = 'api_key'
d['profiles']['openrouter:default']['provider'] = 'openrouter'
with open(path, 'w') as f:
    json.dump(d, f, indent=2)
print('[auth] auth-profiles.json seeded.')
"
  fi
else
  echo "[auth] auth-profiles.json not found yet — openclaw will create it on first run"
fi

# Initialize workspace from git if not already cloned
WORKSPACE_DIR=/home/node/.openclaw/workspace
if [ ! -d "$WORKSPACE_DIR/.git" ]; then
  echo "Cloning workspace from GitHub..."
  rm -rf "$WORKSPACE_DIR"
  git clone "https://$GITHUB_PAT@github.com/markus-barta/oc-workspace-merlin.git" "$WORKSPACE_DIR"
  cd "$WORKSPACE_DIR"
  git config user.name "Merlin AI"
  git config user.email "merlin-ai-mba@users.noreply.github.com"
else
  echo "Workspace already cloned, pulling latest..."
  cd "$WORKSPACE_DIR"
  git config user.name "Merlin AI"
  git config user.email "merlin-ai-mba@users.noreply.github.com"
  git pull --ff-only || echo "Pull failed or conflicts, continuing..."
fi

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
