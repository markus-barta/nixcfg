# Uzumaki Module Restructure

## Status: BACKLOG

## Quick Reference

| Phase                 | Description                                      | Status      |
| --------------------- | ------------------------------------------------ | ----------- |
| 1. Audit & Document   | Architecture flowcharts, dependency mapping      | ✅ Complete |
| 2. Module Framework   | Create `default.nix`, `options.nix`, role system | ✅ Complete |
| 3. Consolidate Fish   | Move to `shared/fish/`, proper exports           | ✅ Complete |
| 4. **Test Suite** 🧪  | Baseline tests, infrastructure, validation       | ✅ Complete |
| 5. Migrate Hosts (I)  | Pilot → Rollout: hsb0/1/8, gpc0, imac0/work      | ⬜ Pending  |
| 6. Cleanup (I)        | Remove deprecated, update docs                   | ⬜ Pending  |
| **─── Phase II ───**  | **Cloud Servers (csb0/csb1)** 🌐                 |             |
| 7. Mixins → Hokage    | Migrate csb0/csb1 from old mixins structure      | ⬜ Pending  |
| 8. Migrate Hosts (II) | Apply uzumaki module to csb0/csb1                | ⬜ Pending  |
| 9. Final Cleanup      | Complete documentation, archive tests            | ⬜ Pending  |

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

### Phase 2: Create Module Framework ✓

- [x] Create `uzumaki/default.nix` with platform detection
- [x] Define options in `uzumaki/options.nix`
- [x] Add role-based defaults (server/desktop/workstation)

**New files created:**

- `modules/uzumaki/default.nix` - Entry point with NixOS/Darwin detection
- `modules/uzumaki/options.nix` - Module options (enable, role, fish, zellij)

### Phase 3: Consolidate Fish Configuration ✓

- [x] Move functions to `shared/fish/functions.nix`
- [x] Create proper export mechanism (no string interpolation)
- [x] Update module to use shared config
- [x] Mark old `fish-config.nix` as deprecated shim

**New directory structure:**

```
modules/shared/fish/
├── default.nix      # Entry point, exports functions/aliases/abbreviations
├── functions.nix    # pingt, stress, helpfish, sourcefish, sourceenv
└── config.nix       # Aliases and abbreviations
```

### Phase 4: Test Suite Development 🧪

> **Philosophy:** Test BEFORE migration. Validate current behavior, then verify identical behavior after migration. Zero regressions, zero surprises.

#### 4.0 Existing Test Infrastructure ✅

You already have professional-grade tests in `hosts/<host>/tests/`:

**Phase I Hosts (All Updated with Uzumaki Tests):**

| Host          | Test Location                | Tests                                                                    |
| ------------- | ---------------------------- | ------------------------------------------------------------------------ |
| hsb0          | `hosts/hsb0/tests/`          | ✅ T00-T13 + T12-uzumaki-fish + T13-stasysmo + run-all-tests.sh          |
| hsb1          | `hosts/hsb1/tests/`          | ✅ T00-T03 + T02-uzumaki-fish + T03-stasysmo + run-all-tests.sh (PILOT)  |
| hsb8          | `hosts/hsb8/tests/`          | ✅ T00-T21 + T20-uzumaki-fish + T21-stasysmo + run-all-tests.sh          |
| gpc0          | `hosts/gpc0/tests/`          | ✅ T00-T11 (nixos-base, theme, fish, stasysmo, plasma, gaming) + run-all |
| imac0         | `hosts/imac0/tests/`         | ✅ T01-fish-shell (updated with uzumaki) + run-all-tests.sh              |
| imac-mba-work | `hosts/imac-mba-work/tests/` | ✅ T01-fish-shell (updated with uzumaki) + run-all-tests.sh              |

**Phase II Hosts (Deferred - OLD Mixins Structure):**

| Host | Test Location       | Existing Tests                        | Notes                     |
| ---- | ------------------- | ------------------------------------- | ------------------------- |
| csb0 | `hosts/csb0/tests/` | T00-T07 (nixos-base, docker, traefik) | Needs mixins→hokage first |
| csb1 | `hosts/csb1/tests/` | T00-T07 (nixos-base, docker, grafana) | Needs mixins→hokage first |

**Existing helper functions** (already in tests):

- `pass()` / `fail()` - Result reporting
- `check_file_exists()` - File presence check
- `check_file_contains()` - Pattern matching
- `check_unicode_python()` - Unicode verification (imac0)

#### 4.1 Audit Existing Tests (Uzumaki Coverage) ✓

Review which existing tests already cover uzumaki functionality:

**Theme Tests (T01-theme.sh)** - Already comprehensive! ✅

- [x] Starship config exists with correct palette
- [x] Zellij config exists with correct theme
- [x] Eza theme file exists
- [x] Unicode/Nerd Font icons preserved
- [x] EZA_CONFIG_DIR set in fish

**Fish Shell Tests** - Now Complete! ✅

- [x] Fish installed from Nix
- [x] Custom functions exist (`brewall`, `sourceenv`, `sourcefish`)
- [x] `pingt` function exists
- [x] `stress` function exists
- [x] `helpfish` function exists
- [x] Key abbreviations: ping→pingt, tmux→zellij

#### 4.2 New Tests Added ✓

**NixOS hosts** - Added uzumaki-specific tests:

- [x] hsb0: `T12-uzumaki-fish.sh`, `T13-stasysmo.sh`
- [x] hsb1: `T02-uzumaki-fish.sh`, `T03-stasysmo.sh` (PILOT HOST)
- [x] hsb8: `T20-uzumaki-fish.sh`, `T21-stasysmo.sh`
- [x] gpc0: Full test suite created (T00-T11)

**gpc0** - Created `hosts/gpc0/tests/`:

- [x] `T00-nixos-base.sh` - Base system checks
- [x] `T01-theme.sh` - Purple palette verification
- [x] `T02-uzumaki-fish.sh` - Fish functions
- [x] `T03-stasysmo.sh` - StaSysMo daemon
- [x] `T10-desktop-plasma.sh` - Plasma integration
- [x] `T11-gaming.sh` - Gaming packages

**macOS hosts** - Extended existing tests:

- [x] `imac0/T01-fish-shell.sh` - Added pingt, stress, helpfish checks
- [x] `imac-mba-work/T01-fish-shell.sh` - Added pingt, stress, helpfish checks

**All hosts** - Added `run-all-tests.sh` runner script

#### 4.3 Pre-Migration Baseline

**Baseline Collection Script:**

```bash
# From your workstation, run:
cd ~/nixcfg/tests
./collect-baselines.sh         # All Phase I hosts
./collect-baselines.sh hsb1    # Single host (pilot)
```

Results saved to: `tests/baselines/YYYYMMDD-<host>.log`

**Manual testing (per host):**

```bash
# SSH to host and run:
cd ~/nixcfg/hosts/<host>/tests
./run-all-tests.sh 2>&1 | tee baseline-$(date +%Y%m%d).log
```

**Baseline Matrix (Phase I Hosts):**

| Host          | T00 Base | T01 Theme | T02 Fish | T03 StaSysMo | Status      |
| ------------- | -------- | --------- | -------- | ------------ | ----------- |
| hsb0          | ⬜       | ⬜        | ⬜       | ⬜           | Pending     |
| hsb1          | ⏭️       | ✅ 27/27  | ❌ (exp) | ✅ 8/8       | ✅ Baseline |
| hsb8          | ⬜       | ⬜        | ⬜       | ⬜           | Pending     |
| gpc0          | ⬜       | ⬜        | ⬜       | ⬜           | Pending     |
| imac0         | ⬜       | ⬜        | ⬜       | ⬜           | Pending     |
| imac-mba-work | ⬜       | ⬜        | ⬜       | ⬜           | Pending     |

**hsb1 Baseline Notes (2024-12-04):**

- T00: Skipped (remote test, needs to run from workstation)
- T01: ✅ Theme system fully functional (green palette)
- T02: ❌ Expected failure - uzumaki module not yet applied, no fish functions
- T03: ✅ StaSysMo fully functional (daemon, files, starship integration)
- T03: ⚠️ Daemon runs, but output files missing (investigate)

**Baseline Matrix (Phase II Hosts - Deferred):**

| Host | T00 Base | T01 Theme | T02 Fish | T03 StaSysMo | Status            |
| ---- | -------- | --------- | -------- | ------------ | ----------------- |
| csb0 | ⏭️       | ⏭️        | ⏭️       | ⏭️           | Phase II (mixins) |
| csb1 | ⏭️       | ⏭️        | ⏭️       | ⏭️           | Phase II (mixins) |

**Legend:** ⬜ Pending | ✅ Pass | ❌ Fail | ⏭️ Skip/Deferred

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

### Phase 5: Migrate Hosts (Phase I)

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

**Migration Order (Phase I - Local Hosts):**

- [ ] **Pilot 1:** hsb1 (server) - Most stable, good test case
- [ ] **Pilot 2:** gpc0 (desktop) - Desktop-specific features
- [ ] **Pilot 3:** imac0 (workstation) - macOS validation
- [ ] **Rollout:** hsb0, hsb8, imac-mba-work

> ⚠️ **csb0/csb1 deferred to Phase II** - These cloud servers still use the old `modules/mixins/` structure and need a separate migration path (mixins → hokage first, then uzumaki).

### Phase 6: Cleanup (Phase I)

- [ ] Remove deprecated files:
  - [ ] `modules/uzumaki/server.nix` (merged into nixos.nix)
  - [ ] `modules/uzumaki/desktop.nix` (merged into nixos.nix)
  - [ ] `modules/uzumaki/macos.nix` (merged into darwin.nix)
  - [ ] `modules/uzumaki/macos-common.nix` (consolidated)
- [ ] Update all documentation
- [ ] Archive migration tests (keep validation tests)
- [ ] Update README.md in modules/uzumaki/
- [ ] Final test run on Phase I hosts

---

## Phase II: Cloud Servers (csb0/csb1) 🌐

> **Prerequisite:** Phase I complete. csb0/csb1 still use OLD `modules/mixins/` structure (not hokage).
> They import `../../modules/mixins/server-remote.nix`, `server-mba.nix`, `zellij.nix` directly.
> Migration requires: mixins → hokage consumer pattern, THEN uzumaki module.

### Phase 7: Mixins → Hokage Migration

- [ ] Audit csb0/csb1 current dependencies on `modules/mixins/`
- [ ] Create migration plan for each server
- [ ] Update csb0 to import from `github:pbek/nixcfg` (hokage consumer pattern)
- [ ] Update csb1 to import from `github:pbek/nixcfg` (hokage consumer pattern)
- [ ] Verify both servers build and deploy correctly
- [ ] Run existing test suites → all pass

### Phase 8: Migrate Hosts (Phase II)

- [ ] csb0: Apply uzumaki module (same procedure as Phase 5)
- [ ] csb1: Apply uzumaki module (same procedure as Phase 5)
- [ ] Run full test suites → all pass

### Phase 9: Final Cleanup

- [ ] Remove ALL deprecated files (including mixins if no longer needed)
- [ ] Complete documentation
- [ ] Final test run on ALL hosts
- [ ] Archive Phase II migration tests

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
