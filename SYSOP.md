# SYSOP - Infrastructure Operations

## Reachability

| Source         | Target  | How          |
| -------------- | ------- | ------------ |
| Home (`imac0`) | `*.lan` | Direct       |
| Home           | `csb*`  | Internet     |
| Work           | `*.lan` | VPN required |
| Work           | `csb*`  | Internet     |

## Operation Loop

1. **Plan**: What, why, risk level (🔴/🟡/🟢)
2. **Commit**: Local changes first
3. **Execute**: Edit in `nixcfg` → push → deploy via NixFleet
4. **Verify**: Run host tests (`hosts/<host>/tests/T*.sh`)
5. **Update**: Sync docs

## Restricted Actions (ASK FIRST)

- SSH writes/switches
- Builds on macOS
- Secret rekeying (`just rekey`)
- Push to `main` without `nix flake check`
- Touch `.age`/`.env` files
- Direct server edits

## Host Inventory

| Host  | User   | Port | Role                   |
| ----- | ------ | ---- | ---------------------- |
| hsb0  | mba    | 22   | DNS/DHCP (Crown Jewel) |
| hsb1  | mba    | 22   | Home Automation        |
| hsb8  | mba    | 22   | Parents' Server        |
| csb0  | mba    | 2222 | Cloud Smart Home       |
| csb1  | mba    | 2222 | Monitoring             |
| gpc0  | mba    | 22   | Build Host             |
| imac0 | markus | 22   | Home Workstation       |

## Key Commands

```bash
# Deploy
ssh mba@gpc0.lan "cd ~/Code/nixcfg && sudo nixos-rebuild switch --flake .#<host>"

# Tests
hosts/<host>/tests/T*.sh

# Secrets
agenix -e secrets/<name>.age
```

## Sources

- Infra: `docs/INFRASTRUCTURE.md`
- Workflow: `docs/AGENT-WORKFLOW.md`
- Host docs: `hosts/<host>/docs/RUNBOOK.md`
