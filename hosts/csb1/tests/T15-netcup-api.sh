#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# T15: Netcup API Status Test
# Verifies server status via Netcup SCP REST API
#

set -euo pipefail

# Configuration
SERVER_ID="${NETCUP_SERVER_ID:-646294}"
SERVER_NAME="${NETCUP_SERVER_NAME:-v2202407214994279426}"
API_BASE="https://servercontrolpanel.de/scp-core/api/v1"
AUTH_URL="https://servercontrolpanel.de/realms/scp/protocol/openid-connect/token"

# Find secrets directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_DIR="$(dirname "$SCRIPT_DIR")/secrets"
TOKEN_FILE="$SECRETS_DIR/netcup-api-refresh-token.txt"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "=== T15: Netcup API Status Test ==="
echo "Server: $SERVER_NAME (ID: $SERVER_ID)"
echo

# Check for refresh token
if [ ! -f "$TOKEN_FILE" ]; then
  echo -e "${YELLOW}⚠️ No API refresh token found${NC}"
  echo
  echo "To set up API access:"
  echo "1. Run the device code flow (see T15-netcup-api.md)"
  echo "2. Save refresh token to: $TOKEN_FILE"
  echo
  echo "Quick setup:"
  echo -e "${BLUE}curl -X POST 'https://servercontrolpanel.de/realms/scp/protocol/openid-connect/auth/device' \\${NC}"
  echo -e "${BLUE}  -d 'client_id=scp' -d 'scope=offline_access openid' | jq${NC}"
  exit 0
fi

REFRESH_TOKEN=$(cat "$TOKEN_FILE")

# Test 1: Get access token
echo -n "Test 1: API authentication... "
ACCESS_TOKEN=$(curl -s "$AUTH_URL" \
  -d 'client_id=scp' \
  -d "refresh_token=$REFRESH_TOKEN" \
  -d 'grant_type=refresh_token' 2>/dev/null | jq -r '.access_token // empty')

if [ -n "$ACCESS_TOKEN" ] && [ "$ACCESS_TOKEN" != "null" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (token refresh failed)"
  echo "Refresh token may have expired. Re-run setup."
  exit 1
fi

# Test 2: List servers
echo -n "Test 2: List servers... "
SERVERS=$(curl -s "$API_BASE/servers?limit=10" \
  -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null)

SERVER_COUNT=$(echo "$SERVERS" | jq -r 'length // 0')
if [ "$SERVER_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✅ PASS${NC} ($SERVER_COUNT servers found)"
else
  echo -e "${RED}❌ FAIL${NC} (no servers found)"
  exit 1
fi

# Test 3: Get server details
echo -n "Test 3: Get server $SERVER_ID... "
SERVER_INFO=$(curl -s "$API_BASE/servers/$SERVER_ID" \
  -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null)

SERVER_STATE=$(echo "$SERVER_INFO" | jq -r '.serverLiveInfo.state // empty')
if [ -n "$SERVER_STATE" ]; then
  echo -e "${GREEN}✅ PASS${NC}"
else
  echo -e "${RED}❌ FAIL${NC} (server not found)"
  exit 1
fi

# Test 4: Server is running
echo -n "Test 4: Server state... "
if [ "$SERVER_STATE" = "RUNNING" ]; then
  echo -e "${GREEN}✅ PASS${NC} ($SERVER_STATE)"
else
  echo -e "${YELLOW}⚠️ NOT RUNNING${NC} ($SERVER_STATE)"
fi

# Test 5: Server details
echo -n "Test 5: Server details... "
NICKNAME=$(echo "$SERVER_INFO" | jq -r '.nickname // "unknown"')
SERVER_IP=$(echo "$SERVER_INFO" | jq -r '.ipv4Addresses[0].ip // "unknown"')
UPTIME_SECS=$(echo "$SERVER_INFO" | jq -r '.serverLiveInfo.uptimeInSeconds // 0')
UPTIME_DAYS=$((UPTIME_SECS / 86400))
SNAPSHOT_COUNT=$(echo "$SERVER_INFO" | jq -r '.snapshotCount // 0')
echo -e "${GREEN}✅ PASS${NC}"

echo
echo "Server Information:"
echo "  Nickname: $NICKNAME"
echo "  Name: $SERVER_NAME"
echo "  ID: $SERVER_ID"
echo "  State: $SERVER_STATE"
echo "  IP: $SERVER_IP"
echo "  Uptime: $UPTIME_DAYS days"
echo "  Snapshots: $SNAPSHOT_COUNT"

echo
echo "========================================"
echo -e "${GREEN}🎉 Netcup API test passed!${NC}"
echo
echo -e "${BLUE}Available API commands (use ID $SERVER_ID):${NC}"
echo "  Status: curl -s '$API_BASE/servers/$SERVER_ID' -H 'Authorization: Bearer \$TOKEN' | jq '.serverLiveInfo.state'"
echo "  Start:  curl -X POST '$API_BASE/servers/$SERVER_ID/start' -H 'Authorization: Bearer \$TOKEN'"
echo "  Stop:   curl -X POST '$API_BASE/servers/$SERVER_ID/stop' -H 'Authorization: Bearer \$TOKEN'"
echo "  Reset:  curl -X POST '$API_BASE/servers/$SERVER_ID/reset' -H 'Authorization: Bearer \$TOKEN'"

exit 0
