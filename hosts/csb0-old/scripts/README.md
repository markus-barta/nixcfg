# csb0 Scripts

Operational utilities and helper scripts for csb0. These are **not tests** - they are tools for server management.

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

## API Token

Uses the same Netcup API token as csb1. Copy from csb1 if needed:

```bash
cp ../csb1/secrets/netcup-api-refresh-token.txt ../secrets/
```

## Related

- `../secrets/RUNBOOK.md` - Emergency procedures
