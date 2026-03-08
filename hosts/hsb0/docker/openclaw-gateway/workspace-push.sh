#!/bin/sh
# workspace-push.sh — daily push of personal agent workspace
# Usage: workspace-push.sh <merlin|nimue>
# Called by cron at 22:00 (merlin) and 22:05 (nimue)
# Commits and pushes any uncommitted changes in the agent's personal workspace.

set -e

AGENT_ID="$1"

if [ -z "${AGENT_ID}" ]; then
  echo "[workspace-push] ERROR: no agent ID provided" >&2
  exit 1
fi

case "${AGENT_ID}" in
merlin)
  GIT_NAME="Merlin AI"
  GIT_EMAIL="262173326+merlin-ai-markus@users.noreply.github.com"
  GITHUB_PAT="${GITHUB_PAT_MERLIN}"
  WORKSPACE_REPO="markus-barta/oc-workspace-merlin"
  ;;
nimue)
  GIT_NAME="Nimue AI"
  GIT_EMAIL="262988279+nimue-ai-mai@users.noreply.github.com"
  GITHUB_PAT="${GITHUB_PAT_NIMUE}"
  WORKSPACE_REPO="markus-barta/oc-workspace-nimue"
  ;;
*)
  echo "[workspace-push] ERROR: unknown agent '${AGENT_ID}'" >&2
  exit 1
  ;;
esac

WORKSPACE_DIR="/home/node/.openclaw/workspace-${AGENT_ID}"

echo "[workspace-push:${AGENT_ID}] Starting daily push — $(date)"

cd "${WORKSPACE_DIR}"

if [ -z "${GITHUB_PAT}" ]; then
  echo "[workspace-push:${AGENT_ID}] Git push disabled - no GitHub PAT configured"
  exit 0
fi

# Ensure PAT is current (rotations take effect without rebuild)
git remote set-url origin "https://${GITHUB_PAT}@github.com/${WORKSPACE_REPO}.git"
git config user.name "${GIT_NAME}"
git config user.email "${GIT_EMAIL}"

if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "auto: daily workspace sync"
  git push
  echo "[workspace-push:${AGENT_ID}] Pushed successfully"
else
  echo "[workspace-push:${AGENT_ID}] Nothing to push — workspace clean"
fi

echo "[workspace-push:${AGENT_ID}] Done — $(date)"
