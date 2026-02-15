#!/usr/bin/env bash
# openrouter-keys - Audit OpenRouter keys across hosts
# Shows full API keys (local use only - don't share!)

set -euo pipefail

check_host_key() {
  local host="$1"
  local description="$2"
  local key_file="$3"
  local ssh_opts="-o ConnectTimeout=10 -o StrictHostKeyChecking=no"

  echo "📍 $host - $description:"

  if ! ssh "$ssh_opts" -o BatchMode=yes "$host" "exit 0" 2>/dev/null; then
    echo "  [host unreachable]"
    return
  fi

  # shellcheck disable=SC2029
  if ssh "$ssh_opts" "$host" "test -f $key_file" 2>/dev/null; then
    # shellcheck disable=SC2029
    ssh "$ssh_opts" "$host" "cat $key_file" 2>/dev/null || echo "  [read error]"
  else
    echo "  [not configured]"
  fi
}

echo "🔍 OpenRouter Keys Audit"
echo "========================"
echo ""

# 1. imac0 (local) - opencode
echo "📍 imac0 (local) - opencode:"
if [[ -f "$HOME/.local/share/opencode/auth.json" ]]; then
  jq -r '.openrouter.key' "$HOME/.local/share/opencode/auth.json" 2>/dev/null || echo "  [parse error]"
else
  echo "  [not configured]"
fi
echo ""

# 2. mba-imac-work - opencode
check_host_key "mba@mba-imac-work.local" "opencode" "$HOME/.local/share/opencode/auth.json"
echo ""

# 3. hsb0 - Merlin
check_host_key "mba@hsb0.lan" "Merlin" "/run/agenix/hsb0-openclaw-openrouter-key"
echo ""

# 4. miniserver-bp - Percy (via Tailscale)
check_host_key "mba@100.64.0.10" "Percy" "/var/lib/openclaw-percaival/data/agents/main/agent/auth-profiles.json"
echo ""

echo "Done."
