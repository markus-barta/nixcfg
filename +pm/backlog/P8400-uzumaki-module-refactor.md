# P8400: Uzumaki Module - Full Data-Driven Refactor

**Created**: 2026-01-13  
**Priority**: P8400 (Backlog)  
**Status**: Backlog  
**Effort**: 10-15 hours  
**Risk**: Medium (architecture change)

---

## Problem

Current uzumaki module has **scattered configuration**:

```
modules/uzumaki/
├── fish/functions.nix     ← Function definitions
├── fish/config.nix        ← Aliases + abbreviations
├── default.nix            ← Manual function list (lines 56-66)
├── options.nix            ← Manual toggle options (lines 48-96)
└── theme/theme-palettes.nix ← Host data
```

**Issues:**

- 3 places to update when adding a function
- No single source of truth
- Hard to test
- Hard to extend

---

## Solution (Option D: Architectural Refactor)

Create a **data-driven architecture** with clear separation:

### New Structure

```
modules/uzumaki/
├── data.nix               ← SINGLE SOURCE OF TRUTH
│   └── Exports: functions, aliases, abbreviations, ssh
│
├── builder.nix            ← Generates fish config
│   └── Converts data → fish functions/aliases
│
├── helpfish.nix           ← Pure fish function
│   └── Reads generated data
│
├── default.nix            ← Entry point (simplified)
│   └── Imports builder + options
│
└── options.nix            ← Auto-generated from data.nix
```

### Data Flow

```
data.nix (source)
    ↓
builder.nix (transforms)
    ↓
/etc/fish/config.fish (generated)
    ↓
helpfish (reads & displays)
```

### Benefits

1. **Single Source of Truth** - `data.nix` only
2. **Auto-generated Options** - No manual lists
3. **Testable** - Can unit test data transformations
4. **Extensible** - Easy to add new tool categories
5. **Maintainable** - Clear patterns

### Example: data.nix

```nix
{
  functions = {
    pingt = {
      description = "Timestamped ping";
      body = "...";
      enable = true;  # Default state
    };
    # ...
  };

  aliases = {
    gitc = "git commit";
    # ...
  };

  abbreviations = {
    ping = "pingt";
    # ...
  };

  ssh = {
    hsb0 = {
      user = "mba";
      ip = "192.168.1.99";
      desc = "Home server 0";
    };
    # ...
  };
}
```

### Example: builder.nix

```nix
{ data, lib, pkgs, ... }:

let
  # Generate fish functions
  fishFunctions = lib.mapAttrsToList (name: def:
    if def.enable then ''
      function ${name} --description '${def.description}'
        ${def.body}
      end
    '' else ""
  ) data.functions;

  # Generate helpfish content
  helpfishData = {
    functions = lib.mapAttrsToList (name: def: {
      inherit name;
      desc = def.description;
    }) data.functions;
    # ...
  };

in {
  # Write helpfish data to /etc/uzumaki-help.json
  environment.etc."uzumaki/help.json".text =
    builtins.toJSON helpfishData;

  # Generate fish init
  programs.fish.interactiveShellInit =
    lib.concatStrings fishFunctions;
}
```

### Example: helpfish.nix (simplified)

```fish
function helpfish
  set -l data (cat /etc/uzumaki/help.json | jq -r '.functions[] | "\(.name)|\(.desc)"')
  # ... display ...
end
```

---

## Implementation Phases

### Phase 1: Create data.nix (2 hours)

- Consolidate all sources into one file
- Validate structure

### Phase 2: Create builder.nix (4 hours)

- Generate fish functions
- Generate helpfish data
- Handle enable/disable flags

### Phase 3: Update default.nix + options.nix (3 hours)

- Wire up builder
- Auto-generate options from data
- Remove manual lists

### Phase 4: Update helpfish (1 hour)

- Read generated JSON
- Preserve visual style

### Phase 5: Testing + Migration (2-3 hours)

- Test on all hosts
- Verify no regressions
- Update docs

---

## Acceptance Criteria

- [ ] `data.nix` is single source of truth
- [ ] All options auto-generated from data
- [ ] `helpfish` reads generated data
- [ ] Build time unchanged or faster
- [ ] All existing functions/aliases work
- [ ] Documentation updated

---

## Related

- **P8300**: Quick fix (auto-sync functions only)
- **Enables**: P8500+ (new tool categories, testing framework)

---

## Notes

**When to do this:**

- After P8300 proves value
- When adding 3+ new tool categories
- When you have 10-15 hours block

**Migration strategy:**

- Keep old module working
- Build new alongside
- Switch hosts one by one
- Remove old after verification
