# Dynamic helpfish data

**Created**: 2025-12-24  
**Priority**: P8300 (Backlog)  
**Status**: Backlog

---

## Problem

The `helpfish` function currently uses hardcoded `printf` statements to display available functions, aliases, and abbreviations. This makes it difficult to maintain and often results in the help output being out of sync with the actual shell environment.

Current implementation in `modules/uzumaki/fish/functions.nix` is a manual list that must be updated every time a new tool is added to the infrastructure.

---

## Solution

Refactor `helpfish` to derive its output from dynamic data sources and the live shell environment where possible.

### Proposed Data Sources

1.  **Functions**:
    - Use `functions -D` to get descriptions if available.
    - Parse `modules/uzumaki/fish/functions.nix` via `nix eval` to get the list of functions and their intended help text.
2.  **Abbreviations/Aliases**:
    - Use `abbr -l` and `alias` to list active definitions.
    - Filter for "known" or "interesting" ones to keep the output clean.
3.  **SSH Shortcuts**:
    - Fetch host list and descriptions from `modules/uzumaki/theme/theme-palettes.nix` or `docs/INFRASTRUCTURE.md` using `nix eval`.
    - This ensures `helpfish` always matches the current infrastructure inventory.

### Complexity & "Great Lengths"

As requested, we should aim for maximum dynamism. This might involve:

- A small helper script (perhaps in `scripts/`) that `helpfish` calls to gather data.
- Using `nix eval` within the fish function to pull data from the Nix configuration files (similar to how `hostcolors` works).
- Parsing markdown docs if they are the only source of truth for certain descriptions.

_Note: If implementing the Nix-to-Fish bridge becomes too complex, consult the user._

---

## Acceptance Criteria

- [ ] `helpfish` no longer contains a hardcoded list of `uzumaki` functions.
- [ ] Abbreviations and Aliases are discovered dynamically.
- [ ] SSH shortcuts are sourced from the repository's host configuration.
- [ ] The visual style (boxed headers, color-coding) is preserved or improved.
- [ ] Performance remains acceptable (caching may be needed if `nix eval` is too slow).

---

## Test Plan

### Manual Test

1. Add a dummy function to `modules/uzumaki/fish/functions.nix`.
2. Run `helpfish` and verify the new function appears automatically.
3. Remove a host from the Nix configuration and verify it disappears from `helpfish` SSH shortcuts.

### Automated Test

```bash
# Check if helpfish output contains a known dynamic element
helpfish | grep -q "hostcolors"
```

---

## Related

- Enables: Better developer experience across all hosts.
- Related: `P6900-fish-tokyo-night-syntax.md`
