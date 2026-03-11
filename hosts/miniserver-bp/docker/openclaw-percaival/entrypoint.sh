#!/bin/sh
set -e

# Build env files from mounted secrets.
# TWO files needed:
#   ~/.openclaw/.env  — bare KEY=VALUE, read by OpenClaw process for ${VAR} config substitution
#   ~/.env            — sourceable export KEY=VALUE, for docker exec / shell scripts
OPENCLAW_ENV_FILE=/home/node/.openclaw/.env
HOME_ENV_FILE=/home/node/.env

mkdir -p /home/node/.openclaw

TELEGRAM_BOT_TOKEN=$(cat /run/secrets/telegram-token)
OPENCLAW_GATEWAY_TOKEN=$(cat /run/secrets/gateway-token)
OPENROUTER_API_KEY=$(cat /run/secrets/openrouter-key)
BRAVE_API_KEY=$(cat /run/secrets/brave-key)
GITHUB_PAT=$(cat /run/secrets/github-pat | sed 's/^GITHUB_PAT=//')
MATTERMOST_BOT_TOKEN=$(cat /run/secrets/mattermost-bot-token)
PMO_TOKEN=$(cat /run/secrets/pmo-token | sed 's/^PMO_TOKEN=//')

# Bare format — OpenClaw reads this for ${VAR} substitution in openclaw.json
cat >"$OPENCLAW_ENV_FILE" <<EOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
BRAVE_API_KEY=${BRAVE_API_KEY}
GITHUB_PAT=${GITHUB_PAT}
MATTERMOST_BOT_TOKEN=${MATTERMOST_BOT_TOKEN}
MATTERMOST_URL=https://mattermost.bytepoets.com
PMO_TOKEN=${PMO_TOKEN}
EOF

# Sourceable format — for docker exec and shell scripts
cat >"$HOME_ENV_FILE" <<EOF
export TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
export OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
export OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
export BRAVE_API_KEY=${BRAVE_API_KEY}
export GITHUB_PAT=${GITHUB_PAT}
export MATTERMOST_BOT_TOKEN=${MATTERMOST_BOT_TOKEN}
export MATTERMOST_URL=https://mattermost.bytepoets.com
export PMO_TOKEN=${PMO_TOKEN}
EOF

# Source env for this process
# shellcheck disable=SC1090,SC1091
. "$HOME_ENV_FILE"

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
  cd "$WORKSPACE_DIR"
  git config user.name "Percy AI"
  git config user.email "bytepoets-percyai@users.noreply.github.com"
  # Push any uncommitted work BEFORE pulling (prevents data loss on rebuild)
  if [ -n "$(git status --porcelain)" ]; then
    echo "[percy] Uncommitted changes found — pushing before pull..."
    git add -A
    git commit -m "auto: pre-pull backup (container restart)"
    git push || echo "[percy] Pre-pull push failed, continuing..."
  fi
  echo "Pulling latest..."
  git pull --ff-only || echo "Pull failed or conflicts, continuing..."
fi

# Sync OpenRouter key into auth-profiles.json (key rotations take effect on restart)
# Single-agent mode: check both possible paths (agent/ and agents/main/agent/)
for AGENT_DIR in /home/node/.openclaw/agent /home/node/.openclaw/agents/main/agent; do
  AUTH_PROFILES="${AGENT_DIR}/auth-profiles.json"
  if [ -f "$AUTH_PROFILES" ]; then
    python3 -c "
import json
path = '${AUTH_PROFILES}'
key = '${OPENROUTER_API_KEY}'
with open(path) as f:
    d = json.load(f)
old_key = d.get('profiles', {}).get('openrouter:default', {}).get('key', '')
if old_key == key:
    print('[percy] auth-profiles.json OpenRouter key already current.')
else:
    d.setdefault('profiles', {}).setdefault('openrouter:default', {})['key'] = key
    d['profiles']['openrouter:default']['type'] = 'api_key'
    d['profiles']['openrouter:default']['provider'] = 'openrouter'
    with open(path, 'w') as f:
        json.dump(d, f, indent=2)
    print('[percy] auth-profiles.json OpenRouter key UPDATED.')
"
    break
  fi
done

# Install bundled plugins if not already present (persisted in data volume)
OPENCLAW_EXT=/usr/local/lib/node_modules/openclaw/extensions
# shellcheck disable=SC2043
for PLUGIN in mattermost; do
  if ! openclaw plugins list 2>/dev/null | grep -q "$PLUGIN"; then
    echo "[plugins] Installing $PLUGIN from bundled extensions..."
    openclaw plugins install "$OPENCLAW_EXT/$PLUGIN"
  fi
done

# -----------------------------------------------------------------------------
# Write agent env file (sourced by cron — PAT not baked into crontab)
# -----------------------------------------------------------------------------
AGENT_ENV_FILE="/home/node/.agent-env"
cat >"${AGENT_ENV_FILE}" <<ENVEOF
export GITHUB_PAT=${GITHUB_PAT}
ENVEOF
chmod 600 "${AGENT_ENV_FILE}"

# -----------------------------------------------------------------------------
# Register cron job: 22:00 — daily workspace push
# -----------------------------------------------------------------------------
CRONTAB_FILE="/home/node/.crontab"
cat >"${CRONTAB_FILE}" <<CRONEOF
0 22 * * * . /home/node/.agent-env && /home/node/workspace-push.sh >> /home/node/.openclaw/workspace-push.log 2>&1
CRONEOF
crontab "${CRONTAB_FILE}"
rm "${CRONTAB_FILE}"
echo "[cron] Daily workspace push registered at 22:00"

# Start cron daemon (node has passwordless sudo for /usr/sbin/cron only)
sudo cron
echo "[cron] Daemon started"

exec openclaw gateway --port 18789
