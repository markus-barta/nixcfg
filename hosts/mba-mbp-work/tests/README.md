# mba-mbp-work Test Suite

Test procedures for validating the Work MacBook Pro (mba-mbp-work) configuration.

## Test Status

| ID  | Test              | Status   | Description              |
| --- | ----------------- | -------- | ------------------------ |
| T00 | Nix Base System   | ✅ Ready | Nix installation, flakes |
| T01 | Fish Shell        | ✅ Ready | Fish + uzumaki functions |
| T02 | Git Dual Identity | ⏳ TODO  | Personal/work git config |
| T03 | Theme (Starship)  | ⏳ TODO  | Starship prompt colors   |
| ~~T04~~ | ~~WezTerm Terminal~~ | REMOVED  | (purged 2026-05-05; Ghostty via Homebrew) |
| T05 | direnv + devenv   | ✅ Ready | Development environment  |
| T06 | CLI Tools         | ⏳ TODO  | Essential CLI tools      |
| ~~T07~~ | ~~GUI Apps~~  | REMOVED  | (was WezTerm Spotlight alias check; purged 2026-05-05) |

## Running Tests

```bash
# Run all tests
./run-all-tests.sh

# Run specific test
./T00-nix-base.sh
./T01-fish-shell.sh
./T05-direnv.sh
# T07-gui-apps.sh removed 2026-05-05 (was WezTerm-specific)
```

## Key Tests for This Host

### T05: direnv + devenv Chain

Tests the critical chain for nixcfg development:

```
direnv → .envrc → devenv → devenv.yaml → .shared/common.just → justfile
```

If `just` fails with "Could not find source file", this chain is broken.

### ~~T07: GUI Apps~~ (REMOVED 2026-05-05)

Was the WezTerm Spotlight-alias-vs-symlink test. WezTerm purged from the fleet
2026-05-05; Ghostty (its replacement) is installed via Homebrew, not Nix, so
no HM-side aliasing is needed for it.

## Quick Validation

```bash
# Essential checks
fish --version                    # Fish from Nix?
which devenv                      # devenv installed?
hostcolors                        # uzumaki function works?
just --list                       # justfile imports work?
```

## Adding Tests

Copy test templates from `hosts/imac0/tests/` and adapt as needed.
