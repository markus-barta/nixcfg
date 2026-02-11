# homebrew-maintenance

**Host**: imac0
**Priority**: P84
**Status**: Pending
**Created**: 2026-01-13

---

## Problem

`brew doctor` reveals deprecations, missing dependencies, and manual installation artifacts. Need cleanup for system stability and clean builds.

## Solution

Address cask/formula deprecations, cleanup kegs with no formulae, fix missing dependencies, and remove unbrewed libraries.

## Implementation

- [ ] Replace deprecated casks:
  - [ ] `osxfuse` → `macfuse`
  - [ ] `syntax-highlight` → find replacement
- [ ] Cleanup kegs with no formulae (manual/deleted artifacts):
  - [ ] Replace `python-idna`
  - [ ] Replace `python-requests`
  - [ ] Replace `python-urllib3`
  - [ ] Replace `python-charset-normalizer`
- [ ] Replace deprecated formulae:
  - [ ] `icu4c@77` → find replacement
- [ ] Tap maintenance:
  - [ ] Untap deprecated: `brew untap Homebrew/homebrew-services`
- [ ] Library cleanup:
  - [ ] Audit `/usr/local/lib/libndi.4.dylib` (check OBS/NDI usage first)
- [ ] Fix missing dependencies:
  - [ ] Install `python@3.12`
- [ ] Run `brew doctor` to verify all issues resolved

## Acceptance Criteria

- [ ] All deprecated casks replaced
- [ ] No kegs without formulae
- [ ] Deprecated formulae replaced
- [ ] Deprecated taps removed
- [ ] Unbrewed libraries audited/removed
- [ ] Missing dependencies installed
- [ ] `brew doctor` reports clean

## Notes

- imac0 is primary local build host for nixcfg
- Keep base environment clean for reproducible builds
- **Warning**: Check if `libndi` used by OBS before removing
