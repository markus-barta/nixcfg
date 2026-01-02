# P8400: imac0 - Homebrew Maintenance & Cleanup

**Status**: ⏳ Pending  
**Priority**: Medium  
**Owner**: SYSOP  
**Host**: imac0 (macOS)

## Context

Running `brew doctor` on `imac0` has revealed several deprecations, missing dependencies, and manual installation artifacts that need cleaning up to ensure system stability and clean builds.

## Tasks

- [ ] **Address Cask Deprecations**
  - [ ] Find replacement for `osxfuse` (likely `macfuse`)
  - [ ] Find replacement for `syntax-highlight`
- [ ] **Cleanup Kegs with no Formulae** (Manual/Deleted artifacts)
  - [ ] Replace `python-idna`
  - [ ] Replace `python-requests`
  - [ ] Replace `python-urllib3`
  - [ ] Replace `python-charset-normalizer`
- [ ] **Address Deprecated Formulae**
  - [ ] Find replacement for `icu4c@77`
- [ ] **Tap Maintenance**
  - [ ] Run `brew untap Homebrew/homebrew-services` (Deprecated official tap)
- [ ] **Library Cleanup**
  - [ ] Audit and potentially remove `/usr/local/lib/libndi.4.dylib` (Unbrewed dylib)
- [ ] **Fix Missing Dependencies**
  - [ ] Run `brew install python@3.12`

## Notes

- `imac0` is the primary local build host for the `nixcfg` repository. Keeping its base environment clean is essential for reproducible builds where homebrew is used.
- Be careful with `libndi` if it's being used by OBS or other NDI-related video software.
