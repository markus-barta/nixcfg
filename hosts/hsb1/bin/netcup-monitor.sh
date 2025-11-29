#!/usr/bin/env bash
# shellcheck disable=SC1090
#
# Netcup Server Monitor
# Checks csb0 and csb1 daily, alerts after 2 consecutive days offline
# Continues alerting daily while servers remain offline
#
# Usage:
#   ./netcup-monitor.sh              # Normal check
#   ./netcup-monitor.sh --test       # Send test notification (Telegram + Email)
#   ./netcup-monitor.sh --test-lametric  # Send test to LaMetric devices
#

set -euo pipefail

# Load config
source ~/secrets/netcup-monitor.env

# LaMetric notification function (uses local API)
notify_lametric() {
  local message="$1"
  local sound="${2:-notification}" # Default sound: notification, alarm1, alarm2, etc.
  local icon="${3:-a26986}"        # Default: warning icon

  # Load LaMetric auth from smarthome.env
  source ~/secrets/smarthome.env 2>/dev/null || true

  # LaMetric Sky (VR) - local API
  if [ -n "${LAMETRIC_SKY_VR_AUTHORIZATION:-}" ]; then
    curl -s -X POST "http://vr-lametric-sky:8080/api/v2/device/notifications" \
      -H "Authorization: Basic $LAMETRIC_SKY_VR_AUTHORIZATION" \
      -H "Content-Type: application/json" \
      -d "{\"model\":{\"frames\":[{\"icon\":\"$icon\",\"text\":\"$message\"}],\"sound\":{\"category\":\"notifications\",\"id\":\"$sound\"}}}" \
      --connect-timeout 5 2>/dev/null || true
  fi
}

# Test LaMetric mode
if [ "${1:-}" = "--test-lametric" ]; then
  echo "Sending test to LaMetric devices..."
  notify_lametric "Test from hsb1" "notification" "i7956" # i7956 = checkmark icon
  echo "LaMetric test sent! Check your LaMetric device."
  exit 0
fi

# Test mode (Telegram + Email)
if [ "${1:-}" = "--test" ]; then
  echo "Sending test notification..."
  urls="tgram://${TELEGRAM_BOT}/${TELEGRAM_CHAT}"
  urls="${urls},mailto://smtp:25?from=netcup-monitor@hsb1&to=${EMAIL}"
  curl -s -X POST "$APPRISE_URL" \
    -d "urls=$urls" \
    -d "title=🧪 Netcup Monitor Test" \
    -d "body=Test notification from hsb1. If you see this, notifications work!" \
    -d "type=info"
  echo "Test sent!"
  exit 0
fi

# State file
STATE_DIR="/var/lib/netcup-monitor"
STATE_FILE="$STATE_DIR/state.json"
LOG_FILE="$STATE_DIR/monitor.log"

# API URLs
AUTH_URL="https://servercontrolpanel.de/realms/scp/protocol/openid-connect/token"
API_BASE="https://servercontrolpanel.de/scp-core/api/v1"

# Ensure state directory exists
mkdir -p "$STATE_DIR" 2>/dev/null || sudo mkdir -p "$STATE_DIR"
chown mba:users "$STATE_DIR" 2>/dev/null || sudo chown mba:users "$STATE_DIR"

# Initialize state file if missing
if [ ! -f "$STATE_FILE" ]; then
  echo '{"csb0_failures":0,"csb1_failures":0}' >"$STATE_FILE"
fi

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

notify() {
  local title="$1"
  local message="$2"

  # Telegram notification
  local tg_url="tgram://${TELEGRAM_BOT}/${TELEGRAM_CHAT}"

  log "Sending notification: $title"

  # Send Telegram
  curl -s -X POST "$APPRISE_URL" \
    -d "urls=$tg_url" \
    -d "title=$title" \
    -d "body=$message" \
    -d "type=warning" || log "Failed to send Telegram notification"

  # Send Email via local SMTP (simpler approach)
  echo -e "Subject: $title\n\n$message" |
    curl -s --url "smtp://smtp:25" \
      --mail-from "netcup-monitor@hsb1.lan" \
      --mail-rcpt "$EMAIL" \
      --upload-file - 2>/dev/null || log "Failed to send email"
}

check_server() {
  local server_id="$1"
  local server_name="$2"

  log "Checking $server_name (ID: $server_id)..."

  # Get access token
  local access_token
  access_token=$(curl -s "$AUTH_URL" \
    -d "client_id=scp" \
    -d "refresh_token=$NETCUP_REFRESH_TOKEN" \
    -d "grant_type=refresh_token" | jq -r '.access_token // empty')

  if [ -z "$access_token" ] || [ "$access_token" = "null" ]; then
    log "  ERROR: Failed to get access token"
    return 1
  fi

  # Check server status
  local server_info
  server_info=$(curl -s "$API_BASE/servers/$server_id" \
    -H "Authorization: Bearer $access_token")

  local state
  state=$(echo "$server_info" | jq -r '.serverLiveInfo.state // empty')

  if [ "$state" = "RUNNING" ]; then
    log "  OK: $server_name is RUNNING"
    return 0
  else
    log "  FAIL: $server_name state is '$state'"
    return 1
  fi
}

# Read current state
csb0_failures=$(jq -r '.csb0_failures // 0' "$STATE_FILE")
csb1_failures=$(jq -r '.csb1_failures // 0' "$STATE_FILE")

log "=== Netcup Monitor Run ==="
log "Previous failures - csb0: $csb0_failures, csb1: $csb1_failures"

# Check csb0
if check_server "$CSB0_ID" "csb0"; then
  csb0_failures=0
else
  csb0_failures=$((csb0_failures + 1))
fi

# Check csb1
if check_server "$CSB1_ID" "csb1"; then
  csb1_failures=0
else
  csb1_failures=$((csb1_failures + 1))
fi

# Save state
echo "{\"csb0_failures\":$csb0_failures,\"csb1_failures\":$csb1_failures,\"last_check\":\"$(date -Iseconds)\"}" >"$STATE_FILE"

log "Current failures - csb0: $csb0_failures, csb1: $csb1_failures"

# Alert if 2+ consecutive days offline (and continue alerting daily)
alert_servers=""
if [ "$csb0_failures" -ge 2 ]; then
  alert_servers="csb0 (${csb0_failures} days)"
fi
if [ "$csb1_failures" -ge 2 ]; then
  [ -n "$alert_servers" ] && alert_servers="$alert_servers, "
  alert_servers="${alert_servers}csb1 (${csb1_failures} days)"
fi

if [ -n "$alert_servers" ]; then
  # Send to Telegram + Email
  notify "🚨 Netcup Server Alert" "Servers offline for 2+ days: $alert_servers. Check immediately!"

  # Also notify LaMetric devices with alarm sound
  notify_lametric "SERVER DOWN: $alert_servers" "alarm1"

  log "ALERT sent for: $alert_servers"
else
  log "All servers OK or first failure - no alert needed"
fi

log "=== Monitor Complete ==="
