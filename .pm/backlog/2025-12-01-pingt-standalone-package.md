# 2025-12-01 - Create Standalone pingt Package

## Status: BACKLOG (Low Priority - Reassess Need)

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

### Questions to Consider

1. **Is bash/zsh support needed?** Current fish-only works for our use case
2. **Upstreaming?** Is there interest in contributing to nixpkgs?
3. **ROI?** Time spent vs benefit gained

## Recommendation

**Deprioritize** unless:

- Need to use pingt from non-fish shells
- Planning to upstream to nixpkgs
- Other users request it

The fish function approach is simple, maintainable, and works perfectly.

## If We Proceed

### Option A: Fish Script Package (Recommended)

```nix
# pkgs/pingt/default.nix
{ writeShellApplication, fish }:
writeShellApplication {
  name = "pingt";
  runtimeInputs = [ fish ];
  text = ''
    fish -c 'source ${./pingt.fish}; pingt $argv' -- "$@"
  '';
}
```

### Option B: Bash Rewrite

Would need to handle:

- `set_color` → ANSI escape codes
- `string match` → bash pattern matching
- Fish `while read` → bash equivalent

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
