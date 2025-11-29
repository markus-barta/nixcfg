# T15: Netcup API Status Test

**Feature ID**: F15  
**Status**: ⏳ Pending  
**Purpose**: Verify server status via Netcup SCP REST API

## Overview

Uses the Netcup Server Control Panel API to verify server status and provides programmatic access to server controls (restart, power off, etc).

## Prerequisites

- Netcup SCP API refresh token stored in `secrets/netcup-api-refresh-token.txt`
- `curl` and `jq` installed
- Network access to servercontrolpanel.de

## Initial Setup (One-Time)

### Step 1: Generate Device Code

```bash
curl -X POST 'https://servercontrolpanel.de/realms/scp/protocol/openid-connect/auth/device' \
  -d "client_id=scp" \
  -d 'scope=offline_access openid' | jq
```

Response:

```json
{
  "device_code": "<device-code>",
  "user_code": "<user-code>",
  "verification_uri": "https://servercontrolpanel.de/realms/scp/device",
  "verification_uri_complete": "https://servercontrolpanel.de/realms/scp/device?user_code=<user-code>",
  "expires_in": 600
}
```

### Step 2: Authenticate in Browser

1. Open `verification_uri_complete` in browser
2. Login with Netcup credentials + 2FA
3. Accept grant access

### Step 3: Get Refresh Token

```bash
curl -X POST 'https://servercontrolpanel.de/realms/scp/protocol/openid-connect/token' \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:device_code' \
  -d 'device_code=<device-code>' \
  -d 'client_id=scp' | jq
```

### Step 4: Save Refresh Token

```bash
# Save to secrets (gitignored)
echo "<refresh-token>" > hosts/csb1/secrets/netcup-api-refresh-token.txt
chmod 600 hosts/csb1/secrets/netcup-api-refresh-token.txt
```

## API Endpoints

### Get Access Token (from refresh token)

```bash
curl -s 'https://servercontrolpanel.de/realms/scp/protocol/openid-connect/token' \
  -d 'client_id=scp' \
  -d "refresh_token=$(cat secrets/netcup-api-refresh-token.txt)" \
  -d 'grant_type=refresh_token' | jq -r '.access_token'
```

### List Servers

```bash
curl -s 'https://servercontrolpanel.de/scp-core/api/v1/servers?limit=10' \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq
```

### Get Server Info

```bash
# Server nickname: v2202407214994279426 (csb1)
curl -s 'https://servercontrolpanel.de/scp-core/api/v1/servers/v2202407214994279426' \
  -H "Authorization: Bearer $ACCESS_TOKEN" | jq
```

### Server Power Controls

```bash
# Start server
curl -X POST 'https://servercontrolpanel.de/scp-core/api/v1/servers/v2202407214994279426/start' \
  -H "Authorization: Bearer $ACCESS_TOKEN"

# Stop server (graceful)
curl -X POST 'https://servercontrolpanel.de/scp-core/api/v1/servers/v2202407214994279426/stop' \
  -H "Authorization: Bearer $ACCESS_TOKEN"

# Hard reset
curl -X POST 'https://servercontrolpanel.de/scp-core/api/v1/servers/v2202407214994279426/reset' \
  -H "Authorization: Bearer $ACCESS_TOKEN"

# ACPI shutdown
curl -X POST 'https://servercontrolpanel.de/scp-core/api/v1/servers/v2202407214994279426/acpi-shutdown' \
  -H "Authorization: Bearer $ACCESS_TOKEN"
```

## Automated Test

```bash
./tests/T15-netcup-api.sh
```

## Success Criteria

- ✅ API authentication successful
- ✅ Server found in API response
- ✅ Server state is "running"
- ✅ Server info matches expected values

## Token Maintenance

- Refresh tokens don't expire if used every 30 days
- Test runs regularly will keep token alive
- If token expires, repeat initial setup

## Test Log

| Date | Tester | Result | Notes |
| ---- | ------ | ------ | ----- |
|      |        | ⏳     |       |
