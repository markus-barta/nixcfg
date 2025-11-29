# csb0 Tests

Repeatable health checks for csb0. These tests can be run **anytime** and should always pass on a healthy system.

## Current Status

No automated tests yet. csb0 uses similar infrastructure to csb1.

## Planned Tests

| Test | Description     | Priority |
| ---- | --------------- | -------- |
| T00  | NixOS Base      | High     |
| T01  | Docker Services | High     |
| T05  | Backup System   | Medium   |
| T06  | SSH Access      | High     |
| T07  | ZFS Storage     | Medium   |

## Usage

Tests can be adapted from csb1:

```bash
# Copy and modify from csb1
cp ../csb1/tests/T00-nixos-base.sh ./
# Edit to change HOST, PORT variables for csb0
```

## Related

- `../scripts/` - Operational utilities (API, restart safety)
- `../secrets/RUNBOOK.md` - Emergency procedures
