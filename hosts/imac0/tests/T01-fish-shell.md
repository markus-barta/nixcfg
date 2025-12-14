# T01: Fish Shell

Test Fish shell configuration and uzumaki functions.

## Prerequisites

- Fish shell installed from Nix
- uzumaki module configured in home-manager

## Uzumaki Functions Overview

| Function      | Description                  | Source       |
| ------------- | ---------------------------- | ------------ |
| `pingt`       | Timestamped ping with colors | uzumaki      |
| `sourcefish`  | Load .env files into Fish    | uzumaki      |
| `stress`      | CPU stress test              | uzumaki      |
| `helpfish`    | Show all functions/aliases   | uzumaki      |
| `stasysmod`   | Toggle StaSysMo debug        | uzumaki      |
| `hostcolors`  | Show hosts with color themes | uzumaki      |
| `hostsecrets` | Show runbook secrets status  | uzumaki      |
| `brewall`     | Homebrew maintenance         | macos-common |

## SSH Shortcuts (Aliases)

| Alias  | Target            | Description      |
| ------ | ----------------- | ---------------- |
| `hsb0` | 192.168.1.99      | Home server 0    |
| `hsb1` | 192.168.1.101     | Home server 1    |
| `hsb8` | 192.168.1.100     | Home server 8    |
| `gpc0` | 192.168.1.154     | Gaming PC        |
| `mbpw` | 192.168.1.197     | Work MacBook Pro |
| `csb0` | cs0.barta.cm:2222 | Cloud server 0   |
| `csb1` | cs1.barta.cm:2222 | Cloud server 1   |

## Manual Test Procedures

### Test 1: Fish Installation

```bash
fish --version     # Should be 4.x
which fish         # Should be ~/.nix-profile/bin/fish
```

### Test 2: Core Functions

```bash
# All should exist
fish -c "functions -q pingt sourcefish stress helpfish stasysmod hostcolors hostsecrets"

# Test pingt (should show timestamps)
pingt -c 1 127.0.0.1

# Test helpfish (should show all functions)
helpfish

# Test hostcolors (should show color-coded host overview)
hostcolors

# Test hostsecrets (shows runbook secrets status)
hostsecrets
```

### Test 3: SSH Shortcuts

```bash
# Type alias name, should connect with zellij session
hsb1  # → ssh mba@192.168.1.101 -t 'zellij attach hsb1 -c'
mbpw  # → ssh mba@192.168.1.197 -t 'zellij attach mbpw -c'
```

### Test 4: Abbreviations

```bash
# Type and press Space to expand
ping     # → pingt
tmux     # → zellij
flushdns # → sudo killall -HUP mDNSResponder...
```

## Summary

- Total Tests: 10 (in automated script)
- Core functions: 7 required
- SSH shortcuts: 7 (optional)

## Related

- Module: `modules/uzumaki/fish/`
- Config: `modules/uzumaki/fish/config.nix` (aliases)
- Functions: `modules/uzumaki/fish/functions.nix`
- Automated: [T01-fish-shell.sh](./T01-fish-shell.sh)
