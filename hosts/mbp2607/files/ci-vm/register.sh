#!/bin/bash
# Root ExecStartPre. The one-shot token is read only for an unconfigured runner.
# Verified against actions/runner v2.338.2, src/Runner.Listener/CommandSettings.cs:
# constructor imports ACTIONS_RUNNER_INPUT_*, registers TOKEN with SecretMasker,
# then removes the environment inputs; GetArg/TestFlag support strings/booleans.
set +x
set -euo pipefail
umask 077
id=$1
dir="/var/lib/ci-runners/$id"
if [ -f "$dir/.runner" ]; then
  exit 0
fi
secret="/etc/ci-vm-secrets/$id.token"
if [ ! -f "$secret" ] || [ -L "$secret" ]; then
  printf 'ci-vm: registration token missing or unsafe for %s\n' "$id" >&2
  exit 1
fi
test "$(stat -c %a "$secret")" = 600
repo=$(jq -er --arg id "$id" '.[] | select(.id == $id)' /etc/ci-vm-repositories.json)
ACTIONS_RUNNER_INPUT_URL="https://github.com/$(jq -r .repository <<<"$repo")"
ACTIONS_RUNNER_INPUT_NAME=$(jq -r .runnerName <<<"$repo")
ACTIONS_RUNNER_INPUT_LABELS=$(jq -r '.labels | join(",")' <<<"$repo")
export ACTIONS_RUNNER_INPUT_URL ACTIONS_RUNNER_INPUT_NAME ACTIONS_RUNNER_INPUT_LABELS
export ACTIONS_RUNNER_INPUT_UNATTENDED=true
export ACTIONS_RUNNER_INPUT_REPLACE=true
export ACTIONS_RUNNER_INPUT_DISABLEUPDATE=true
export ACTIONS_RUNNER_INPUT_WORK=_work
IFS= read -r ACTIONS_RUNNER_INPUT_TOKEN <"$secret"
test -n "$ACTIONS_RUNNER_INPUT_TOKEN"
export ACTIONS_RUNNER_INPUT_TOKEN
export HOME="$dir" USER="ci-$id" LOGNAME="ci-$id"
export PATH=/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin
# Never pass a token through argv, tee, a temporary file or a journal message.
# The pinned runner masks its own diagnostics; suppress enrollment console too.
cd "$dir"
if ! runuser --preserve-environment -u "ci-$id" -- ./config.sh >/dev/null 2>&1; then
  printf 'ci-vm: registration failed for %s; coordinator must check token expiry\n' "$id" >&2
  exit 1
fi
