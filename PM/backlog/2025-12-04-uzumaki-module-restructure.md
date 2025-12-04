# Uzumaki Module Restructure

## Status: BACKLOG

## Overview

Restructure the `modules/shared/` and `modules/uzumaki/` directories into a consistent, coherent, and properly architected Nix module system.

## Current State

### Problems

1. **Inconsistent module structure:**
   - `modules/shared/` contains mixed content (fish-config.nix, theme files, stasysmo/, etc.)
   - `modules/uzumaki/` has ad-hoc files that aren't proper Nix modules
   - No clear separation between "library code" and "module definitions"

2. **uzumaki is not a real module:**
   - `common.nix` exports raw attribute sets, not a proper module
   - `server.nix` and `desktop.nix` are fragments, not standalone modules
   - `macos-common.nix` and `macos.nix` follow different patterns than NixOS counterparts
   - No `default.nix` entry point
   - No module options (`config`, `options`, `lib`)

3. **Function definitions scattered:**
   - Fish functions defined in `uzumaki/common.nix`
   - But exported via string interpolation in `server.nix`/`desktop.nix`
   - macOS uses different export mechanism (`inherit`)

4. **Naming inconsistency:**
   - `stasysmo/` uses proper module pattern with `nixos.nix` and `home-manager.nix`
   - Other shared code doesn't follow this pattern

## Proposed Structure

```
modules/
├── common.nix                    # Base NixOS config (existing)
├── lib/
│   └── utils.nix                 # Shared utility functions
├── shared/
│   ├── fish/
│   │   ├── aliases.nix           # Shared aliases
│   │   ├── abbreviations.nix     # Shared abbreviations
│   │   └── functions.nix         # Shared fish functions (pingt, stress, etc.)
│   ├── starship/
│   │   ├── template.toml         # Starship template
│   │   └── README.md
│   ├── stasysmo/                  # (keep as-is, good structure)
│   │   ├── nixos.nix
│   │   ├── home-manager.nix
│   │   ├── daemon.sh
│   │   ├── reader.sh
│   │   └── ...
│   └── theme/
│       ├── palettes.nix          # Color palettes
│       └── hm.nix                 # Home-manager theme module
└── uzumaki/
    ├── default.nix               # Main entry point with module options
    ├── options.nix               # Module option definitions
    ├── nixos.nix                 # NixOS-specific implementation
    ├── darwin.nix                # macOS-specific implementation (nix-darwin)
    ├── home-manager.nix          # Home-manager integration
    └── README.md                 # Documentation
```

## Goals

### 1. Make uzumaki a proper Nix module

```nix
# Usage in host config:
imports = [ ../../modules/uzumaki ];

uzumaki = {
  enable = true;
  role = "server";  # or "desktop" or "workstation"

  fish = {
    functions.pingt = true;
    functions.stress = true;
  };

  theme.palette = "green";
};
```

### 2. Consistent patterns

- All modules follow the same structure
- Clear separation: options → implementation → platform-specific
- Proper use of `mkOption`, `mkEnableOption`, `mkIf`

### 3. Better code reuse

- Fish functions defined once, used everywhere
- No string interpolation hacks
- Proper module composition

### 4. Documentation

- Each module directory has a README
- Module options are self-documenting with descriptions
- Examples for common use cases

## Implementation Plan

### Phase 1: Audit and Document

- [ ] Document current module dependencies
- [ ] Map which hosts use which modules
- [ ] Identify breaking changes

### Phase 2: Create uzumaki Module Framework

- [ ] Create `uzumaki/default.nix` with basic structure
- [ ] Define module options in `uzumaki/options.nix`
- [ ] Migrate server.nix logic to proper module

### Phase 3: Consolidate Fish Configuration

- [ ] Move fish functions to `shared/fish/functions.nix`
- [ ] Create proper export mechanism (no string interpolation)
- [ ] Update uzumaki module to use shared fish config

### Phase 4: Migrate Hosts

- [ ] Update one host as pilot (hsb1?)
- [ ] Verify all functionality works
- [ ] Migrate remaining hosts incrementally

### Phase 5: Cleanup

- [ ] Remove deprecated files
- [ ] Update documentation
- [ ] Add integration tests

## Risks

- Breaking existing host configurations
- Complex migration due to interdependencies
- macOS vs NixOS differences need careful handling

## Acceptance Criteria

- [ ] `modules/uzumaki/` is a proper Nix module with options
- [ ] All hosts can import uzumaki with role-based configuration
- [ ] Fish functions defined once, work on NixOS and macOS
- [ ] Consistent directory structure across all modules
- [ ] Documentation for module usage
- [ ] No regression in functionality on any host

## References

- [Nix Module System](https://nixos.wiki/wiki/NixOS_modules)
- Current hokage pattern: `github:pbek/nixcfg`
- StaSysMo as reference for good module structure

## Priority

Medium - improves maintainability but not blocking any features

## Estimated Effort

Large - touches many files, requires careful migration
