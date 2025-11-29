# csb1 Tests

Repeatable health checks for csb1. These tests can be run **anytime** and should always pass on a healthy system.

## Tests

| Test | Description     | What It Checks                    |
| ---- | --------------- | --------------------------------- |
| T00  | NixOS Base      | Version, generations, systemd     |
| T01  | Docker Services | Containers running, healthy       |
| T02  | Grafana         | Dashboard accessible              |
| T03  | InfluxDB        | Database healthy, buckets exist   |
| T04  | Traefik         | Reverse proxy, SSL certs          |
| T05  | Backup System   | Restic configured, recent backups |
| T06  | SSH Access      | Key auth, sudo, hardening         |
| T07  | ZFS Storage     | Pool health, compression          |

## Usage

```bash
# Run all tests
for f in T*.sh; do ./$f; done

# Run specific test
./T00-nixos-base.sh

# Quick health check
./T00-nixos-base.sh && ./T01-docker-services.sh
```

## Test Format

Each test has:

- `TXX-name.md` - Manual test procedure and expected results
- `TXX-name.sh` - Automated test script

## Exit Codes

- `0` - All checks passed
- `1` - One or more checks failed

## Related

- `../scripts/` - Operational utilities (API, restart safety)
- `../migrations/` - One-time migration scripts
- `../docs/` - Documentation
