#!/bin/sh
# shared-sync.sh — nightly sync of oc-workspace-shared
# Usage: shared-sync.sh <merlin|nimue>
# Called by cron at 23:30 (merlin) and 23:31 (nimue)
# Each agent: git pull → commit own FROM-<AGENT>.md → git push

set -e

AGENT_ID="$1"

if [ -z "${AGENT_ID}" ]; then
  echo "[shared-sync] ERROR: no agent ID provided" >&2
  exit 1
fi

case "${AGENT_ID}" in
merlin)
  GIT_NAME="Merlin AI"
  GIT_EMAIL="262173326+merlin-ai-mba@users.noreply.github.com"
  GITHUB_PAT="${GITHUB_PAT_MERLIN}"
  OWN_FILE="FROM-MERLIN.md"
  ;;
nimue)
  GIT_NAME="Nimue AI"
  GIT_EMAIL="262988279+nimue-ai-mai@users.noreply.github.com"
  GITHUB_PAT="${GITHUB_PAT_NIMUE}"
  OWN_FILE="FROM-NIMUE.md"
  ;;
*)
  echo "[shared-sync] ERROR: unknown agent '${AGENT_ID}'" >&2
  exit 1
  ;;
esac

SHARED_DIR="/home/node/.openclaw/workspace-shared"
SHARED_REPO="markus-barta/oc-workspace-shared"

echo "[shared-sync:${AGENT_ID}] Starting nightly sync — $(date)"

cd "${SHARED_DIR}"

# Update remote URL with current PAT (rotations, restarts)
git remote set-url origin "https://${GITHUB_PAT}@github.com/${SHARED_REPO}.git"

# Pull latest from remote (gets the other agent's previous push)
git pull --ff-only || echo "[shared-sync:${AGENT_ID}] Pull failed or nothing to pull, continuing..."

# Configure git identity for this agent's commit
git config user.name "${GIT_NAME}"
git config user.email "${GIT_EMAIL}"

# Stage only this agent's own file — never touch KNOWLEDGEBASE.md or the other's file
if [ -f "${OWN_FILE}" ]; then
  git add "${OWN_FILE}"
  if git diff --cached --quiet; then
    echo "[shared-sync:${AGENT_ID}] No changes in ${OWN_FILE} — nothing to commit"
  else
    git commit -m "sync: ${OWN_FILE} — $(date +%Y-%m-%d)"
    git push
    echo "[shared-sync:${AGENT_ID}] Pushed ${OWN_FILE} successfully"
  fi
else
  echo "[shared-sync:${AGENT_ID}] WARNING: ${OWN_FILE} not found — skipping commit"
fi

echo "[shared-sync:${AGENT_ID}] Done — $(date)"
