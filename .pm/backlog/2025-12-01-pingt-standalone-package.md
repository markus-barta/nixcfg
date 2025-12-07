# 2025-12-01 - Create Standalone pingt Package

## Status: BACKLOG (Medium Priority - Confirmed Interest)

## Description

Create a standalone Nix package for the `pingt` fish function (timestamped ping with color-coded output).

## Current Implementation

**Location:** `modules/uzumaki/fish/functions.nix`

```fish
pingt = {
  description = "Timestamped ping with color-coded output";
  body = ''
    set -l color_gray (set_color brblack)
    # ... color-coded ping output with timestamps
    command ping $argv 2>&1 | while read -l line
      # Yellow for timeouts, red for errors, normal otherwise
    end
  '';
};
```

**Usage:**

- Defined as fish function via uzumaki module
- Aliased: `ping` → `pingt` in `common.nix`
- Works on all hosts with uzumaki/fish enabled

## Analysis

### Current State: ✅ Working Fine

| Aspect        | Status                                |
| ------------- | ------------------------------------- |
| Functionality | ✅ Works perfectly                    |
| Availability  | ✅ All NixOS & macOS hosts            |
| Maintenance   | ✅ Single definition in functions.nix |
| Shell support | Fish only (by design)                 |

### Effort to Package

| Option              | Effort | Notes                                      |
| ------------------- | ------ | ------------------------------------------ |
| Fish script package | Low    | Wrap current function as executable script |
| Bash rewrite        | Medium | Different color handling, string matching  |
| Python/Go rewrite   | High   | Cross-platform but overkill                |

### Confirmed Interest (2025-12-07)

1. **Bash/zsh support needed?** ✅ YES - for broader usability
2. **Upstreaming?** ✅ YES - pbek expressed interest in using it
3. **Other users?** ✅ YES - pbek would love it and use it!

## Recommendation

**Proceed with packaging** - confirmed external interest from pbek.

Suggested approach: **Bash rewrite** for maximum compatibility (works in fish, bash, zsh).

## Implementation Plan

### Recommended: Bash Script Package

Pure bash for maximum compatibility (fish, bash, zsh, sh):

```bash
#!/usr/bin/env bash
# pingt - Timestamped ping with color-coded output

# ANSI colors
GRAY='\033[90m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

ping "$@" 2>&1 | while IFS= read -r line; do
  timestamp=$(date '+%H:%M:%S')
  case "$line" in
    *timeout*|*"Request timeout"*)
      printf "${GRAY}%s ·${RESET} ${YELLOW}%s${RESET}\n" "$timestamp" "$line"
      ;;
    *sendto:*|*"No route to host"*|*"Host is down"*|*"Destination Host Unreachable"*)
      printf "${GRAY}%s ·${RESET} ${RED}%s${RESET}\n" "$timestamp" "$line"
      ;;
    *)
      printf "${GRAY}%s ·${RESET} %s\n" "$timestamp" "$line"
      ;;
  esac
done
```

### Nix Package

```nix
# pkgs/pingt/default.nix
{ writeShellApplication }:
writeShellApplication {
  name = "pingt";
  text = builtins.readFile ./pingt.sh;
}
```

### Alternative: Keep Fish Function Too

Could provide both:

- `pingt` bash script (standalone package)
- Fish function (for fish-specific features if needed)

## Acceptance Criteria (if proceeding)

- [ ] Create package definition in `pkgs/pingt/`
- [ ] Package provides `pingt` command
- [ ] Maintains current functionality
- [ ] Test on server and desktop hosts
- [ ] Document the package

## Notes

- Currently aliased: `ping` → `pingt` (overrides hokage's `ping` → `gping`)
- Used daily for network diagnostics
- Low urgency - current solution works well
