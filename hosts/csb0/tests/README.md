# csb0 Test Suite

This directory contains test procedures and automated scripts to verify csb0 server functionality.

## Quick Start

```bash
# Run all tests
cd hosts/csb0
for test in tests/T*.sh; do
  echo "Running $test..."
  bash "$test" || echo "❌ Failed: $test"
done
```

## Test Status

| Test ID | Feature        | 🤖 Auto | Result | Notes                      |
| ------- | -------------- | ------- | ------ | -------------------------- |
| T15     | Netcup API     | ⏳      | ⏳     | Server status via REST API |
| T16     | Restart Safety | ⏳      | ⏳     | Pre-restart safety checks  |

## Environment Variables

```bash
export CSB0_HOST="cs0.barta.cm"
export CSB0_USER="mba"
export CSB0_SSH_PORT="2222"
```

## API Token Setup

The same Netcup API token works for both csb0 and csb1:

```bash
# Copy from csb1
cp hosts/csb1/secrets/netcup-api-refresh-token.txt hosts/csb0/secrets/
```

## Server Info

| Item      | Value                        |
| --------- | ---------------------------- |
| Nickname  | csb0                         |
| Server ID | 607878                       |
| Name      | v2202401214994252795         |
| IP        | 85.235.65.226                |
| SSH       | ssh -p 2222 mba@cs0.barta.cm |

## API Commands

```bash
# Get token
TOKEN=$(curl -s 'https://servercontrolpanel.de/realms/scp/protocol/openid-connect/token' \
  -d 'client_id=scp' -d "refresh_token=$(cat secrets/netcup-api-refresh-token.txt)" \
  -d 'grant_type=refresh_token' | jq -r '.access_token')

# Check status
curl -s 'https://servercontrolpanel.de/scp-core/api/v1/servers/607878' \
  -H "Authorization: Bearer $TOKEN" | jq '.serverLiveInfo.state'

# Restart (graceful)
curl -X POST 'https://servercontrolpanel.de/scp-core/api/v1/servers/607878/acpi-shutdown' \
  -H "Authorization: Bearer $TOKEN"
# Wait 60-90 seconds
curl -X POST 'https://servercontrolpanel.de/scp-core/api/v1/servers/607878/start' \
  -H "Authorization: Bearer $TOKEN"
```
