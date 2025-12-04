# Uzumaki Module Restructure

## Status: BACKLOG

## Quick Reference

| Phase                | Description                                      | Status      |
| -------------------- | ------------------------------------------------ | ----------- |
| 1. Audit & Document  | Architecture flowcharts, dependency mapping      | ✅ Complete |
| 2. Module Framework  | Create `default.nix`, `options.nix`, role system | ⬜ Pending  |
| 3. Consolidate Fish  | Move to `shared/fish/`, proper exports           | ⬜ Pending  |
| 4. **Test Suite** 🧪 | Baseline tests, infrastructure, validation       | ⬜ Pending  |
| 5. Migrate Hosts     | Pilot → Rollout with validation gates            | ⬜ Pending  |
| 6. Cleanup           | Remove deprecated, update docs                   | ⬜ Pending  |

---

## Overview

Restructure `modules/shared/` and `modules/uzumaki/` into a proper NixOS module system.

**Uzumaki** is the "son of Hokage" - builds on hokage's infrastructure to add personalized tooling and theming. Hokage handles heavy lifting (user management, system setup); Uzumaki adds the personal touch (fish functions, per-host themes).

> ⚠️ **CAUTION:** Current setup works. Changes should be incremental and well-tested.

## Documentation Files

| File                                                           | Description                            |
| -------------------------------------------------------------- | -------------------------------------- |
| [architecture-current.md](./architecture-current.md)           | Current module structure documentation |
| [architecture-current.mermaid](./architecture-current.mermaid) | Current state flowchart (Mermaid)      |
| [architecture-planned.md](./architecture-planned.md)           | Planned module structure documentation |
| [architecture-planned.mermaid](./architecture-planned.mermaid) | Planned state flowchart (Mermaid)      |

## Problem Summary

### Current Issues

1. **uzumaki is not a real module** - No `default.nix`, no options, just importable files
2. **Inconsistent patterns** - NixOS uses `interactiveShellInit`, macOS uses `programs.fish.functions`
3. **String interpolation hacks** - `mkFishFunction` converts defs to strings
4. **No single entry point** - Hosts must know which file to import
5. **gpc0 special case** - Different module ordering to override hokage

### What Works (Don't Break!)

- ✅ All 6 NixOS hosts build and deploy
- ✅ Both macOS hosts work with home-manager
- ✅ Fish functions (pingt, stress, etc.) work everywhere
- ✅ Per-host theming (starship, zellij, eza)
- ✅ StaSysMo system metrics in prompts

## Proposed Solution

Transform uzumaki into a proper NixOS module:

```nix
# Future usage (single import, role-based)
imports = [ ../../modules/uzumaki ];

uzumaki = {
  enable = true;
  role = "server";  # or "desktop" or "workstation"
  stasysmo.enable = true;
};
```

See [architecture-planned.md](./architecture-planned.md) for full details.

## Implementation Phases

### Phase 1: Audit and Document ✓

- [x] Document current module dependencies
- [x] Map which hosts use which modules
- [x] Create architecture flowcharts
- [x] Identify breaking changes

### Phase 2: Create Module Framework

- [ ] Create `uzumaki/default.nix` with platform detection
- [ ] Define options in `uzumaki/options.nix`
- [ ] Add role-based defaults

### Phase 3: Consolidate Fish Configuration

- [ ] Move functions to `shared/fish/functions.nix`
- [ ] Create proper export mechanism (no string interpolation)
- [ ] Update module to use shared config

### Phase 4: Test Suite Development 🧪

> **Philosophy:** Test BEFORE migration. Validate current behavior, then verify identical behavior after migration. Zero regressions, zero surprises.

#### 4.0 Existing Test Infrastructure ✅

You already have professional-grade tests in `hosts/<host>/tests/`:

| Host          | Test Location                | Existing Tests                              |
| ------------- | ---------------------------- | ------------------------------------------- |
| hsb0          | `hosts/hsb0/tests/`          | T00-T11 (nixos-base, dns, dhcp, theme, zfs) |
| hsb1          | `hosts/hsb1/tests/`          | T01-theme                                   |
| hsb8          | `hosts/hsb8/tests/`          | T00-T19 (nixos-base, theme, zfs, agenix)    |
| csb0          | `hosts/csb0/tests/`          | _(check coverage)_                          |
| csb1          | `hosts/csb1/tests/`          | _(check coverage)_                          |
| gpc0          | —                            | _(needs tests directory)_                   |
| imac0         | `hosts/imac0/tests/`         | T00-T11 (nix-base, fish, theme, cli, gui)   |
| imac-mba-work | `hosts/imac-mba-work/tests/` | T00-T08 (nix-base, fish, starship, cli)     |

**Existing helper functions** (already in tests):

- `pass()` / `fail()` - Result reporting
- `check_file_exists()` - File presence check
- `check_file_contains()` - Pattern matching
- `check_unicode_python()` - Unicode verification (imac0)

#### 4.1 Audit Existing Tests (Uzumaki Coverage)

Review which existing tests already cover uzumaki functionality:

**Theme Tests (T01-theme.sh)** - Already comprehensive! ✅

- [x] Starship config exists with correct palette
- [x] Zellij config exists with correct theme
- [x] Eza theme file exists
- [x] Unicode/Nerd Font icons preserved
- [x] EZA_CONFIG_DIR set in fish

**Fish Shell Tests (T01-fish-shell.sh)** - Partial coverage:

- [x] Fish installed from Nix
- [x] Custom functions exist (`brewall`, `sourceenv`, `sourcefish`)
- [ ] **ADD:** `pingt` function exists
- [ ] **ADD:** `stress` function exists
- [ ] **ADD:** `helpfish` function exists

**NixOS Base Tests (T00-nixos-base.sh)** - System-level:

- [ ] Verify includes fish, zellij, starship packages

#### 4.2 New Tests to Add (Per Host)

**For ALL NixOS hosts** - Add to `hosts/<host>/tests/`:

```bash
# T02-uzumaki-fish.sh (or extend T01-fish-shell.sh)
- pingt function exists and callable
- sourcefish function exists
- sourceenv function exists
- stress function exists (shows core count)
- helpfish function displays function list
- Abbreviations: ping→pingt, tmux→zellij, vim→hx

# T03-uzumaki-stasysmo.sh (or add to existing)
- systemctl status stasysmo-daemon (active)
- /dev/shm/sysmon_* files exist
- stasysmo-reader produces output

# T04-uzumaki-zellij.sh
- which zellij returns path
- Config uses host-specific theme name
```

**For gpc0** - Create `hosts/gpc0/tests/`:

- [ ] `T00-nixos-base.sh` - Base system checks
- [ ] `T01-theme.sh` - Purple palette verification
- [ ] `T02-uzumaki-fish.sh` - Fish functions
- [ ] `T03-uzumaki-stasysmo.sh` - StaSysMo daemon
- [ ] `T10-desktop-plasma.sh` - Plasma integration
- [ ] `T11-desktop-gaming.sh` - Gaming packages

**For macOS hosts** - Extend existing tests:

- [ ] `T01-fish-shell.sh` - Add pingt, stress, helpfish checks
- [ ] `T12-stasysmo.sh` - LaunchAgent running check

#### 4.3 Pre-Migration Baseline

Run ALL existing tests and record results:

```bash
# Per host, SSH in and run:
cd ~/nixcfg/hosts/<host>/tests
./run-all-tests.sh 2>&1 | tee baseline-$(date +%Y%m%d).log
```

**Baseline Matrix:**

| Host          | T00 Base | T01 Theme | T02 Fish | T03 StaSysMo | Status  |
| ------------- | -------- | --------- | -------- | ------------ | ------- |
| hsb0          | ⬜       | ⬜        | ⬜       | ⬜           | Pending |
| hsb1          | ⬜       | ⬜        | ⬜       | ⬜           | Pending |
| hsb8          | ⬜       | ⬜        | ⬜       | ⬜           | Pending |
| csb0          | ⬜       | ⬜        | ⬜       | ⬜           | Pending |
| csb1          | ⬜       | ⬜        | ⬜       | ⬜           | Pending |
| gpc0          | ⬜       | ⬜        | ⬜       | ⬜           | Pending |
| imac0         | ⬜       | ⬜        | ⬜       | ⬜           | Pending |
| imac-mba-work | ⬜       | ⬜        | ⬜       | ⬜           | Pending |

**Legend:** ⬜ Pending | ✅ Pass | ❌ Fail | ⏭️ Skip

#### 4.4 Post-Migration Validation Tests

Add to each host's test directory:

```bash
# T20-uzumaki-module.sh - Verify new module works
- nixos-rebuild build --flake .#<host> succeeds
- Config uses uzumaki.enable = true
- Config uses uzumaki.role = "<role>"
- All T00-T03 tests still pass (regression check)
```

#### 4.5 Diff Comparison Script

Create `tests/compare-closures.sh`:

```bash
#!/usr/bin/env bash
# Compare system closures before/after migration
# Usage: ./compare-closures.sh <host>

HOST="$1"
nix build .#nixosConfigurations.$HOST.config.system.build.toplevel -o result-new
diff -u baseline-$HOST result-new/
```

### Phase 5: Migrate Hosts

> **Gate:** Phase 4 baseline tests MUST all pass before migration begins.

**Migration Procedure (per host):**

1. Run baseline tests → all pass ✅
2. Create backup branch: `git checkout -b backup/pre-uzumaki-<host>`
3. Update host config to use new uzumaki module
4. Build: `nixos-rebuild build --flake .#<host>`
5. Run T22 diff comparison
6. Deploy: `nixos-rebuild switch --flake .#<host>`
7. Run full test suite → all pass ✅
8. Document any deviations

**Migration Order:**

- [ ] **Pilot 1:** hsb1 (server) - Most stable, good test case
- [ ] **Pilot 2:** gpc0 (desktop) - Desktop-specific features
- [ ] **Pilot 3:** imac0 (workstation) - macOS validation
- [ ] **Rollout:** hsb0, hsb8, csb0, csb1, imac-mba-work

### Phase 6: Cleanup

- [ ] Remove deprecated files:
  - [ ] `modules/uzumaki/server.nix` (merged into nixos.nix)
  - [ ] `modules/uzumaki/desktop.nix` (merged into nixos.nix)
  - [ ] `modules/uzumaki/macos.nix` (merged into darwin.nix)
  - [ ] `modules/uzumaki/macos-common.nix` (consolidated)
- [ ] Update all documentation
- [ ] Archive migration tests (keep validation tests)
- [ ] Update README.md in modules/uzumaki/
- [ ] Final test run on all hosts

## Risks

| Risk                       | Mitigation                                                 |
| -------------------------- | ---------------------------------------------------------- |
| Breaking host configs      | Phase 4 baseline tests + backup branches before migration  |
| Module interdependencies   | Phase 1 audit + T22 diff comparison                        |
| macOS vs NixOS differences | Platform detection + separate test suites                  |
| gpc0 module ordering       | Role-based defaults + desktop-specific tests               |
| Silent regressions         | Comprehensive test matrix covering all features            |
| Test flakiness             | Deterministic tests, retry logic, clear pass/fail criteria |

## Acceptance Criteria

### Module Quality

- [ ] `modules/uzumaki/` is a proper Nix module with options
- [ ] All hosts import uzumaki with role-based configuration
- [ ] Fish functions defined once, work on NixOS and macOS
- [ ] Platform detection works correctly
- [ ] Documentation for module usage

### Test Coverage

- [ ] Baseline tests pass for ALL hosts before migration
- [ ] Test infrastructure (`tests/uzumaki/lib.sh`) complete
- [ ] Per-host test directories created and populated
- [ ] T22 diff shows minimal/expected changes only

### Zero Regressions

- [ ] All fish functions work identically post-migration
- [ ] All theme files generated correctly
- [ ] StaSysMo metrics functional on all hosts
- [ ] SSH abbreviations work (hsb0, hsb1, etc.)
- [ ] No build warnings introduced

## References

- [Nix Module System](https://nixos.wiki/wiki/NixOS_modules)
- [NixOS Module Options](https://nixos.org/manual/nixos/stable/#sec-writing-modules)
- External hokage: `github:pbek/nixcfg`
- Good local example: `modules/shared/stasysmo/`

## Priority & Effort

- **Priority:** Medium - improves maintainability but not blocking features
- **Effort:** Large - touches many files, requires careful migration
