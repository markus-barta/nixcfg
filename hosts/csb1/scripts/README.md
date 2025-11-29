# csb1 Scripts

Operational utilities and helper scripts for csb1. These are **not tests** - they are tools for server management.

## Scripts

| Script              | Purpose                      | When to Use               |
| ------------------- | ---------------------------- | ------------------------- |
| `netcup-api.sh`     | Test Netcup API connectivity | Verify API token works    |
| `restart-safety.sh` | Pre-restart checklist        | Before any server restart |

## Usage

```bash
# Test Netcup API access
./netcup-api.sh

# Run pre-restart safety checks
./restart-safety.sh
```

## Netcup API Setup

See `netcup-api.md` for OAuth2 device flow setup instructions.

The API token is stored in `../secrets/netcup-api-refresh-token.txt` (gitignored).

## Related

- `../tests/` - Repeatable health checks
- `../migrations/` - One-time migration scripts
- `../secrets/RUNBOOK.md` - Emergency procedures
