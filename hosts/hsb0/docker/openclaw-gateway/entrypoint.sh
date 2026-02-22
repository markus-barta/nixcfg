#!/bin/sh
set -e

# =============================================================================
# openclaw-gateway entrypoint — multi-agent (Merlin + Nimue)
#
# Reads secrets from /run/secrets/* (mounted from agenix).
# Initialises each agent's workspace, auth-profiles, and gogcli env.
# Starts one gateway process serving both agents.
# =============================================================================

OPENCLAW_ENV_FILE=/home/node/.openclaw/.env
HOME_ENV_FILE=/home/node/.env

mkdir -p /home/node/.openclaw

# -----------------------------------------------------------------------------
# 1. Read shared + per-agent secrets
# -----------------------------------------------------------------------------
OPENROUTER_API_KEY=$(cat /run/secrets/openrouter-key)
BRAVE_API_KEY=$(cat /run/secrets/brave-key)
OPENCLAW_GATEWAY_TOKEN=$(cat /run/secrets/gateway-token)
TELEGRAM_BOT_TOKEN_MERLIN=$(cat /run/secrets/telegram-token-merlin)
TELEGRAM_BOT_TOKEN_NIMUE=$(cat /run/secrets/telegram-token-nimue)
GITHUB_PAT_MERLIN=$(cat /run/secrets/github-pat-merlin)
GITHUB_PAT_NIMUE=$(cat /run/secrets/github-pat-nimue)

# Write global .env for the gateway process (openclaw reads this for ${VAR} substitution)
cat >"$OPENCLAW_ENV_FILE" <<EOF
OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
BRAVE_API_KEY=${BRAVE_API_KEY}
OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
TELEGRAM_BOT_TOKEN_MERLIN=${TELEGRAM_BOT_TOKEN_MERLIN}
TELEGRAM_BOT_TOKEN_NIMUE=${TELEGRAM_BOT_TOKEN_NIMUE}
EOF

# Shell-sourceable version for docker exec / oc wrapper
cat >"$HOME_ENV_FILE" <<EOF
export OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
export BRAVE_API_KEY=${BRAVE_API_KEY}
export OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
export TELEGRAM_BOT_TOKEN_MERLIN=${TELEGRAM_BOT_TOKEN_MERLIN}
export TELEGRAM_BOT_TOKEN_NIMUE=${TELEGRAM_BOT_TOKEN_NIMUE}
EOF

# shellcheck disable=SC1090,SC1091
. "$HOME_ENV_FILE"

# -----------------------------------------------------------------------------
# 2. Install SSH key for Merlin → hsb1 access
#    agenix mounts secrets as 444 (world-readable) but SSH refuses keys
#    with permissions looser than 600. Copy to writable location + chmod.
# -----------------------------------------------------------------------------
if [ -f /run/secrets/merlin-ssh-key ]; then
  mkdir -p /home/node/.ssh
  cp /run/secrets/merlin-ssh-key /home/node/.ssh/merlin-hsb1
  chmod 600 /home/node/.ssh/merlin-hsb1
  echo "[ssh] Merlin SSH key installed at /home/node/.ssh/merlin-hsb1"
else
  echo "[ssh] WARNING: /run/secrets/merlin-ssh-key not found — hsb1 SSH access will not work"
fi

# -----------------------------------------------------------------------------
# 3. Deploy git-managed openclaw.json (with timestamped backup)
# -----------------------------------------------------------------------------
CONFIG_SRC=/home/node/.openclaw-config/openclaw.json
CONFIG_DST=/home/node/.openclaw/openclaw.json
if [ -f "$CONFIG_DST" ]; then
  BACKUP="$CONFIG_DST.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG_DST" "$BACKUP"
  echo "[config] Backed up existing config to $BACKUP"
fi
cp "$CONFIG_SRC" "$CONFIG_DST"
echo "[config] Deployed git-managed openclaw.json"

# -----------------------------------------------------------------------------
# 4. Per-agent init
# -----------------------------------------------------------------------------
init_agent() {
  AGENT_ID="$1"
  WORKSPACE_REPO="$2"
  GITHUB_PAT="$3"
  GIT_NAME="$4"
  GIT_EMAIL="$5"
  GOG_ACCOUNT="$6"
  GOG_KEYRING_FILE="$7"

  WORKSPACE_DIR="/home/node/.openclaw/workspace-${AGENT_ID}"
  AGENT_DIR="/home/node/.openclaw/agents/${AGENT_ID}/agent"
  CONFIG_DIR="/home/node/.config/${AGENT_ID}"

  echo "[agent:${AGENT_ID}] Initialising..."

  # -- Workspace clone / pull --
  if [ ! -d "${WORKSPACE_DIR}/.git" ]; then
    echo "[agent:${AGENT_ID}] Cloning workspace from GitHub..."
    rm -rf "${WORKSPACE_DIR}"
    git clone "https://${GITHUB_PAT}@github.com/${WORKSPACE_REPO}.git" "${WORKSPACE_DIR}"
  else
    echo "[agent:${AGENT_ID}] Workspace exists, pulling latest..."
    cd "${WORKSPACE_DIR}"
    git remote set-url origin "https://${GITHUB_PAT}@github.com/${WORKSPACE_REPO}.git"
    git pull --ff-only || echo "[agent:${AGENT_ID}] Pull failed or conflicts, continuing..."
  fi

  cd "${WORKSPACE_DIR}"
  git config user.name "${GIT_NAME}"
  git config user.email "${GIT_EMAIL}"

  # -- Auth profiles: seed OpenRouter key if missing --
  AUTH_PROFILES="${AGENT_DIR}/auth-profiles.json"
  mkdir -p "${AGENT_DIR}"
  if [ -f "$AUTH_PROFILES" ]; then
    HAS_KEY=$(python3 -c "
import json,sys
d=json.load(open('${AUTH_PROFILES}'))
p=d.get('profiles',{}).get('openrouter:default',{})
print('yes' if p.get('key') else 'no')
" 2>/dev/null || echo "no")
    if [ "$HAS_KEY" = "no" ]; then
      echo "[agent:${AGENT_ID}] Seeding OpenRouter key into auth-profiles.json"
      python3 -c "
import json
path = '${AUTH_PROFILES}'
key = '${OPENROUTER_API_KEY}'
with open(path) as f:
    d = json.load(f)
d.setdefault('profiles', {}).setdefault('openrouter:default', {})['key'] = key
d['profiles']['openrouter:default']['type'] = 'api_key'
d['profiles']['openrouter:default']['provider'] = 'openrouter'
with open(path, 'w') as f:
    json.dump(d, f, indent=2)
print('[agent:${AGENT_ID}] auth-profiles.json seeded.')
"
    fi
  else
    echo "[agent:${AGENT_ID}] auth-profiles.json not found yet — openclaw will create on first run"
  fi

  # -- Per-agent gogcli env file --
  # Skills source this before calling gog (GOG_ACCOUNT differs per agent)
  mkdir -p "${CONFIG_DIR}/gogcli"
  GOG_ENV_FILE="${CONFIG_DIR}/gogcli/gogcli.env"
  GOG_KEYRING_PASSWORD=""
  if [ -f "${GOG_KEYRING_FILE}" ]; then
    GOG_KEYRING_PASSWORD=$(cat "${GOG_KEYRING_FILE}")
  fi
  cat >"${GOG_ENV_FILE}" <<GOGEOF
export GOG_ACCOUNT=${GOG_ACCOUNT}
export GOG_KEYRING_BACKEND=file
export GOGCLI_KEYRING_PASSWORD=${GOG_KEYRING_PASSWORD}
GOGEOF
  echo "[agent:${AGENT_ID}] gogcli env written to ${GOG_ENV_FILE}"

  # -- Daily auto-push loop (background) --
  (while true; do
    sleep 86400
    cd "${WORKSPACE_DIR}"
    if [ -n "$(git status --porcelain)" ]; then
      echo "[auto-push:${AGENT_ID}] Uncommitted workspace changes, pushing..."
      git add -A
      git commit -m "auto: daily workspace sync"
      git push || echo "[auto-push:${AGENT_ID}] Push failed, will retry next cycle"
    fi
  done) &

  echo "[agent:${AGENT_ID}] Init complete."
}

init_agent \
  "merlin" \
  "markus-barta/oc-workspace-merlin" \
  "${GITHUB_PAT_MERLIN}" \
  "Merlin AI" \
  "262173326+merlin-ai-mba@users.noreply.github.com" \
  "markus@barta.com" \
  "/run/secrets/gogcli-keyring-password"

init_agent \
  "nimue" \
  "markus-barta/oc-workspace-nimue" \
  "${GITHUB_PAT_NIMUE}" \
  "Nimue AI" \
  "262988279+nimue-ai-mai@users.noreply.github.com" \
  "mailina.barta@gmail.com" \
  "/run/secrets/gogcli-keyring-password-nimue"

# -----------------------------------------------------------------------------
# 5. Shared workspace — clone/pull + symlinks in each agent workspace
# -----------------------------------------------------------------------------
SHARED_DIR="/home/node/.openclaw/workspace-shared"
SHARED_REPO="markus-barta/oc-workspace-shared"

echo "[shared] Initialising shared workspace..."
if [ ! -d "${SHARED_DIR}/.git" ]; then
  echo "[shared] Cloning shared workspace from GitHub..."
  rm -rf "${SHARED_DIR}"
  git clone "https://${GITHUB_PAT_MERLIN}@github.com/${SHARED_REPO}.git" "${SHARED_DIR}"
else
  echo "[shared] Shared workspace exists, pulling latest..."
  cd "${SHARED_DIR}"
  git remote set-url origin "https://${GITHUB_PAT_MERLIN}@github.com/${SHARED_REPO}.git"
  git pull --ff-only || echo "[shared] Pull failed or conflicts, continuing..."
fi

# Create symlinks in each agent workspace (relative, idempotent)
ln -sfn /home/node/.openclaw/workspace-shared /home/node/.openclaw/workspace-merlin/shared
ln -sfn /home/node/.openclaw/workspace-shared /home/node/.openclaw/workspace-nimue/shared
echo "[shared] Symlinks created in workspace-merlin/shared and workspace-nimue/shared"

# -----------------------------------------------------------------------------
# 6. Set up nightly cron sync for shared workspace
#    Merlin: 23:30 — pull + commit FROM-MERLIN.md + push (as merlin-ai-mba)
#    Nimue:  23:31 — pull + commit FROM-NIMUE.md  + push (as nimue-ai-mai)
# -----------------------------------------------------------------------------
CRONTAB_FILE="/home/node/shared-crontab"
cat >"${CRONTAB_FILE}" <<CRONEOF
30 23 * * * GITHUB_PAT_MERLIN=${GITHUB_PAT_MERLIN} GITHUB_PAT_NIMUE=${GITHUB_PAT_NIMUE} /home/node/shared-sync.sh merlin >> /home/node/.openclaw/shared-sync-merlin.log 2>&1
31 23 * * * GITHUB_PAT_MERLIN=${GITHUB_PAT_MERLIN} GITHUB_PAT_NIMUE=${GITHUB_PAT_NIMUE} /home/node/shared-sync.sh nimue >> /home/node/.openclaw/shared-sync-nimue.log 2>&1
CRONEOF
crontab "${CRONTAB_FILE}"
rm "${CRONTAB_FILE}"
echo "[shared] Nightly cron sync registered (Merlin: 23:30, Nimue: 23:31)"

# Start cron daemon as root (node has passwordless sudo for /usr/sbin/cron only)
sudo cron
echo "[shared] Cron daemon started"

echo "[gateway] All agents initialised. Starting openclaw gateway on port 18789..."
exec openclaw gateway --port 18789
