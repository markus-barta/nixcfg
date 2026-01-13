# P8300: Auto-sync helpfish function list

**Created**: 2025-12-24  
**Priority**: P8300 (Backlog)  
**Status**: Backlog  
**Effort**: 2 hours  
**Risk**: Low

---

## Problem

The `helpfish` function uses **hardcoded `printf` statements** for the function list. Every time a new function is added to `modules/uzumaki/fish/functions.nix`, you must manually update:

1. `functions.nix` - helpfish body (line ~282-289)
2. `default.nix` - fishInitFunctions (lines 56-66)
3. `options.nix` - function toggle options (lines 48-96)

**Result:** Functions get out of sync, causing confusion.

---

## Solution (Option C: Hybrid Approach)

**Auto-generate the function list** from `functions.nix` during build, keep aliases/abbreviations/SSH hardcoded (they rarely change).

### Architecture

```
Build Time (modules/uzumaki/default.nix):
  1. Import functions.nix
  2. Extract: name + description for each function
  3. Generate printf statements as string
  4. Inject into helpfish function body

Runtime:
  helpfish → displays pre-generated list (instant)
```

### Implementation Details

**In `modules/uzumaki/default.nix`:**

```nix
let
  # Extract function data from functions.nix
  funcData = lib.mapAttrsToList (name: def: {
    inherit name;
    desc = def.description;
  }) (import ./fish/functions.nix);

  # Generate printf statements
  funcList = lib.concatStringsSep "\n" (lib.map (f:
    ''printf " $color_func%-12s$color_reset %-58s\n" "${f.name}" "${f.desc}"''
  ) funcData);

in {
  # Inject into helpfish
  programs.fish.interactiveShellInit = ''
    function helpfish
      # ... header ...
      ${funcList}
      # ... rest ...
    end
  '';
}
```

**In `modules/uzumaki/fish/functions.nix`:**

- Remove hardcoded function list from helpfish
- Keep the rest (aliases, abbreviations, SSH)

### What Stays Hardcoded

- **Aliases** (`config.nix`) - Stable, rarely change
- **Abbreviations** (`config.nix`) - Stable, rarely change
- **SSH shortcuts** (`config.nix`) - IPs stable

### What Becomes Dynamic

- **Functions** - Auto-sync from `functions.nix`

---

## Acceptance Criteria

- [ ] Adding a function to `functions.nix` automatically appears in `helpfish`
- [ ] No manual updates needed to helpfish body
- [ ] Build time overhead < 1 second
- [ ] Runtime performance unchanged (instant)
- [ ] Visual style preserved

---

## Test Plan

1. Add test function to `functions.nix`
2. Rebuild system
3. Run `helpfish` → verify new function appears
4. Run `helpfish | grep -q "test-function"`

---

## Related

- **P8400**: Full module refactor (Option D) - future
- **P6900**: Fish Tokyo Night syntax
