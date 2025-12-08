# T05: direnv + devenv

Test direnv and devenv integration for nixcfg development environment.

## The Chain

```
┌─────────────────────────────────────────────────────────────────┐
│  THE CHAIN: How .shared/common.just gets created                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. You enter ~/Code/nixcfg                                     │
│           │                                                     │
│           ▼                                                     │
│  2. direnv detects .envrc                                       │
│           │                                                     │
│           ▼                                                     │
│  3. .envrc runs: eval "$(devenv direnvrc)" && use devenv        │
│           │                                                     │
│           ▼                                                     │
│  4. devenv reads devenv.yaml                                    │
│           │                                                     │
│           ▼                                                     │
│  5. devenv.yaml imports: shared/common (from github:pbek/...)   │
│           │                                                     │
│           ▼                                                     │
│  6. Creates .shared/common.just symlink → Nix store             │
│           │                                                     │
│           ▼                                                     │
│  7. justfile can now: import ".shared/common.just"              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- `direnv` installed via home-manager (`programs.direnv.enable = true`)
- `devenv` installed via home.packages (CRITICAL!)
- `just` installed via home.packages

## Manual Test Procedures

### Test 1: direnv Installed

```bash
which direnv
direnv version
```

**Expected:** Path contains `.nix-profile` or `/nix/store`

### Test 2: devenv Installed (CRITICAL!)

```bash
which devenv
devenv version
```

**Expected:** devenv is available

**If missing:** The chain breaks! `.envrc` will fail with `devenv: command not found`

### Test 3: .envrc Works

```bash
cd ~/Code/nixcfg
direnv allow
# Wait for devenv to initialize (first time is slow)
```

**Expected:** See "🛠️ nixcfg macOS" message

### Test 4: .shared/common.just Created

```bash
ls -la ~/Code/nixcfg/.shared/common.just
```

**Expected:** Symlink to `/nix/store/...-shared-common.just`

### Test 5: just Works

```bash
cd ~/Code/nixcfg
just --list
```

**Expected:** Shows available recipes (sw, check, audit, etc.)

## Troubleshooting

**`devenv: command not found`:**

- Add `devenv` to `home.packages` in home.nix
- Run `home-manager switch`

**`Could not find source file for import`:**

- devenv wasn't installed when .envrc ran
- Fix: `direnv allow` after installing devenv

**First time is slow:**

- devenv downloads dependencies from GitHub
- Creates `.shared/` directory
- Subsequent runs are fast (cached)

## Summary

- Total Tests: 6
- Critical: devenv must be installed for the chain to work

## Related

- Chain documentation: `docs/MACOS-SETUP.md` section 5.3
- Config: `devenv.yaml`, `.envrc`
- Automated: [T05-direnv.sh](./T05-direnv.sh)
