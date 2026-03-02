#!/bin/sh
# workspace-push.sh — daily push of Percy's workspace
# Called by cron at 22:00
# Commits and pushes any uncommitted changes in Percy's workspace.

set -e

WORKSPACE_DIR=/home/node/.openclaw/workspace
WORKSPACE_REPO="bytepoets-mba/oc-workspace-percy"
GIT_NAME="Percy AI"
GIT_EMAIL="bytepoets-percyai@users.noreply.github.com"

echo "[workspace-push:percy] Starting daily push — $(date)"

cd "${WORKSPACE_DIR}"

# Ensure PAT is current (rotations take effect without rebuild)
git remote set-url origin "https://${GITHUB_PAT}@github.com/${WORKSPACE_REPO}.git"
git config user.name "${GIT_NAME}"
git config user.email "${GIT_EMAIL}"

if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -m "auto: daily workspace sync"
  git push
  echo "[workspace-push:percy] Pushed successfully"
else
  echo "[workspace-push:percy] Nothing to push — workspace clean"
fi

echo "[workspace-push:percy] Done — $(date)"
